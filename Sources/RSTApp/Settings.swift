import AppKit
import RSTCore

/// **Every setting that exists, in one window, behind the PIN** — T17.
///
/// The point of the window is stated in the task doc and worth repeating here: *expose all
/// of them.* A hidden setting is one someone eventually edits in `config.json` by hand, and
/// a hand-edited config is how a config becomes corrupt — which the app then quarantines and
/// replaces with shipped defaults, silently undoing whatever they were trying to do.
///
/// **English, by DESIGN §2.4.2's one rule**: if a string can appear without anyone typing
/// the PIN it is Polish, and nothing here can. Every string below is therefore a literal
/// rather than an entry in `Strings.swift`, which stays Polish-only. The one Polish string
/// on this path is the PIN prompt that opens the window, and it is already in that file.
///
/// What is a *rule* is in ``SettingsDraft``, ``MinuteList`` and ``PINChangeFlow`` over in
/// `RSTCore`, where `make test` can reach it. This file is the window.
///
/// **AppKit, not SwiftUI**, which is where it departs from DESIGN §3.2's module table. The
/// table's `SettingsView.swift | SwiftUI settings window` was written before any UI existed;
/// since then the cover (T11), the PIN prompt (T13) and the wizard (T16) have all been
/// hand-rolled AppKit and reviewed as such. Two reasons beyond consistency: the PIN change
/// below reuses ``PINBoxes`` — an `NSView`, which SwiftUI reaches only through a wrapper —
/// and the activation-policy dance in ``takeDockIcon()`` is AppKit either way. See the
/// 2026-08-27 finding.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    /// Everything the window needs from the rest of the app, as closures. It owns no state
    /// but the draft on the screen: the config, the store, the engine and the tick are all
    /// `main.swift`'s, exactly as they are for the wizard.
    struct Host {
        /// Read at every use rather than captured once — a PIN changed in this window is
        /// the one the next check has to use.
        let config: () -> Config
        /// Whether a session is running right now. Only used for the note under the session
        /// length field — see ``sessionNote``.
        let sessionRunning: () -> Bool
        /// Write the settings. `nil` on success, a message to put on the screen otherwise.
        let saveSettings: (SettingsDraft) -> String?
        /// Write a new PIN, already hashed. Same convention.
        let savePIN: (String, Data) -> String?
        let eventsURL: URL
        let dataDirectory: URL
        /// Remove the login item, optionally the data, and quit. Never returns in practice.
        let uninstall: (Bool) -> Void
        /// Run the whole §2.3 update flow and report what it did. On ``Updater/Outcome/updating``
        /// the app relaunches inside this closure and it never returns; every other outcome comes
        /// back for the window to show. Async because it fetches, downloads and installs.
        let update: () async -> Updater.Outcome
        /// The cover is up. The window can be open underneath one — a session can expire
        /// while a parent is reading it — and the activation policy is then the kiosk's.
        let isCovering: () -> Bool

        // MARK: Remote pairing (DESIGN §2.4, T06)

        /// The live pairing state for the status line. Read on open, after a pair or unpair, and
        /// on every ``refreshPairingStatus()`` tick — so a token rejected by the poller (T04)
        /// while this window sits open flips the line to "re-pair" without a reopen.
        let remotePairingStatus: () -> PairingStatus
        /// Redeem a typed pairing code. `nil` on success; the ``RemoteClientError`` otherwise,
        /// which the window turns into an English sentence. Async because it is a network
        /// round-trip — the window kicks it off and does not block (Settings is not modal).
        let pairRemote: (String) async -> RemoteClientError?
        /// Disconnect this Mac locally — clear the stored token and endpoint (DESIGN §2.4).
        let unpairRemote: () -> Void
    }

    /// The one on screen, if any. Static because the menu item can be chosen again while a
    /// window is already up, and it is also what keeps this object alive.
    private static var showing: SettingsWindow?

    private let window: NSWindow
    private let host: Host
    private let clock: any Clock
    private let diagnostics: Diagnostics

    /// What is being edited. Seeded from the config when the window opens and read back out
    /// of the fields on every save — the fields are the truth while the window is up.
    private var draft: SettingsDraft

    // MARK: - The controls

    /// The three numbers and the day-start hour are combo boxes and a pop-up now (CR-01 §5),
    /// the same controls the wizard's step 3 uses — session length and the hour suggest a few
    /// values while any number stays typeable, and sessions-per-day is a pop-up that cannot
    /// express a wrong value. Detection reads in whole minutes through two more combos (§2.7);
    /// grants and warnings are token fields (§2.6). After all of this the only inputs that can
    /// still raise a complaint are the four combo boxes.
    private let sessionMinutesCombo = SettingsWindow.combo(width: 80)
    private let sessionsPerDayPopUp = NSPopUpButton()
    private let dayResetHourCombo = SettingsWindow.combo(width: 80)
    private let grantsField = SettingsWindow.tokenField()
    private let idleGraceCombo = SettingsWindow.combo(width: 80)
    private let mediaGraceCombo = SettingsWindow.combo(width: 80)
    private let warningsField = SettingsWindow.tokenField()

    /// The two token-field rules (CR-01 §6). Held so they stay alive as the fields' delegates,
    /// and separate instances because the two lists are not the same shape: grants keeps at
    /// least one token, warnings may be emptied.
    private let grantsDelegate = NumberTokenFieldDelegate(
        suggestions: [5, 10, 15, 20, 30, 45, 60, 90], keepAtLeastOne: true)
    private let warningsDelegate = NumberTokenFieldDelegate(
        suggestions: [1, 2, 3, 5, 10, 15, 20, 30], keepAtLeastOne: false)

    /// The value the sessions-per-day pop-up was built from, captured when the window fills.
    /// The pop-up's rows never change after that, so a chosen index must always be resolved
    /// against this same value — not the mutating draft — or the index-to-value mapping could
    /// drift from the rows actually on screen (an out-of-range stored value adds a trailing row).
    private var originalSessionsPerDay = 0

    /// Where a ``SettingsProblem`` puts the keyboard — the box that caused it. The
    /// sessions-per-day pop-up is deliberately absent: it cannot produce an invalid value, so
    /// no complaint ever needs to focus it.
    private lazy var focusTargets: [SettingsField: NSView] = [
        .sessionMinutes: sessionMinutesCombo,
        .dayResetHour: dayResetHourCombo,
        .extensionOptions: grantsField,
        .idleGraceSeconds: idleGraceCombo,
        .mediaGraceSeconds: mediaGraceCombo,
        .warningMinutes: warningsField,
    ]

    private let noteLabel = SettingsWindow.label(size: 12, weight: .regular)
    private let pinStatusLabel = SettingsWindow.label(size: 12, weight: .regular)
    private let saveButton = NSButton()

    /// The version line and the Update button (DESIGN §2.3, T04). The version is the single
    /// source of truth in `RSTCore` (T01), never the plist. The button is disabled while an
    /// update is in flight so a second press cannot start a second download; ``updateStatusLabel``
    /// carries the outcome in English beside it.
    private let versionValueLabel = SettingsWindow.label(size: 13, weight: .regular)
    private let updateButton = NSButton()
    private let updateStatusLabel = SettingsWindow.label(size: 12, weight: .regular)

    /// The remote-pairing controls (DESIGN §2.4, T06). The status line reads the three
    /// ``PairingStatus`` states; the code field and `Pair` redeem a code; `Unpair` clears a
    /// stored token and is enabled only when paired; the note carries the outcome in English.
    private let pairingStatusValueLabel = SettingsWindow.label(size: 13, weight: .regular)
    private let pairingCodeField = NSTextField()
    private let pairButton = NSButton()
    private let unpairButton = NSButton()
    /// The whole "Pairing code" row — label, field and `Pair`. Hidden as one unit, so a paired Mac
    /// shows no orphaned "Pairing code" label beside an empty gap (2026-09-23).
    private var pairingCodeRow: NSView?
    private let pairingNoteLabel = SettingsWindow.label(size: 12, weight: .regular)

    /// Refreshes the status line once a second while the window is up, so a 401 the poller (T04)
    /// raises against an open Settings window shows as "re-pair" without a reopen. Started only on
    /// the presenting path; a headed test drives ``refreshPairingStatus()`` directly instead
    /// (DESIGN §3.1). Invalidated on close.
    private var pairingStatusTimer: Timer?

    // MARK: - Presenting

    /// Put the window on the screen. A second call while one is up brings the first forward
    /// rather than opening another.
    ///
    /// **The PIN is checked before this is called**, not inside it (T13's prompt, with
    /// ``PINAction/settings``). One prompt, one window: a window that asked for the PIN
    /// itself would be a second PIN path to keep in step with the first.
    static func present(host: Host, clock: any Clock, diagnostics: Diagnostics) {
        if let showing {
            showing.window.makeKeyAndOrderFront(nil)
            showing.window.orderFrontRegardless()
            NSApp.activate()
            return
        }
        showing = SettingsWindow(host: host, clock: clock, diagnostics: diagnostics)
    }

    static var isShowing: Bool { showing != nil }

    // MARK: - Tier 1 seam (DESIGN §3.1, T05)

    /// **Build the window off-screen for the headed suite** — the entry point that passes
    /// `present: false` (see the note on ``init(host:clock:diagnostics:present:)``). It does not
    /// register in ``showing`` and takes no Dock icon, so the caller owns the returned object's
    /// lifetime and nothing is ever ordered onto a display. `present`'s path is untouched.
    static func buildForTesting(host: Host, clock: any Clock,
                                diagnostics: Diagnostics = .discarded) -> SettingsWindow {
        SettingsWindow(host: host, clock: clock, diagnostics: diagnostics, present: false)
    }

    /// **Read access for the headed suite, and only that** — the same additive, read-only
    /// reach the menu bar exposes (T04). Every control the window builds is `private`, which
    /// `@testable` does not open, so a Tier 1 test cannot otherwise see what ``fill()`` put on
    /// screen or drive ``savePressed()`` through the real button. These three are the whole of
    /// it; the app calls none of them and its behaviour is unchanged.
    ///
    /// The controls are keyed by ``SettingsField`` — ``focusTargets`` plus the pop-up, which
    /// has no focus target because it cannot hold an invalid value.
    var testControls: [SettingsField: NSView] {
        focusTargets.merging([.selfServiceSessionsPerDay: sessionsPerDayPopUp]) { existing, _ in existing }
    }
    var testSaveButton: NSButton { saveButton }
    var testWindow: NSWindow { window }

    /// **Read access to the pairing controls for the headed suite, and only that** (DESIGN §3.1,
    /// T06). Same additive, read-only reach as the controls above. ``testPair()`` runs the exact
    /// async work the `Pair` button kicks off — validate, call the host, render, refresh — so a
    /// synchronous headed test can `await` it and assert the outcome without pumping a run loop.
    var testPairingStatusLabel: NSTextField { pairingStatusValueLabel }
    var testPairingCodeField: NSTextField { pairingCodeField }
    var testPairButton: NSButton { pairButton }
    var testUnpairButton: NSButton { unpairButton }
    var testPairingCodeRow: NSView? { pairingCodeRow }
    var testPairingNoteLabel: NSTextField { pairingNoteLabel }
    func testRefreshPairingStatus() { refreshPairingStatus() }
    func testPair() async { await performPair() }

    /// `present: false` is the **build-but-do-not-show seam** (DESIGN §3.1, T05): it builds the
    /// window, its controls and fills them from the config, but runs none of the presenting
    /// tail — no `center`, no ``takeDockIcon()`` (so the activation policy stays non-`.regular`),
    /// no ordering. A headed test builds one through ``buildForTesting(host:clock:diagnostics:)``,
    /// queries and drives its controls, and tears it down without a window reaching a display.
    /// `present`'s own path passes the default `true`, so the shipping behaviour is unchanged.
    private init(host: Host, clock: any Clock, diagnostics: Diagnostics, present: Bool = true) {
        self.host = host
        self.clock = clock
        self.diagnostics = diagnostics
        self.draft = SettingsDraft(host.config())
        // **A fixed dialog, not a document window.** No `.resizable`, so there is no resize
        // handle and no green fullscreen button — a settings dialog a parent could send
        // fullscreen or stretch was reading as an app in its own right rather than a box to fill
        // in and dismiss. Wide enough (670) that the sessions-per-day row's "per day" suffix
        // clears the pop-up, which is as wide as "None — every session needs your PIN".
        //
        // **Not a true app-modal `runModal`.** That would run a modal event loop that does not
        // include `.common`, and the engine tick lives on `.common` (AppController) precisely so
        // it survives an open menu — a blocking modal would stop it, and the cover would fail to
        // appear if a session expired while this window sat open. The window is centred, front
        // and non-resizable instead, which is the "modal" feel without the safety hole.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 700),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "Real Screen Time — Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        // The size is locked (no `.resizable`), so tall content on a short screen stays reachable
        // through the scroll view below rather than by resizing the window.
        buildContent()
        fill()

        // The presenting tail, skipped by the seam (see the `present` note on `init`). Made
        // conditional rather than an early `return`, per CLAUDE.md — it is all and only the
        // calls that touch a display or the app-global activation policy.
        if present {
            window.center()
            takeDockIcon()
            NSApp.activate()

            // Keep the pairing status line live while the window is up (T06). Only on the
            // presenting path: a headed test builds through the seam and drives the refresh by
            // hand, so no `Timer` runs under `make test`.
            startPairingStatusTimer()

            // **Three lines rather than one, because a window that does not appear is otherwise
            // completely silent.** `NSApplication` swallows an exception raised inside an event
            // handler (T00) and keeps its run loop going, so a failure anywhere in here leaves an
            // app that is alive, has taken a Dock icon, and shows nothing — which is exactly what
            // was seen by hand on 2026-08-27. These say which step was the last one reached.
            diagnostics("settings: window built, ordering front", at: clock.now)
            window.makeKeyAndOrderFront(nil)
            // **After `makeKeyAndOrderFront`, not instead of it** — the wizard's finding of
            // 2026-08-26: an order-front from an app the system has decided is not active can be
            // dropped, and this one cannot.
            window.orderFrontRegardless()

            diagnostics("settings: opened, visible=\(window.isVisible), "
                        + "frame=\(Int(window.frame.width))x\(Int(window.frame.height))"
                        + "+\(Int(window.frame.minX))+\(Int(window.frame.minY))", at: clock.now)
        }
    }

    /// **A real window needs a real app.** `Info.plist` sets `LSUIElement`, so the app runs
    /// `.accessory` and a window it opens can come up empty or never appear at all — verified
    /// on the installed `.app` with the wizard on 2026-08-26, and there is no reason this
    /// window would be treated differently.
    ///
    /// **Only when nothing is covering.** `KioskLock` owns the activation policy while the
    /// cover is up (T12); putting it back to `.accessory` underneath one would drop the
    /// presentation options that hold the kiosk together. A session can expire while this
    /// window is open, so the guard is real on the way out as well as in.
    private func takeDockIcon() {
        guard !host.isCovering() else { return }
        NSApp.setActivationPolicy(.regular)
    }

    private func restoreDockIcon() {
        guard !host.isCovering() else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Layout

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func add(_ views: [NSView]) { views.forEach(stack.addArrangedSubview) }

        add([Self.sectionTitle("Version")])
        versionValueLabel.stringValue = AppVersion.current
        updateButton.title = "Update…"
        updateButton.bezelStyle = .rounded
        updateButton.target = self
        updateButton.action = #selector(updatePressed)
        updateButton.keyEquivalent = ""          // Return belongs to Save; never a held key
        updateStatusLabel.textColor = .secondaryLabelColor
        add([field(versionValueLabel, "This copy is version", ""),
             buttonRow([updateButton]),
             updateStatusLabel,
             Self.note("""
                 Checks GitHub for a newer release and, if there is one, installs it after your \
                 admin password — keeping this build as a backup. Nothing is checked in the \
                 background; this button is the only time it looks.
                 """)])

        add([Self.sectionTitle("Sessions")])
        add([field(sessionMinutesCombo, "Session length", "minutes"),
             sessionNote,
             field(sessionsPerDayPopUp, "Sessions he can start himself", "per day"),
             field(dayResetHourCombo, "The day starts at", "o'clock"),
             Self.note("""
                 The day's sessions come back at the hour above.
                 """)])

        add([Self.sectionTitle("Grants")])
        add([field(grantsField, "Amounts offered by “Dodaj minuty…”", "minutes"),
             Self.note("""
                 In the order you want them offered — the first one is pre-selected, so putting \
                 your usual amount first makes it one keystroke. There is no upper limit and the \
                 list may not be empty.
                 """)])

        add([Self.sectionTitle("Detection")])
        add([field(idleGraceCombo, "Pause the clock after", "minutes idle"),
             field(mediaGraceCombo, "…or, with something playing, after", "minutes idle"),
             Self.note("""
                 Time only counts while he is actually there. Nothing playing and no typing \
                 or clicking for the first number, and the clock stops; something playing and \
                 it waits for the second instead, which is what stops a film from looking \
                 like an empty room. A locked screen or another user logged in counts for \
                 nothing at all, with no wait.
                 """)])

        add([Self.sectionTitle("Warnings")])
        add([field(warningsField, "Warn when this much is left", "minutes"),
             Self.note("""
                 Spoken and shown, once each, on the way down. Order does not matter and repeats \
                 are dropped; leave it empty for no warnings at all — the countdown stays in the \
                 menu bar either way.
                 """)])

        add([Self.sectionTitle("Security")])
        add([buttonRow([button("Change PIN…", #selector(changePINPressed))]),
             pinStatusLabel])

        // **Remote grants** (DESIGN §2.4). The parent types only the pairing code the web app
        // shows — the endpoint is fixed at bundle time (`RemoteClient.productionEndpoint`), not a URL
        // to copy, because one family has one deployed backend (§8). Status, a code field with
        // `Pair`, and `Unpair` (live only when paired).
        add([Self.sectionTitle("Remote grants")])
        pairingCodeField.placeholderString = "Pairing code"
        pairingCodeField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        pairButton.title = "Pair"
        pairButton.bezelStyle = .rounded
        pairButton.target = self
        pairButton.action = #selector(pairPressed)
        pairButton.keyEquivalent = ""             // Return belongs to Save
        unpairButton.title = "Unpair"
        unpairButton.bezelStyle = .rounded
        unpairButton.target = self
        unpairButton.action = #selector(unpairPressed)
        unpairButton.keyEquivalent = ""
        pairingNoteLabel.textColor = .secondaryLabelColor
        let codeRow = NSStackView(views: [pairingCodeField, pairButton])
        codeRow.orientation = .horizontal
        codeRow.spacing = 8
        let codeEntryRow = field(codeRow, "Pairing code", "")
        pairingCodeRow = codeEntryRow
        add([field(pairingStatusValueLabel, "Status", ""),
             codeEntryRow,
             buttonRow([unpairButton]),
             pairingNoteLabel,
             Self.note("""
                 Sign in to the web app, ask it for a pairing code, and type it here. Pairing lets \
                 you add minutes from your phone; it never covers the screen. Pairing again on \
                 another Mac disconnects this one — it will then show “re-pair”. Unpair disconnects \
                 this Mac now.
                 """)])

        add([Self.sectionTitle("Maintenance")])
        add([buttonRow([button("Reveal the event log", #selector(revealLog)),
                        button("Reveal the data folder", #selector(revealFolder))]),
             Self.note("""
                 The log is the report: one line per thing the app did, in English, readable \
                 with any text editor or with `jq`.
                 """),
             buttonRow([button("Uninstall…", #selector(uninstallPressed))])])

        pinStatusLabel.textColor = .secondaryLabelColor
        noteLabel.textColor = .systemOrange

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        // **Or the constraints below fight an autoresizing frame of zero.** A scroll view's
        // document view is positioned by the clip view, and one still translating its
        // autoresizing mask arrives with `frame == .zero` and a mask that keeps insisting on
        // it — against a stack pinned to all four of its edges. AppKit resolves that by
        // breaking constraints, and what it breaks is not predictable from here.
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.documentView = document

        // The footer stays put while the settings scroll: `Save` is the one control that
        // must never be somewhere a parent has to hunt for it.
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.keyEquivalent = "\r"

        let close = button("Close", #selector(closePressed))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [noteLabel, spacer, close, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 28, bottom: 16, right: 28)
        footer.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        window.contentView = container
    }

    /// **What a change to the session length actually does to a session already running:
    /// nothing** — and saying so is the whole of this label.
    ///
    /// The task doc expects the opposite ("shortening it below what a running session has
    /// already consumed means the cover appears immediately") and the ledger does not work
    /// that way: `session_minutes` seeds a *new* session (`SessionState.fullSession`) and a
    /// running one carries its own `remaining_seconds`, untouched by the config. Making the
    /// doc's version true would mean changing T04's ledger, which is not this task's to do.
    ///
    /// So the surprise the doc is guarding against is headed off by saying what will happen
    /// instead of by warning about what will not. See `PROGRESS.md` and the report.
    private lazy var sessionNote = Self.note("")

    private func updateSessionNote() {
        sessionNote.stringValue = host.sessionRunning()
            ? "A session is running. A new length applies to the next session he starts — "
              + "the one on the clock now keeps the minutes it was given."
            : ""
        sessionNote.isHidden = sessionNote.stringValue.isEmpty
    }

    // MARK: - Filling and reading

    /// Put the config on the screen. Called once, when the window opens.
    ///
    /// **Detection is shown in minutes** (`GraceMinutes.toMinutes`), while the two token fields
    /// take an array of number strings — one pill each — rather than a comma-joined line.
    private func fill() {
        configureControls()
        sessionMinutesCombo.stringValue = String(draft.sessionMinutes)
        dayResetHourCombo.stringValue = String(draft.dayResetHour)
        idleGraceCombo.stringValue = String(GraceMinutes.toMinutes(seconds: draft.idleGraceSeconds))
        mediaGraceCombo.stringValue = String(GraceMinutes.toMinutes(seconds: draft.mediaGraceSeconds))
        grantsField.objectValue = draft.extensionOptions.map(String.init)
        warningsField.objectValue = draft.warningMinutes.map(String.init)

        updatePINStatus()
        updateSessionNote()
        refreshPairingStatus()
    }

    /// Fill the combo boxes' suggestion lists and the pop-up's rows from the draft, showing a
    /// stored value outside a control's list rather than clamping it (DESIGN §2.2, §2.7). The
    /// lists, the merge rule and the pop-up's mapping are all `RSTCore`'s; this only paints them.
    ///
    /// The grace combos suggest and merge on **minutes**, so a stored `420` seconds shows and
    /// merges as `7`, not `420` — the conversion happens before the merge.
    private func configureControls() {
        func fillCombo(_ combo: NSComboBox, _ suggestions: [Int], stored: Int) {
            combo.removeAllItems()
            combo.addItems(withObjectValues:
                ComboSuggestions.merged(suggestions, storedValue: stored).map(String.init))
            // Any number stays typeable; no autocomplete narrowing it to the suggestions.
            combo.completes = false
        }
        fillCombo(sessionMinutesCombo, ComboSuggestions.sessionLength, stored: draft.sessionMinutes)
        fillCombo(dayResetHourCombo, ComboSuggestions.dayStartHour, stored: draft.dayResetHour)
        fillCombo(idleGraceCombo, ComboSuggestions.idleGraceMinutes,
                  stored: GraceMinutes.toMinutes(seconds: draft.idleGraceSeconds))
        fillCombo(mediaGraceCombo, ComboSuggestions.mediaGraceMinutes,
                  stored: GraceMinutes.toMinutes(seconds: draft.mediaGraceSeconds))

        grantsField.delegate = grantsDelegate
        warningsField.delegate = warningsDelegate

        // Captured once — see ``originalSessionsPerDay``. The row labels are unique by
        // construction (None, 1…4, and any appended value is outside 0…4), so the pop-up's
        // dedup-by-title never drops one.
        originalSessionsPerDay = draft.selfServiceSessionsPerDay
        sessionsPerDayPopUp.removeAllItems()
        sessionsPerDayPopUp.addItems(withTitles:
            SessionsPerDayChoice.items(storedValue: originalSessionsPerDay).map(Self.sessionsLabel))
        sessionsPerDayPopUp.selectItem(at:
            SessionsPerDayChoice.selectedIndex(storedValue: originalSessionsPerDay))
    }

    /// The English label for a pop-up row — Settings is parent-side (DESIGN §2.4.2's exception),
    /// so only the value and case come from `RSTCore`. The same text the wizard uses (T01), so
    /// the two windows read identically.
    private static func sessionsLabel(_ item: SessionsItem) -> String {
        if item.isNoneCase { return "None — every session needs your PIN" }
        return item.value == 1 ? "1 session" : "\(item.value) sessions"
    }

    /// **Only this line, never the whole form.** Called again after a PIN change, and a
    /// `fill()` there would throw away whatever numbers the parent had half typed before
    /// they went to change it.
    private func updatePINStatus() {
        pinStatusLabel.stringValue = host.config().isConfigured
            ? "A PIN is set. Changing it asks for the current one first."
            : "No PIN is set — the app is not covering anything until one is (see setup)."
    }

    /// Read the seven fields back, or `nil` with the reason already on the screen and the
    /// keyboard in the box that caused it.
    ///
    /// **Every rule is `RSTCore`'s** (``SettingsDraft/problem``). This function does the two
    /// things that cannot live there: turning text into numbers, and turning a problem into
    /// an English sentence.
    private func readDraft() -> SettingsDraft? {
        var problem: SettingsProblem?
        // In field order, so the first complaint is the topmost one — the same order
        // `SettingsDraft.problem` reports its own in.
        func flag(_ p: SettingsProblem) { if problem == nil { problem = p } }

        // A combo box's free text can still fail to parse; the pop-up and the token fields
        // cannot express a non-number, but the tokens are re-checked anyway (the delegate is the
        // rule, not the guarantee).
        func combo(_ box: NSComboBox, _ field: SettingsField) -> Int? {
            guard let value = Int(box.stringValue.trimmingCharacters(in: .whitespaces)) else {
                flag(.notANumber(field)); return nil
            }
            return value
        }
        func tokens(_ tokenField: NSTokenField, _ field: SettingsField) -> [Int]? {
            let strings = (tokenField.objectValue as? [Any])?.map { "\($0)" } ?? []
            var values: [Int] = []
            for string in strings {
                guard let value = Int(string.trimmingCharacters(in: .whitespaces)) else {
                    flag(.notANumber(field)); return nil
                }
                values.append(value)
            }
            return values
        }

        let minutes = combo(sessionMinutesCombo, .sessionMinutes)
        // The pop-up resolves against the value its rows were built from, never the mutating
        // draft — see ``originalSessionsPerDay``. It can only yield a whole number.
        let sessions = SessionsPerDayChoice.value(atIndex: sessionsPerDayPopUp.indexOfSelectedItem,
                                                  storedValue: originalSessionsPerDay)
        let hour = combo(dayResetHourCombo, .dayResetHour)
        let grants = tokens(grantsField, .extensionOptions)
        // Detection is typed in minutes and stored in seconds (§2.7); the conversion is a rule
        // (`GraceMinutes`), tested in both directions including the rounding.
        let idleMinutes = combo(idleGraceCombo, .idleGraceSeconds)
        let mediaMinutes = combo(mediaGraceCombo, .mediaGraceSeconds)
        let warnings = tokens(warningsField, .warningMinutes)

        if let problem { return refuse(problem) }
        guard let minutes, let hour, let grants, let idleMinutes, let mediaMinutes, let warnings
        else { return refuse(.notANumber(.sessionMinutes)) }

        let typed = SettingsDraft(sessionMinutes: minutes,
                                  selfServiceSessionsPerDay: sessions,
                                  dayResetHour: hour,
                                  idleGraceSeconds: GraceMinutes.toSeconds(minutes: idleMinutes),
                                  mediaGraceSeconds: GraceMinutes.toSeconds(minutes: mediaMinutes),
                                  warningMinutes: warnings,
                                  extensionOptions: grants)
        if let problem = typed.problem { return refuse(problem) }
        return typed
    }

    private func refuse(_ problem: SettingsProblem) -> SettingsDraft? {
        complain(Self.message(for: problem))
        if let field = focusTargets[problem.field] {
            window.makeFirstResponder(field)
        }
        return nil
    }

    /// The complaint, in English, and never in the shape of a telling-off.
    private static func message(for problem: SettingsProblem) -> String {
        switch problem {
        case .notANumber(let field):
            switch field {
            case .extensionOptions, .warningMinutes:
                return "\(name(field)): whole numbers separated by commas."
            default:
                return "\(name(field)) needs a whole number."
            }
        case .sessionTooShort:
            return "A session has to be at least one minute long."
        case .negativeSessions:
            return "Sessions per day cannot be negative. Zero is allowed, and means every "
                + "session needs your PIN."
        case .resetHourOutOfRange:
            return "The day starts at an hour between 0 and 23."
        case .negativeGrace(let field):
            return "\(name(field)) cannot be negative. Zero is allowed."
        case .noGrants:
            return "There has to be at least one amount to offer — otherwise “Dodaj minuty…” "
                + "asks for your PIN and can then grant nothing."
        case .notPositive(let field):
            return "\(name(field)): every number has to be more than zero."
        case .duplicate(_, let value):
            return "\(value) is in the list twice."
        }
    }

    private static func name(_ field: SettingsField) -> String {
        switch field {
        case .sessionMinutes:             return "Session length"
        case .selfServiceSessionsPerDay:  return "Sessions he can start himself"
        case .dayResetHour:               return "The hour the day starts at"
        case .extensionOptions:           return "The grant amounts"
        case .idleGraceSeconds:           return "The idle pause"
        case .mediaGraceSeconds:          return "The pause with something playing"
        case .warningMinutes:             return "The warning thresholds"
        }
    }

    private func complain(_ text: String) {
        noteLabel.stringValue = text
        noteLabel.textColor = .systemOrange
    }

    private func report(_ text: String) {
        noteLabel.stringValue = text
        noteLabel.textColor = .secondaryLabelColor
    }

    // MARK: - Buttons

    /// **A key held down delivers repeats, and a repeat must never press a button twice.**
    /// T16's finding, including the part that cost a hand run: `NSEvent.isARepeat` raises on
    /// anything that is not a key event, so the type has to be checked first or a *mouse*
    /// click throws an exception `NSApplication` swallows — leaving a button that silently
    /// does nothing.
    private var isKeyRepeat: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .keyDown, .keyUp: return event.isARepeat
        default: return false
        }
    }

    @objc private func savePressed() {
        guard !isKeyRepeat, let typed = readDraft() else { return }
        // A session can start or end while the window sits open, and the note under the
        // length field is a claim about *now* — so it is re-read here rather than left as
        // whatever was true when the window opened (T17 review).
        updateSessionNote()
        draft = typed
        if let failure = host.saveSettings(typed) {
            complain(failure)
            return
        }
        // §2.8: the window closing **is** the confirmation. No "Saved" label — the old one was
        // there because a Save that leaves an unchanged-looking window open is a Save a parent
        // presses again; closing removes the doubt without a line to read. Nothing to apply or
        // restart either: `Engine` re-reads its config every tick, so the next one already uses
        // this. A validation failure above keeps the window open with the reason instead.
        close()
    }

    @objc private func closePressed() {
        guard !isKeyRepeat else { return }
        close()
    }

    @objc private func revealLog() {
        // Created on its first event, so a run that has written none has no file to select.
        if FileManager.default.fileExists(atPath: host.eventsURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([host.eventsURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([host.dataDirectory])
        }
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([host.dataDirectory])
    }

    // MARK: - Update

    /// **Press once, and wait.** The flow — fetch, compare, download, admin swap — is
    /// ``Host/update``'s and takes seconds, so the button is disabled while it runs and the
    /// outcome lands in ``updateStatusLabel`` when it comes back.
    ///
    /// **On a real install this closure never returns**: a newer build relaunches the app, so
    /// only the up-to-date, offline and failed outcomes are ever rendered here. The window may
    /// also be closed by the time the flow finishes (an update proceeds regardless of the
    /// window), so the label writes are guarded by `[weak self]`.
    @objc private func updatePressed() {
        guard !isKeyRepeat else { return }
        updateButton.isEnabled = false
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.stringValue = "Checking GitHub for a newer version…"
        Task { @MainActor [weak self] in
            let outcome = await self?.host.update()
            guard let self, let outcome else { return }
            updateButton.isEnabled = true
            switch outcome {
            case .upToDate:
                updateStatusLabel.textColor = .secondaryLabelColor
                updateStatusLabel.stringValue =
                    "You’re already on the latest version (\(AppVersion.current))."
            case .offline:
                updateStatusLabel.textColor = .systemOrange
                updateStatusLabel.stringValue =
                    "Couldn’t reach GitHub — check the network and try again."
            case .failed(let message):
                updateStatusLabel.textColor = .systemOrange
                updateStatusLabel.stringValue = message
            case .updating:
                // Only reached if the caller chose not to relaunch; production always does.
                updateStatusLabel.textColor = .secondaryLabelColor
                updateStatusLabel.stringValue = "Update installed — relaunching…"
            }
        }
    }

    // MARK: - Changing the PIN

    @objc private func changePINPressed() {
        guard !isKeyRepeat else { return }
        guard host.config().isConfigured else {
            // Nothing to check the current PIN against. §2.5's derived rule the other way
            // round: with no PIN nothing is covered either, so nobody is trapped.
            complain("There is no PIN to change yet — finish setup first.")
            return
        }
        PINChangeSheet.present(on: window, config: host.config, clock: clock,
                               diagnostics: diagnostics) { [weak self] hash, salt in
            guard let self else { return }
            if let failure = host.savePIN(hash, salt) {
                complain(failure)
                return
            }
            report("The PIN has been changed.")
            updatePINStatus()
        }
    }

    // MARK: - Remote pairing (DESIGN §2.4, T06)

    /// Paint the status line, the code entry, and the `Unpair` button from the live
    /// ``PairingStatus``. Called on open, after a pair or unpair, on the once-a-second timer, and
    /// whenever the window returns to the front — so a token the poller (T04) has just seen
    /// rejected shows as "re-pair" without the parent reopening the window. `Unpair` is meaningful
    /// only when a token is stored.
    ///
    /// The code field and `Pair` button are shown only when entering a code can do something (T12):
    /// hidden once ``PairingStatus/paired``, since a working token is already stored, so the section
    /// then reads as just "Paired" plus `Unpair`. ``PairingStatus/expired`` keeps them, because a
    /// rejected token is exactly the case where the parent needs to type a fresh code to re-pair.
    private func refreshPairingStatus() {
        let showCodeEntry: Bool
        switch host.remotePairingStatus() {
        case .notPaired:
            pairingStatusValueLabel.stringValue = "Not paired"
            unpairButton.isEnabled = false
            showCodeEntry = true
        case .paired:
            pairingStatusValueLabel.stringValue = "Paired"
            unpairButton.isEnabled = true
            showCodeEntry = false
        case .expired:
            // A stored token the server has rejected — the parent re-pairs to get a fresh one, so
            // the code entry stays even though a (dead) token is stored.
            pairingStatusValueLabel.stringValue = "Paired — token rejected, re-pair"
            unpairButton.isEnabled = true
            showCodeEntry = true
        }
        // Hide the whole row, label included — hiding only the field left "Pairing code" standing
        // alone once paired. The field and `Pair` are hidden *and* disabled as well: a
        // hidden-but-live control is a trap. NSStackView collapses a hidden row, so no gap is left.
        pairingCodeRow?.isHidden = !showCodeEntry
        pairingCodeField.isHidden = !showCodeEntry
        pairingCodeField.isEnabled = showCodeEntry
        pairButton.isHidden = !showCodeEntry
        pairButton.isEnabled = showCodeEntry
    }

    private func startPairingStatusTimer() {
        guard pairingStatusTimer == nil else { return }
        // Holds `self` strongly, as `PINChangeSheet`'s countdown does: the run loop owns the
        // timer and it is invalidated the moment the window closes. `.common` so it keeps
        // ticking while a menu or a sheet is open over the window.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPairingStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pairingStatusTimer = timer
    }

    @objc private func pairPressed() {
        guard !isKeyRepeat else { return }
        // The redemption is async; the button hands off to `performPair` and returns at once so
        // the window never blocks (Settings is not modal — the engine tick runs on `.common`).
        Task { @MainActor in await performPair() }
    }

    /// Validate the typed code, redeem it, and show the outcome. The whole of it, so a headed
    /// test can `await testPair()` and see exactly what a button press does (DESIGN §3.1).
    private func performPair() async {
        guard let code = PairingCode.normalized(pairingCodeField.stringValue) else {
            // The rule that a code is non-empty lives in Core; this is only the English for it.
            pairingComplaint("Type the pairing code from the web app first.")
            return
        }
        // A second press cannot start a second redemption while one is in flight.
        pairButton.isEnabled = false
        pairingReport("Pairing…")
        let error = await host.pairRemote(code)
        pairButton.isEnabled = true
        if let error {
            pairingComplaint(Self.message(for: error))
        } else {
            // Success. Clear the field so the spent code is not left on screen, and let the
            // refreshed status line ("Paired") be the confirmation.
            pairingCodeField.stringValue = ""
            pairingReport("Paired.")
        }
        refreshPairingStatus()
    }

    @objc private func unpairPressed() {
        guard !isKeyRepeat else { return }
        host.unpairRemote()
        pairingReport("This Mac is no longer paired.")
        refreshPairingStatus()
    }

    /// The English for each ``RemoteClientError`` on the pairing path. A rejected or expired code
    /// comes back as `.http` (401 is reserved for a rejected device token, not a code — T03), so
    /// that case reads as "the code was refused" rather than a raw status.
    private static func message(for error: RemoteClientError) -> String {
        switch error {
        case .offline:
            return "Couldn’t reach the server — check the network and try again."
        case .timeout:
            return "The server took too long to answer — try again."
        case .http, .unauthorized:
            return "That code was refused — it may have been used already or expired. "
                + "Ask the web app for a new one."
        case .malformed:
            return "The server’s reply couldn’t be read — try again."
        }
    }

    private func pairingComplaint(_ text: String) {
        pairingNoteLabel.stringValue = text
        pairingNoteLabel.textColor = .systemOrange
    }

    private func pairingReport(_ text: String) {
        pairingNoteLabel.stringValue = text
        pairingNoteLabel.textColor = .secondaryLabelColor
    }

    // MARK: - Uninstall

    /// **Confirmed, and the data is kept unless it is asked for** (T16's uninstall note).
    ///
    /// `events.jsonl` is the only record of what the app ever did and the only thing here
    /// that cannot be recreated by reinstalling, so keeping it is the default and deleting
    /// it is a deliberate tick.
    @objc private func uninstallPressed() {
        guard !isKeyRepeat else { return }

        let alert = NSAlert()
        alert.messageText = "Uninstall Real Screen Time?"
        alert.informativeText = """
            This removes the login item so the app never starts again, and quits it. The \
            screen is not covered again after that.

            The app itself stays in your Applications folder — drag it to the Bin when you \
            are done with it.
            """
        alert.alertStyle = .warning

        let deleteData = NSButton(checkboxWithTitle:
            "Also delete the settings, the event log and the session state", target: nil,
                                  action: nil)
        deleteData.state = .off
        alert.accessoryView = deleteData

        alert.addButton(withTitle: "Uninstall")
        // Second, so Return is not the destructive one — `NSAlert` makes the first button
        // the default and Escape the second.
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            diagnostics("settings: uninstall cancelled", at: clock.now)
            return
        }

        let alsoData = deleteData.state == .on
        diagnostics("settings: uninstalling\(alsoData ? ", data included" : ", data kept")",
                    at: clock.now)
        // The window goes first: what follows removes the login item and ends the process,
        // and a window still on screen while that happens looks like a crash.
        close()
        host.uninstall(alsoData)
    }

    // MARK: - Closing

    private func close() {
        pairingStatusTimer?.invalidate()
        pairingStatusTimer = nil
        window.delegate = nil
        window.orderOut(nil)
        Self.showing = nil
        restoreDockIcon()
        diagnostics("settings: closed", at: clock.now)
    }

    /// The same claim, refreshed whenever the window comes back to the front: a parent who
    /// left it open while the child started a session returns to a note that is true rather
    /// than to the one that was true an hour ago.
    func windowDidBecomeKey(_ notification: Notification) {
        updateSessionNote()
        refreshPairingStatus()
    }

    /// The red button or `Cmd+W`. **Unsaved edits are discarded**, and deliberately: `Save`
    /// is the only thing that writes, so closing is the way to back out of a change you have
    /// half typed. Nothing here is destructive enough to be worth an "are you sure".
    func windowWillClose(_ notification: Notification) {
        pairingStatusTimer?.invalidate()
        pairingStatusTimer = nil
        window.delegate = nil
        Self.showing = nil
        restoreDockIcon()
        diagnostics("settings: closed", at: clock.now)
    }

    // MARK: - Small builders

    private static func label(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: size, weight: weight)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func sectionTitle(_ text: String) -> NSView {
        let label = Self.label(size: 15, weight: .semibold)
        label.stringValue = text
        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let stack = NSStackView(views: [spacer, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private static func note(_ text: String) -> NSTextField {
        let label = Self.label(size: 11, weight: .regular)
        label.stringValue = text
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return label
    }

    /// A combo box, fixed and compact — it holds a two-digit number and a small pop-out list, so
    /// it does not need the width the token fields do. The suggestion list is filled in
    /// ``configureControls()``.
    private static func combo(width: CGFloat) -> NSComboBox {
        let combo = NSComboBox()
        combo.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        combo.completes = false
        combo.widthAnchor.constraint(equalToConstant: width).isActive = true
        return combo
    }

    /// A token field for a list of minutes — a pill per number (CR-01 §6). Its delegate (the
    /// numeric constraint, the pick-list and, for grants, the refusal to empty) is set in
    /// ``configureControls()`` because the two fields carry different ones.
    private static func tokenField() -> NSTokenField {
        let field = NSTokenField(string: "")
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return field
    }

    private func field(_ control: NSView, _ title: String, _ unit: String) -> NSView {
        let name = Self.label(size: 13, weight: .regular)
        name.stringValue = title
        name.alignment = .right
        name.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let suffix = Self.label(size: 13, weight: .regular)
        suffix.stringValue = unit
        suffix.textColor = .secondaryLabelColor

        let row = NSStackView(views: [name, control, suffix])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        // **No key equivalent on any of these.** Return belongs to `Save`; `Uninstall…` in
        // particular must not be reachable by a held key — T16's step 4 learned that with a
        // login item, and this button ends the app.
        button.keyEquivalent = ""
        return button
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let leading = NSView()
        leading.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let row = NSStackView(views: [leading] + buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}

// MARK: - The token fields (CR-01 §6)

/// **A token field that holds whole numbers and nothing else** — CR-01 §6, T03.
///
/// Both minute lists are `NSTokenField`s: a pill per number, letters refused, a short pick-list
/// of common amounts offered, any number still typeable. The token shows the bare number — the
/// unit is the trailing label beside the field, not part of the pill.
///
/// **The two lists are not the same shape** (DESIGN §2.6). Grants (`extension_options`) may
/// never be empty — the first is pre-selected in `Dodaj minuty…`, and an empty list is the one
/// thing ``SettingsDraft/problem`` forbids — so the grant field refuses to delete its last
/// token. Warnings may be emptied freely. `keepAtLeastOne` is that difference.
///
/// **The refusal to empty is a convenience, not the guarantee.** This class cannot save
/// anything; the guarantee is ``SettingsDraft/problem`` returning `.noGrants`, which refuses the
/// Save and names the field. The delete guard only spares a parent the round-trip to find that
/// out — and it is a hand-verified behaviour, since there is no UI automation on this machine.
@MainActor
final class NumberTokenFieldDelegate: NSObject, NSTokenFieldDelegate {
    private let suggestions: [Int]
    private let keepAtLeastOne: Bool

    init(suggestions: [Int], keepAtLeastOne: Bool) {
        self.suggestions = suggestions
        self.keepAtLeastOne = keepAtLeastOne
    }

    /// The pick-list of common amounts, as strings, narrowed by whatever has been typed so far.
    /// Any number stays typeable — this only offers, it does not constrain.
    func tokenField(_ tokenField: NSTokenField,
                    completionsForSubstring substring: String,
                    indexOfToken tokenIndex: Int,
                    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        suggestions.map(String.init).filter { $0.hasPrefix(substring) }
    }

    /// **Letters never become a token.** A token is kept only if it is a whole number; anything
    /// else returns `nil`, which `NSTokenField` drops.
    func tokenField(_ tokenField: NSTokenField,
                    representedObjectForEditing editingString: String) -> Any? {
        let trimmed = editingString.trimmingCharacters(in: .whitespaces)
        return Int(trimmed) == nil ? nil : trimmed
    }

    /// A comma-split or a paste can offer several strings at once; keep only the whole numbers.
    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any],
                    at index: Int) -> [Any] {
        tokens.filter { Int("\($0)".trimmingCharacters(in: .whitespaces)) != nil }
    }

    /// **Refuse the delete that would empty a grant field** (DESIGN §2.6). `NSTokenField` has no
    /// "will remove token" hook, so the delete command itself is intercepted here: with one token
    /// left, no plain text half-typed, and nothing selected, the delete would land on the sole
    /// token and is swallowed. Committed tokens render in the field editor as attachment
    /// characters, so those are stripped before asking whether any typed text remains — a
    /// backspace inside a would-be second token must still work. Biased to allow: when unsure it
    /// lets the delete through, because ``SettingsDraft/problem`` refuses an empty save anyway.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard keepAtLeastOne,
              commandSelector == #selector(NSResponder.deleteBackward(_:))
                || commandSelector == #selector(NSResponder.deleteForward(_:)) else {
            return false
        }
        let tokenCount = (control.objectValue as? [Any])?.count ?? 0
        guard tokenCount <= 1 else { return false }
        let pending = textView.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")   // NSAttachmentCharacter — the tokens
            .trimmingCharacters(in: .whitespaces)
        let hasSelection = textView.selectedRange().length > 0
        return pending.isEmpty && !hasSelection   // swallow only when it would empty the field
    }
}

// MARK: - The PIN change

/// **The three questions, on a sheet** — the current PIN, the new one, the new one again.
///
/// One ``PINBoxes`` control asked three things in turn. The *sequence* is ``PINChangeFlow``'s
/// over in `RSTCore`, where `make test` can reach it; what is here is the sheet, the
/// off-the-main-thread work, and the rate limit.
///
/// A sheet rather than the panel T13's menu-bar prompt uses, because unlike an `NSStatusItem`
/// this has a window to hang from — and a sheet cannot be left behind or lost under
/// something, which for a dialog holding a half-changed PIN is the whole point.
@MainActor
final class PINChangeSheet: NSObject {

    /// The hashed result. The caller writes it; this object never touches the config.
    typealias Done = (String, Data) -> Void

    private let sheet: NSWindow
    private let parent: NSWindow
    private let config: () -> Config
    private let clock: any Clock
    private let diagnostics: Diagnostics
    private let done: Done

    private var flow = PINChangeFlow()
    private var gate = PINGate()
    private let verifier = PINVerifier()
    private var countdown: Timer?
    /// Held for the life of the sheet: nothing else references it once `beginSheet` returns.
    private static var showing: PINChangeSheet?

    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private lazy var boxes = PINBoxes(scale: 0.8)

    static func present(on parent: NSWindow, config: @escaping () -> Config,
                        clock: any Clock, diagnostics: Diagnostics, done: @escaping Done) {
        guard showing == nil else { return }
        showing = PINChangeSheet(on: parent, config: config, clock: clock,
                                 diagnostics: diagnostics, done: done)
    }

    private init(on parent: NSWindow, config: @escaping () -> Config, clock: any Clock,
                 diagnostics: Diagnostics, done: @escaping Done) {
        self.parent = parent
        self.config = config
        self.clock = clock
        self.diagnostics = diagnostics
        self.done = done
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()

        verifier.onResult = { [weak self] _, ok in self?.currentVerified(ok) }
        boxes.onComplete = { [weak self] entered in self?.entered(entered) }

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 0
        hintLabel.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"          // Escape; Return belongs to the boxes

        let stack = NSStackView(views: [titleLabel, boxes, hintLabel, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        sheet.contentView = content

        show(.current)
        parent.beginSheet(sheet) { _ in }
        // The boxes have to be told they are the ones typing — and told again once the sheet
        // is really up. A PIN control that silently accepts no keystrokes is the oldest trap
        // in this app (CLAUDE.md, `canBecomeKey`), and one extra hop is a cheap seatbelt
        // against the sheet not yet being key when `beginSheet` returns.
        sheet.makeFirstResponder(boxes)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, Self.showing === self else { return }
                self.sheet.makeFirstResponder(self.boxes)
            }
        }
    }

    private func show(_ stage: PINChangeStage) {
        boxes.clear()
        boxes.isEnabled = true
        switch stage {
        case .current:
            titleLabel.stringValue = "Enter the current PIN"
            hintLabel.stringValue = "Asked because this window can be left open on a Mac "
                + "someone else is sitting at."
        case .new:
            titleLabel.stringValue = "Choose a new PIN"
            hintLabel.stringValue = "Four digits. This is what unlocks the screen and grants "
                + "extra minutes."
        case .repeated:
            titleLabel.stringValue = "Type it again"
            hintLabel.stringValue = "A mistyped new PIN is a PIN nobody knows, and the only "
                + "way back from one is a reboot."
        }
        sheet.makeFirstResponder(boxes)
    }

    /// Four digits landed.
    private func entered(_ digits: String) {
        let now = clock.now
        guard gate.isOpen(at: now) else { return holdBack(at: now) }

        switch flow.entered(digits) {
        case .verifyCurrent(let text):
            let settings = config()
            guard let salt = settings.pinSaltData, !settings.pinHash.isEmpty else {
                diagnostics("settings: no PIN to change", at: now)
                return finish()
            }
            // 200 000 rounds — never on the main thread (`pinRounds`).
            verifier.offer(text: text, hash: settings.pinHash, salt: salt)
        case .ask(let stage):
            show(stage)
        case .rejected(let problem):
            show(.new)
            hintLabel.stringValue = Self.message(for: problem)
            hintLabel.textColor = .systemOrange
        case .settled(let pin):
            settle(pin)
        }
    }

    private func currentVerified(_ ok: Bool) {
        let now = clock.now
        guard ok else {
            gate.failed(at: now)
            diagnostics("settings: wrong current PIN, \(gate.failures) in a row", at: now)
            _ = flow.currentRejected()
            hintLabel.stringValue = "That is not the current PIN."
            hintLabel.textColor = .systemOrange
            return holdBack(at: now)
        }
        gate.succeeded()
        hintLabel.textColor = .secondaryLabelColor
        if case .ask(let stage) = flow.currentAccepted() { show(stage) }
    }

    /// Both new entries agree. Hash it — off the main thread, ~0.5 s — and hand it over.
    private func settle(_ pin: String) {
        boxes.isEnabled = false
        titleLabel.stringValue = "Saving…"
        hintLabel.stringValue = ""

        DispatchQueue.global(qos: .userInitiated).async { [pin] in
            let salt = newPINSalt()
            let hash = hashPIN(pin, salt: salt)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.diagnostics("settings: PIN changed", at: self.clock.now)
                    // The sheet goes first: the caller's completion touches the window
                    // underneath it.
                    let done = self.done
                    self.finish()
                    done(hash, salt)
                }
            }
        }
    }

    // MARK: - The rate limit

    /// Shut the boxes for however long the gate says.
    ///
    /// **The `wait == 0` branch re-opens them, and that is not a formality.** `PINBoxes` goes
    /// inert the instant the fourth digit lands, so a path out of here that only ever
    /// *disables* leaves a sheet whose boxes accept nothing and say nothing — the same shape
    /// of silent dead end `PINFlow.reopen` exists to prevent.
    private func holdBack(at now: Date) {
        boxes.clear()
        guard gate.wait(at: now) > 0 else {
            boxes.isEnabled = true
            sheet.makeFirstResponder(boxes)
            return
        }
        boxes.isEnabled = false
        startCountdown()
    }

    private func startCountdown() {
        guard countdown == nil else { return }
        // Holds `self` strongly on purpose, exactly as `PINFlow` does: the run loop owns the
        // timer, and this one stops itself the moment the gate opens — five seconds at most.
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.countdownTicked() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }

    private func countdownTicked() {
        guard gate.wait(at: clock.now) == 0 else { return }
        countdown?.invalidate()
        countdown = nil
        boxes.isEnabled = true
        sheet.makeFirstResponder(boxes)
    }

    private static func message(for problem: PINProblem) -> String {
        switch problem {
        case .empty:              return "Type four digits."
        case .notDigits:          return "Digits only."
        case .wrongLength(let n): return "A PIN is \(pinDigits) digits — that was \(n)."
        case .mismatch:           return "Those did not match. Start again."
        }
    }

    @objc private func cancelPressed() {
        diagnostics("settings: PIN change cancelled", at: clock.now)
        finish()
    }

    private func finish() {
        countdown?.invalidate()
        countdown = nil
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        Self.showing = nil
    }
}

// MARK: - Uninstall

/// **Taking the app off the machine** — T16's uninstall note, built here because this is
/// where the menu item that asks for it lives.
///
/// Three steps, in an order that matters: stop the LaunchAgent *before* quitting, or
/// `KeepAlive` brings the process straight back and the parent watches an app they just
/// uninstalled reappear in the menu bar.
enum Uninstaller {

    /// What it managed to do, for `app.log`.
    struct Outcome {
        var bootedOut = false
        var plistRemoved = false
        var dataRemoved = false
        var failures: [String] = []
    }

    /// Remove the login item and, if asked, the data directory.
    ///
    /// **Nothing here is fatal.** A `bootout` that fails still leaves an app that is about to
    /// quit and a plist that is about to be deleted, and an app that refused to uninstall
    /// because one step of three did not work is worse than one that says what it managed.
    static func run(dataDirectory: URL, deleteData: Bool,
                    diagnostics: Diagnostics, at now: Date) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default

        outcome.bootedOut = LaunchAgentInstaller.bootout(diagnostics: diagnostics, at: now)

        let plist = LaunchAgentInstaller.plistURL
        if fm.fileExists(atPath: plist.path) {
            do {
                try fm.removeItem(at: plist)
                outcome.plistRemoved = true
            } catch {
                outcome.failures.append("could not remove \(plist.path): "
                                        + error.localizedDescription)
            }
        }

        if deleteData {
            do {
                try fm.removeItem(at: dataDirectory)
                outcome.dataRemoved = true
            } catch {
                outcome.failures.append("could not remove \(dataDirectory.path): "
                                        + error.localizedDescription)
            }
        }

        diagnostics("uninstall: agent \(outcome.bootedOut ? "booted out" : "not loaded"), "
                    + "plist \(outcome.plistRemoved ? "removed" : "absent"), "
                    + "data \(deleteData ? (outcome.dataRemoved ? "removed" : "NOT removed") : "kept")"
                    + (outcome.failures.isEmpty ? "" : " — \(outcome.failures.joined(separator: "; "))"),
                    at: now)
        return outcome
    }
}
