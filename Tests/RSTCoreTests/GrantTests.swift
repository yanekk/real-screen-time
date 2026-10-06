import Foundation
import Testing
@testable import RSTCore

/// **T13 — the way back in.** The PIN itself is `PINTests`; this is everything the prompt
/// is a front for: the rate limit, the amounts it offers, and what the two grants actually
/// do to the ledger.
///
/// The dialog itself cannot be tested here and is not pretended to be — `NSSecureTextField`
/// and a floating panel are `RSTApp`'s, on a machine with no UI automation. What *is* here
/// is every rule the dialog obeys, which is the whole point of the Core/App split.
@Suite("T13 — the PIN prompt and the two grants")
@MainActor
struct GrantTests {

    // MARK: - The rate limit

    /// One second after the first wrong PIN, growing a second at a time, capped at five.
    ///
    /// Linear and bounded. DESIGN §2.5 refuses a lockout outright, so the schedule's job is
    /// to make ten thousand guesses tedious without ever making the tenth impossible.
    @Test("the delay grows a second at a time and stops at five")
    func backoffSchedule() {
        #expect(PINGate.delay(afterFailures: 0) == 0)
        #expect((1...9).map(PINGate.delay(afterFailures:)) == [1, 2, 3, 4, 5, 5, 5, 5, 5])
        // Nothing a caller can do makes the gate hand back a delay it cannot honour.
        #expect(PINGate.delay(afterFailures: -3) == 0)
        #expect(PINGate.delay(afterFailures: .max) == PINGate.maxDelay)
    }

    @Test("a fresh gate is open, and stays open until something fails")
    func openUntilItFails() {
        let now = Date(timeIntervalSince1970: 1_000)
        var gate = PINGate()
        #expect(gate.isOpen(at: now))
        #expect(gate.wait(at: now) == 0)
        #expect(gate.failures == 0)

        gate.failed(at: now)
        #expect(gate.failures == 1)
        #expect(gate.isOpen(at: now) == false)
        #expect(gate.wait(at: now) == 1)
    }

    /// The wait runs down with the clock and opens exactly on time — `wait == 0` at the
    /// instant it expires, not a tick later.
    @Test("the wait counts down and the gate opens on the instant")
    func waitCountsDown() {
        let now = Date(timeIntervalSince1970: 1_000)
        var gate = PINGate()
        gate.failed(at: now)
        gate.failed(at: now)                     // two in a row: two seconds

        #expect(gate.wait(at: now) == 2)
        #expect(gate.wait(at: now.addingTimeInterval(0.5)) == 1.5)
        #expect(gate.wait(at: now.addingTimeInterval(2)) == 0)
        #expect(gate.isOpen(at: now.addingTimeInterval(2)))
        #expect(gate.isOpen(at: now.addingTimeInterval(60)))
    }

    /// A correct PIN forgets everything. The next prompt starts from one second again, not
    /// from wherever the last argument got to.
    @Test("a correct PIN clears the failures and opens the gate")
    func successResets() {
        let now = Date(timeIntervalSince1970: 1_000)
        var gate = PINGate()
        for _ in 0..<4 { gate.failed(at: now) }
        #expect(gate.wait(at: now) == 4)

        gate.succeeded()
        #expect(gate.failures == 0)
        #expect(gate.isOpen(at: now))

        gate.failed(at: now)
        #expect(gate.wait(at: now) == 1)
    }

    /// **A clock stepped backwards must not hold the field shut for the size of the step.**
    ///
    /// `RST_TIME_SCALE` moves the clock in leaps and a real Mac corrects its own by an hour
    /// twice a year; either would otherwise leave a covered screen with a PIN box that
    /// refuses to answer for an hour, which is the lockout §2.5 forbids under another name.
    @Test("a clock stepped backwards cannot extend the wait past the cap")
    func clockGoingBackwards() {
        let now = Date(timeIntervalSince1970: 1_000)
        var gate = PINGate()
        gate.failed(at: now)
        #expect(gate.wait(at: now.addingTimeInterval(-3_600)) == PINGate.maxDelay)
    }

