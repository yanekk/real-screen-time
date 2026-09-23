import AppKit
import RSTCore

/// **The four questions, once** — DESIGN §6, T16.
///
/// Drag the `.app` to `/Applications`, launch it as the child, answer four questions, done.
/// No terminal, no `sudo`, no installer script.
///
/// **English, and this is the one place the language rule has an exception written into it.**
/// DESIGN §2.4.2 splits at the PIN — anything that can appear without one being typed is
/// Polish — and a first run is by definition before there is a PIN to type. The table in
/// §2.4.2 nevertheless says *First-run wizard: English*, because the audience is the parent
/// setting the machine up, not the child using it. Every string below is therefore a
/// literal here rather than an entry in `Strings.swift`, which stays Polish-only.
///
/// What is a *rule* is in ``FirstRunStep``, ``firstRunPINProblem`` and ``SessionLimits`` over
/// in `RSTCore`, where `make test` can reach it. This file is the window.
@MainActor
final class FirstRunWindow: NSObject, NSWindowDelegate {

    /// What the wizard hands back when the answers are in: a message on failure, `nil` on
    /// success. `main.swift` owns the `ConfigStore`, so it does the writing.
    typealias Save = (FirstRunAnswers) -> String?

    /// The one on screen, if any. Static because setup can be asked for again from the menu
    /// while a window is already up, and it is also what keeps this object alive.
    private static var showing: FirstRunWindow?

    static var isShowing: Bool { showing != nil }

    // MARK: - Tier 1 seam (DESIGN §3.1, T05)

    /// **Build the wizard off-screen for the headed suite** — the entry point that passes
    /// `present: false` (see the note on the designated initialiser). It does not register in
    /// ``showing`` and takes no Dock icon, so the caller owns the returned object's lifetime
    /// and nothing is ever ordered onto a display. `present`'s path is untouched.
    static func buildForTesting(isConfigured: Bool,
                                savedLimits: SessionLimits = .suggested,
                                clock: any Clock,
                                diagnostics: Diagnostics = .discarded,
                                save: @escaping Save = { _ in nil },
                                onClose: @escaping () -> Void = {}) -> FirstRunWindow {
        FirstRunWindow(isConfigured: isConfigured, savedLimits: savedLimits, clock: clock,
                       diagnostics: diagnostics, isCovering: { false }, save: save,
                       onClose: onClose, present: false)
    }

    /// **Read access for the headed suite, and only that** — the same additive, read-only
    /// reach the menu bar exposes (T04). The step, the three nav buttons and the PIN boxes are
    /// all `private`, which `@testable` does not open, so a Tier 1 test cannot otherwise assert
    /// the step machinery or type a PIN. These are the whole of the reach — the step, the two
    /// buttons a headed test presses (`Continue`/`Install login item`/`Finish` and `Finish
    /// without it`), and the PIN boxes; the app calls none of them and its behaviour is unchanged.
    var testStep: FirstRunStep { step }
    var testNextButton: NSButton { nextButton }
    var testAltButton: NSButton { altButton }
    var testPINBoxes: PINBoxes { pinBoxes }

    private let window: NSWindow
    private let save: Save
    private let diagnostics: Diagnostics
    private let clock: any Clock
    private let onClose: () -> Void
    /// Whether the cover is up. Only used to keep this window's hands off the activation
    /// policy while `KioskLock` owns it — see ``takeDockIcon()``.
    private let isCovering: () -> Bool

    private var step: FirstRunStep = .welcome
    /// The earliest step this run of the wizard may show. ``firstRunEntryStep`` decides it:
    /// an app that already has a PIN reopens on step 4 and cannot walk back to step 2.
    private let entryStep: FirstRunStep

    // Step 2's state. The PIN is held in the clear only between the second entry and the
    // save a step later — hashing costs ~0.5 s and must not be done on the main thread
    // while a parent is looking at a frozen window (see `pinRounds`).
    private enum PINStage { case first, second }
    private var pinStage: PINStage = .first
    private var firstEntry = ""
    private var settledPIN: String?

