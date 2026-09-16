import Foundation
import Testing
@testable import RSTCore

/// **The Phase 1 exit gate (T07).**
///
/// Everything below drives the real ``Engine``, the real ``decide``, the real
/// ``SessionState`` and the real ``Event`` through scripted days, second by second, and
/// asserts the whole ordered list of decisions and the whole ordered list of events. Only
/// the two edges are fake: the sensor readings going in and the enforcer coming out.
///
/// That is the argument for the Core/App boundary in one file. There is no UI automation on
/// this machine, so a rule that reaches the screen is a rule nobody can check; here a
/// fourteen-hour day runs in a few hundred milliseconds and a changed rule fails a literal
/// list, by name, with a timestamp.
///
/// **Where the task doc and DESIGN disagree, DESIGN wins and the difference is recorded.**
/// The canonical scenario's arithmetic assumes the 10-minute idle grace *freezes* the
/// session clock the moment he steps away; DESIGN §2.2 says the opposite in as many words —
/// "a pause to read something does not stop the clock and make the countdown feel
/// dishonest" — so the grace is charged, and everything after the walk-away happens ten
/// minutes earlier than the doc's table says. See `plans/initial-build/PROGRESS.md`.
@Suite("Integration — scripted days")
@MainActor
struct IntegrationTests {

    // MARK: - 1. The canonical scenario

    /// One evening, end to end: the day's one self-service session, a walk-away, three
    /// warnings each time, a grant of 15 minutes, a screen lock, two logouts, two more PIN grants of half
    /// an hour each, and the 06:00 rollover that hands back a fresh day.
    ///
    /// Both lists are literal and complete. A rule added to `decide` that changes any
    /// decision, and a rule added to ``Engine`` that writes any line, fails here — which is
    /// what T07's "Done when" asks for.
    @Test("the canonical evening, decision by decision and line by line")
    func canonicalEvening() {
        let day = Calendar.warsaw
        let h = canonicalDay(year: 2026, month: 8, evening: 21, morning: 22)

        #expect(h.beats == Self.canonicalBeats, "timeline was:\n\(h.timelineDescription)")
        #expect(h.events == Self.canonicalEvents(day, evening: (2026, 8, 21), morning: (2026, 8, 22)),
                "log was:\n\(h.eventDescription)")

        // The enforcer hears from every single tick, not only the interesting ones: the cover
        // has to be re-asserted while it is up, and T10's countdown redraws every second.
        #expect(h.enforcer.calls.count == h.ticks)
        // Every warning that was written was also spoken, and vice versa.
        #expect(h.enforcer.warnings.map(\.threshold) == [10, 5, 1, 10, 5, 1, 10, 5, 1, 10, 5, 1])