    /// Failing since the Bronze Age. Saturating rather than wrapping: `Int.max + 1` goes
    /// negative, and a negative count hands back a delay of zero — the one direction this
    /// must never fail.
    @Test("the failure count saturates instead of wrapping into a free attempt")
    func failureCountSaturates() {
        let now = Date(timeIntervalSince1970: 1_000)
        var gate = PINGate()
        for _ in 0..<3 { gate.failed(at: now) }
        #expect(gate.failures == 3)

        // Reached the only way the type allows, then pushed one further.
        var extreme = PINGate()
        for _ in 0..<10 { extreme.failed(at: now) }
        #expect(extreme.wait(at: now) == PINGate.maxDelay)
    }

    /// **The PIN is four digits, and since 2026-08-25 that is enforced rather than assumed.**
    ///
    /// The prompt is four boxes that submit themselves on the fourth digit (the user's
    /// change), so a PIN of any other length cannot be typed at all. Nothing in `RSTCore`
    /// rejects one — as this test shows, a six-digit PIN hashes and verifies perfectly well —
    /// which makes the gap real and makes it **T16's** to close at the moment the parent
    /// chooses the PIN. A wizard that wrote a five-digit hash would produce a cover with no
    /// key, which is the one failure DESIGN §2.5 exists to prevent.
    @Test("a PIN is four digits, and nothing below the wizard enforces it")
    func pinIsFourDigits() {
        #expect(pinDigits == 4)

        let salt = newPINSalt()
        let four = hashPIN("1234", salt: salt, rounds: 1_000)
        #expect(verifyPIN("1234", hash: four, salt: salt, rounds: 1_000))

        // Longer still works here, and can never be entered up there. Hence T16.
        let six = hashPIN("123456", salt: salt, rounds: 1_000)
        #expect(verifyPIN("123456", hash: six, salt: salt, rounds: 1_000))
        #expect(verifyPIN("1234", hash: six, salt: salt, rounds: 1_000) == false)
    }

    // MARK: - What the dialog offers

    /// The config's amounts, ascending whatever order they were typed in (sort-grant-amounts).
    @Test("the amounts are the config's, ascending")
    func grantOffersTheConfiguredAmounts() {
        var config = Config()
        #expect(GrantModel(config: config).amounts == [15, 30, 60])

        config.extensionOptions = [15, 30, 60, 5, 10]
        #expect(GrantModel(config: config).amounts == [5, 10, 15, 30, 60])
        config.extensionOptions = [45, 5, 90]
        #expect(GrantModel(config: config).amounts == [5, 45, 90])
    }

    /// **A grant dialog with no amounts on it is a PIN prompt that can grant nothing**, and
    /// that is the one shape it must never take. Nothing validates `config.json`, so every
    /// one of these is a hand-edit away.
    @Test("a list edited down to nothing usable falls back to what ships")
    func grantNeverOffersNothing() {
        for edited in [[], [0], [-30, 0], [Int.min]] {
            var config = Config()
            config.extensionOptions = edited
            let model = GrantModel(config: config)
            #expect(model.amounts == Config.defaultExtensionOptions, "\(edited)")
        }
    }

    @Test("duplicates go and the rest is ascending")
    func grantDropsDuplicates() {
        var config = Config()
        config.extensionOptions = [30, 15, 30, -1, 15, 60]
        #expect(GrantModel(config: config).amounts == [15, 30, 60])
    }

    // MARK: - Dodaj minuty

    /// Three grants of 15 are 45 minutes on the session, and three lines in the log.
    ///
    /// Repeatable is the whole shape of §2.5's answer to a cap: 90 minutes is 60 then 30,
    /// and the log shows both, which reads better than one large number anyway.
    @Test("grants stack: three of 15 make 45 minutes")
    func grantsStack() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.tick()