    /// Seeded from the config already on disk, so a wizard **reopened** on a configured app
    /// (which enters at step 4 and never shows step 3) renders the terminal screen's paragraph
    /// one from the parent's real settings, not the factory default. On a fresh run step 3
    /// overwrites this, and an unconfigured app's config already equals ``SessionLimits/suggested``.
    private var limits = SessionLimits.suggested

    /// The answers, hashed and validated, waiting for the window to close. See
    /// ``saveAnswers()``: writing them is what arms the app, and arming it while its own
    /// setup window is still open buries the last step under the cover.
    private var pendingAnswers: FirstRunAnswers?

    private var saving = false
    /// Whether the login item was installed during this run — set by ``installAndFinish()``.
    private var agentInstalled = false

    /// **Step 4's primary is disabled for ``armingDelay`` after the step appears** (DESIGN
    /// §2.3). Install moved back into the corner reverses the fix of 2026-08-26; the delay is
    /// the seatbelt that replaces it, so a stray second click chasing step 3's ~1.3 s save
    /// cannot reach `launchctl bootstrap`. ``isKeyRepeat`` guards a held key; the delay guards
    /// a second physical click, which is what actually happened.
    private var loginArmed = false
    private static let armingDelay: TimeInterval = 0.5

    // MARK: - Chrome

    private let titleLabel = FirstRunWindow.label(size: 22, weight: .semibold)
    private let bodyLabel = FirstRunWindow.label(size: 13, weight: .regular)
    private let noteLabel = FirstRunWindow.label(size: 12, weight: .regular)
    private let progressLabel = FirstRunWindow.label(size: 11, weight: .regular)
    private let content = NSStackView()
    private let custom = NSStackView()
    private let backButton = NSButton()
    /// Step 4's middle button, `Finish without it`. Hidden on every other step.
    private let altButton = NSButton()
    private let nextButton = NSButton()

    /// Step 2's four boxes — the same control the cover and the menu-bar panel use, so the
    /// PIN chosen here can only ever be a PIN T13's prompt can accept back.
    private lazy var pinBoxes: PINBoxes = {
        let boxes = PINBoxes(scale: 0.8)
        boxes.onComplete = { [weak self] entered in self?.pinEntered(entered) }
        return boxes
    }()

    /// Step 3's two controls (CR-01 §2). The rules behind them — the pop-up's rows and the
    /// combo's suggestion list — are ``SessionsPerDayChoice`` and ``ComboSuggestions`` in
    /// `RSTCore`; these are only the AppKit that shows them.
    private let minutesCombo = NSComboBox()
    private let sessionsPopUp = NSPopUpButton()

    // MARK: - Presenting

    /// Put the wizard on the screen. A second call while one is up brings the first forward.
    static func present(isConfigured: Bool,
                        savedLimits: SessionLimits = .suggested,
                        clock: any Clock,
                        diagnostics: Diagnostics,
                        isCovering: @escaping () -> Bool = { false },
                        save: @escaping Save,
                        onClose: @escaping () -> Void) {
        if let showing {
            showing.window.makeKeyAndOrderFront(nil)
            showing.window.orderFrontRegardless()
            NSApp.activate()
            return
        }
        showing = FirstRunWindow(isConfigured: isConfigured, savedLimits: savedLimits,
                                 clock: clock, diagnostics: diagnostics, isCovering: isCovering,
                                 save: save, onClose: onClose)
    }

