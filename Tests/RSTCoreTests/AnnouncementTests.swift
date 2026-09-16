import Foundation
import Testing
@testable import RSTCore

/// **T14 — the warnings, the expiry line and the grant confirmation.**
///
/// Everything here is the half of T14 that `make test` can reach: which threshold a
/// remainder falls into, which line names the consequence, which voice is chosen from a
/// list of installed ones, and — the part that matters most — that each announcement
/// happens exactly once and never while somebody else has the Mac.
///
/// What is *not* here, and cannot be: whether the chime is audible, whether the banner
/// steals focus, and whether the voice that was chosen is the voice that spoke. Those need
/// a person in the room (CLAUDE.md).
@Suite("T14 — warnings, the expiry and the grant")
@MainActor
struct AnnouncementTests {

    private let day = Calendar.warsaw

    // MARK: - Which threshold a remainder falls into

    /// The task doc's own table, and the boundary in both directions: a threshold is
    /// **inclusive**, so exactly 5:00 is the five-minute warning and not the ten.
    @Test("10:00, 9:59, 5:00, 1:00 and 0:59 fall into 10, 10, 5, 1 and 1")
    func thresholdSelection() {
        let config = Config()                       // ships [10, 5, 1]
        #expect(config.warningThreshold(for: 601) == nil)
        #expect(config.warningThreshold(for: 600) == 10)
        #expect(config.warningThreshold(for: 599) == 10)
        #expect(config.warningThreshold(for: 300) == 5)
        #expect(config.warningThreshold(for: 60) == 1)
        #expect(config.warningThreshold(for: 59) == 1)
        // Zero is not a warning: that is `.expired`, and the cover speaks for itself.
        #expect(config.warningThreshold(for: 0) == 1)
    }

    // MARK: - What a warning carries

