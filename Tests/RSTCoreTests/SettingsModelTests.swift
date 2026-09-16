import Foundation
import Testing
@testable import RSTCore

/// The settings window's rules — T17.
///
/// The window is `RSTApp`'s and can only be seen by a person; what is proved here is
/// everything it is not allowed to save. Two of them are why the file exists: **a grant
/// list with nothing on it**, which turns `Dodaj minuty…` into a PIN prompt that can grant
/// nothing (DESIGN §2.5), and **a session length of zero**, which covers the screen for ever
/// the first time a session is started.
@Suite("Settings window")
struct SettingsModelTests {

    /// The shipped config, as the window opens on a fresh install.
    private var shipped: SettingsDraft { SettingsDraft(Config()) }

    // MARK: - What the window opens with

    @Test("the draft opens on exactly what is in the config")
    func draftMirrorsConfig() {
        var config = Config()
        config.sessionMinutes = 45
        config.selfServiceSessionsPerDay = 2
        config.dayResetHour = 7
        config.idleGraceSeconds = 300
        config.mediaGraceSeconds = 900
        config.warningMinutes = [20, 5]
        config.extensionOptions = [10, 20]

        let draft = SettingsDraft(config)
        #expect(draft.sessionMinutes == 45)
        #expect(draft.selfServiceSessionsPerDay == 2)
        #expect(draft.dayResetHour == 7)
        #expect(draft.idleGraceSeconds == 300)
        #expect(draft.mediaGraceSeconds == 900)
        #expect(draft.warningMinutes == [20, 5])
        #expect(draft.extensionOptions == [10, 20])
    }

    /// **The repaired list is not what the parent typed.** `extensionChoices` turns a
    /// hand-edited `[]` back into the shipped three so the dialog always has an answer; a
    /// window that showed the repair would be telling a parent their file says something it
    /// does not, and hiding the one edit they need to fix.
    @Test("a hand-edited empty grant list is shown as empty, not as the shipped fallback")
    func draftShowsWhatIsOnDisk() {
        var config = Config()
        config.extensionOptions = []
        #expect(config.extensionChoices == Config.defaultExtensionOptions)
        #expect(SettingsDraft(config).extensionOptions == [])
        #expect(SettingsDraft(config).problem == .noGrants)
    }

    @Test("the shipped defaults are savable")
    func defaultsAreValid() {
        #expect(shipped.problem == nil)
    }

    // MARK: - Sessions

    @Test("a session length below one minute is rejected", arguments: [0, -1, -30])
    func sessionTooShort(minutes: Int) {
        var draft = shipped
        draft.sessionMinutes = minutes
        #expect(draft.problem == .sessionTooShort)
        #expect(draft.problem?.field == .sessionMinutes)
    }

    @Test("one minute is legal")
    func oneMinuteSession() {
        var draft = shipped
        draft.sessionMinutes = 1
        #expect(draft.problem == nil)
    }

    /// DESIGN §2.1: zero self-service sessions is a real setting — every minute of the day
    /// becomes a PIN decision. Negative is not a stricter version of it, it is a number
    /// nobody chose.
    @Test("zero sessions a day is legal and negative is not")
    func sessionsPerDay() {
        var draft = shipped
        draft.selfServiceSessionsPerDay = 0
        #expect(draft.problem == nil)

        draft.selfServiceSessionsPerDay = -1
        #expect(draft.problem == .negativeSessions)
        #expect(draft.problem?.field == .selfServiceSessionsPerDay)
    }