    /// `present: false` is the **build-but-do-not-show seam** (DESIGN §3.1, T05): it builds the
    /// window and shows the entry step's controls, but runs none of the presenting tail — no
    /// `center`, no ``takeDockIcon()`` (so the activation policy stays non-`.regular`, and the
    /// wizard's step machinery is asserted without a Dock icon), no ordering. A headed test
    /// builds one through ``buildForTesting(isConfigured:savedLimits:clock:diagnostics:save:onClose:)``,
    /// drives its nav buttons and PIN boxes, and tears it down without a window reaching a
    /// display. `present`'s path passes the default `true`, so the shipping behaviour is unchanged.
    private init(isConfigured: Bool,
                 savedLimits: SessionLimits,
                 clock: any Clock,
                 diagnostics: Diagnostics,
                 isCovering: @escaping () -> Bool,
                 save: @escaping Save,
                 onClose: @escaping () -> Void,
                 present: Bool = true) {
        entryStep = firstRunEntryStep(isConfigured: isConfigured)
        self.isCovering = isCovering
        self.clock = clock
        self.diagnostics = diagnostics
        self.save = save
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        // Seed the step-3 numbers from what is already configured (see ``limits``): harmless
        // on a fresh run, where step 3 overwrites them, and the whole of the fix on a reopen,
        // where step 3 never shows and the terminal screen would otherwise report defaults.
        limits = savedLimits

        window.title = "Real Screen Time — Setup"
        window.delegate = self
        window.isReleasedWhenClosed = false
        // **Closable on purpose.** Step 1's whole argument is that this is a visible
        // boundary rather than a trap, and a setup window with no way out would contradict
        // it in the app's first thirty seconds. Nothing is enforced until the PIN exists,
        // so backing out costs the child nothing — and the menu bar offers setup again.
        buildChrome()
        show(entryStep)

        // The presenting tail, skipped by the seam (see the `present` note on `init`). Made
        // conditional rather than an early `return`, per CLAUDE.md — it is all and only the
        // calls that touch a display or the app-global activation policy.
        if present {
            window.center()
            takeDockIcon()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // **After `makeKeyAndOrderFront`, not instead of it.** A background agent is not
            // always granted activation, and an ordinary order-front from an app the system has
            // decided is not active can be dropped; this one cannot. See ``takeDockIcon()`` for
            // what went wrong without it.
            window.orderFrontRegardless()
        }

        diagnostics(entryStep == .welcome
                    ? "first run: no PIN configured, wizard opened"
                    : "first run: reopened at the login-item step — the PIN is already set",
                    at: clock.now)
    }

    /// **A real window needs a real app** — and until it has one, this window did not appear.
    ///
    /// `Info.plist` sets `LSUIElement`, so the app runs `.accessory`: no Dock icon, no menu
    /// bar of its own, and no claim on the screen. Verified on the installed `.app`,
    /// 2026-08-26: started by `launchd` the setup window came up **empty**, opened from
    /// Finder it **never appeared at all**, and the identical code under `swift run` — which
    /// is not a bundle and goes through none of this — drew correctly twice. `app.log` said
    /// `wizard opened` every time, so the window was always built; it was the showing of it
    /// that the system declined.
    ///
    /// `.regular` for as long as the wizard is up is what T12 already does for the cover, and
    /// for the same underlying reason. It also makes the wizard behave the way a parent will
    /// expect — a Dock icon to click back to, and a Cmd+Tab that reaches it.
    ///
    /// **Only when nothing is covering.** `KioskLock` owns the policy while the cover is up
    /// (T12) and putting it back to `.accessory` underneath it would drop the presentation
    /// options that hold the kiosk together. The first run cannot be covering — there is no
    /// PIN — but a wizard *reopened* from the menu can be, so the guard is real.
    private func takeDockIcon() {
        guard !isCovering() else { return }
        NSApp.setActivationPolicy(.regular)
    }

