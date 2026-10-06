import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **Settings, in memory** (DESIGN §2.1 Tier 1, §2.2 faithful-in-memory band; T05).
///
/// The rules the window holds a parent to — what may be saved, how a stored value merges into a
/// combo's list, how detection converts between seconds and minutes — are ``SettingsDraft`` and
/// its neighbours in `RSTCore`, unit-tested there. What is under test here is the AppKit wiring
/// in `Settings.swift`: that ``SettingsWindow/fill()`` puts the config on the real controls,
/// that a bad value moves the keyboard to the offending control and refuses to save, and that a
/// good one round-trips back out through ``SettingsWindow/readDraft()`` to the host.
///
/// Everything is built through ``SettingsWindow/buildForTesting(host:clock:diagnostics:)`` — the
/// build-but-do-not-show seam (§3.1) — so no window is ordered onto a display and the activation
/// policy is never taken to `.regular`. The scan in `WindowScanTests` guards that this file names
/// none of the ordering calls.
///
/// Fully synchronous, no run-loop pump: `savePressed` reads the fields, calls the host's save
/// closure and closes, with no queue hop or `Timer` to wait on. Serialized like the other headed
/// suites because each body swaps the process-global `RST_DATA_DIR` through `HeadedHarness.withApp`.
@Suite("Settings headed", .serialized)
@MainActor
struct SettingsHeadedTests {

    // MARK: - Filling the controls

