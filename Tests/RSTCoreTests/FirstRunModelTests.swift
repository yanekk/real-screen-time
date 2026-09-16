import Foundation
import Testing
@testable import RSTCore

/// The first-run wizard's rules — DESIGN §6, T16.
///
/// The window is `RSTApp`'s and can only be seen by a person; what is proved here is
/// everything the window is not allowed to get wrong. Two of these are the reason the file
/// exists at all: **a PIN this app could never check again**, and **a plist pointing at a
/// build directory**. Both are silent when they happen and expensive when they are found.
@Suite("First-run wizard")
struct FirstRunModelTests {

    // MARK: - The steps

    @Test("the steps run welcome → PIN → limits → login → the terminal screen")
    func stepOrder() {
        #expect(FirstRunStep.allCases == [.welcome, .pin, .sessions, .login, .done])
        #expect(FirstRunStep.welcome.next == .pin)
        #expect(FirstRunStep.pin.next == .sessions)
        #expect(FirstRunStep.sessions.next == .login)
        #expect(FirstRunStep.login.next == .done)
        #expect(FirstRunStep.done.next == nil)
        #expect(FirstRunStep.welcome.previous == nil)
        #expect(FirstRunStep.login.previous == .sessions)
        #expect(FirstRunStep.done.previous == .login)
    }

    /// The terminal screen has no number, so a fifth case must not renumber the four real
    /// steps — the welcome screen promises four questions (CR-01 §4).
    @Test("the four numbered steps count from one of four; the terminal screen has no number")
    func stepPosition() {
        #expect(FirstRunStep.welcome.position?.index == 1)
        #expect(FirstRunStep.welcome.position?.count == 4)
        #expect(FirstRunStep.pin.position?.index == 2)
        #expect(FirstRunStep.sessions.position?.index == 3)
        #expect(FirstRunStep.login.position?.index == 4)
        #expect(FirstRunStep.login.position?.count == 4)
        #expect(FirstRunStep.done.position == nil)
    }

    // MARK: - The terminal screen's first paragraph (CR-01 §4, T02)