    private func restoreDockIcon() {
        guard !isCovering() else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func buildChrome() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
        content.translatesAutoresizingMaskIntoConstraints = false

        custom.orientation = .vertical
        custom.alignment = .leading
        custom.spacing = 10

        bodyLabel.textColor = .labelColor
        noteLabel.textColor = .secondaryLabelColor
        progressLabel.textColor = .tertiaryLabelColor

        for button in [backButton, altButton, nextButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        backButton.action = #selector(backPressed)
        altButton.action = #selector(finishWithoutPressed)
        nextButton.action = #selector(nextPressed)
        // Return presses the primary button — except on step 2, where the fourth digit is the
        // whole submission and `PINBoxes` deliberately ignores Return. On step 4 the primary
        // is `Install login item`; the arming delay (see `loginArmed`) is what stops a held or
        // stray Return reaching it.
        nextButton.keyEquivalent = "\r"
        // No key equivalent on `Finish without it`: Return belongs to the primary, and the
        // middle button must never be the one a held key lands on.
        altButton.keyEquivalent = ""
        // Step 3's combo box wants a fixed, compact width; the pop-up sizes to its rows.
        minutesCombo.widthAnchor.constraint(equalToConstant: 80).isActive = true

        // §2.1: one row — the step counter at the leading edge, a spacer, then the buttons
        // trailing with the primary rightmost. Apple's convention, and the one Settings' own
        // footer follows. `Back` and `Finish without it` collapse out when hidden, so the
        // primary stays rightmost on every step.
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(
            views: [progressLabel, footerSpacer, backButton, altButton, nextButton])
        footer.orientation = .horizontal
        footer.spacing = 10

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)

        for view in [titleLabel, bodyLabel, custom, noteLabel, spacer, footer] {
            content.addArrangedSubview(view)
        }

        let host = NSView()
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -64),
            bodyLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -64),
            noteLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -64),
            // Same inset width as the labels. Without it the step's custom controls (step 3's
            // field rows) drift to the window's left edge instead of lining up under the title
            // and paragraph — a leading-aligned sub-stack with no width of its own does not
            // settle at the stack's edge inset on its own.
            custom.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -64),
            // The footer spans the same inset width as the labels, so its spacer actually
            // pushes the buttons to the trailing edge instead of collapsing to intrinsic size.
            footer.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -64),
        ])
        window.contentView = host
    }

    // MARK: - The steps

    private func show(_ step: FirstRunStep) {
        self.step = step
        custom.arrangedSubviews.forEach { $0.removeFromSuperview() }
        noteLabel.stringValue = ""

        // Hidden on the terminal screen, which has no place in the counter (CR-01 §4).
        if let position = step.position {
            progressLabel.isHidden = false
            progressLabel.stringValue = "Step \(position.index) of \(position.count)"
        } else {
            progressLabel.isHidden = true
        }
        // Never below the entry step: reopened on an app that already has a PIN, walking
        // back would reach step 2 and let anyone set a new one from an ungated menu item. The
        // terminal screen has no way back into the wizard at all.
        backButton.isHidden = step.previous == nil || step <= entryStep || step == .done
        backButton.title = "Back"

        switch step {
        case .welcome:   showWelcome()
        case .pin:       showPIN()
        case .sessions:  showSessions()
        case .login:     showLogin()
        case .done:      showDone()
        }
        updateNextButton()
    }

    /// **Step 1 is not politeness.** The design's stance is that this works because it is a
    /// visible boundary rather than a hidden trap, and the first thing the app says is where
    /// that stance is either made or lost.
    private func showWelcome() {
        titleLabel.stringValue = "Real Screen Time"
        bodyLabel.stringValue = """
            This Mac gives your child screen time in sessions. One 30-minute session a day he can \
            start himself, from a button on the screen; any more minutes come from you, by \
            typing a PIN.

            When no session is running, every display is covered. The cover says why, and it \
            says how to get more time. Nothing here is hidden: there is a countdown in the \
            menu bar the whole time, and everything the app does is written to a log you can \
            read.

            Four questions and you are done.
            """
    }

    private func showPIN() {
        titleLabel.stringValue = "Choose a PIN"
        pinStage = .first
        firstEntry = ""
        settledPIN = nil
        pinBoxes.clear()
        pinBoxes.isEnabled = true
        custom.addArrangedSubview(pinBoxes)
        updatePINPrompt()
        // The window is key already; the boxes have to be told they are the ones typing.
        window.makeFirstResponder(pinBoxes)
    }

    private func updatePINPrompt() {
        switch pinStage {
        case .first:
            bodyLabel.stringValue = """
                Four digits, and there is no way to skip this step: with no PIN the app \
                will not cover anything, because nothing would be able to uncover it again.

                This is what unlocks the screen and grants extra minutes. Choose something \
                your child will not guess by watching you type it.
                """
        case .second:
            bodyLabel.stringValue = "Type the same four digits again."
        }
    }

    private func pinEntered(_ entered: String) {
        switch pinStage {
        case .first:
            firstEntry = entered
            pinStage = .second
            pinBoxes.clear()
            pinBoxes.isEnabled = true
            noteLabel.stringValue = ""
            updatePINPrompt()

        case .second:
            let problem = firstRunPINProblem(entered: firstEntry, repeated: entered)
            switch problem {
            case nil:
                settledPIN = firstEntry
                noteLabel.stringValue = "PIN set. Continue."
                noteLabel.textColor = .secondaryLabelColor
                // Left filled and disabled: the four dots are the visible answer to "did
                // that work", and re-enabling them would invite a fifth digit into a PIN
                // that is already settled.
            default:
                settledPIN = nil
                noteLabel.stringValue = message(for: problem ?? .mismatch)
                noteLabel.textColor = .systemOrange
                pinStage = .first
                firstEntry = ""
                pinBoxes.clear()
                pinBoxes.isEnabled = true
                updatePINPrompt()
                window.makeFirstResponder(pinBoxes)
            }
            updateNextButton()
        }
    }

    private func message(for problem: PINProblem) -> String {
        switch problem {
        case .empty:               return "Type four digits."
        case .notDigits:           return "Digits only."
        case .wrongLength(let n):  return "A PIN is \(pinDigits) digits — that was \(n)."
        case .mismatch:            return "Those did not match. Start again."
        }
    }

    private func showSessions() {
        titleLabel.stringValue = "Sessions"
        bodyLabel.stringValue = """
            How long one session lasts, and how many your child may start on his own each day. \
            Anything beyond that needs your PIN, and you choose the amount at the time.

            Both can be changed later.
            """
        configureSessionsControls()
        custom.addArrangedSubview(field(minutesCombo, "Session length", "minutes"))
        custom.addArrangedSubview(field(sessionsPopUp, "Sessions he can start himself", "per day"))
        window.makeFirstResponder(minutesCombo)
    }

    /// Fill step 3's combo box and pop-up from the current `limits`, showing a stored value
    /// outside either control's list rather than clamping it (DESIGN §2.2). The lists and the
    /// mapping are `RSTCore`'s rules; this only paints them.
    private func configureSessionsControls() {
        minutesCombo.removeAllItems()
        minutesCombo.addItems(withObjectValues:
            ComboSuggestions.merged(ComboSuggestions.sessionLength, storedValue: limits.minutes)
                .map(String.init))
        // Any number stays typeable; no autocomplete narrowing it to the suggestions.
        minutesCombo.completes = false
        minutesCombo.stringValue = String(limits.minutes)

        // The row labels are unique by construction (None, 1…4, and any appended value is
        // outside 0…4), so `NSPopUpButton`'s dedup-by-title never drops one.
        sessionsPopUp.removeAllItems()
        sessionsPopUp.addItems(withTitles:
            SessionsPerDayChoice.items(storedValue: limits.sessionsPerDay).map(Self.sessionsLabel))
        sessionsPopUp.selectItem(at:
            SessionsPerDayChoice.selectedIndex(storedValue: limits.sessionsPerDay))
    }

    /// The English label for a pop-up row — the wizard is parent-side (DESIGN §2.4.2's
    /// exception), so only the value and case come from `RSTCore`.
    private static func sessionsLabel(_ item: SessionsItem) -> String {
        if item.isNoneCase { return "None — every session needs your PIN" }
        return item.value == 1 ? "1 session" : "\(item.value) sessions"
    }

    /// **Step 4's install action is back in the corner — and this reverses the fix of
    /// 2026-08-26** (DESIGN §2.3, CR-01 §3).
    ///
    /// The row is `[Back] [Finish without it] [Install login item]`, install the primary and
    /// rightmost (§2.1's ordering). Install *used to* be a button in the body, precisely
    /// because a corner button that changed identity under the pointer — `Continue` →
    /// `Saving…` → install — took a stray second click straight into `launchctl bootstrap`
    /// during step 3's ~1.3 s save. `app.log` showed 1.3 s between leaving step 3 and the
    /// install.
    ///
    /// The layout is the right one; the seatbelt is the **arming delay**. The primary is
    /// disabled for ``armingDelay`` after this step appears, so a click landing in that window
    /// does nothing. ``isKeyRepeat`` covers a held key; the delay covers the second physical
    /// click, which is what actually happened. This is the one hand test that must be attacked
    /// deliberately.
    private func showLogin() {
        titleLabel.stringValue = "Start at login"
        bodyLabel.stringValue = """
            This installs a small system entry that starts Real Screen Time when your child logs \
            in, and starts it again if it is ever quit or killed. Time the app is away is \
            charged against the session, so stopping it buys nothing.

            Your child can remove that entry himself — he owns his own account, and closing that \
            gap would need a system-wide installer this app deliberately does not have.
            """
        // Disabled now (painted by `updateNextButton()` at the end of `show`), re-enabled
        // after the arming delay. Re-armed on every arrival, because step 3's save completing
        // is the dangerous transition and it lands here each time.
        loginArmed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armingDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.step == .login else { return }
                self.loginArmed = true
                self.updateNextButton()
            }
        }
    }

    /// **The terminal "You're done" screen** (CR-01 §4, DESIGN §2.4). The one moment a parent
    /// sees all four answers at once, and the last chance to notice one is wrong — built from
    /// the answers actually given. Paragraph one's count-and-minutes agreement is a rule and
    /// lives in ``FinalScreenSummary``; paragraphs two and three are fixed English, paragraph
    /// two chosen by whether the login item was installed. No Back, no step counter (handled in
    /// ``show(_:)``), one `Finish` button.
    private func showDone() {
        titleLabel.stringValue = "You're done"
        let sessions = FinalScreenSummary.sessionsParagraph(
            sessionsPerDay: limits.sessionsPerDay, minutes: limits.minutes)
        // Paragraph two, reworded from the CR: it no longer points at `Konfiguracja…`, which
        // §2.9 removes, so the not-installed variant says only that the app must be opened by
        // hand after each login (DESIGN §7).
        let startup = agentInstalled
            ? "Real Screen Time starts when your child logs in, and starts again if it is ever quit "
              + "or killed."
            : "Real Screen Time will not start on its own. You will need to open it after each "
              + "login."
        let visibility = "The countdown sits in the menu bar the whole time. Settings and "
            + "extra minutes are behind your PIN; everything the app does is written to a log "
            + "you can read."
        bodyLabel.stringValue = [sessions, startup, visibility].joined(separator: "\n\n")
    }

    // MARK: - Buttons

    private func updateNextButton() {
        // The middle button belongs to step 4 alone; hidden, it collapses out of the row.
        altButton.isHidden = step != .login
        switch step {
        case .welcome:
            nextButton.title = "Continue"
            nextButton.isEnabled = true
        case .pin:
            nextButton.title = "Continue"
            // The only step that cannot be walked past. DESIGN §2.5: an app with no PIN
            // must never cover the screen, so a wizard that let you through here would
            // produce an app that does nothing at all.
            nextButton.isEnabled = settledPIN != nil
        case .sessions:
            nextButton.title = saving ? "Saving…" : "Continue"
            nextButton.isEnabled = !saving
        case .login:
            // §2.3: install is the primary, rightmost, disabled until the arming delay
            // elapses. `Finish without it` sits immediately left of it and needs no seatbelt.
            nextButton.title = "Install login item"
            nextButton.isEnabled = loginArmed
            altButton.title = "Finish without it"
            altButton.isEnabled = true
        case .done:
            // The terminal screen: one `Finish` button, which only closes the window (the
            // config was already written or deliberately not). No seatbelt — nothing here can
            // reach `launchctl`.
            nextButton.title = "Finish"
            nextButton.isEnabled = true
        }
        backButton.isEnabled = !saving
    }

    /// **A key held down delivers repeats, and a repeat must never advance the wizard.**
    /// The same argument `PINBoxes` makes about the fourth digit: without this, one Return
    /// held through step 3's one-second save arrives on whatever step it produced.
    ///
    /// **The event type has to be checked first, and this cost a hand run** (2026-08-26).
    /// `NSEvent.isARepeat` raises `NSInternalInconsistencyException` on anything that is not
    /// a key event — so reading it during a *mouse* click threw, `NSApplication` swallowed
    /// the exception the way T00 found it swallows them, and `Continue` silently did
    /// nothing. A button that does nothing and logs nothing is the worst shape this bug
    /// could have taken.
    private var isKeyRepeat: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .keyDown, .keyUp: return event.isARepeat
        default: return false
        }
    }

    @objc private func backPressed() {
        guard !isKeyRepeat, let previous = step.previous, previous >= entryStep else { return }
        show(previous)
    }

    @objc private func nextPressed() {
        guard !isKeyRepeat else { return }
        switch step {
        case .welcome:
            show(.pin)

        case .pin:
            guard settledPIN != nil else { return }
            show(.sessions)

        case .sessions:
            guard let typed = readLimits() else { return }
            limits = typed
            // **Walked back from step 4, where the PIN is already hashed and deliberately
            // forgotten** (see ``hashed(_:)``). `saveAnswers` needs `settledPIN` and would
            // have returned in silence — a Continue button that does nothing and logs
            // nothing, the exact shape the `isARepeat` defect took. Only the two numbers can
            // still change at this point, so change them and go on; a parent who wants a
            // different PIN walks back one more step, which re-arms the whole path.
            if settledPIN == nil, var waiting = pendingAnswers {
                waiting.limits = typed
                pendingAnswers = waiting
                show(.login)
                return
            }
            saveAnswers()

        case .login:
            // The primary is `Install login item`. The button is disabled inside the arming
            // window; this guard is the belt to those braces, so a key equivalent cannot slip
            // through either. See ``showLogin()``.
            guard loginArmed else { return }
            installAndFinish()

        case .done:
            // `Finish`. The answers were committed on the way out either way (see `close()`);
            // this just dismisses the terminal screen.
            close()
        }
    }

    /// The two controls, or `nil` with the reason already on screen.
    private func readLimits() -> SessionLimits? {
        // The pop-up can only yield a whole number — one of its rows, including the shown
        // out-of-range one — so only the combo box's free text can fail to parse.
        guard let minutes = Int(minutesCombo.stringValue.trimmingCharacters(in: .whitespaces))
        else {
            complain("Session length needs a whole number of minutes.")
            return nil
        }
        let sessions = SessionsPerDayChoice.value(atIndex: sessionsPopUp.indexOfSelectedItem,
                                                  storedValue: limits.sessionsPerDay)
        let typed = SessionLimits(minutes: minutes, sessionsPerDay: sessions)
        switch typed.problem {
        case nil:
            return typed
        case .sessionTooShort:
            complain("A session has to be at least one minute long.")
        case .negativeSessions:
            complain("Sessions per day cannot be negative. Zero is allowed, "
                     + "and means every session needs your PIN.")
        }
        return nil
    }

    private func complain(_ text: String) {
        noteLabel.stringValue = text
        noteLabel.textColor = .systemOrange
    }

    /// **Hashed here, written when the window closes** — and that difference is the whole of
    /// a defect found by hand on 2026-08-26.
    ///
    /// Writing `config.json` is what *arms* the app: DESIGN §2.5's first rule is that no PIN
    /// means no cover, so the moment a PIN lands on disk the next tick covers the screen. It
    /// used to be written here, leaving step 3 — so the cover went up **on top of the
    /// wizard**, and step 4 lived out its life underneath a full-screen kiosk window. The
    /// login item was never installed, because nobody could see the button:
    ///
    ///     18:30:20.664  cover: up on 2 window(s)
    ///     18:30:20.689  first run: configured
    ///
    /// **Deferring the write beats suppressing the cover.** A suppression would be a new
    /// rule saying the app declines to enforce while some window is open, and
    /// `Konfiguracja…` opens one from the menu — left open, that would be a way to keep the
    /// screen free indefinitely. This way §2.5's existing rule does all the work: while the
    /// wizard is up there is no PIN, so there is nothing to suppress.
    ///
    /// The hash stays here, with its `Saving…`, because it is the slow part (~0.5 s, see
    /// `pinRounds`) and here is where the parent is looking.
    private func saveAnswers() {
        guard let pin = settledPIN else { return }
        saving = true
        updateNextButton()
        noteLabel.stringValue = ""

        let limits = self.limits
        // ~0.5 s at the shipped rounds, and a second in a debug build — see `pinRounds`.
        // On the main thread that is a window that stops redrawing while a parent watches.
        DispatchQueue.global(qos: .userInitiated).async {
            let salt = newPINSalt()
            let answers = FirstRunAnswers(limits: limits,
                                          pinHash: hashPIN(pin, salt: salt),
                                          pinSalt: salt.base64EncodedString())
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.hashed(answers) }
            }
        }
    }

    private func hashed(_ answers: FirstRunAnswers) {
        saving = false
        settledPIN = nil          // not held a moment longer than the hash needed it
        pendingAnswers = answers
        show(.login)
    }

    /// Write the answers, if there are any waiting. Called from **both** ways out of the
    /// window: `Finish` and the red button are the same act as far as the four questions
    /// are concerned. See ``saveAnswers()`` for why it is not done a step earlier.
    private func commitAnswers() {
        guard let answers = pendingAnswers else { return }
        pendingAnswers = nil
        if let failure = save(answers) {
            // The window is on its way out and there is nowhere left to show this. The app
            // stays unconfigured, which means it enforces nothing and asks again at the next
            // launch — the correct failure, and one DESIGN §2.5 already describes.
            diagnostics("first run: could not save the config — \(failure)", at: clock.now)
            FileHandle.standardError.write(Data("RealScreenTime: \(failure)\n".utf8))
            return
        }
        diagnostics("first run: configured — \(answers.limits.minutes) min, "
                    + "\(answers.limits.sessionsPerDay) self-service session(s) a day",
                    at: clock.now)
    }

    /// `Install login item` — the step-4 primary. Installs the login item, then finishes. On a
    /// failure the wizard stays so the parent can read the reason and retry or finish without
    /// it. Guarded by the arming delay in ``showLogin()``, and by the ``isKeyRepeat`` check in
    /// ``nextPressed()`` that dispatches here.
    private func installAndFinish() {
        switch LaunchAgentInstaller.install(diagnostics: diagnostics, at: clock.now) {
        case .bootstrapped, .alreadyLoaded:
            agentInstalled = true
            // Not `close()`: the wizard now ends on the terminal screen (CR-01 §4), which
            // reports what was set and installed. The config is written when that screen's
            // `Finish` closes the window — deferring the write past this screen keeps the cover
            // from landing while a window is still up (see ``saveAnswers()``).
            show(.done)
        case .notInstalled:
            complain("Real Screen Time is not in your Applications folder yet. "
                     + "Drag it there, then try again.")
        case .failed(let message):
            complain("It could not be installed. \(message)")
        }
    }

    /// `Finish without it` — step 4's middle button. Closes without touching the login item;
    /// the choice is logged because it is otherwise invisible. No key equivalent (see
    /// ``buildChrome()``), so a held Return cannot reach it.
    @objc private func finishWithoutPressed() {
        guard !isKeyRepeat else { return }
        diagnostics("first run: finished without the login item — the app will not "
                    + "start by itself at the next login", at: clock.now)
        // To the terminal screen, not straight out (CR-01 §4): its not-installed paragraph is
        // what finally makes this silent choice visible. The config lands when `Finish` there
        // closes the window.
        show(.done)
    }

    // MARK: - Closing

    private func close() {
        window.delegate = nil
        window.orderOut(nil)
        Self.showing = nil
        restoreDockIcon()
        // Before `onClose()`, which runs a tick: the tick is what puts the cover up, and it
        // has to see the config this wizard just produced. The window is ordered out first,
        // so the cover never lands on top of it.
        commitAnswers()
        onClose()
    }

    /// The red button or `Cmd+W`. Whatever has been saved stays saved; what has not is
    /// asked again next time.
    func windowWillClose(_ notification: Notification) {
        diagnostics("first run: wizard closed at step "
                    + "\(step.position.map { String($0.index) } ?? "done (final screen)")",
                    at: clock.now)
        window.delegate = nil
        Self.showing = nil
        restoreDockIcon()
        // **One hop.** Unlike ``close()``, the window is still on screen inside
        // `windowWillClose`, and committing the answers here runs a tick that can put the
        // cover up — landing it on top of a window in the act of disappearing. The closure
        // holds `self`, which `Self.showing = nil` has just stopped doing.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.commitAnswers()
                self.onClose()
            }
        }
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

    private func field(_ control: NSView, _ title: String, _ unit: String) -> NSView {
        let name = Self.label(size: 13, weight: .regular)
        name.stringValue = title
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let suffix = Self.label(size: 13, weight: .regular)
        suffix.stringValue = unit
        suffix.textColor = .secondaryLabelColor

        let row = NSStackView(views: [name, control, suffix])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}