    /// The threshold, and whether it is the one that says `Zapisz swoją grę.`
    ///
    /// It carried a `namesConsequence` flag — §2.6.2's rule that a fullscreen game is quit
    /// when the cover appears — until the user heard that sentence out loud on 2026-08-25
    /// and cut it: eight words about consequences, three times a session. **What is here now
    /// is the other sentence**, §2.4's own three-word instruction, which the review found had
    /// been specified in two places and never spoken. Restored the same day at his direction,
    /// and deliberately without the longer half.
    @Test("a warning carries its threshold and whether it says save your game")
    func warningCarriesTheThreshold() {
        #expect(Announcement.warning(minutes: 10, suggestsSaving: false).logDescription
                == "10 min warning")
        #expect(Announcement.warning(minutes: 5, suggestsSaving: true).logDescription
                == "5 min warning, save your game")
        #expect(Announcement.expired.logDescription == "time is up")
        #expect(Announcement.granted(minutes: 15).logDescription == "granted 15 min")
    }

    // MARK: - Which warning tells him to save

    /// **The one threshold that still leaves time to act**, and it is chosen by position
    /// rather than by the number 5 — so a retuned `warningMinutes` keeps the instruction
    /// instead of silently dropping it.
    ///
    /// The last warning is too late to start saving and every warning above it would be
    /// nagging, which leaves the second smallest.
    @Test("the second-smallest threshold is the one that says save your game")
    func whichWarningSuggestsSaving() {
        var config = Config()                                   // ships [10, 5, 1]
        #expect(!config.warningSuggestsSaving(10))
        #expect(config.warningSuggestsSaving(5))
        #expect(!config.warningSuggestsSaving(1))

        // DESIGN §2.4 offers this one by name as the revert if sessions get longer.
        config.warningMinutes = [15, 5, 1]
        #expect(config.warningSuggestsSaving(5))
        #expect(!config.warningSuggestsSaving(15))

        // Retuned entirely: 5 is not special, the position is.
        config.warningMinutes = [20, 10, 2]
        #expect(config.warningSuggestsSaving(10))
        #expect(!config.warningSuggestsSaving(5))
        #expect(!config.warningSuggestsSaving(2))

        // One warning is the only notice there is, so it carries the instruction.
        config.warningMinutes = [5]
        #expect(config.warningSuggestsSaving(5))

        // Junk from a hand-edited config.json: the zero and the negative are dropped by
        // `warningThresholds` first, so the carrier is picked from what is left.
        config.warningMinutes = [10, 5, 1, 0, -3, 5]
        #expect(config.warningSuggestsSaving(5))
        #expect(!config.warningSuggestsSaving(0))

        config.warningMinutes = []
        #expect(!config.warningSuggestsSaving(5))
    }

    // MARK: - Polish numerals

    /// `minuta` is feminine and the digits are read in the masculine, so `1` and everything
    /// ending in `2` have to be spelled out — and nothing else does. DESIGN §2.4's worked
    /// example of the wrong answer is "Dodano dwa minut", which only a listener catches.
    @Test("only one and the numbers ending in two need a word")
    func numerals() {
        #expect(PolishNumeral.form(1) == .one)
        #expect(PolishNumeral.form(2) == .two(tens: 0))
        #expect(PolishNumeral.form(22) == .two(tens: 20))
        #expect(PolishNumeral.form(32) == .two(tens: 30))
        #expect(PolishNumeral.form(92) == .two(tens: 90))

        // 12 is *dwanaście*, read correctly from the digits — the teens are the exception
        // to the last-digit rule, exactly as they are for the plural form.
        #expect(PolishNumeral.form(12) == .digits)
        #expect(PolishNumeral.form(112) == .digits)

        for safe in [0, 3, 4, 5, 10, 11, 13, 15, 20, 21, 30, 45, 60, 90, 100] {
            #expect(PolishNumeral.form(safe) == .digits, "\(safe) should read straight from the digits")
        }

        // Past 99 the tens word is not enough — `102` needs *sto* as well — and the digits
        // are the honest limit of a two-row table rather than a wrong word.
        #expect(PolishNumeral.form(102) == .digits)

        // Nothing should hand these in — every caller clamps — but neither may trap.
        #expect(PolishNumeral.form(-1) == .one)
        #expect(PolishNumeral.form(-22) == .two(tens: 20))
        #expect(PolishNumeral.form(Int.min) == .digits)
    }

    // MARK: - Choosing a voice (§2.4.1)

    private func voice(_ identifier: String, _ name: String,
                       _ language: String, _ quality: Int) -> VoiceOption {
        VoiceOption(identifier: identifier, name: name, language: language, quality: quality)
    }

    /// The chain is Premium → Enhanced → compact Zosia → any Polish → the system default,
    /// and each tier is tested by taking the one above it away.
    @Test("the best installed Polish voice wins, tier by tier")
    func voiceFallbackChain() {
        let premium = voice("com.apple.voice.premium.pl-PL.Zosia", "Zosia (Premium)", "pl-PL", 3)
        let enhanced = voice("com.apple.voice.enhanced.pl-PL.Zosia", "Zosia (Enhanced)", "pl-PL", 2)
        let compact = voice("com.apple.voice.super-compact.pl-PL.Zosia", "Zosia", "pl-PL", 1)
        let otherPolish = voice("com.apple.voice.compact.pl-PL.Krzysztof", "Krzysztof", "pl-PL", 1)
        let english = voice("com.apple.voice.premium.en-GB.Serena", "Serena (Premium)", "en-GB", 3)

        #expect(VoiceChoice.pick(from: [english, compact, premium, enhanced]) == premium)
        #expect(VoiceChoice.pick(from: [english, compact, enhanced]) == enhanced)
        // Compact Zosia beats another compact Polish voice — the one name worth preferring.
        #expect(VoiceChoice.pick(from: [english, otherPolish, compact]) == compact)
        // And with no Zosia at all, any Polish voice beats the system default.
        #expect(VoiceChoice.pick(from: [english, otherPolish]) == otherPolish)
    }

    /// **A Mac with no Polish voice must still say something** — the one failure this
    /// feature cannot have, because apps get quit on the strength of these warnings. `nil`
    /// means the system default, which `AVSpeechSynthesizer` supplies.
    @Test("no Polish voice at all falls through to the system default")
    func noPolishVoice() {
        let english = [voice("en-GB.Serena", "Serena", "en-GB", 3),
                       voice("en-US.Samantha", "Samantha", "en-US", 2)]
        #expect(VoiceChoice.pick(from: english) == nil)
        #expect(VoiceChoice.pick(from: []) == nil)
    }

    /// **Three spellings of one language**, and `AVFoundation` uses the one DESIGN §2.4.1
    /// does not: `pl-PL` with a hyphen, measured on this Mac 2026-08-25. Matching only the
    /// underscore form finds nothing at all — and finding nothing is silent.
    @Test("pl, pl-PL and pl_PL all count; plt does not")
    func languageTags() {
        #expect(VoiceChoice.speaks("pl", "pl"))
        #expect(VoiceChoice.speaks("pl-PL", "pl"))
        #expect(VoiceChoice.speaks("pl_PL", "pl"))
        #expect(VoiceChoice.speaks("PL-pl", "pl"))
        // Malagasy. A bare `hasPrefix` would warn a Polish child in it.
        #expect(!VoiceChoice.speaks("plt", "pl"))
        #expect(!VoiceChoice.speaks("en-GB", "pl"))
    }

    /// Two voices level on every count are separated by the identifier, so the choice does
    /// not depend on the order the system happened to enumerate them in.
    @Test("a tie is settled the same way whichever order they arrive in")
    func deterministicTieBreak() {
        let a = voice("com.apple.a", "Marek", "pl-PL", 2)
        let b = voice("com.apple.b", "Wojciech", "pl-PL", 2)
        #expect(VoiceChoice.pick(from: [a, b]) == a)
        #expect(VoiceChoice.pick(from: [b, a]) == a)
    }

    // MARK: - Once each, and never over somebody else's Mac

    /// An evening's warnings, in order, each fired once — not once a tick, which is what
    /// `decide` reports and what makes the de-duplication `Engine`'s job (T05).
    @Test("each threshold is announced once, and the expiry follows it")
    func firesOnceEach() {
        let h = harness(at: 20, 0)
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 20, 31))

        #expect(h.ticks > 1800, "the session was ticked second by second")
        // Only the five-minute line tells him to do anything — §2.4's own table, and the
        // half the review found missing.
        #expect(h.enforcer.announced.map(\.announcement) == [
            .warning(minutes: 10, suggestsSaving: false),
            .warning(minutes: 5, suggestsSaving: true),
            .warning(minutes: 1, suggestsSaving: false),
            .expired
        ])
        // At 20:20, 20:25, 20:29 and 20:30 — the thresholds, not the ticks around them.
        #expect(h.enforcer.announced.map { h.hhmmss($0.now) }
                == ["20:20:00", "20:25:00", "20:29:00", "20:30:00"])
    }

    /// §2.4's table has nothing to say about a screen nobody has started a session on: there
    /// is no session to end, so there is nothing to warn about.
    @Test("no announcement while the cover is offering Rozpocznij or Wznów")
    func nothingToWarnAbout() {
        let waiting = harness(at: 20, 0)
        waiting.run(until: day.wall(2026, 8, 25, 20, 30))
        #expect(waiting.enforcer.announced.isEmpty)

        // Four minutes left and paused behind `Wznów` — inside the 5-minute threshold, and
        // still silent, because the countdown is not running.
        let paused = SessionState(dayKey: "2026-08-25", remainingSeconds: 240, wasRunning: true)
        let resumable = Harness(start: day.wall(2026, 8, 25, 20, 0), state: paused)
        resumable.run(until: day.wall(2026, 8, 25, 20, 10))
        #expect(resumable.engine.lastDecision == .awaitingResume(remaining: 240))
        #expect(resumable.enforcer.announced.isEmpty)
    }

    /// **§2.2: nothing is spoken while another user has the Mac** — and for a warning that
    /// is T07's test (`a warning already due is not spoken off-console`), which holds the
    /// rule and is not repeated here. What T14 adds is that the *other two* announcements
    /// take the same silence, through one gate rather than three.
    ///
    /// Defensive rather than reachable, and worth saying so: a grant is made from the
    /// child's own session, so in practice the console is his whenever one arrives. The rule
    /// is absolute anyway — the app is silent while the Mac belongs to somebody else — and a
    /// gate that holds only where somebody proved it was needed is a gate with a gap in it.
    @Test("a grant made while another user is switched in says nothing")
    func silentGrantOffConsole() {
        let h = harness(at: 20, 0)
        h.sensors.sessionOnConsole = false
        h.tick()
        h.engine.extend(minutes: 15, at: h.now)
        #expect(h.enforcer.announced.isEmpty)
        #expect(h.events.contains { $0.type == .extended }, "the grant is still recorded")
    }

    // MARK: - A grant re-arms the way down

    /// "If 15 minutes are added after the 5-minute warning, the 5-minute warning should fire
    /// again on the way back down" — the task doc, and the behaviour anyone would expect.
    @Test("an extension after a warning warns again on the way down")
    func extensionRearmsTheWarnings() {
        let h = harness(at: 20, 0)
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 20, 26))            // 10 and 5 have fired
        #expect(h.enforcer.warnings.map(\.threshold) == [10, 5])

        h.engine.extend(minutes: 15, at: h.now)                // 4 min left becomes 19
        h.run(until: day.wall(2026, 8, 25, 20, 46))

        #expect(h.enforcer.warnings.map(\.threshold) == [10, 5, 10, 5, 1])
        #expect(h.enforcer.announced.map(\.announcement).last == .expired)
    }

    @Test("a real grant is announced with the parent's own number; a grant of nothing is not")
    func grantIsAnnounced() {
        let h = harness(at: 20, 0)
        h.tick()
        h.engine.extend(minutes: 30, at: h.now)
        #expect(h.enforcer.announced.map(\.announcement) == [.granted(minutes: 30)])

        // `minutes: 0` changes nothing, and a Mac announcing that nothing was added is
        // worse than silence (§2.5).
        h.engine.extend(minutes: 0, at: h.now)
        #expect(h.enforcer.announced.count == 1)

        // Clamped, like the ledger and the log: a negative must not hand back time and must
        // not be spoken as one.
        h.engine.extend(minutes: -10, at: h.now)
        #expect(h.enforcer.announced.count == 1)
    }

    // MARK: - Which endings speak

    /// Only a session that ran out under an ordinary tick says `Czas minął`. A gap charged
    /// at launch ended it minutes or hours ago, and a stand-down is the parent's doing.
    @Test("a gap and a stand-down end the session in silence")
    func onlyExpirySpeaks() {
        let standDown = harness(at: 20, 0)
        standDown.engine.startSelfService(at: standDown.now)
        standDown.run(until: day.wall(2026, 8, 25, 20, 5))
        standDown.engine.disable(at: standDown.now)
        #expect(standDown.enforcer.announced.isEmpty)
        #expect(standDown.events.contains { $0.type == .sessionEnd })

        // Killed with 25 minutes left, back an hour later: the gap takes the rest of it.
        let gap = harness(at: 20, 0)
        let boot = day.wall(2026, 8, 25, 8, 0)
        gap.launch(bootTime: boot)
        gap.engine.startSelfService(at: gap.now)
        gap.run(until: day.wall(2026, 8, 25, 20, 5))
        gap.kill()
        gap.skip(to: day.wall(2026, 8, 25, 21, 5))
        gap.launch(bootTime: boot)
        #expect(gap.remaining == 0)
        #expect(gap.enforcer.announced.isEmpty)
        #expect(gap.events.contains { $0.type == .sessionEnd })
    }

    // MARK: - The 06:00 rollover

    /// The task doc asks for the fired set to be cleared on the day rollover.
    ///
    /// **Asserted on the state, not on behaviour, and deliberately.** A remainder only ever
    /// falls, so a threshold already spoken cannot come round again without a grant — and a
    /// grant clears the set anyway. There is no scenario today that behaves differently with
    /// the line removed, which is exactly why it is worth pinning: the next rule that lets a
    /// remainder rise would otherwise take the morning's first warning with it, silently.
    @Test("the day rollover clears the threshold already spoken")
    func rolloverClearsTheFiredSet() {
        // A 15-minute session started at 05:50, so its 10-minute warning lands at 05:55 —
        // five minutes on the near side of the reset.
        var config = Config.forTesting()
        config.sessionMinutes = 15
        let start = day.wall(2026, 8, 25, 5, 50)
        let h = Harness(start: start, config: config)
        h.launch(bootTime: start.addingTimeInterval(-3600))
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 5, 56))
        #expect(h.enforcer.warnings.map(\.threshold) == [10])
        #expect(h.engine.announced == 10)
        #expect(h.engine.state.dayKey == "2026-08-24", "still yesterday until 06:00")

        // Switched away, which freezes the countdown (§2.2), so the nine minutes still on the
        // session are what the boundary meets rather than something the clock ate first.
        h.sensors.sessionOnConsole = false
        h.run(until: day.wall(2026, 8, 25, 6, 0, 1))
        #expect(h.engine.state.dayKey == "2026-08-25")
        #expect(h.remaining == 0, "T21: the boundary discards the nine minutes")
        #expect(h.engine.announced == nil, "a new day starts owing every warning again")
        // Nothing further is said. `endSession` clears the set for `.discarded` as it does
        // for anything else, so this line no longer depends on the day-key clear above — it
        // is asserted anyway, because the day the app starts fresh is the one day it must
        // not warn less.
        #expect(h.enforcer.warnings.map(\.threshold) == [10])
    }

    // MARK: - T21: 06:00 takes the rest, and says nothing about it

    /// **The child is told nothing** (the user's decision, 2026-09-04). 06:00 is before he is
    /// up, and the new day's offer on the cover is the honest statement.
    ///
    /// On console throughout, deliberately: §2.2's off-console gate would suppress an
    /// announcement on its own, and a silence test that leans on the wrong gate proves
    /// nothing about the one it is meant to be testing.
    @Test("nothing is spoken when 06:00 discards a session, and nobody is warned")
    func discardAtSixIsSilent() {
        var config = Config.forTesting()
        config.sessionMinutes = 25          // above every threshold, so none is due either
        let start = day.wall(2026, 8, 25, 5, 50)
        let h = Harness(start: start, config: config)
        h.launch(bootTime: start.addingTimeInterval(-3600))
        h.engine.startSelfService(at: h.now)

        // He is at the keyboard, playing straight through six o'clock.
        h.run(until: day.wall(2026, 8, 25, 6, 0, 5))

        #expect(h.remaining == 0)
        #expect(h.enforcer.announced.isEmpty, "no chime, no line, no banner")
        // Interrupted there and offered the day's own session in the same breath.
        #expect(h.beats.last == .awaitingStart(1))

        let ended = h.events.filter { $0.type == .sessionEnd }
        #expect(ended.count == 1)
        #expect(ended.first?[.reason] == .string("discarded"))
        // Ten minutes at the machine, not the twenty-five that were on the clock. 599 rather
        // than 600 because the tick landing exactly on 06:00:00 rolls the day over before it
        // charges, so the last second belongs to the new day and is never spent.
        #expect(ended.first?[.usedSeconds] == .number(599))
    }

    /// **The wake path, which is the one the reported scenario takes.** Sleeping writes the
    /// clean-exit marker and waking reconciles against it, so the morning after a session left
    /// unfinished never reaches a tick with anything on the clock — a fix that only handled
    /// `tick` would fix nothing for the case that prompted T21.
    @Test("waking after a night with a session left on it discards it, silently")
    func discardOnWakeIsSilentToo() {
        let start = day.wall(2026, 8, 25, 22, 0)
        let boot = start.addingTimeInterval(-7200)
        let h = Harness(start: start, config: Config.forTesting())
        h.launch(bootTime: boot)
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 22, 15))     // fifteen of his thirty minutes
        #expect(h.remaining == 900)

        // To bed: the Mac sleeps, which writes the marker, and wakes at eight.
        h.quit()
        h.skip(to: day.wall(2026, 8, 26, 8, 0))
        h.launch(bootTime: boot)

        #expect(h.remaining == 0)
        #expect(h.enforcer.announced.isEmpty)
        let ended = h.events.filter { $0.type == .sessionEnd }
        #expect(ended.count == 1)
        #expect(ended.first?[.reason] == .string("discarded"))
        // Nothing was charged in this run — the clean exit costs nothing (§2.3) and the
        // discard is not time he spent.
        #expect(ended.first?[.usedSeconds] == .number(0))

        // And the cover offers the new day's session rather than a resume.
        h.tick()
        #expect(h.beats.last == .awaitingStart(1))
    }

    // MARK: - The voice on the record

    /// **A Mac quietly speaking English is invisible** unless the log says which voice
    /// spoke (§2.4.1). `Engine` cannot ask `AVFoundation` anything, so the answer comes back
    /// up through the enforcer.
    @Test("the resolved voice is written onto the warned event")
    func warnedCarriesTheVoice() {
        let h = harness(at: 20, 0, voice: "Zosia (pl-PL, quality 2)")
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 20, 21))

        let warned = h.events.filter { $0.type == .warned }
        #expect(warned.count == 1)
        #expect(warned.first?[.voice] == .string("Zosia (pl-PL, quality 2)"))
    }

    /// An enforcer that does not speak — an observer run, or any test — omits the field
    /// rather than claiming something about a subsystem that was never asked.
    @Test("an enforcer with no voice writes no voice field")
    func silentEnforcerOmitsTheVoice() {
        let h = harness(at: 20, 0)
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 20, 21))

        let warned = h.events.filter { $0.type == .warned }
        #expect(warned.count == 1)
        #expect(warned.first?[.voice] == nil)
    }

    // MARK: - A break does not re-speak the warning already given

    /// **`Wznów` hands back the same remainder it paused on**, so the threshold spoken
    /// before the break is still the threshold he is standing in — announcing it again names
    /// the *bucket* rather than his own time. Found in review: `resume` cleared the fired
    /// set, and a child who went for a snack at 3:55 came back to "Zostało Ci 5 minut",
    /// once for every break he took.
    ///
    /// The task doc gives the reset set as the 06:00 rollover and a PIN grant, and both of
    /// those really do put time back. A resume does not.
    @Test("a pause and a resume does not re-speak the threshold already given")
    func resumeDoesNotRearmTheWarning() {
        let h = harness(at: 20, 0)
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 20, 26))
        #expect(h.enforcer.warnings.map(\.threshold) == [10, 5])
        #expect(h.remaining == 240)

        // The lid closes and opens: `AppController.wake` reconciles it with `Engine.launch`
        // on the same engine, and `reconcile` always pauses the session, so `Wznów` is the
        // way back on. Both used to clear the fired set and either alone re-fires it.
        h.engine.expectedExit(at: h.now)
        h.skip(to: day.wall(2026, 8, 25, 20, 27))
        h.launch(bootTime: day.wall(2026, 8, 25, 8, 0))
        h.run(until: day.wall(2026, 8, 25, 20, 27, 5))
        #expect(h.engine.lastDecision == .awaitingResume(remaining: 240))

        h.engine.resume(at: h.now)
        h.run(until: day.wall(2026, 8, 25, 20, 28))
        #expect(h.remaining == 185, "a clean sleep charges nothing; the resumed run does")
        #expect(h.enforcer.warnings.map(\.threshold) == [10, 5],
                "the 5-minute warning was already given before the break")

        // **And every threshold below him is still owed.** This is the half that would break
        // if the fix were "never clear it": the last minute must still arrive.
        h.run(until: day.wall(2026, 8, 25, 20, 32))
        #expect(h.enforcer.warnings.map(\.threshold) == [10, 5, 1])
        #expect(h.enforcer.announced.map(\.announcement).last == .expired)
    }

    // MARK: - Shorthand

    /// A launched run, because that is the only kind there is: `Engine.launch` is what sets
    /// the first heartbeat, and a `tick` against a state that has never had one charges the
    /// whole interval since `distantPast` and kills the session on its first second.
    private func harness(at hour: Int, _ minute: Int, voice: String? = nil) -> Harness {
        let start = day.wall(2026, 8, 25, hour, minute)
        let h = Harness(start: start, voice: voice)
        h.launch(bootTime: start.addingTimeInterval(-3600))
        return h
    }
}