        // Morning: a new day key, the count back to zero, both sessions on offer again.
        #expect(h.engine.state.dayKey == "2026-08-22")
        #expect(h.engine.state.sessionsUsedToday == 0)
        #expect(h.remaining == 0)
    }

    // MARK: - 2. Gaps (DESIGN §2.3)

    /// Killed: no clean-exit marker, boot older than the heartbeat. Charged in full, and the
    /// `tamper_gap` line is the parent's evidence it happened.
    @Test("a killed app is charged the whole gap and logged")
    func killedGapIsChargedInFull() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0), until: day.wall(2026, 8, 21, 16, 10, 0))
        #expect(h.remaining == 1200)

        h.kill()
        h.skip(to: day.wall(2026, 8, 21, 16, 14, 48))         // 4m48s = 288s
        let gap = h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))

        #expect(gap == .unexplained(288))
        #expect(h.remaining == 912)
        #expect(h.events.last == Event(.tamperGap, at: day.wall(2026, 8, 21, 16, 14, 48),
                                       [.seconds: 288]))

        // And the session comes back paused, not counting down under him.
        h.tick()
        #expect(h.enforcer.calls.last?.decision == .awaitingResume(remaining: 912))
    }

    /// Slept: the clean-exit marker is written before going away, so nothing is charged and
    /// nothing is logged. This asymmetry is the whole of §2.3.
    @Test("a clean exit costs nothing and writes no gap line")
    func sleptGapIsNotCharged() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0), until: day.wall(2026, 8, 21, 16, 10, 0))

        h.quit()
        h.skip(to: day.wall(2026, 8, 21, 16, 50, 0))          // 40 minutes asleep
        let gap = h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))

        #expect(gap == .expected(2400))
        #expect(h.remaining == 1200)
        #expect(h.events.contains { $0.type == .tamperGap } == false)
    }

    /// Rebooted: the machine was off for most of the gap, so only the part after boot is his.
    @Test("a reboot charges only the minutes since boot")
    func rebootedGapChargesOnlyAfterBoot() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0), until: day.wall(2026, 8, 21, 16, 10, 0))

        h.kill()
        h.skip(to: day.wall(2026, 8, 21, 18, 10, 0))          // two hours later…
        let gap = h.launch(bootTime: day.wall(2026, 8, 21, 18, 5, 0))   // …booted five minutes ago

        #expect(gap == .rebooted(charge: 300))
        #expect(h.remaining == 900)
        // Not a tamper: the machine was genuinely off, and saying otherwise in the log would
        // accuse him of something he did not do.
        #expect(h.events.contains { $0.type == .tamperGap } == false)
    }

    /// A gap long enough to take the rest of the session ends it, with its own reason.
    ///
    /// **The two numbers are deliberately different.** `tamper_gap` reports the gap — 1800
    /// seconds nobody can account for, which is what the parent is being told about.
    /// `used_s` reports what the gap actually *took*: the session held 1200, and
    /// `SessionState.charge` floors at zero rather than going negative. Writing 1800 in both
    /// places would put a session on the record as having used half an hour it never had.
    /// Found reviewing T07 — `launch` was reporting `gap.chargedSeconds` where `tick` has
    /// always reported the decrement.
    @Test("a gap that outlasts the session ends it as a gap, and is charged only what it took")
    func gapCanEndTheSession() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0), until: day.wall(2026, 8, 21, 16, 10, 0))
        #expect(h.remaining == 1200)

        h.kill()
        h.skip(to: day.wall(2026, 8, 21, 16, 40, 0))          // 30 min unexplained > 20 min left
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))

        #expect(h.remaining == 0)
        #expect(h.events.suffix(2) == [
            Event(.tamperGap, at: day.wall(2026, 8, 21, 16, 40, 0), [.seconds: 1800]),
            Event(.sessionEnd, at: day.wall(2026, 8, 21, 16, 40, 0),
                  [.reason: "gap", .usedSeconds: 1200]),
        ])
    }

    /// The control for the clamp above: a gap that lands *exactly* on the remainder reports
    /// the same number in both lines, because nothing was floored away.
    ///
    /// The pair is what pins the rule. One test alone would pass just as happily against
    /// `min(gap, anything)` or against the gap itself; only the two together say that the
    /// number is the decrement.
    @Test("a gap exactly the size of the remainder charges all of it and no more")
    func gapExactlyTheSizeOfTheSession() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0), until: day.wall(2026, 8, 21, 16, 10, 0))
        #expect(h.remaining == 1200)

        h.kill()
        h.skip(to: day.wall(2026, 8, 21, 16, 30, 0))          // 1200s unexplained == 1200s left
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))

        #expect(h.remaining == 0)
        #expect(h.events.suffix(2) == [
            Event(.tamperGap, at: day.wall(2026, 8, 21, 16, 30, 0), [.seconds: 1200]),
            Event(.sessionEnd, at: day.wall(2026, 8, 21, 16, 30, 0),
                  [.reason: "gap", .usedSeconds: 1200]),
        ])
    }

    // MARK: - 3. Logging out (DESIGN §2.1)

    /// **The rule the whole design turns on.** He must never learn that logging out to free
    /// the Mac costs him time, because then he stops doing it. Asserted across a real
    /// `JSONEncoder`/`JSONDecoder` round trip of the ledger, which is what `session.json` is.
    @Test("logging out mid-session preserves the remainder and consumes no session")
    func logoutIsNotAGap() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0), until: day.wall(2026, 8, 21, 16, 10, 0))

        h.quit()
        h.skip(to: day.wall(2026, 8, 21, 17, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))
        h.tick()

        #expect(h.enforcer.calls.last?.decision == .awaitingResume(remaining: 1200))
        #expect(h.engine.state.sessionsUsedToday == 1)        // still one, not two
        #expect(h.events.contains { $0.type == .tamperGap } == false)
    }

    /// `wasRunning` is the only thing that survives the logout, and it is what separates
    /// "his session ran out" from "he has not started one". Without it a child who lets a
    /// session expire and then logs out would be handed a fresh one as though nothing had
    /// happened.
    ///
    /// **T07's task doc says this returns `awaitingStart(1 left)`.** It cannot: that is the
    /// decision for a child who has started nothing today, and the doc's own "Expired then
    /// logout" bullet asks for the opposite. The question the doc was reaching for — may he
    /// start another one unaided — went away on 2026-08-22 with the move to one session a
    /// day: the answer is `.expired(selfServiceLeft: 0)`, and the way on is the PIN.
    @Test("a session that expired before the logout is still expired after it")
    func expiredThenLogoutStaysExpired() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0), until: day.wall(2026, 8, 21, 16, 31, 0))
        #expect(h.remaining == 0)

        h.quit()
        h.skip(to: day.wall(2026, 8, 21, 18, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))
        h.tick()

        #expect(h.enforcer.calls.last?.decision == .expired(selfServiceLeft: 0))
        // The day's one session is spent, so more minutes are the parent's to give — and
        // giving them never touches the count, however many they are.
        h.engine.extend(minutes: 30, at: h.now)
        h.run(until: day.wall(2026, 8, 21, 18, 0, 1))
        #expect(h.enforcer.calls.last?.decision == .allowed(remaining: 1799))
        #expect(h.engine.state.sessionsUsedToday == 1)
    }

    // MARK: - 4. The shared machine (DESIGN §2.2)

    /// Another user switches in for two hours. Nothing is charged — charging him while the
    /// parent works would be theft — and nothing is spoken into their session either.
    ///
    /// The threshold he was one second away from fires the moment he is back.
    @Test("two hours off-console charge nothing, and the threshold waits for his return")
    func sharedMachineChargesNothingAndSaysNothing() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 16, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))
        h.tick()
        h.engine.startSelfService(at: h.now)

        h.run(until: day.wall(2026, 8, 21, 16, 19, 59))
        #expect(h.remaining == 601)                           // one second above the threshold

        h.sensors.sessionOnConsole = false
        h.run(until: day.wall(2026, 8, 21, 18, 19, 59))
        #expect(h.remaining == 601)                           // two hours later, untouched
        #expect(h.events.contains { $0.type == .warned } == false)
        #expect(h.enforcer.warnings.isEmpty)

        h.sensors.sessionOnConsole = true
        h.run(until: day.wall(2026, 8, 21, 18, 20, 0))
        #expect(h.remaining == 600)
        #expect(h.events.last == Event(.warned, at: day.wall(2026, 8, 21, 18, 20, 0),
                                       [.threshold: 10, .remainingSeconds: 600]))
    }

    /// The suppression rule on its own, at the one instant it bites: the threshold is already
    /// crossed when the console goes away.
    ///
    /// Seeded rather than scripted, and it has to be — while another user is switched in
    /// nothing is charged, so the remainder cannot *fall* into a threshold during it. The
    /// reachable case is a session that is already inside one, which is what this seeds. The
    /// rule is invisible to `decide`, which reads no sensors at all (T05), so it lives in
    /// ``Engine`` and this is the test that holds it there.
    @Test("a warning already due is not spoken off-console, and is not forgotten either")
    func warningIsSuppressedOffConsole() {
        let day = Calendar.warsaw
        let start = day.wall(2026, 8, 21, 16, 0, 0)
        let seeded = SessionState(dayKey: "2026-08-21", remainingSeconds: 600,
                                  selfServiceStarts: ["2026-08-21": 1], wasRunning: true,
                                  lastHeartbeat: start, exitKind: .unknown, isLive: true)
        let h = Harness(start: start, state: seeded)
        h.sensors.sessionOnConsole = false

        h.tick()
        h.run(until: day.wall(2026, 8, 21, 16, 5, 0))
        #expect(h.enforcer.calls.last?.decision == .warning(remaining: 600, threshold: 10))
        #expect(h.events.isEmpty)                             // said nothing, wrote nothing
        #expect(h.enforcer.warnings.isEmpty)

        h.sensors.sessionOnConsole = true
        h.run(until: day.wall(2026, 8, 21, 16, 5, 1))
        #expect(h.events == [Event(.warned, at: day.wall(2026, 8, 21, 16, 5, 1),
                                   [.threshold: 10, .remainingSeconds: 599])])
        #expect(h.enforcer.warnings.count == 1)
    }

    // MARK: - 5. A film versus an abandoned game (DESIGN §2.2)

    /// The media clause and its cap, from both sides of the same script. A 60-minute session
    /// so that the boundary being tested is the 30-minute cap and not the session running out
    /// underneath it.
    @Test("media playing charges at 15 minutes idle and stops at 35")
    func filmChargesAndAbandonedGameDoesNot() {
        let day = Calendar.warsaw
        var hour = Config.forTesting()
        hour.sessionMinutes = 60
        let h = Harness(start: day.wall(2026, 8, 21, 16, 0, 0), config: hour)
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))
        h.tick()
        h.engine.startSelfService(at: h.now)

        h.run(until: day.wall(2026, 8, 21, 16, 10, 0))
        #expect(h.remaining == 3000)

        h.sensors.mediaPlaying = true
        h.walksAway()
        h.run(until: day.wall(2026, 8, 21, 16, 25, 0))        // 15 minutes idle
        #expect(h.remaining == 2100)                          // …still counting: a film
        h.run(until: day.wall(2026, 8, 21, 16, 40, 0))        // 30 minutes idle, the cap
        #expect(h.remaining == 1200)
        h.run(until: day.wall(2026, 8, 21, 16, 45, 0))        // 35 minutes idle
        #expect(h.remaining == 1200)                          // …stopped: a game left running
        h.run(until: day.wall(2026, 8, 21, 17, 0, 0))
        #expect(h.remaining == 1200)
    }

    /// The same script with nothing playing stops twenty minutes earlier, at the plain idle
    /// grace. The media clause is what moves the boundary, and this is the control.
    @Test("with nothing playing the clock stops at the 10-minute grace")
    func idleWithNothingPlayingStopsAtTheGrace() {
        let day = Calendar.warsaw
        var hour = Config.forTesting()
        hour.sessionMinutes = 60
        let h = Harness(start: day.wall(2026, 8, 21, 16, 0, 0), config: hour)
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))
        h.tick()
        h.engine.startSelfService(at: h.now)

        h.run(until: day.wall(2026, 8, 21, 16, 10, 0))
        h.walksAway()
        h.run(until: day.wall(2026, 8, 21, 16, 20, 0))        // 10 minutes idle, the grace
        #expect(h.remaining == 2400)
        h.run(until: day.wall(2026, 8, 21, 17, 0, 0))
        #expect(h.remaining == 2400)
    }

    // MARK: - 6. Standing the app down (DESIGN §2.5)

    /// `PIN ▸ Wyłącz` at 21:15 ends the running session outright, stands the app down through
    /// the night, and re-arms itself at 06:00 with both self-service sessions back.
    ///
    /// Ended rather than banked: the count is keyed by day, so 06:00 refills the allowance
    /// regardless, and carrying a remainder across would hand out that allowance *plus* the
    /// leftover.
    @Test("a stand-down ends the session, holds all night and re-arms at 06:00")
    func disabledUntilMorning() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 21, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 20, 0, 0))
        h.tick()
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 21, 21, 15, 0))
        #expect(h.remaining == 900)

        let until = h.engine.disable(at: h.now)
        #expect(until == day.wall(2026, 8, 22, 6, 0, 0))
        #expect(h.remaining == 0)
        h.run(until: day.wall(2026, 8, 21, 21, 15, 1))
        #expect(h.enforcer.calls.last?.decision == .dormant)

        // Not a cover between the stand-down and the morning: `.dormant` stands the app down,
        // it does not block the screen (§2.5).
        let standDown = h.enforcer.calls.count
        h.walksAway()
        h.run(until: day.wall(2026, 8, 22, 5, 59, 0), step: 60)
        #expect(h.enforcer.calls[standDown...].allSatisfy { !$0.decision.coversScreen })
        h.run(until: day.wall(2026, 8, 22, 6, 0, 10))

        #expect(h.events.contains(Event(.sessionEnd, at: day.wall(2026, 8, 21, 21, 15, 0),
                                        [.reason: "disabled", .usedSeconds: 900])))
        #expect(h.events.contains(Event(.disabled, at: day.wall(2026, 8, 21, 21, 15, 0),
                                        [.until: .string(Event.timestampText(until, day.timeZone))])))
        #expect(h.events.contains(Event(.rearmed, at: day.wall(2026, 8, 22, 6, 0, 0))))
        #expect(h.enforcer.calls.last?.decision == .awaitingStart(selfServiceLeft: 1))

        // Both sessions really are back, not merely offered.
        h.engine.startSelfService(at: h.now)
        #expect(h.engine.state.sessionsUsedToday == 1)
        #expect(h.remaining == 1800)
    }

    /// **A PIN grant during a stand-down switches the app back on.** The user's decision,
    /// 2026-08-22, and the fix for a real hole: without it the granted minutes drained in
    /// silence. `decide` returns `.dormant` for the whole stand-down, so the screen stays
    /// free and no countdown ever appears — but `advance` charges whenever the session is
    /// live and he is at the machine, and it reads neither the stand-down nor the decision.
    /// Half an hour granted at 21:00 was gone by 21:30 and the child never saw a second of it.
    ///
    /// `disable` had made that safe by *ending* the session, leaving nothing to charge; a
    /// grant puts a live session back, which is what re-opened it.
    @Test("minutes granted during a stand-down switch the app back on rather than draining")
    func grantDuringAStandDownLiftsIt() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 21, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 20, 0, 0))
        h.tick()
        let until = h.engine.disable(at: h.now)
        h.run(until: day.wall(2026, 8, 21, 21, 0, 5))
        #expect(h.enforcer.calls.last?.decision == .dormant)

        // The parent changes their mind five seconds later.
        h.engine.extend(minutes: 30, at: h.now)
        h.run(until: day.wall(2026, 8, 21, 21, 0, 6))

        // Armed again, counting down, and on screen — not draining behind a free screen.
        #expect(h.engine.state.disabledUntil == nil)
        #expect(h.enforcer.calls.last?.decision == .allowed(remaining: 1799))

        // `rearmed` before `extended`: the app came back on, and then the minutes landed.
        #expect(h.events.suffix(2) == [
            Event(.rearmed,  at: day.wall(2026, 8, 21, 21, 0, 5)),
            Event(.extended, at: day.wall(2026, 8, 21, 21, 0, 5), [.minutes: 30, .countToday: 0]),
        ])
        // And **no `uncovered`** for the grant, which is right: the cover came down at
        // 21:00:01 when the stand-down began, and `.dormant` → `.allowed` is not a cover
        // edge — neither of them puts anything on the screen. The only `uncovered` in this
        // scenario is the one the stand-down itself caused.
        #expect(h.events.filter { $0.type == .uncovered } == [
            Event(.uncovered, at: day.wall(2026, 8, 21, 21, 0, 1), [.by: "disabled"]),
        ])

        // They run out as ordinary minutes do, warnings and cover included — the whole point
        // of switching the app back on rather than merely handing over a number.
        h.run(until: day.wall(2026, 8, 21, 21, 30, 5))
        #expect(h.remaining == 0)
        #expect(h.enforcer.warnings.map(\.threshold) == [10, 5, 1])
        // **`.awaitingStart`, not `.expired` — changed by T20 (2026-08-30).** He has not
        // touched his own self-service session all day; the thirty minutes that just ran out
        // were the parent's grant. Before T20 this read `.expired(selfServiceLeft: 1)`, whose
        // cover offers no `Rozpocznij` at any count — so accepting a PIN grant early in the
        // evening silently cost him the session he was already entitled to, for the rest of
        // the day. Same defect as the straddled rollover, reached by a different door.
        #expect(h.enforcer.calls.last?.decision == .awaitingStart(selfServiceLeft: 1))

        // And the stand-down really is gone, not merely ignored: 06:00 has nothing to re-arm,
        // so there is exactly one `rearmed` in the whole night.
        h.run(until: day.wall(2026, 8, 22, 6, 0, 10), step: 60)
        #expect(h.events.filter { $0.type == .rearmed }.count == 1)
        #expect(until == day.wall(2026, 8, 22, 6, 0, 0))   // …the one it would have fired at
    }

    /// A grant of nothing is not a grant, and must not end the night's stand-down.
    ///
    /// The clamp makes `-5` and `0` the same call, so this pins both: a hand-edited or
    /// mis-typed caller cannot switch the app back on by granting no time at all.
    @Test("a zero-minute grant leaves the stand-down standing")
    func zeroGrantDoesNotLiftTheStandDown() {
        let day = Calendar.warsaw
        for minutes in [0, -5] {
            let h = Harness(start: day.wall(2026, 8, 21, 21, 0, 0))
            h.launch(bootTime: day.wall(2026, 8, 21, 20, 0, 0))
            h.tick()
            h.engine.disable(at: h.now)

            h.engine.extend(minutes: minutes, at: h.now)
            h.run(until: day.wall(2026, 8, 21, 21, 0, 2))

            #expect(h.engine.state.disabledUntil != nil, "minutes \(minutes)")
            #expect(h.enforcer.calls.last?.decision == .dormant, "minutes \(minutes)")
            #expect(h.events.contains { $0.type == .rearmed } == false, "minutes \(minutes)")
            #expect(h.remaining == 0, "minutes \(minutes)")
        }
    }

    /// A stand-down taken from behind the expired cover lifts it, and says why.
    @Test("standing down from the cover lifts it")
    func disableFromTheCoverLiftsIt() {
        let day = Calendar.warsaw
        let h = sessionUnderway(from: day.wall(2026, 8, 21, 21, 0, 0), until: day.wall(2026, 8, 21, 21, 31, 0))
        #expect(h.enforcer.calls.last?.decision == .expired(selfServiceLeft: 0))

        h.engine.disable(at: h.now)
        h.run(until: day.wall(2026, 8, 21, 21, 31, 1))
        #expect(h.events.last == Event(.uncovered, at: day.wall(2026, 8, 21, 21, 31, 1),
                                       [.by: "disabled"]))
        #expect(h.enforcer.calls.last?.decision == .dormant)
    }

    // MARK: - 7. No PIN (DESIGN §2.5)

    /// The one fail-open in the app, and the only one. With no PIN nothing could uncover the
    /// screen, so nothing may cover it — for a whole day, with both sessions spent, at every
    /// hour of it.
    @Test("with no PIN the app never covers the screen, all day")
    func noPINStandsTheAppDownAllDay() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 6, 0, 0), config: Config())   // no PIN
        h.launch(bootTime: day.wall(2026, 8, 21, 5, 0, 0))
        h.tick()

        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 21, 12, 0, 0), step: 60)
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 22, 5, 59, 0), step: 60)

        #expect(h.beats == [.launched, .dormant])
        #expect(h.enforcer.calls.allSatisfy { $0.decision == .dormant })
        #expect(h.events.contains { $0.type == .blocked } == false)
        #expect(h.events.contains { $0.type == .uncovered } == false)
        #expect(h.events.contains { $0.type == .warned } == false)
    }

    // MARK: - 8. The two days a year that are not 24 hours long

    /// The same evening, on the morning that is 23 hours from its midnight and on the one that
    /// is 25. The rollover is a wall-clock 06:00 on both, because `DayWindow` does calendar
    /// arithmetic rather than subtracting six hours of elapsed time.
    ///
    /// The whole point of injecting a `Calendar` everywhere is that these two days are
    /// testable at all — `Calendar.current` would be a system query `RSTCore` may not make,
    /// and this would be a manual check nobody would ever run twice.
    @Test("the canonical evening is identical on a 23-hour and a 25-hour day",
          arguments: [(3, 28, 29, "2026-03-29"), (10, 24, 25, "2026-10-25")])
    func canonicalEveningAcrossDST(month: Int, evening: Int, morning: Int, key: String) {
        let day = Calendar.warsaw
        let h = canonicalDay(year: 2026, month: month, evening: evening, morning: morning)

        #expect(h.beats == Self.canonicalBeats, "timeline was:\n\(h.timelineDescription)")
        #expect(h.events == Self.canonicalEvents(day, evening: (2026, month, evening),
                                                 morning: (2026, month, morning)),
                "log was:\n\(h.eventDescription)")

        // The rollover landed on the wall clock, not six hours after midnight.
        #expect(h.timeline.last?.now == day.wall(2026, month, morning, 6, 0, 0))
        #expect(h.engine.state.dayKey == key)
        #expect(h.engine.state.sessionsUsedToday == 0)
    }

    // MARK: - 9. The gate itself

    /// Every ``Decision`` this app can make is reached by the scenarios above.
    ///
    /// A seventh case added to `Decision` — or a rule that makes an existing one
    /// unreachable — fails here rather than passing silently, which is the difference between
    /// a suite that guards Phase 1 and a suite that merely runs.
    @Test("the scenarios reach every decision the app can make")
    func everyDecisionIsExercised() {
        let day = Calendar.warsaw
        var seen = Set<String>()
        for harness in [canonicalDay(year: 2026, month: 8, evening: 21, morning: 22),
                        noPINDay()] {
            for call in harness.enforcer.calls { seen.insert(Self.caseName(call.decision)) }
        }
        // …plus the paused offer, which only a logout mid-session produces.
        let paused = sessionUnderway(from: day.wall(2026, 8, 21, 16, 0, 0),
                                     until: day.wall(2026, 8, 21, 16, 10, 0))
        paused.quit()
        paused.skip(to: day.wall(2026, 8, 21, 17, 0, 0))
        paused.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))
        paused.tick()
        for call in paused.enforcer.calls { seen.insert(Self.caseName(call.decision)) }

        #expect(seen == ["dormant", "awaitingStart", "awaitingResume",
                         "allowed", "warning", "expired"])
    }

    private static func caseName(_ decision: Decision) -> String {
        switch decision {
        case .dormant: return "dormant"
        case .awaitingStart: return "awaitingStart"
        case .awaitingResume: return "awaitingResume"
        case .allowed: return "allowed"
        case .warning: return "warning"
        case .expired: return "expired"
        }
    }
}