    /// **Every complaint has to point at the box it is about**, because that is the only
    /// thing `refuse` does with it: the message goes on the screen and the keyboard goes
    /// into `problem.field`. Sent to the wrong box it puts a cursor in a number that was
    /// perfectly good and leaves the offending one untouched — which is how
    /// `negativeSessions` behaved until the T17 review, grouped in the same `case` as
    /// `sessionTooShort` and inheriting its field.
    ///
    /// Written out case by case rather than derived, so that the expectation is an
    /// independent statement of the mapping and not a copy of it.
    @Test("every problem points at the box that caused it")
    func problemsPointAtTheirOwnField() {
        let expected: [(SettingsProblem, SettingsField)] = [
            (.sessionTooShort, .sessionMinutes),
            (.negativeSessions, .selfServiceSessionsPerDay),
            (.resetHourOutOfRange, .dayResetHour),
            (.noGrants, .extensionOptions),
            (.negativeGrace(.idleGraceSeconds), .idleGraceSeconds),
            (.negativeGrace(.mediaGraceSeconds), .mediaGraceSeconds),
            (.notANumber(.dayResetHour), .dayResetHour),
            (.notPositive(.warningMinutes), .warningMinutes),
            (.duplicate(.extensionOptions, 15), .extensionOptions),
        ]
        for (problem, field) in expected {
            #expect(problem.field == field, "\(problem) points at the wrong box")
        }
        // Every field is reachable by some complaint. A box no problem can name is a box
        // whose rule is enforced somewhere the parent will never be shown.
        #expect(Set(expected.map(\.1)) == Set(SettingsField.allCases))
    }