    /// Every control comes up showing what the config holds — the combos as their numbers, the
    /// grace combos converted to minutes, the token fields one pill per number, the pop-up on the
    /// row its stored value maps to. A regression in ``fill()`` for any one of them fails here.
    @Test("the controls build and reflect the config")
    func controlsReflectTheConfig() {
        HeadedHarness.withApp { _ in
            let recorder = Recorder(config: Self.distinctiveConfig)
            let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)
            let c = settings.testControls

            #expect(Self.combo(c[.sessionMinutes]).stringValue == "45")
            #expect(Self.combo(c[.dayResetHour]).stringValue == "7")
            // Detection is stored in seconds and shown in whole minutes (`GraceMinutes`).
            #expect(Self.combo(c[.idleGraceSeconds]).stringValue == "5")     // 300 s
            #expect(Self.combo(c[.mediaGraceSeconds]).stringValue == "45")   // 2700 s
            #expect(Self.tokens(c[.extensionOptions]) == ["15", "30"])
            #expect(Self.tokens(c[.warningMinutes]) == ["10", "5"])

            let popUp = c[.selfServiceSessionsPerDay] as! NSPopUpButton
            #expect(popUp.indexOfSelectedItem == SessionsPerDayChoice.selectedIndex(storedValue: 2))
        }
    }

    /// A grant list stored unsorted opens ascending, the order `Dodaj minuty` draws it in
    /// (sort-grant-amounts).
    @Test("an unsorted grant list fills the field ascending")
    func grantsFieldOpensSorted() {
        HeadedHarness.withApp { _ in
            var config = Self.distinctiveConfig
            config.extensionOptions = [15, 30, 60, 5, 10]
            let recorder = Recorder(config: config)
            let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)
            #expect(Self.tokens(settings.testControls[.extensionOptions])
                    == ["5", "10", "15", "30", "60"])
        }
    }

    // MARK: - Invalid input

    /// A non-numeric value blocks the save and sends the keyboard to the box that caused it — not
    /// to the first box, the exact wrong-field bug T17's review caught. `dayResetHour` is made
    /// invalid while `sessionMinutes` (parsed first) stays good, so the focus landing on the hour
    /// combo and not the minutes combo proves the complaint is filed under the offending control.
    @Test("invalid input focuses the offending control and blocks the save")
    func invalidInputFocusesAndBlocks() {
        HeadedHarness.withApp { _ in
            let recorder = Recorder(config: Self.distinctiveConfig)
            let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)
            let c = settings.testControls

            Self.combo(c[.dayResetHour]).stringValue = "abc"     // sessionMinutes stays "45"
            settings.testSaveButton.performClick(nil)

            #expect(recorder.saved.isEmpty)                       // nothing committed
            #expect(settings.testWindow.delegate != nil)          // window not closed (still open)
            #expect(Self.isFocused(c[.dayResetHour]!, in: settings.testWindow))
            #expect(!Self.isFocused(c[.sessionMinutes]!, in: settings.testWindow))
        }
    }

    // MARK: - Valid input

    /// A good form saves the values read back off the controls — edited ones included — and then
    /// closes, which is the confirmation (DESIGN §2.8). Editing the session length and the grants
    /// before saving proves the round-trip reads the live controls, not the seed draft.
    @Test("valid input saves the round-tripped values and closes")
    func validInputSavesAndCloses() {
        HeadedHarness.withApp { _ in
            let recorder = Recorder(config: Self.distinctiveConfig)
            let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)
            let c = settings.testControls

            Self.combo(c[.sessionMinutes]).stringValue = "50"
            (c[.extensionOptions] as! NSTokenField).objectValue = ["20", "40"]
            settings.testSaveButton.performClick(nil)

            #expect(recorder.saved.count == 1)
            let saved = recorder.saved.first
            #expect(saved?.sessionMinutes == 50)
            #expect(saved?.extensionOptions == [20, 40])
            // The untouched fields round-trip unchanged — hour, the two graces (in seconds),
            // warnings and sessions-per-day all as the config held them.
            #expect(saved?.dayResetHour == 7)
            #expect(saved?.idleGraceSeconds == 300)
            #expect(saved?.mediaGraceSeconds == 2700)
            #expect(saved?.warningMinutes == [10, 5])
            #expect(saved?.selfServiceSessionsPerDay == 2)
            // On success the window closes, and `close()` clears the delegate — the signal that
            // the save path ran rather than a validation failure that keeps the window open.
            #expect(settings.testWindow.delegate == nil)
        }
    }

    // MARK: - Remote pairing (DESIGN §2.4, T06)

    /// The status line renders each of the three ``PairingStatus`` states with the exact text the
    /// interface sketch fixes, and `Unpair` is live only when a token is stored. Driving
    /// ``SettingsWindow/testRefreshPairingStatus()`` is the synchronous stand-in for the once-a-
    /// second timer the presenting path runs.
    @Test("the status line renders the three pairing states and gates Unpair")
    func pairingStatusStates() {
        HeadedHarness.withApp { _ in
            let recorder = Recorder(config: Self.distinctiveConfig)
            let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)

            recorder.pairingStatus = .notPaired
            settings.testRefreshPairingStatus()
            #expect(settings.testPairingStatusLabel.stringValue == "Not paired")
            #expect(settings.testUnpairButton.isEnabled == false)

            recorder.pairingStatus = .paired
            settings.testRefreshPairingStatus()
            #expect(settings.testPairingStatusLabel.stringValue == "Paired")
            #expect(settings.testUnpairButton.isEnabled == true)

            recorder.pairingStatus = .expired
            settings.testRefreshPairingStatus()
            #expect(settings.testPairingStatusLabel.stringValue == "Paired — token rejected, re-pair")
            #expect(settings.testUnpairButton.isEnabled == true)
        }
    }

    /// Once a Mac is paired, entering a code can do nothing, so the whole "Pairing code" row —
    /// label, field and `Pair` — is hidden (field and button also disabled) and the section reads
    /// as just "Paired" plus `Unpair` (T12; the label too since 2026-09-23). `.notPaired` shows
    /// them, and `.expired` keeps them — a rejected token is exactly when a fresh code is needed.
    @Test("the code field and Pair are hidden when paired, shown when a code can act")
    func codeEntryVisibilityFollowsPairingState() {
        HeadedHarness.withApp { _ in
            let recorder = Recorder(config: Self.distinctiveConfig)
            let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)

            #expect(settings.testPairingCodeRow != nil)

            recorder.pairingStatus = .notPaired
            settings.testRefreshPairingStatus()
            #expect(settings.testPairingCodeRow?.isHidden == false)
            #expect(settings.testPairingCodeField.isHidden == false)
            #expect(settings.testPairingCodeField.isEnabled == true)
            #expect(settings.testPairButton.isHidden == false)
            #expect(settings.testPairButton.isEnabled == true)

            recorder.pairingStatus = .paired
            settings.testRefreshPairingStatus()
            // The whole row goes, "Pairing code" label included — not just the field (2026-09-23).
            #expect(settings.testPairingCodeRow?.isHidden == true)
            #expect(settings.testPairingCodeField.isHidden == true)
            #expect(settings.testPairingCodeField.isEnabled == false)
            #expect(settings.testPairButton.isHidden == true)
            #expect(settings.testPairButton.isEnabled == false)

            // Expired still needs a way back: the code entry returns so the parent can re-pair.
            recorder.pairingStatus = .expired
            settings.testRefreshPairingStatus()
            #expect(settings.testPairingCodeRow?.isHidden == false)
            #expect(settings.testPairingCodeField.isHidden == false)
            #expect(settings.testPairingCodeField.isEnabled == true)
            #expect(settings.testPairButton.isHidden == false)
            #expect(settings.testPairButton.isEnabled == true)
        }
    }

    /// `Pair` redeems the **trimmed** code through the host and shows the outcome. On success the
    /// field is cleared and the status line follows the host's new state; on a refusal the code is
    /// kept on screen with an English reason. Async because the redeem is — `testPair()` runs the
    /// exact work the button kicks off and is awaited, so no run loop is pumped.
    ///
    /// `withApp` is sync-only, so this does the little it needs by hand: the pairing path touches
    /// no `RST_DATA_DIR` state (the recorder holds config in memory and pairs through closures),
    /// it only needs the shared application to build the off-screen window.
    @Test("Pair redeems the trimmed code and shows the outcome")
    func pairRedeemsAndShowsOutcome() async {
        _ = NSApplication.shared
        let recorder = Recorder(config: Self.distinctiveConfig)
        let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)

        recorder.pairingStatus = .paired
        recorder.pairResult = nil                              // success
        settings.testPairingCodeField.stringValue = "  CODE123  "
        await settings.testPair()
        #expect(recorder.pairedCodes == ["CODE123"])           // trimmed before use
        #expect(settings.testPairingCodeField.stringValue == "")   // spent code cleared
        #expect(settings.testPairingStatusLabel.stringValue == "Paired")

        recorder.pairingStatus = .notPaired
        recorder.pairResult = .http(400)                       // a refused / expired code
        settings.testPairingCodeField.stringValue = "BADCODE"
        await settings.testPair()
        #expect(recorder.pairedCodes == ["CODE123", "BADCODE"])
        #expect(settings.testPairingCodeField.stringValue == "BADCODE")   // kept to retry
        #expect(settings.testPairingNoteLabel.stringValue.contains("refused"))
        #expect(settings.testPairingStatusLabel.stringValue == "Not paired")
    }

    /// A blank code is refused in the window with no round-trip — the non-empty rule is Core's
    /// (`PairingCode`), and the window spends no redeem to be told what it already knows. And
    /// `Unpair`, disabled when not paired, drives the host's unpair once enabled.
    @Test("a blank code is refused without a redeem, and Unpair drives the host")
    func blankCodeRefusedAndUnpair() async {
        _ = NSApplication.shared
        let recorder = Recorder(config: Self.distinctiveConfig)
        let settings = SettingsWindow.buildForTesting(host: recorder.host(), clock: Self.clock)

        recorder.pairingStatus = .notPaired
        settings.testRefreshPairingStatus()
        #expect(settings.testUnpairButton.isEnabled == false)

        settings.testPairingCodeField.stringValue = "   "
        await settings.testPair()
        #expect(recorder.pairedCodes.isEmpty)                  // no network round-trip
        #expect(!settings.testPairingNoteLabel.stringValue.isEmpty)

        recorder.pairingStatus = .paired
        settings.testRefreshPairingStatus()
        #expect(settings.testUnpairButton.isEnabled == true)
        settings.testUnpairButton.performClick(nil)
        #expect(recorder.unpairs == 1)
    }

    // MARK: - Fixtures

    static let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))

    /// A config whose every setting differs from the shipped default, so each control asserts a
    /// value the window actually carried rather than one it would have shown empty. Carries a PIN
    /// so `isConfigured` holds, though nothing here verifies one.
    static let distinctiveConfig: Config = {
        var config = Config()
        config.sessionMinutes = 45
        config.selfServiceSessionsPerDay = 2
        config.dayResetHour = 7
        config.idleGraceSeconds = 300         // 5 minutes
        config.mediaGraceSeconds = 2700       // 45 minutes
        config.warningMinutes = [10, 5]
        config.extensionOptions = [15, 30]
        config.pinSalt = Data([1, 2, 3, 4]).base64EncodedString()
        config.pinHash = "placeholder — no PIN is verified in these tests"
        return config
    }()

    // MARK: - Reading the controls

    static func combo(_ view: NSView?) -> NSComboBox { view as! NSComboBox }

    /// A token field's numbers as bare strings, read the same way ``readDraft()`` reads them.
    static func tokens(_ view: NSView?) -> [String] {
        ((view as! NSTokenField).objectValue as? [Any])?.map { "\($0)" } ?? []
    }

    /// Whether the keyboard is on `control` — either the control itself is first responder, or,
    /// as a text control on a window usually arranges, its field editor is and names the control
    /// as its delegate.
    static func isFocused(_ control: NSView, in window: NSWindow) -> Bool {
        if window.firstResponder === control { return true }
        if let editor = window.firstResponder as? NSText {
            return editor.delegate as AnyObject? === control
        }
        return false
    }
}