// MARK: - The scripts

extension IntegrationTests {

    /// A launch, one session started immediately, and time run forward. The opening of half
    /// the scenarios above.
    func sessionUnderway(from start: Date, until: Date) -> Harness {
        let h = Harness(start: start)
        h.launch(bootTime: start.addingTimeInterval(-3600))
        h.tick()
        h.engine.startSelfService(at: h.now)
        h.run(until: until)
        return h
    }

    func noPINDay() -> Harness {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 16, 0, 0), config: Config())
        h.launch(bootTime: day.wall(2026, 8, 21, 15, 0, 0))
        h.tick()
        h.run(until: day.wall(2026, 8, 21, 20, 0, 0), step: 60)
        return h
    }

    /// **The canonical scenario, as a script.** Parameterised by date so the DST test can run
    /// the identical evening on the two mornings that are not 24 hours from their midnight.
    ///
    /// Times are the task doc's; the consequences are DESIGN §2.2's — see the suite comment.
    func canonicalDay(year: Int, month: Int, evening: Int, morning: Int) -> Harness {
        let day = Calendar.warsaw
        let boot = day.wall(year, month, evening, 15, 0, 0)
        let h = Harness(start: day.wall(year, month, evening, 16, 0, 0))

        // 16:00 — logs in to a cover offering the day's one self-service session.
        h.launch(bootTime: boot)
        h.tick()
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(year, month, evening, 16, 10, 0))

        // 16:10 — walks away. The grace keeps the clock running for ten more minutes, which is
        // where this parts company with the task doc's arithmetic.
        h.walksAway()
        h.run(until: day.wall(year, month, evening, 16, 25, 0))
        h.returns()
        h.run(until: day.wall(year, month, evening, 16, 46, 0))

        // 16:46 — PIN ▸ Dodaj minuty, from behind the expired cover. Fifteen, because that is
        // what the parent typed; the app has no opinion about the size of a grant (§2.5).
        h.engine.extend(minutes: 15, at: h.now)
        h.run(until: day.wall(year, month, evening, 17, 2, 0))

        // 17:02 — Zablokuj ekran, then hands the Mac over and logs out. No PIN for either.
        h.engine.lockScreen(at: h.now)
        h.sensors.screenLocked = true
        h.sensors.typing = false
        h.run(until: day.wall(year, month, evening, 17, 3, 0))
        h.quit()

        // 18:00 — logs back in. The day's one session is spent, so this is `Na dziś koniec
        // sesji` and the way on is the PIN. The parent gives him half an hour.
        h.skip(to: day.wall(year, month, evening, 18, 0, 0))
        h.sensors.screenLocked = false
        h.returns()
        h.launch(bootTime: boot)
        h.tick()
        h.engine.extend(minutes: 30, at: h.now)
        h.run(until: day.wall(year, month, evening, 18, 10, 0))

        // 18:10 — logs out mid-session. Twenty minutes preserved, no session consumed.
        h.quit()
        h.skip(to: day.wall(year, month, evening, 19, 0, 0))
        h.returns()
        h.launch(bootTime: boot)
        h.tick()
        h.engine.resume(at: h.now)
        h.run(until: day.wall(year, month, evening, 19, 21, 0))

        // 19:21 — another half hour, typed into the same box. What used to be `Nowa sesja` is
        // `minutes: 30`, and the log records the size rather than the name.
        h.engine.extend(minutes: 30, at: h.now)
        h.run(until: day.wall(year, month, evening, 19, 55, 0))

        // …and the app runs on through the night, evaluating the rollover from the wall clock
        // on every tick. Nothing may schedule a timer for 06:00: a timer set across a sleep
        // does not fire, and a fixed 24-hour delay is wrong on both days below.
        h.walksAway()
        h.run(until: day.wall(year, month, morning, 5, 59, 0), step: 60)
        h.run(until: day.wall(year, month, morning, 6, 0, 10))
        return h
    }
}