    /// The wizard and this window ask the same question, so they must not drift into two
    /// answers. If this ever fails, one of them has grown a rule of its own.
    @Test("the two session rules are the wizard's own rules", arguments: [-5, 0, 1, 30])
    func limitsAgreeWithTheWizard(minutes: Int) {
        var draft = shipped
        draft.sessionMinutes = minutes
        #expect(draft.limits.problem == SessionLimits(minutes: minutes,
                                                      sessionsPerDay: 1).problem)
    }

    @Test("the day rolls over at one of twenty-four hours", arguments: [-1, 24, 25, 100])
    func resetHourOutOfRange(hour: Int) {
        var draft = shipped
        draft.dayResetHour = hour
        #expect(draft.problem == .resetHourOutOfRange)
    }

    @Test("midnight and 23:00 are both legal", arguments: [0, 6, 23])
    func resetHourInRange(hour: Int) {
        var draft = shipped
        draft.dayResetHour = hour
        #expect(draft.problem == nil)
    }

    // MARK: - The grant list (DESIGN §2.5)

    /// **The rule this window exists to enforce.** `Config.extensionChoices` already falls
    /// back to the shipped three for a hand-edited file, but a window that *saved* `[]` and
    /// then silently drew 15/30/60 would be an app disagreeing with its own settings.
    @Test("an empty grant list cannot be saved")
    func emptyGrantsRejected() {
        var draft = shipped
        draft.extensionOptions = []
        #expect(draft.problem == .noGrants)
        #expect(draft.problem?.field == .extensionOptions)
    }

    @Test("a list of one is legal, and so is a large amount")
    func oneGrantIsEnough() {
        var draft = shipped
        draft.extensionOptions = [240]
        #expect(draft.problem == nil)

        // DESIGN §2.5: no upper bound, ever. The app does not argue with an amount its
        // owner chose — it only insists there is one.
        draft.extensionOptions = [1, 6000]
        #expect(draft.problem == nil)
    }

    @Test("a grant of zero or less is rejected", arguments: [0, -15])
    func nonPositiveGrant(amount: Int) {
        var draft = shipped
        draft.extensionOptions = [15, amount, 60]
        #expect(draft.problem == .notPositive(.extensionOptions))
    }

    @Test("the same amount twice is rejected")
    func duplicateGrant() {
        var draft = shipped
        draft.extensionOptions = [15, 30, 15]
        #expect(draft.problem == .duplicate(.extensionOptions, 15))
    }

    /// **Order is a setting** (DESIGN §2.5): the first entry is what T13's dialog
    /// pre-selects, so reordering the list is how the one-keystroke default changes. Nothing
    /// between the field and the file may sort it.
    @Test("the grant list's order survives the save, and the first entry stays first")
    func grantOrderSurvives() {
        var draft = shipped
        draft.extensionOptions = [60, 15, 30]
        #expect(draft.problem == nil)

        let saved = Config().applying(draft)
        #expect(saved.extensionOptions == [60, 15, 30])
        #expect(saved.extensionChoices == [60, 15, 30])
        #expect(GrantModel(config: saved).defaultAmount == 60)
    }

    // MARK: - Detection and warnings

    @Test("a negative grace is rejected")
    func negativeGrace() {
        var draft = shipped
        draft.idleGraceSeconds = -1
        #expect(draft.problem == .negativeGrace(.idleGraceSeconds))

        draft = shipped
        draft.mediaGraceSeconds = -1
        #expect(draft.problem == .negativeGrace(.mediaGraceSeconds))
    }

    /// Zero is legal for both, and means what it says: the clock pauses the moment he stops
    /// touching the Mac. `SessionState.isActive` handles it — `idleSeconds <= 0` is only
    /// true on a tick with input in it.
    @Test("a zero grace is legal")
    func zeroGrace() {
        var draft = shipped
        draft.idleGraceSeconds = 0
        draft.mediaGraceSeconds = 0
        #expect(draft.problem == nil)
    }

    /// **Empty is allowed here and forbidden for grants**, and the asymmetry is the point.
    /// No spoken warnings is a defensible choice — the countdown is still in the menu bar.
    /// No grant amounts is a dialog that cannot answer the question it opens.
    @Test("no warning thresholds at all is a choice, not an error")
    func noWarningsIsLegal() {
        var draft = shipped
        draft.warningMinutes = []
        #expect(draft.problem == nil)
    }

    @Test("a warning at zero minutes or below is rejected", arguments: [0, -5])
    func nonPositiveWarning(threshold: Int) {
        var draft = shipped
        draft.warningMinutes = [10, threshold]
        #expect(draft.problem == .notPositive(.warningMinutes))
    }

    @Test("the same threshold twice is rejected")
    func duplicateWarning() {
        var draft = shipped
        draft.warningMinutes = [10, 5, 10]
        #expect(draft.problem == .duplicate(.warningMinutes, 10))
    }

    /// The complaint has to land under the box that caused it. A window that puts every
    /// message in one place at the bottom is a window a parent reads as broken.
    @Test("the first problem is the topmost one")
    func problemsAreReportedInFieldOrder() {
        var draft = shipped
        draft.sessionMinutes = 0
        draft.dayResetHour = 99
        draft.extensionOptions = []
        #expect(draft.problem == .sessionTooShort)

        draft.sessionMinutes = 30
        #expect(draft.problem == .resetHourOutOfRange)

        draft.dayResetHour = 6
        #expect(draft.problem == .noGrants)
    }

    // MARK: - Parsing the two list fields

    @Test("a list of minutes round-trips through the field")
    func listRoundTrip() {
        #expect(MinuteList.format([15, 30, 60]) == "15, 30, 60")
        #expect(MinuteList.parse("15, 30, 60") == [15, 30, 60])
        #expect(MinuteList.parse(MinuteList.format([60, 15])) == [60, 15])
        #expect(MinuteList.format([]) == "")
    }

    @Test("commas separate, spare ones and stray spaces do not matter")
    func listSeparators() {
        #expect(MinuteList.parse("15,30,60") == [15, 30, 60])
        #expect(MinuteList.parse("  15 ,, 30 , ") == [15, 30])
        #expect(MinuteList.parse("") == [])
        #expect(MinuteList.parse("   ") == [])
    }

    /// **`"1 000"` is why a space does not separate.** One thousand, written the way half of
    /// Europe writes it, would otherwise parse quietly as `1` and `0` — and the complaint
    /// the parent then gets is about a grant of zero minutes they never typed. Refusing the
    /// field says the one useful thing: use commas.
    @Test("anything that is not a whole number is refused",
          arguments: ["15, x", "abc", "1.5", "15-30", "1 000", "15 30 60"])
    func listRejectsNonNumbers(text: String) {
        #expect(MinuteList.parse(text) == nil)
    }

    /// Parsing keeps the sign so ``SettingsDraft/problem`` can complain about it in the
    /// window's own words, rather than the field silently swallowing a minus.
    @Test("a negative number parses and is then rejected by the rules")
    func listKeepsNegatives() {
        #expect(MinuteList.parse("15, -30") == [15, -30])
        var draft = shipped
        draft.extensionOptions = [15, -30]
        #expect(draft.problem == .notPositive(.extensionOptions))
    }

    // MARK: - Detection, shown in minutes (CR-01 §7, T03)

    /// The plain direction: seconds on disk, whole minutes in the field.
    @Test("seconds convert to whole minutes")
    func graceToMinutes() {
        #expect(GraceMinutes.toMinutes(seconds: 600) == 10)
        #expect(GraceMinutes.toMinutes(seconds: 1800) == 30)
        #expect(GraceMinutes.toMinutes(seconds: 0) == 0)
    }

    @Test("minutes convert back to seconds")
    func graceToSeconds() {
        #expect(GraceMinutes.toSeconds(minutes: 10) == 600)
        #expect(GraceMinutes.toSeconds(minutes: 0) == 0)
    }

    /// **Every value the window itself writes round-trips unchanged.** A saved value is always
    /// `minutes * 60`, so it is a whole number of minutes going back in — the rounding below
    /// only ever bites a hand-edited file, never the window's own output.
    @Test("a value the window wrote round-trips stably",
          arguments: [0, 2, 5, 10, 15, 30, 45, 60])
    func graceRoundTripIsStable(minutes: Int) {
        let seconds = GraceMinutes.toSeconds(minutes: minutes)
        #expect(GraceMinutes.toMinutes(seconds: seconds) == minutes)
    }

    /// **The accepted consequence (DESIGN §2.7, product manager 2026-09-04): a hand-edited value
    /// that is not a round number of minutes rounds to the nearest one on the way to the field,
    /// and Save then writes that rounded value back.** Rounding, not truncation, so `100` reads
    /// as `2` (→ `120`), not `1` (→ `60`). Both directions of rounding are covered.
    @Test("a non-round hand-edited value rounds to the nearest minute",
          arguments: [(100, 2, 120), (80, 1, 60), (90, 2, 120), (89, 1, 60), (29, 0, 0)])
    func graceRoundsHandEditedValues(_ triple: (seconds: Int, minutes: Int, savedSeconds: Int)) {
        let shown = GraceMinutes.toMinutes(seconds: triple.seconds)
        #expect(shown == triple.minutes)
        #expect(GraceMinutes.toSeconds(minutes: shown) == triple.savedSeconds)
    }

    // MARK: - The combo suggestion lists Settings adds (CR-01 §5, §7, T03)

    @Test("the hour and grace lists are the agreed suggestions")
    func settingsComboSuggestions() {
        #expect(ComboSuggestions.dayStartHour == [4, 5, 6, 7, 8])
        #expect(ComboSuggestions.idleGraceMinutes == [2, 5, 10, 15])
        #expect(ComboSuggestions.mediaGraceMinutes == [15, 30, 45, 60])
    }

    /// **Append, don't clamp** (DESIGN §2.2, §2.7), reusing T01's `merged` rule. A stored hour
    /// of 3 or 23, or an idle grace of 7 minutes, must appear even though none is a suggestion —
    /// the box shows what is configured, not the nearest suggestion.
    @Test("a stored value outside a list is appended, not clamped")
    func settingsCombosAppendStoredValue() {
        #expect(ComboSuggestions.merged(ComboSuggestions.dayStartHour, storedValue: 3)
                == [4, 5, 6, 7, 8, 3])
        #expect(ComboSuggestions.merged(ComboSuggestions.dayStartHour, storedValue: 23)
                == [4, 5, 6, 7, 8, 23])
        #expect(ComboSuggestions.merged(ComboSuggestions.idleGraceMinutes, storedValue: 7)
                == [2, 5, 10, 15, 7])
        // A stored value that is a suggestion leaves the list untouched.
        #expect(ComboSuggestions.merged(ComboSuggestions.mediaGraceMinutes, storedValue: 30)
                == [15, 30, 45, 60])
    }

    /// The combo box merges a stored value in rather than clamping it, but ``SettingsDraft/problem``
    /// still governs what may be **saved**: an out-of-range hour typed into the box is refused.
    @Test("a typed-in out-of-range hour is still rejected", arguments: [24, 25, 100, -1])
    func typedHourStillRejected(hour: Int) {
        var draft = shipped
        draft.dayResetHour = hour
        #expect(draft.problem == .resetHourOutOfRange)
    }

    /// A negative grace typed into a minutes combo becomes a negative number of seconds, and the
    /// same rule refuses it — re-asserted here through the minute→second conversion the field
    /// now goes through, not just the raw seconds.
    @Test("a negative grace typed in minutes is still rejected", arguments: [-1, -5])
    func negativeGraceThroughConversion(minutes: Int) {
        var draft = shipped
        draft.idleGraceSeconds = GraceMinutes.toSeconds(minutes: minutes)
        #expect(draft.problem == .negativeGrace(.idleGraceSeconds))

        draft = shipped
        draft.mediaGraceSeconds = GraceMinutes.toSeconds(minutes: minutes)
        #expect(draft.problem == .negativeGrace(.mediaGraceSeconds))
    }

    // MARK: - What gets written

    /// Everything else in the file is left alone — the PIN above all. A window that saved a
    /// number and cleared a PIN would arm §2.5's one unrecoverable state.
    @Test("saving the settings touches nothing but the settings")
    func applyingLeavesThePINAlone() {
        var config = Config()
        config.pinHash = "hash"
        config.pinSalt = Data("salt".utf8).base64EncodedString()

        var draft = SettingsDraft(config)
        draft.sessionMinutes = 45
        let saved = config.applying(draft)

        #expect(saved.sessionMinutes == 45)
        #expect(saved.pinHash == config.pinHash)
        #expect(saved.pinSalt == config.pinSalt)
        #expect(saved.isConfigured)
    }

    /// The task doc's last test: what this window writes is a `Config` like any other, and
    /// the file it produces reads back as the same thing.
    @Test("a config saved by this window round-trips through the store unchanged")
    func savedConfigRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rst-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var config = Config()
        config.pinHash = "hash"
        config.pinSalt = Data("salt".utf8).base64EncodedString()

        var draft = SettingsDraft(config)
        draft.sessionMinutes = 45
        draft.selfServiceSessionsPerDay = 0
        draft.dayResetHour = 5
        draft.idleGraceSeconds = 90
        draft.mediaGraceSeconds = 2400
        draft.warningMinutes = [20, 3]
        draft.extensionOptions = [60, 15, 30]
        #expect(draft.problem == nil)

        let saved = config.applying(draft)
        let store = ConfigStore(directory: directory)
        try store.save(saved)

        let loaded = store.load()
        #expect(loaded.outcome == .loaded)
        #expect(loaded.config == saved)
        #expect(SettingsDraft(loaded.config) == draft)
    }

    // MARK: - The log line

    /// DESIGN §3.5 gives the log the job of explaining a sudden change in behaviour six
    /// weeks later, and this is the only line that can explain one a parent made themselves.
    @Test("the log line names what moved and what it moved to")
    func changesAreDescribed() {
        var updated = Config()
        updated.sessionMinutes = 45
        updated.warningMinutes = [5]

        let changes = Config().changes(to: updated)
        #expect(changes == ["session_minutes 30→45", "warning_minutes [10, 5, 1]→[5]"])
    }

    @Test("nothing changed says nothing")
    func noChangesDescribed() {
        #expect(Config().changes(to: Config()).isEmpty)
    }

    /// **The PIN is never printed, in either direction.** `events.jsonl` is a plain file in
    /// the child's own home directory.
    @Test("a PIN change is recorded without the PIN")
    func pinChangeIsDescribedNotPrinted() {
        let before = Config().changingPIN(hash: "old", salt: Data("a".utf8))
        let after = before.changingPIN(hash: "new", salt: Data("b".utf8))

        let changes = before.changes(to: after)
        #expect(changes == ["pin_hash changed"])
        #expect(!changes.joined().contains("old"))
        #expect(!changes.joined().contains("new"))
    }

    // MARK: - Changing the PIN

    /// It rewrites the salt as well as the hash: leaving the old salt would derive both
    /// hashes from the same bytes, which is the one thing a per-install salt prevents.
    @Test("changing the PIN rewrites the salt and the hash, and nothing else")
    func pinChangeRewritesTheSalt() throws {
        let rounds = 1_000
        let oldSalt = newPINSalt()
        var config = Config()
        config.sessionMinutes = 45
        config.pinHash = hashPIN("1111", salt: oldSalt, rounds: rounds)
        config.pinSalt = oldSalt.base64EncodedString()

        let newSalt = newPINSalt()
        let changed = config.changingPIN(hash: hashPIN("2222", salt: newSalt, rounds: rounds),
                                         salt: newSalt)

        #expect(changed.pinSalt != config.pinSalt)
        #expect(changed.pinHash != config.pinHash)
        #expect(changed.sessionMinutes == 45)
        #expect(changed.isConfigured)

        let salt = try #require(changed.pinSaltData)
        #expect(verifyPIN("2222", hash: changed.pinHash, salt: salt, rounds: rounds))
        // The old PIN stops working the moment the new one is saved.
        #expect(!verifyPIN("1111", hash: changed.pinHash, salt: salt, rounds: rounds))
    }

    /// **The current PIN is asked for first, and the flow cannot be entered past it.** The
    /// window is already behind one prompt, but a window left open on a Mac a child is
    /// sitting at is not a parent standing over it.
    @Test("the change asks for the current PIN, then the new one twice")
    func pinChangeSequence() {
        var flow = PINChangeFlow()
        #expect(flow.stage == .current)
        #expect(flow.entered("1111") == .verifyCurrent("1111"))
        // Still on the current PIN until the verifier says otherwise.
        #expect(flow.stage == .current)

        #expect(flow.currentAccepted() == .ask(.new))
        #expect(flow.entered("2222") == .ask(.repeated))
        #expect(flow.entered("2222") == .settled("2222"))
    }

    @Test("a wrong current PIN leaves the flow where it was")
    func pinChangeCurrentRejected() {
        var flow = PINChangeFlow()
        _ = flow.entered("9999")
        #expect(flow.currentRejected() == .ask(.current))
        #expect(flow.stage == .current)
        // And the next four digits are still an attempt at the current PIN.
        #expect(flow.entered("1111") == .verifyCurrent("1111"))
    }

    /// **All the way back to the new PIN, not to the second entry.** Half of a mismatched
    /// pair is not a PIN anyone has confirmed, and "type the second one again" would settle
    /// on whichever of the two was typed twice by accident.
    @Test("a mismatched new PIN starts the new PIN over")
    func pinChangeMismatch() {
        var flow = PINChangeFlow()
        _ = flow.entered("1111")
        _ = flow.currentAccepted()
        _ = flow.entered("2222")
        #expect(flow.entered("3333") == .rejected(.mismatch))
        #expect(flow.stage == .new)

        // Nothing was remembered from the failed pair.
        #expect(flow.entered("4444") == .ask(.repeated))
        #expect(flow.entered("4444") == .settled("4444"))
    }

    /// The wizard's rule, reused: a PIN of any other length can never be typed into T13's
    /// prompt, so it must not be settable here either. `PINBoxes` makes it unreachable
    /// through the UI; this is the rule behind the control.
    @Test("the new PIN obeys the wizard's own length rule")
    func pinChangeLengthRule() {
        var flow = PINChangeFlow()
        _ = flow.entered("1111")
        _ = flow.currentAccepted()
        _ = flow.entered("123")
        #expect(flow.entered("123") == .rejected(.wrongLength(3)))
        #expect(flow.stage == .new)
    }
}