// MARK: - The recording host

/// **Stands in for `main.swift`'s ownership of the config and the store** (T05). The window owns
/// no state but the draft on its controls; everything else it reaches through the ``Host``
/// closures. This records the drafts a save produces so a headed test can assert what the window
/// committed — and returning `nil` from `saveSettings` is the success the window closes on.
@MainActor
final class Recorder {
    var config: Config
    private(set) var saved: [SettingsDraft] = []

    // Remote pairing (T06). The window reaches these through the `Host` closures below: the
    // status it shows, the outcome a redeem returns, and a record of the codes it redeemed and
    // the unpairs it asked for.
    var pairingStatus: PairingStatus = .notPaired
    var pairResult: RemoteClientError?
    private(set) var pairedCodes: [String] = []
    private(set) var unpairs = 0

    init(config: Config) { self.config = config }

    /// `saveResult` is what the save closure returns: `nil` on success, a message to stand for a
    /// write failure that keeps the window open.
    func host(saveResult: String? = nil) -> SettingsWindow.Host {
        SettingsWindow.Host(
            config: { self.config },
            sessionRunning: { false },
            saveSettings: { draft in self.saved.append(draft); return saveResult },
            savePIN: { _, _ in nil },
            eventsURL: URL(fileURLWithPath: "/dev/null"),
            dataDirectory: URL(fileURLWithPath: "/dev/null"),
            uninstall: { _ in },
            update: { .upToDate },
            isCovering: { false },
            remotePairingStatus: { self.pairingStatus },
            pairRemote: { code in self.pairedCodes.append(code); return self.pairResult },
            unpairRemote: { self.unpairs += 1 })
    }
}