// MARK: - What the canonical scenario must produce

extension IntegrationTests {

    /// The decision timeline, with consecutive repeats of a shape collapsed and a marker at
    /// each run boundary. Identical on all three dates.
    static let canonicalBeats: [Beat] = [
        .launched, .awaitingStart(1), .allowed,                       // 16:00 Rozpocznij
        .warning(10), .warning(5), .warning(1), .expired(0),          // 16:20 → 16:35
        .allowed, .warning(10), .warning(5), .warning(1), .expired(0),// 16:46 +15 → 17:01
        .launched, .expired(0), .allowed,                             // 18:00 PIN ▸ +30
        .launched, .awaitingResume, .allowed,                         // 19:00 Wznów
        .warning(10), .warning(5), .warning(1), .expired(0),          // 19:10 → 19:20
        .allowed, .warning(10), .warning(5), .warning(1), .expired(0),// 19:21 PIN ▸ +30
        .awaitingStart(1),                                            // 06:00 a fresh day
    ]

    /// The log, line for line. `used_s` counts what was charged **in the run that wrote it**,
    /// and granted minutes continue the session rather than starting a new one — so 1800 at
    /// 16:35 is a full session, 2700 at 17:01 is that session plus the 15 granted at 16:46,
    /// 1200 at 19:20 counts only from the resume (a resumed session's earlier minutes are not
    /// in `session.json` to be found), and 3000 at 19:51 is those 1200 plus the 30 granted at
    /// 19:21. Every number is the seconds actually charged since the run began.
    ///
    /// There is exactly one `session_start` in the evening, and it carries no `kind`: since
    /// 2026-08-22 a session can only ever be self-service, and every further minute is an
    /// `extended` line with the amount the parent typed.
    static func canonicalEvents(_ day: Calendar,
                                evening: (Int, Int, Int),
                                morning: (Int, Int, Int)) -> [Event] {
        func e(_ h: Int, _ m: Int, _ s: Int) -> Date {
            day.wall(evening.0, evening.1, evening.2, h, m, s)
        }
        return [
            Event(.blocked,       at: e(16, 0, 0),  [.reason: "no_session"]),
            Event(.sessionStart,  at: e(16, 0, 0),  [.countToday: 1]),
            Event(.uncovered,     at: e(16, 0, 1),  [.by: "started"]),
            Event(.warned,        at: e(16, 20, 0), [.threshold: 10, .remainingSeconds: 600]),
            Event(.warned,        at: e(16, 30, 0), [.threshold: 5, .remainingSeconds: 300]),
            Event(.warned,        at: e(16, 34, 0), [.threshold: 1, .remainingSeconds: 60]),
            Event(.sessionEnd,    at: e(16, 35, 0), [.reason: "expired", .usedSeconds: 1800]),
            Event(.blocked,       at: e(16, 35, 0), [.reason: "expired"]),
            Event(.extended,      at: e(16, 46, 0), [.minutes: 15, .countToday: 1]),
            Event(.uncovered,     at: e(16, 46, 1), [.by: "extended"]),
            Event(.warned,        at: e(16, 51, 0), [.threshold: 10, .remainingSeconds: 600]),
            Event(.warned,        at: e(16, 56, 0), [.threshold: 5, .remainingSeconds: 300]),
            Event(.warned,        at: e(17, 0, 0),  [.threshold: 1, .remainingSeconds: 60]),
            Event(.sessionEnd,    at: e(17, 1, 0),  [.reason: "expired", .usedSeconds: 2700]),
            Event(.blocked,       at: e(17, 1, 0),  [.reason: "expired"]),
            Event(.screenLocked,  at: e(17, 2, 0)),
            Event(.blocked,       at: e(18, 0, 0),  [.reason: "expired"]),
            Event(.extended,      at: e(18, 0, 0),  [.minutes: 30, .countToday: 1]),
            Event(.uncovered,     at: e(18, 0, 1),  [.by: "extended"]),
            Event(.blocked,       at: e(19, 0, 0),  [.reason: "paused"]),
            Event(.sessionResume, at: e(19, 0, 0),  [.remainingSeconds: 1200]),
            Event(.uncovered,     at: e(19, 0, 1),  [.by: "resumed"]),
            Event(.warned,        at: e(19, 10, 0), [.threshold: 10, .remainingSeconds: 600]),
            Event(.warned,        at: e(19, 15, 0), [.threshold: 5, .remainingSeconds: 300]),
            Event(.warned,        at: e(19, 19, 0), [.threshold: 1, .remainingSeconds: 60]),
            Event(.sessionEnd,    at: e(19, 20, 0), [.reason: "expired", .usedSeconds: 1200]),
            Event(.blocked,       at: e(19, 20, 0), [.reason: "expired"]),
            Event(.extended,      at: e(19, 21, 0), [.minutes: 30, .countToday: 1]),
            Event(.uncovered,     at: e(19, 21, 1), [.by: "extended"]),
            Event(.warned,        at: e(19, 41, 0), [.threshold: 10, .remainingSeconds: 600]),
            Event(.warned,        at: e(19, 46, 0), [.threshold: 5, .remainingSeconds: 300]),
            Event(.warned,        at: e(19, 50, 0), [.threshold: 1, .remainingSeconds: 60]),
            Event(.sessionEnd,    at: e(19, 51, 0), [.reason: "expired", .usedSeconds: 3000]),
            Event(.blocked,       at: e(19, 51, 0), [.reason: "expired"]),
        ]
    }
}