    @Test("paragraph one agrees its noun and pronoun with the session count")
    func finalScreenAgreement() {
        #expect(FinalScreenSummary.sessionsParagraph(sessionsPerDay: 1, minutes: 30)
            == "Your child gets one session of 30 minutes a day, and he can start it himself. "
             + "Anything beyond that needs your PIN, and you choose the amount at the time.")
        #expect(FinalScreenSummary.sessionsParagraph(sessionsPerDay: 2, minutes: 30)
            == "Your child gets 2 sessions of 30 minutes a day, and he can start them himself. "
             + "Anything beyond that needs your PIN, and you choose the amount at the time.")
    }

    @Test("zero sessions gets the distinct every-session-needs-a-PIN sentence")
    func finalScreenZero() {
        #expect(FinalScreenSummary.sessionsParagraph(sessionsPerDay: 0, minutes: 30)
            == "Every session needs your PIN. Your child cannot start one himself — you grant the "
             + "minutes, and you choose how many at the time.")
        // The zero case carries no session length — there is no self-service session to size.
        #expect(!FinalScreenSummary.sessionsParagraph(sessionsPerDay: 0, minutes: 45)
            .contains("45"))
    }

    @Test("paragraph one's minutes figure follows the session length")
    func finalScreenMinutes() {
        #expect(FinalScreenSummary.sessionsParagraph(sessionsPerDay: 1, minutes: 30)
            .contains("of 30 minutes"))
        #expect(FinalScreenSummary.sessionsParagraph(sessionsPerDay: 1, minutes: 45)
            .contains("of 45 minutes"))
    }

    // MARK: - Where setup resumes

    @Test("with no PIN the wizard starts at the beginning")
    func entryStepUnconfigured() {
        #expect(firstRunEntryStep(isConfigured: false) == .welcome)
    }

    /// **A PIN that exists must never be re-settable from an ungated menu item.** The child
    /// owns his own `~/Library/LaunchAgents`, so he can delete the login item and make the
    /// setup entry reappear; if that reopened a wizard with step 2 on it he could choose a
    /// PIN of his own and own the app. Reopened, there is exactly one thing left to finish.
    @Test("with a PIN already set it reopens at the login item, past the PIN step")
    func entryStepConfigured() {
        let entry = firstRunEntryStep(isConfigured: true)
        #expect(entry == .login)
        #expect(entry > .pin)
    }

    // MARK: - Step 2: the PIN

    /// The step opens with two empty boxes, and that is not a mistake to report.
    @Test("nothing typed is not an error")
    func emptyIsNotAnError() {
        #expect(firstRunPINProblem(entered: "", repeated: "") == .empty)
    }

    @Test("a matching four-digit pair is accepted")
    func goodPair() {
        #expect(firstRunPINProblem(entered: "0000", repeated: "0000") == nil)
        #expect(firstRunPINProblem(entered: "9137", repeated: "9137") == nil)
    }

    @Test("the second entry has to match")
    func mismatch() {
        #expect(firstRunPINProblem(entered: "1234", repeated: "1235") == .mismatch)
        #expect(firstRunPINProblem(entered: "1234", repeated: "") == .mismatch)
    }

    /// **The rule the whole file is here for.** T13's prompt is exactly `pinDigits` boxes
    /// that submit themselves on the last digit, so a PIN of any other length can never be
    /// typed into the thing that lifts the cover — and the hash reveals no length, so
    /// nothing downstream would ever notice. A five-digit PIN written here is a cover with
    /// no key, and the only way out of that is the reboot in RECOVERY.md.
    @Test("a PIN that T13's boxes could never accept is refused",
          arguments: ["1", "12", "123", "12345", "123456"])
    func wrongLength(_ pin: String) {
        #expect(firstRunPINProblem(entered: pin, repeated: pin) == .wrongLength(pin.count))
    }

    @Test("four digits is exactly four digits")
    func rightLengthIsFour() {
        #expect(pinDigits == 4)
    }

    /// Unreachable through `PINBoxes`, which takes no other key — checked because this
    /// function is the rule and that view is one caller of it.
    @Test("non-digits are refused", arguments: ["abcd", "12 4", "1.34", "12-4", "١٢٣٤"])
    func notDigits(_ pin: String) {
        #expect(firstRunPINProblem(entered: pin, repeated: pin) == .notDigits)
    }

    /// `Character.isNumber` is true for Eastern Arabic digits, and a PIN that hashes one
    /// set of code points while its owner believes they typed `1234` is a PIN nobody can
    /// reproduce. The wrong-length answer would be wrong here too — `١٢٣٤` *is* four.
    @Test("non-ASCII digits are refused as characters, not as a length")
    func easternArabicIsNotFourDigits() {
        #expect(firstRunPINProblem(entered: "١٢٣٤", repeated: "١٢٣٤") == .notDigits)
    }

    @Test("a mismatch is reported before it is hashed, whichever side is short")
    func shortSecondEntry() {
        #expect(firstRunPINProblem(entered: "1234", repeated: "123") == .mismatch)
        #expect(firstRunPINProblem(entered: "123", repeated: "1234") == .wrongLength(3))
    }

    // MARK: - Step 3: the limits

    @Test("the fields are pre-filled with what the app ships")
    func suggestedLimits() {
        #expect(SessionLimits.suggested == SessionLimits(minutes: 30, sessionsPerDay: 1))
        #expect(SessionLimits.suggested.problem == nil)
    }

    /// A zero-minute session starts already spent: the cover goes straight back up and
    /// `Rozpocznij` becomes a button that does nothing.
    @Test("a session shorter than a minute is refused", arguments: [0, -1, -30])
    func sessionTooShort(_ minutes: Int) {
        let limits = SessionLimits(minutes: minutes, sessionsPerDay: 1)
        #expect(limits.problem == .sessionTooShort)
    }

    /// Zero is a setting, not a mistake: every session then needs a parent (DESIGN §2.1).
    @Test("zero self-service sessions is legal")
    func zeroSessionsIsLegal() {
        #expect(SessionLimits(minutes: 30, sessionsPerDay: 0).problem == nil)
    }

    @Test("a negative session count is not a stricter setting")
    func negativeSessions() {
        #expect(SessionLimits(minutes: 30, sessionsPerDay: -1).problem == .negativeSessions)
    }

    @Test("a long session is the parent's business")
    func longSessionIsAllowed() {
        #expect(SessionLimits(minutes: 240, sessionsPerDay: 3).problem == nil)
    }

    // MARK: - Step 3's controls: the sessions-per-day pop-up (CR-01 §2)

    /// Five rows for any in-range stored value: None first (value 0), then 1…4.
    @Test("the pop-up shows None then 1…4 for an in-range value", arguments: [0, 1, 2, 3, 4])
    func sessionsPopUpInRange(_ stored: Int) {
        let items = SessionsPerDayChoice.items(storedValue: stored)
        #expect(items.count == 5)
        #expect(items[0] == SessionsItem(value: 0, isNoneCase: true))
        #expect(items.map(\.value) == [0, 1, 2, 3, 4])
        // None is the only None case; the rest are ordinary counts.
        #expect(items.filter(\.isNoneCase).count == 1)
    }

    /// **The append-don't-clamp rule (DESIGN §2.2).** A hand-edited `7` must be shown, not
    /// silently rewritten to 4 the next time the window saves.
    @Test("a stored value beyond the cap is appended, not clamped")
    func sessionsPopUpOutOfRange() {
        let items = SessionsPerDayChoice.items(storedValue: 7)
        #expect(items.count == 6)
        #expect(items.last == SessionsItem(value: 7, isNoneCase: false))
        #expect(SessionsPerDayChoice.selectedIndex(storedValue: 7) == 5)
    }

    @Test("the pre-selected row is the one matching the stored value",
          arguments: [(0, 0), (1, 1), (4, 4), (7, 5)])
    func sessionsSelectedIndex(_ pair: (stored: Int, index: Int)) {
        #expect(SessionsPerDayChoice.selectedIndex(storedValue: pair.stored) == pair.index)
    }

    /// The two-way mapping: each row index resolves to the `sessionsPerDay` it stands for,
    /// including 0 for None and the appended out-of-range value.
    @Test("a chosen row maps to the right sessionsPerDay")
    func sessionsValueAtIndex() {
        #expect(SessionsPerDayChoice.value(atIndex: 0, storedValue: 1) == 0)   // None
        #expect(SessionsPerDayChoice.value(atIndex: 1, storedValue: 1) == 1)
        #expect(SessionsPerDayChoice.value(atIndex: 4, storedValue: 1) == 4)
        #expect(SessionsPerDayChoice.value(atIndex: 5, storedValue: 7) == 7)   // appended
        // Out of bounds falls back to None's 0, never a crash.
        #expect(SessionsPerDayChoice.value(atIndex: 9, storedValue: 1) == 0)
    }

    /// The pop-up cannot express a negative count: picking None yields 0, and 0 is legal.
    /// `SessionLimits.problem` still governs a value the pop-up produces.
    @Test("None yields zero, and zero still passes the limits rule")
    func noneIsZeroAndLegal() {
        let none = SessionsPerDayChoice.value(atIndex: 0, storedValue: 2)
        #expect(none == 0)
        #expect(SessionLimits(minutes: 30, sessionsPerDay: none).problem == nil)
    }

    // MARK: - Step 3's controls: the combo suggestion list (CR-01 §2)

    @Test("session length suggests the five common values")
    func sessionLengthSuggestions() {
        #expect(ComboSuggestions.sessionLength == [15, 20, 30, 45, 60])
    }

    @Test("a stored value already suggested leaves the list untouched")
    func mergedKeepsListWhenPresent() {
        #expect(ComboSuggestions.merged(ComboSuggestions.sessionLength, storedValue: 30)
                == [15, 20, 30, 45, 60])
    }

    @Test("a stored value not suggested is appended without reordering or duplicating")
    func mergedAppendsWhenAbsent() {
        #expect(ComboSuggestions.merged(ComboSuggestions.sessionLength, storedValue: 25)
                == [15, 20, 30, 45, 60, 25])
        // Idempotent: merging a value that the merge itself added does not double it.
        let once = ComboSuggestions.merged(ComboSuggestions.sessionLength, storedValue: 25)
        #expect(ComboSuggestions.merged(once, storedValue: 25) == once)
    }

    /// A combo value the parent types is still the combo's to validate — the merge rule only
    /// governs what the list shows, never whether a value is allowed. Zero minutes is still
    /// rejected by ``SessionLimits/problem``.
    @Test("the combo's value is still governed by the limits rule")
    func comboValueStillValidated() {
        #expect(SessionLimits(minutes: 0, sessionsPerDay: 1).problem == .sessionTooShort)
        #expect(SessionLimits(minutes: 25, sessionsPerDay: 1).problem == nil)
    }

    // MARK: - What gets written

    @Test("the wizard's answers make a configured app")
    func answersConfigure() {
        let salt = newPINSalt()
        let answers = FirstRunAnswers(limits: SessionLimits(minutes: 45, sessionsPerDay: 2),
                                      pinHash: hashPIN("1234", salt: salt, rounds: 1),
                                      pinSalt: salt.base64EncodedString())
        let config = Config().applying(answers)
        #expect(config.isConfigured)
        #expect(config.sessionMinutes == 45)
        #expect(config.selfServiceSessionsPerDay == 2)
        #expect(verifyPIN("1234", hash: config.pinHash,
                          salt: config.pinSaltData ?? Data(), rounds: 1))
    }

    /// The wizard is not the only way a `config.json` comes into existence: a hand-edited
    /// file with no `pin_hash` re-runs the wizard (DESIGN §6), and that file's thresholds
    /// and grant amounts are the parent's. Rebuilding a fresh `Config()` would bin them.
    @Test("everything the wizard was not asked about survives")
    func unrelatedSettingsSurvive() {
        var existing = Config()
        existing.warningMinutes = [7]
        existing.extensionOptions = [90]
        existing.idleGraceSeconds = 123
        existing.dayResetHour = 4

        let salt = newPINSalt()
        let applied = existing.applying(
            FirstRunAnswers(limits: .suggested,
                            pinHash: hashPIN("4321", salt: salt, rounds: 1),
                            pinSalt: salt.base64EncodedString()))

        #expect(applied.warningMinutes == [7])
        #expect(applied.extensionOptions == [90])
        #expect(applied.idleGraceSeconds == 123)
        #expect(applied.dayResetHour == 4)
    }

    @Test("what the wizard writes round-trips through the store")
    func roundTripsThroughDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rst-firstrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory)
        let salt = newPINSalt()
        let written = Config().applying(
            FirstRunAnswers(limits: SessionLimits(minutes: 20, sessionsPerDay: 0),
                            pinHash: hashPIN("5678", salt: salt, rounds: 1),
                            pinSalt: salt.base64EncodedString()))
        try store.save(written)

        let reloaded = store.load()
        #expect(reloaded.outcome == .loaded)
        #expect(reloaded.config == written)
        #expect(reloaded.config.isConfigured)
    }

    // MARK: - The LaunchAgent's plist

    @Test("the plist says what DESIGN §2.7 needs it to say")
    func plistContents() throws {
        let data = try LaunchAgent.plistData(programPath: LaunchAgent.installedBinaryPath)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        let unwrapped = try #require(plist)

        #expect(unwrapped["Label"] as? String == "com.krolikowski.realscreentime.agent")
        #expect(unwrapped["ProgramArguments"] as? [String] == [LaunchAgent.installedBinaryPath])
        // The two that carry the design: start at login, and start again when killed.
        #expect(unwrapped["RunAtLoad"] as? Bool == true)
        #expect(unwrapped["KeepAlive"] as? Bool == true)
    }

    /// Hand-written XML would have needed escaping, and a plist that has to be escaped
    /// correctly is a plist that will one day be escaped incorrectly.
    @Test("a path with XML in it survives the round trip")
    func plistEscaping() throws {
        let awkward = "/Applications/A & B <test>.app/Contents/MacOS/RealScreenTime"
        let data = try LaunchAgent.plistData(programPath: awkward)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        #expect(plist?["ProgramArguments"] as? [String] == [awkward])
    }

    @Test("the file is named after the label")
    func plistFileName() {
        #expect(LaunchAgent.plistFileName == LaunchAgent.label + ".plist")
    }

    @Test("the launchctl targets are the ones the runbook uses")
    func targets() {
        #expect(LaunchAgent.serviceTarget(uid: 502)
                == "gui/502/com.krolikowski.realscreentime.agent")
        #expect(LaunchAgent.domainTarget(uid: 502) == "gui/502")
    }

    // MARK: - Which binary the plist points at

    @Test("the installed app names itself")
    func programWhenInstalled() {
        let resolved = LaunchAgent.program(runningBinary: LaunchAgent.installedBinaryPath,
                                           installedBinaryExists: true)
        #expect(resolved == .running(path: LaunchAgent.installedBinaryPath))
    }

    /// **The gotcha the task doc names.** A LaunchAgent pointing into `.build/debug`
    /// survives a `swift build` and then silently stops having anything to launch the first
    /// time the package is cleaned — a half-working state nobody would think to look at.
    @Test("a development build never puts its own path in the plist")
    func developmentBuildNamesTheInstalledCopy() {
        let resolved = LaunchAgent.program(
            runningBinary: "/Users/child/src/real-screen-time/.build/debug/RealScreenTime",
            installedBinaryExists: true)
        #expect(resolved == .installed(path: LaunchAgent.installedBinaryPath))
        #expect(resolved.path == LaunchAgent.installedBinaryPath)
    }

    @Test("with nothing in /Applications the step has nothing to write")
    func notInstalled() {
        let resolved = LaunchAgent.program(
            runningBinary: "/Users/child/src/real-screen-time/.build/debug/RealScreenTime",
            installedBinaryExists: false)
        #expect(resolved == .notInstalled)
        #expect(resolved.path == nil)
    }

    /// `swift run` resolves through symlinks and `..` differently depending on how it was
    /// invoked; the comparison has to be about the file, not about the spelling.
    @Test("an unstandardised path to the installed binary is still the installed binary")
    func pathIsStandardisedBeforeComparing() {
        let noisy = "/Applications/RealScreenTime.app/Contents/MacOS/../MacOS/RealScreenTime"
        #expect(LaunchAgent.program(runningBinary: noisy, installedBinaryExists: true)
                == .running(path: LaunchAgent.installedBinaryPath))
    }
}