        for _ in 0..<3 { h.engine.extend(minutes: 15, at: h.now) }
        #expect(h.remaining == 45 * 60)
        #expect(h.events.filter { $0.type == .extended }.count == 3)

        // And they are real minutes, not a number in a field: they run down like any other.
        h.run(until: day.wall(2026, 8, 21, 19, 45, 0))
        #expect(h.remaining == 0)
    }

    /// **Granted minutes never touch the self-service count, whatever their size.**
    ///
    /// That count gates what he can do *alone*; minutes a parent granted were never
    /// self-service. 240 in one press is the same rule as 15.
    @Test("a grant costs no session, at any size")
    func grantsCostNoSession() {
        let day = Calendar.warsaw
        for minutes in [1, 15, 60, 240, 6_000] {
            let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
            h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
            h.tick()

            h.engine.extend(minutes: minutes, at: h.now)
            #expect(h.engine.state.sessionsUsedToday == 0, "\(minutes)")
            // Still his to start, untouched — the whole point of the rule.
            #expect(h.engine.state.selfServiceLeft(h.config) == 1, "\(minutes)")
            #expect(h.events.last == Event(.extended, at: h.now,
                                           [.minutes: .number(Double(minutes)),
                                            .countToday: 0]), "\(minutes)")
        }
    }

    /// `Rozpocznij` is the one thing that does cost a session — and when they are gone the
    /// cover offers the PIN and the screen lock, and nothing else.
    @Test("Rozpocznij spends the day's allowance and leaves only the PIN path")
    func selfServiceSpendsTheAllowance() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.tick()

        h.engine.startSelfService(at: h.now)
        #expect(h.engine.state.sessionsUsedToday == 1)
        #expect(h.engine.state.selfServiceLeft(h.config) == 0)

        h.run(until: day.wall(2026, 8, 21, 19, 30, 1))
        #expect(h.enforcer.calls.last?.decision == .expired(selfServiceLeft: 0))

        let cover = CoverModel(decision: h.enforcer.calls.last?.decision,
                               sessionsUsedToday: h.engine.state.sessionsUsedToday,
                               config: h.config)
        #expect(cover?.face == .exhausted)
        #expect(cover?.buttons == [.pin, .lock, .logout])
    }

    /// A grant on the expired cover puts the child back in, and the minutes run out exactly
    /// as the first ones did — `.expired` again, not `.awaitingStart`.
    @Test("a grant on an expired session allows again, and expires again when it is spent")
    func grantOnAnExpiredSession() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.tick()
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 21, 19, 30, 1))
        #expect(h.enforcer.calls.last?.decision == .expired(selfServiceLeft: 0))

        h.engine.extend(minutes: 15, at: h.now)
        h.run(until: day.wall(2026, 8, 21, 19, 30, 2))
        #expect(h.enforcer.calls.last?.decision == .allowed(remaining: 899))

        h.run(until: day.wall(2026, 8, 21, 19, 45, 2))
        #expect(h.enforcer.calls.last?.decision == .expired(selfServiceLeft: 0))
        // Still no session spent: a whole second helping, and the count never moved.
        #expect(h.engine.state.sessionsUsedToday == 1)
    }

    /// `extend` is **total**. Nothing a caller passes traps, and nothing hands time back.
    ///
    /// The dialog cannot produce these — every amount it offers came out of the config — but
    /// `Engine.extend(minutes:at:)` is public and the config is hand-edited, so both ends of
    /// `Int` are pinned here rather than argued about.
    @Test("an absurd or negative amount is clamped, not trapped")
    func absurdAmountsAreClamped() {
        let day = Calendar.warsaw
        for (minutes, expected) in [(-1, 0.0), (Int.min, 0.0), (0, 0.0),
                                    (Int.max, SessionState.secondsCeiling)] {
            let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
            h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
            h.tick()

            h.engine.extend(minutes: minutes, at: h.now)
            #expect(h.remaining == expected, "\(minutes)")
            // Logged as what was granted after the clamp, never as what was asked for: the
            // event log is evidence, and a line saying 9 223 372 036 854 775 807 minutes
            // would be evidence of nothing.
            #expect(h.events.last == Event(.extended, at: h.now,
                                           [.minutes: .number(Double(max(0, minutes))),
                                            .countToday: 0]), "\(minutes)")
        }
    }

    // MARK: - Remote grants (T04)

    /// The remote door adds the same minutes the PIN door does, records the dedupe id in the
    /// same object, and marks its `extended` line `source:"remote"` — the one thing that tells
    /// a parent reading the log a remote grant from one typed at the Mac.
    @Test("applyRemoteGrant adds the minutes, records the id, and marks the log remote")
    func remoteGrantAppliesAndMarksTheLog() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.tick()

        h.engine.applyRemoteGrant(id: "g1", minutes: 15, at: h.now, announce: true)

        #expect(h.remaining == 15 * 60)
        #expect(h.engine.state.appliedRemoteGrants["g1"] == h.now)
        #expect(h.events.last == Event(.extended, at: h.now,
                                       [.minutes: 15, .countToday: 0, .source: "remote"]))
        // On-console, so the grant is spoken exactly as the PIN grant is (§2.6).
        #expect(h.enforcer.announced.contains { if case .granted(15) = $0.announcement { return true }; return false })
    }

    /// **Off-console suppresses the chime** (DESIGN §2.6). The minutes land and the line is
    /// still written — what happened is a fact about the evening — but nothing is spoken over
    /// whoever the parent switched in to.
    @Test("a remote grant applied off-console adds the minutes and logs them but does not speak")
    func remoteGrantOffConsoleIsSilent() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.tick()

        h.engine.applyRemoteGrant(id: "g2", minutes: 30, at: h.now, announce: false)

        #expect(h.remaining == 30 * 60)
        #expect(h.engine.state.appliedRemoteGrants["g2"] == h.now)
        #expect(h.events.last == Event(.extended, at: h.now,
                                       [.minutes: 30, .countToday: 0, .source: "remote"]))
        // Nothing spoken: no grant announcement at all.
        #expect(!h.enforcer.announced.contains { if case .granted = $0.announcement { return true }; return false })
    }

    /// The `announce` flag reaches the PIN door too, so a caller that wants the minutes without
    /// the chime has one — and its default keeps every existing call site speaking.
    @Test("extend(announce: false) applies without speaking, and no source field is written")
    func extendCanSuppressTheChime() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.tick()

        h.engine.extend(minutes: 15, at: h.now, announce: false)

        #expect(h.remaining == 15 * 60)
        // A local grant carries no `source` — byte-for-byte the line it has always been.
        #expect(h.events.last == Event(.extended, at: h.now, [.minutes: 15, .countToday: 0]))
        #expect(!h.enforcer.announced.contains { if case .granted = $0.announcement { return true }; return false })
    }

    /// A remote grant on an expired cover is the whole point of the feature: it lifts the cover
    /// through the same path the PIN grant uses, so `decide` goes from `.expired` to `.allowed`.
    @Test("a remote grant on an expired session allows again")
    func remoteGrantLiftsTheExpiredCover() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.tick()
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 21, 19, 30, 1))
        #expect(h.enforcer.calls.last?.decision == .expired(selfServiceLeft: 0))

        h.engine.applyRemoteGrant(id: "g3", minutes: 15, at: h.now, announce: true)
        h.run(until: day.wall(2026, 8, 21, 19, 30, 2))
        #expect(h.enforcer.calls.last?.decision == .allowed(remaining: 899))
        // A grant costs no self-service session, remote or local.
        #expect(h.engine.state.sessionsUsedToday == 1)
    }

    /// A remote stand-down lift: a grant arriving during a PIN stand-down re-arms the app, the
    /// same as a PIN grant does (§2.5) — the remote grant *is* a PIN grant.
    @Test("a remote grant during a stand-down lifts it")
    func remoteGrantLiftsAStandDown() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 22, 20, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 22, 19, 0, 0))
        h.tick()
        h.engine.disable(at: h.now)
        #expect(h.engine.state.disabledUntil != nil)

        h.engine.applyRemoteGrant(id: "g4", minutes: 15, at: h.now, announce: true)
        #expect(h.engine.state.disabledUntil == nil)
        #expect(h.remaining == 15 * 60)
        // The lift is recorded, so the parent's log shows the app came back on and when.
        #expect(h.events.contains { $0.type == .rearmed })
    }

    // MARK: - Wyłącz do jutra

    /// **The 05:30 case, which is the one that is wrong on the first attempt.**
    ///
    /// "Until tomorrow" is not a day away at half past five in the morning — it is half an
    /// hour away, because the day has not turned over yet. `DayWindow.nextReset` is what
    /// gets this right, and this is the test that says so out loud.
    @Test("Wyłącz sets the stand-down to the next 06:00, half an hour away at 05:30")
    func standDownAtHalfPastFive() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 22, 5, 30, 0))
        h.launch(bootTime: day.wall(2026, 8, 22, 5, 0, 0))
        h.tick()

        let until = h.engine.disable(at: h.now)
        #expect(until == day.wall(2026, 8, 22, 6, 0, 0))
        #expect(until.timeIntervalSince(h.now) == 1_800)
    }

    /// The ordinary evening case, and the boundary between them: at 06:00 exactly the reset
    /// that has just happened is behind us, so "tomorrow" really is a day away.
    @Test("the stand-down lands on tomorrow's 06:00 from the evening, and from 06:00 itself")
    func standDownFromEveningAndFromTheBoundary() {
        let day = Calendar.warsaw
        for (start, expected) in [(day.wall(2026, 8, 21, 21, 15, 0), day.wall(2026, 8, 22, 6, 0, 0)),
                                  (day.wall(2026, 8, 21, 6, 0, 0), day.wall(2026, 8, 22, 6, 0, 0)),
                                  (day.wall(2026, 8, 21, 5, 59, 59), day.wall(2026, 8, 21, 6, 0, 0))] {
            let h = Harness(start: start)
            h.launch(bootTime: start.addingTimeInterval(-3_600))
            h.tick()
            #expect(h.engine.disable(at: h.now) == expected, "\(h.hhmmss(start))")
        }
    }

    /// Standing down at 05:30 and re-arming at 06:00 gives back a **whole** day's budget —
    /// the stand-down took the running session with it, and the morning refills the
    /// allowance regardless, so nothing is carried across and nothing is lost.
    @Test("a stand-down half an hour before the reset re-arms with a full budget")
    func rearmAtSixRestoresTheBudget() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 22, 5, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 22, 4, 0, 0))
        h.tick()
        // He started one at 05:00 — yesterday's allowance, since the day turns at 06:00.
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 22, 5, 30, 0))
        #expect(h.engine.state.sessionsUsedToday == 1)

        h.engine.disable(at: h.now)
        #expect(h.remaining == 0)
        h.run(until: day.wall(2026, 8, 22, 5, 30, 1))
        #expect(h.enforcer.calls.last?.decision == .dormant)

        h.run(until: day.wall(2026, 8, 22, 6, 0, 10))
        #expect(h.events.contains { $0.type == .rearmed })
        #expect(h.enforcer.calls.last?.decision == .awaitingStart(selfServiceLeft: 1))

        h.engine.startSelfService(at: h.now)
        #expect(h.remaining == 1_800)
        #expect(h.engine.state.sessionsUsedToday == 1)   // a fresh day's first, not a second
    }
}
