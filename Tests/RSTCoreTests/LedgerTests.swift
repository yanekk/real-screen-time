import Foundation
import Testing
@testable import RSTCore

/// The ledger decides whether a child's evening is billed correctly, and it does it from
/// four booleans and a timestamp. Every one of those cases is cheap to test and impossible
/// to check by hand, which is the whole argument for `RSTCore` existing.
///
/// Dates are built in a **fixed** `Europe/Warsaw` calendar, as `DayWindowTests` does: the
/// day boundary is the thing under test here, and a suite that used the machine's own zone
/// would pass or fail depending on where the Mac was.
@Suite("SessionState")
struct SessionStateTests {

    private let warsaw = ledgerCalendar(in: "Europe/Warsaw")
    private let config = Config()   // 30 min, 1 a day, 06:00, 10 min idle, 30 min media

    // MARK: - isActive: the four reasons not to charge

    @Test("recent input counts, wherever it comes from")
    func recentInputCounts() {
        #expect(SessionState.isActive(sensors(idleSeconds: 0), config))
        #expect(SessionState.isActive(sensors(idleSeconds: 300), config))
    }

    @Test("the idle grace is inclusive: 599 charges, 600 charges, 601 does not")
    func idleGraceBoundary() {
        #expect(SessionState.isActive(sensors(idleSeconds: 599), config))
        #expect(SessionState.isActive(sensors(idleSeconds: 600), config))
        #expect(!SessionState.isActive(sensors(idleSeconds: 601), config))
    }

    @Test("idle past the grace with nothing playing is a paused game in an empty room")
    func idlePastGraceWithoutMedia() {
        #expect(!SessionState.isActive(sensors(idleSeconds: 900, mediaPlaying: false), config))
    }

    @Test("a locked screen charges nothing, whatever else is true")
    func lockedChargesNothing() {
        #expect(!SessionState.isActive(sensors(idleSeconds: 0, screenLocked: true), config))
        #expect(!SessionState.isActive(
            sensors(idleSeconds: 0, screenLocked: true, mediaPlaying: true),
            config))
    }

    /// Fast user switching is not a logout. The Mac is shared, and charging him while the
    /// parent works would be theft — so this one has no grace at all, not even one tick.
    @Test("off-console charges nothing, with no grace at all")
    func offConsoleChargesNothing() {
        #expect(!SessionState.isActive(sensors(idleSeconds: 0, sessionOnConsole: false), config))
        #expect(!SessionState.isActive(
            sensors(idleSeconds: 1, sessionOnConsole: false, mediaPlaying: true),
            config))
    }

    // MARK: - isActive: the media clause

    @Test("something playing, 15 minutes idle: still watching")
    func mediaWithinCapCharges() {
        #expect(SessionState.isActive(sensors(idleSeconds: 900, mediaPlaying: true), config))
    }

    /// The cap is inclusive at the boundary and hard one second past it. A game and a film
    /// hold the identical display assertion, so this single number is the whole of the
    /// app's answer to "watching, or gone to bed with it running" (T19 dropped 2026-08-27).
    @Test("something playing, half an hour idle: a game left running")
    func mediaBeyondCapDoesNotCharge() {
        #expect(SessionState.isActive(sensors(idleSeconds: 1800, mediaPlaying: true), config))
        #expect(!SessionState.isActive(sensors(idleSeconds: 1801, mediaPlaying: true), config))
        // And it keeps not charging however long it runs — no second wind at any duration.
        #expect(!SessionState.isActive(sensors(idleSeconds: 36_000, mediaPlaying: true), config))
    }

    /// Recent input settles the tick on its own, before the media clause gets a say — he is
    /// demonstrably at the keyboard, and nothing downstream may take that away from him.
    @Test("recent input charges whether or not anything is playing")
    func recentInputChargesRegardlessOfMedia() {
        for media in [true, false] {
            #expect(SessionState.isActive(sensors(idleSeconds: 5, mediaPlaying: media), config))
            #expect(SessionState.isActive(sensors(idleSeconds: 600, mediaPlaying: media), config))
        }
    }

    @Test("locked and off-console beat the media clause outright")
    func lockAndConsoleBeatMedia() {
        #expect(!SessionState.isActive(
            sensors(idleSeconds: 60, screenLocked: true, mediaPlaying: true), config))
        #expect(!SessionState.isActive(
            sensors(idleSeconds: 60, sessionOnConsole: false, mediaPlaying: true), config))
    }

    /// Every combination of the inputs, because this predicate is four booleans and a
    /// number wide and it decides whether an evening is billed correctly.
    ///
    /// The oracle is DESIGN §2.2's predicate copied as one expression, where the
    /// implementation is a sequence of guards. That is the point of writing it twice: the
    /// two forms are only equal if the guard *order* is right, and the order is where a
    /// predicate like this goes wrong.
    @Test("the truth table, in full")
    func exhaustiveTruthTable() {
        let idleBands: [TimeInterval] = [0, 599, 600, 601, 1799, 1800, 1801, 7200]
        var checked = 0
        for onConsole in [true, false] {
            for locked in [true, false] {
                for media in [true, false] {
                    for idle in idleBands {
                        let snapshot = sensors(idleSeconds: idle, screenLocked: locked,
                                                sessionOnConsole: onConsole,
                                                mediaPlaying: media)
                        let expected = onConsole && !locked && (
                            idle <= Double(config.idleGraceSeconds)
                            || (media && idle <= Double(config.mediaGraceSeconds))
                        )
                        #expect(SessionState.isActive(snapshot, config) == expected,
                                "console=\(onConsole) locked=\(locked) media=\(media) idle=\(idle)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 2 * 2 * 2 * idleBands.count)
    }

    @Test("a hand-edited negative grace cannot make the predicate nonsense")
    func negativeGracesClampAtZero() {
        var broken = Config()
        broken.idleGraceSeconds = -600
        broken.mediaGraceSeconds = -1800
        // Zero grace still charges the tick where input just happened, and nothing after.
        #expect(SessionState.isActive(sensors(idleSeconds: 0), broken))
        #expect(!SessionState.isActive(sensors(idleSeconds: 1), broken))
        #expect(!SessionState.isActive(sensors(idleSeconds: 1, mediaPlaying: true), broken))
    }

    // MARK: - Advancing

    @Test("a live session is charged the elapsed interval while it is being used")
    func advanceChargesWhileActive() {
        let start = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: start)

        state.advance(to: start + 60, snapshot: sensors(idleSeconds: 3),
                      config: config, calendar: warsaw)

        #expect(state.remainingSeconds == 1800 - 60)
        #expect(state.lastHeartbeat == start + 60)
        #expect(state.exitKind == .unknown)
    }

    @Test("an idle, locked or off-console tick moves the heartbeat and charges nothing")
    func advanceDoesNotChargeWhileInactive() {
        let start = warsaw.at(2026, 8, 22, 18, 0, 0)
        let inactive = [
            sensors(idleSeconds: 1200),                                   // walked away
            sensors(idleSeconds: 0, screenLocked: true),                  // locked
            sensors(idleSeconds: 0, sessionOnConsole: false),             // parent switched in
            sensors(idleSeconds: 2000, mediaPlaying: true),  // past the cap
        ]
        for snapshot in inactive {
            var state = running(at: start)
            state.advance(to: start + 60, snapshot: snapshot, config: config, calendar: warsaw)
            #expect(state.remainingSeconds == 1800)
            #expect(state.lastHeartbeat == start + 60)
        }
    }

    /// The cover saying `Wznów` is on screen; charging him for looking at it would be the
    /// worst kind of quiet bug — the counter falls while he cannot use the machine.
    @Test("a session that is not live is not charged, however active the snapshot looks")
    func advanceDoesNotChargeWhileAwaitingResume() {
        let start = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = SessionState(dayKey: "2026-08-22", remainingSeconds: 900,
                                 wasRunning: true, lastHeartbeat: start, isLive: false)

        state.advance(to: start + 300, snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)

        #expect(state.remainingSeconds == 900)

        // …and it is charged the moment he presses the button.
        state.resume()
        state.advance(to: start + 360, snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)
        #expect(state.remainingSeconds == 840)
    }

    @Test("a clock stepped backwards charges nothing and does not sit out the difference")
    func advanceWithBackwardsClock() {
        let start = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: start)

        state.advance(to: start - 3600, snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)
        #expect(state.remainingSeconds == 1800)
        // The cursor followed the clock back, so the next tick charges one second rather
        // than granting a free hour while the clock catches up.
        #expect(state.lastHeartbeat == start - 3600)

        state.advance(to: start - 3599, snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)
        #expect(state.remainingSeconds == 1799)
    }

    @Test("charging floors at zero, never negative")
    func chargingFloorsAtZero() {
        let start = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: start)

        state.advance(to: start + 10_000, snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(state.wasRunning)   // it ran out; it was not never started
    }

    // MARK: - The day rollover

    /// T21, and the reversal of what this test used to assert: the remainder used to survive
    /// the boundary on the grounds that a session granted at 05:50 was legitimately granted.
    /// True, and it made the overnight case absurd — see `rolloverDiscardsAnUnfinishedNight`.
    @Test("06:00 refills the allowance and discards whatever was left on the session")
    func rolloverResetsCountAndDiscardsRemainder() {
        var state = SessionState(dayKey: "2026-08-21", remainingSeconds: 600,
                                 selfServiceStarts: ["2026-08-21": 2], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 5, 59, 50), isLive: true)

        let discarded = state.advance(to: warsaw.at(2026, 8, 22, 6, 0, 10),
                                      snapshot: sensors(idleSeconds: 1200),   // idle: the charge is not the subject
                                      config: config, calendar: warsaw)

        #expect(state.dayKey == "2026-08-22")
        #expect(state.sessionsUsedToday == 0)
        #expect(state.selfServiceLeft(config) == 1)
        #expect(state.remainingSeconds == 0)
        #expect(discarded == 600)          // reported, so `Engine` can tell it from a charge
        #expect(!state.wasRunning)         // → `Rozpocznij sesję`, not `Wznów`
        #expect(!state.isLive)
        #expect(state.selfServiceStarts["2026-08-21"] == 2)
    }

    /// The morning the whole task exists for. He stops mid-session at bedtime and the Mac is
    /// left alone; the boundary passes with 15 minutes still on the clock.
    @Test("a night left unfinished starts the morning at a fresh session, not a resume")
    func rolloverDiscardsAnUnfinishedNight() {
        var state = SessionState(dayKey: "2026-08-29", remainingSeconds: 900,
                                 selfServiceStarts: ["2026-08-29": 1], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 5, 59, 50), isLive: true)

        // Off console overnight, so nothing is charged and only the boundary moves.
        let discarded = state.advance(to: warsaw.at(2026, 8, 30, 8, 0),
                                      snapshot: sensors(sessionOnConsole: false),
                                      config: config, calendar: warsaw)

        #expect(discarded == 900)
        #expect(state.remainingSeconds == 0)
        #expect(state.selfServiceLeft(config) == 1)
        let decision = decide(sensors().applying(state, configuredWithPIN), configuredWithPIN)
        #expect(decision == .awaitingStart(selfServiceLeft: 1))
        #expect(decision.offersSelfServiceStart)
    }

    /// **PIN-granted minutes go on the same line** (the user's decision, 2026-09-04): one pot,
    /// no distinction. Keeping a grant alive across the night would mean tracking two kinds of
    /// minute through every path that spends one, and the parent can simply grant again.
    @Test("PIN-granted minutes are discarded at 06:00 alongside his own")
    func rolloverDiscardsGrantedMinutesToo() {
        var state = SessionState(dayKey: "2026-08-29", selfServiceStarts: ["2026-08-29": 1],
                                 wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 5, 59, 50))
        state.extend(minutes: 60)          // an hour behind the PIN, late on
        #expect(state.remainingSeconds == 3600)

        let discarded = state.advance(to: warsaw.at(2026, 8, 30, 6, 0, 10),
                                      snapshot: sensors(sessionOnConsole: false),
                                      config: config, calendar: warsaw)

        #expect(discarded == 3600)
        #expect(state.remainingSeconds == 0)
        #expect(!state.wasRunning)
    }

    /// The one household the trade costs anything, and it is honest: with no self-service
    /// allowance there is nothing to refill, so the morning says `Na dziś koniec sesji` and
    /// every minute comes from the parent — which is what `0` asks for.
    @Test("with no self-service allowance, 06:00 discards and offers nothing")
    func rolloverWithNoSelfServiceLeavesTheDayClosed() {
        var noSelfService = configuredWithPIN
        noSelfService.selfServiceSessionsPerDay = 0
        var state = SessionState(dayKey: "2026-08-29", remainingSeconds: 900, wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 5, 59, 50), isLive: true)

        state.advance(to: warsaw.at(2026, 8, 30, 6, 0, 10), snapshot: sensors(idleSeconds: 1200),
                      config: noSelfService, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(state.selfServiceLeft(noSelfService) == 0)
        let decision = decide(sensors().applying(state, noSelfService), noSelfService)
        #expect(decision == .awaitingStart(selfServiceLeft: 0))
        #expect(!decision.offersSelfServiceStart)
        // Which is `Na dziś koniec sesji` on the cover, with the PIN as the only way on.
        let cover = CoverModel(decision: decision, sessionsUsedToday: 0, config: noSelfService)
        #expect(cover?.face == .exhausted)
    }

    // MARK: - T20: a spent session stops blocking a day that still has one

    /// The 2026-08-30 defect was found on a session that crossed 06:00 and was finished in
    /// the morning: nothing cleared `wasRunning` once the carried remainder ran out, so he saw
    /// `Czas minął` with an untouched session in the ledger until the *next* day.
    ///
    /// **T21 closed that door from the other side** — nothing crosses 06:00 any more, so the
    /// scenario as written cannot happen. Rewritten rather than deleted, because what it now
    /// pins is the same morning arriving at the same answer by the other route: the discard.
    /// The T20 rule itself is still live through its two same-day doors, which
    /// `secondDailySessionIsReachable` and `spentByAGapStillOffersTheDaysSession` guard.
    @Test("the morning after a straddling session offers the new day's, by discard now")
    func spentAfterRolloverStillOffersTheNewDay() {
        // 15 minutes left, started yesterday, still on the clock at 05:59:50.
        var state = SessionState(dayKey: "2026-08-29", remainingSeconds: 900,
                                 selfServiceStarts: ["2026-08-29": 1], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 5, 59, 50), isLive: true)

        // Off console overnight, so nothing is charged and only the boundary moves.
        state.advance(to: warsaw.at(2026, 8, 30, 8, 0),
                      snapshot: sensors(sessionOnConsole: false), config: config, calendar: warsaw)
        #expect(state.dayKey == "2026-08-30")
        #expect(state.remainingSeconds == 0)   // taken at 06:00, not waiting to be finished
        #expect(!state.wasRunning)

        // A second tick changes nothing: there is no remainder left to retire, and the day
        // key has already moved, so the offer is stable rather than a one-tick artefact.
        state.advance(to: warsaw.at(2026, 8, 30, 8, 16),
                      snapshot: sensors(idleSeconds: 0), config: config, calendar: warsaw)

        #expect(!state.wasRunning)
        #expect(state.selfServiceLeft(config) == 1)
        let decision = decide(sensors().applying(state, configuredWithPIN), configuredWithPIN)
        #expect(decision == .awaitingStart(selfServiceLeft: 1))
        #expect(decision.offersSelfServiceStart)
    }

    @Test("the second of two daily sessions becomes reachable when the first runs out")
    func secondDailySessionIsReachable() {
        var twoADay = Config()
        twoADay.selfServiceSessionsPerDay = 2
        twoADay.pinHash = "x"
        twoADay.pinSalt = Data("saltsalt".utf8).base64EncodedString()

        var state = SessionState(dayKey: "2026-08-30", remainingSeconds: 10,
                                 selfServiceStarts: ["2026-08-30": 1], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 10, 0), isLive: true)

        state.advance(to: warsaw.at(2026, 8, 30, 10, 0, 30),
                      snapshot: sensors(idleSeconds: 0), config: twoADay, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(!state.wasRunning)
        #expect(decide(sensors().applying(state, twoADay), twoADay)
                == .awaitingStart(selfServiceLeft: 1))
    }

    /// The shipped default must be untouched: one session a day, spent, is still `Czas minął`.
    @Test("the day's only session running out is still expired, not a fresh offer")
    func lastSessionOfTheDayStillExpires() {
        var state = SessionState(dayKey: "2026-08-30", remainingSeconds: 10,
                                 selfServiceStarts: ["2026-08-30": 1], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 10, 0), isLive: true)

        state.advance(to: warsaw.at(2026, 8, 30, 10, 0, 30),
                      snapshot: sensors(idleSeconds: 0), config: config, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(state.wasRunning)
        #expect(state.selfServiceLeft(config) == 0)
        #expect(decide(sensors().applying(state, configuredWithPIN), configuredWithPIN)
                == .expired(selfServiceLeft: 0))
    }

    /// `disable(until:)` zeroes the remainder and deliberately leaves `wasRunning` set, so a
    /// stand-down lifted early returns the expired cover rather than re-offering a session
    /// already started. T20 keys off the charge-to-zero *transition* precisely so that this
    /// path is not caught by it.
    @Test("a stand-down still leaves the expired cover, even with a session left in the day")
    func standDownIsNotMistakenForASpentSession() {
        var twoADay = Config()
        twoADay.selfServiceSessionsPerDay = 2
        twoADay.pinHash = "x"
        twoADay.pinSalt = Data("saltsalt".utf8).base64EncodedString()

        var state = SessionState(dayKey: "2026-08-30", remainingSeconds: 900,
                                 selfServiceStarts: ["2026-08-30": 1], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 10, 0), isLive: true)

        state.disable(until: warsaw.at(2026, 8, 31, 6, 0))
        #expect(state.remainingSeconds == 0)
        #expect(state.wasRunning)

        // A tick after the stand-down must not retire the session behind it.
        state.advance(to: warsaw.at(2026, 8, 30, 10, 0, 30),
                      snapshot: sensors(idleSeconds: 0), config: twoADay, calendar: warsaw)
        #expect(state.wasRunning)

        // Lifted early, it is still the honest reading: he started that session.
        state.disable(until: nil)
        #expect(decide(sensors().applying(state, twoADay), twoADay)
                == .expired(selfServiceLeft: 1))
    }

    /// The fourth door, found reviewing T20: a **gap** spends a session down to zero too,
    /// and `reconcile` charges without going anywhere near `advance`. Reachable on the
    /// shipped default — a PIN grant taken before he has used his own session, then a crash
    /// or a forced power-off that eats the grant. Same day, so the rollover's own clear
    /// never runs, and his untouched session was unofferable until the next 06:00.
    @Test("a gap that spends the session still leaves the day's own session offerable")
    func spentByAGapStillOffersTheDaysSession() {
        // A PIN grant of 30 minutes, and not one of his own sessions used today.
        var state = SessionState(dayKey: "2026-08-30", remainingSeconds: 1800,
                                 selfServiceStarts: [:], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 30, 19, 10), isLive: true)

        // Power cut at 19:10, back up at 19:12, the app running again at 19:45: 33 minutes
        // charged against a 30-minute grant, which floors it.
        state.reconcile(at: warsaw.at(2026, 8, 30, 19, 45),
                        bootTime: warsaw.at(2026, 8, 30, 19, 12),
                        config: configuredWithPIN, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(state.dayKey == "2026-08-30")      // same day: no rollover to rescue it
        #expect(!state.wasRunning)
        #expect(state.selfServiceLeft(configuredWithPIN) == 1)
        #expect(decide(sensors().applying(state, configuredWithPIN), configuredWithPIN)
                == .awaitingStart(selfServiceLeft: 1))
    }
    @Test("a spent session becomes a fresh offer in the morning, not yesterday's Czas minął")
    func rolloverClearsWasRunningOnceSpent() {
        var state = SessionState(dayKey: "2026-08-21", remainingSeconds: 0,
                                 selfServiceStarts: ["2026-08-21": 2], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 5, 59, 50))

        state.advance(to: warsaw.at(2026, 8, 22, 6, 0, 10), snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)

        #expect(!state.wasRunning)
        #expect(state.sessionsUsedToday == 0)
    }

    /// The companion to the test above, and the reason it is a separate one: `wasRunning`
    /// is not the only flag that says "a session is running". `isLive` is the other half of
    /// T05's four-quadrant reading, and a session that expired last night and was never
    /// logged out is still `isLive` at 06:00 — the app ticked straight through the
    /// rollover. Left set, `remainingSeconds == 0 && isLive` reads as *expired* — yesterday's
    /// `Czas minął` — on a morning whose whole point is that the allowance came back.
    @Test("a spent session is not still live in the morning")
    func rolloverClearsLivenessOnceSpent() {
        var state = SessionState(dayKey: "2026-08-21", remainingSeconds: 0,
                                 selfServiceStarts: ["2026-08-21": 2], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 5, 59, 50),
                                 isLive: true)   // expired last night, never logged out

        state.advance(to: warsaw.at(2026, 8, 22, 6, 0, 10), snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)

        #expect(!state.wasRunning)
        #expect(!state.isLive)       // → awaiting start, not expired
        #expect(state.selfServiceLeft(config) == 1)
    }

    /// The case that used to be the mirror image, and is now the same case: someone actively
    /// playing at 06:00 is interrupted there. **The boundary discards asleep or awake,
    /// playing or paused** — the rejected alternative made the loss conditional on an
    /// interruption, which left the reported scenario surviving the fix on any Mac left awake
    /// all night with a paused session.
    @Test("a session still running at 06:00 is ended there, not charged across")
    func rolloverEndsASessionStillRunning() {
        var state = SessionState(dayKey: "2026-08-21", remainingSeconds: 600,
                                 selfServiceStarts: ["2026-08-21": 2], wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 5, 59, 50),
                                 isLive: true)

        // Typing through the boundary: the twenty seconds either side used to be charged.
        let discarded = state.advance(to: warsaw.at(2026, 8, 22, 6, 0, 10),
                                      snapshot: sensors(idleSeconds: 3),
                                      config: config, calendar: warsaw)

        #expect(discarded == 600)
        #expect(state.remainingSeconds == 0)
        #expect(!state.wasRunning)
        #expect(!state.isLive)
        // And the new day's own session is there to be started immediately.
        #expect(state.selfServiceLeft(config) == 1)
    }

    /// T03's review found the day key is **not monotonic**: a backwards NTP correction, a
    /// hand-set clock or a time-zone change steps it back to yesterday. A counter reset on
    /// every change would hand out two fresh sessions each time that happened. Keyed by the
    /// day string, stepping back finds yesterday's count still sitting there.
    @Test("a backwards day key finds yesterday's count, not a fresh allowance")
    func backwardsDayKeyIsSelfHealing() {
        var state = SessionState(dayKey: "2026-08-22", remainingSeconds: 0,
                                 selfServiceStarts: ["2026-08-21": 2, "2026-08-22": 1],
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 10, 0, 0))

        // The clock steps back into yesterday.
        state.advance(to: warsaw.at(2026, 8, 22, 5, 0, 0), snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)
        #expect(state.dayKey == "2026-08-21")
        #expect(state.sessionsUsedToday == 2)
        #expect(state.selfServiceLeft(config) == 0)

        // And forward again, to find today's count where it was left.
        state.advance(to: warsaw.at(2026, 8, 22, 10, 0, 1), snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)
        #expect(state.dayKey == "2026-08-22")
        #expect(state.sessionsUsedToday == 1)
    }

    @Test("the history stays bounded, and never at the cost of today's count")
    func historyIsPruned() {
        var starts: [String: Int] = [:]
        for day in 1...28 { starts[String(format: "2026-07-%02d", day)] = 1 }
        starts["2030-01-01"] = 9   // a clock that went somewhere strange
        var state = SessionState(dayKey: "2026-07-28", selfServiceStarts: starts,
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 10, 0, 0))

        state.advance(to: warsaw.at(2026, 8, 22, 10, 0, 1), snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)

        #expect(state.selfServiceStarts.count <= SessionState.historyLimit + 1)
        #expect(state.selfServiceStarts["2026-08-22"] == nil)   // nothing used today yet
        #expect(state.dayKey == "2026-08-22")

        // Today survives pruning even when a future key sorts above it.
        state.startSelfService(config)
        state.advance(to: warsaw.at(2026, 8, 22, 10, 0, 2), snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)
        #expect(state.sessionsUsedToday == 1)
    }

    /// `pruneHistory` keeps the most recent ``historyLimit`` keys *and* today's, and the
    /// second half of that is not redundant: a clock that spent a fortnight in 2030 leaves
    /// fourteen keys all sorting above today's, so the plain top-14 would drop the day we
    /// are actually counting against — and dropping it means a fresh allowance out of thin
    /// air, which is the one failure this whole map exists to prevent.
    @Test("today's count survives a pruning where every other key sorts above it")
    func todaySurvivesPruningUnderFutureKeys() {
        var starts: [String: Int] = [:]
        for day in 1...SessionState.historyLimit { starts[String(format: "2030-01-%02d", day)] = 1 }
        starts["2026-08-22"] = 2     // today, already spent
        var state = SessionState(dayKey: "2026-08-21", selfServiceStarts: starts,
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 5, 0, 0))

        // Rolling into today prunes, with fourteen future keys outranking it.
        state.advance(to: warsaw.at(2026, 8, 22, 7, 0, 0), snapshot: sensors(idleSeconds: 0),
                      config: config, calendar: warsaw)

        #expect(state.dayKey == "2026-08-22")
        #expect(state.sessionsUsedToday == 2)             // not resurrected as unspent
        #expect(state.selfServiceLeft(config) == 0)
    }

    // MARK: - Starting, granting, extending

    /// The count gates self-service and nothing else. Run against a two-a-day config as well
    /// as the shipped one-a-day, so what is being tested is the *counting*, not the number.
    @Test("a self-service start costs one of the day's allowance; granted minutes cost none")
    func startVersusGrant() {
        var twoADay = config
        twoADay.selfServiceSessionsPerDay = 2
        var state = SessionState(dayKey: "2026-08-22",
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 18, 0, 0))

        state.startSelfService(twoADay)
        #expect(state.remainingSeconds == 1800)
        #expect(state.sessionsUsedToday == 1)
        #expect(state.selfServiceLeft(twoADay) == 1)
        #expect(state.selfServiceLeft(config) == 0)      // …and none at all on the default
        #expect(state.wasRunning)
        #expect(state.isLive)

        state.startSelfService(twoADay)
        #expect(state.sessionsUsedToday == 2)
        #expect(state.selfServiceLeft(twoADay) == 0)

        // Behind the PIN. The count gates what he can do unaided, and this was not unaided —
        // however many minutes it is. `grantSession` was retired 2026-08-22: a whole further
        // session is 30 typed into the same box (DESIGN §2.5).
        // Adds, where the retired `grantSession` replaced: the second start had already put a
        // full session on the clock, so half an hour granted on top makes an hour.
        state.extend(minutes: twoADay.sessionMinutes)
        #expect(state.remainingSeconds == 3600)
        #expect(state.sessionsUsedToday == 2)
        #expect(state.selfServiceLeft(twoADay) == 0)
    }

    @Test("granted minutes add to whatever is left, including nothing")
    func extendAddsToTheRemainder() {
        var state = SessionState(dayKey: "2026-08-22", remainingSeconds: 300, wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 18, 0, 0), isLive: true)
        state.extend(minutes: 15)
        #expect(state.remainingSeconds == 300 + 900)

        // The amount is the caller's, not the config's: any number, as often as they like.
        state.extend(minutes: 90)
        #expect(state.remainingSeconds == 300 + 900 + 5400)

        // From the expired cover: remaining is zero and the grant brings it back.
        var expired = SessionState(dayKey: "2026-08-22", remainingSeconds: 0, wasRunning: true,
                                   lastHeartbeat: warsaw.at(2026, 8, 22, 18, 0, 0))
        expired.extend(minutes: 15)
        #expect(expired.remainingSeconds == 900)
        #expect(expired.isLive)
    }

    @Test("a hand-edited negative session length cannot produce a negative countdown")
    func negativeSessionLengthClamps() {
        var broken = Config()
        broken.sessionMinutes = -30
        var state = SessionState(dayKey: "2026-08-22")
        state.startSelfService(broken)
        #expect(state.remainingSeconds == 0)
        // Same clamp on the grant, which now comes from a caller rather than from the file —
        // a dialog is not the only thing that can hand this a number.
        state.extend(minutes: -15)
        #expect(state.remainingSeconds == 0)
    }

    // MARK: - Standing down

    /// §2.5's stand-down ends the session rather than suspending it, and the reason is that
    /// `decide` cannot enforce its own `.dormant`: it is pure, and `advance` runs before it
    /// on every tick reading only the sensors. A session left live would be charged behind
    /// a free screen for the whole evening.
    @Test("standing down ends the running session instead of draining it")
    func standingDownEndsTheSession() {
        let config = Config()
        let evening = warsaw.at(2026, 8, 22, 20, 0, 0)
        let morning = warsaw.at(2026, 8, 23, 6, 0, 0)

        var state = SessionState(dayKey: "2026-08-22", selfServiceStarts: ["2026-08-22": 1],
                                 lastHeartbeat: evening)
        state.startSelfService(config)
        #expect(state.remainingSeconds == 1800 && state.isLive)

        state.disable(until: morning)
        #expect(state.remainingSeconds == 0)
        #expect(!state.isLive)
        #expect(state.wasRunning)          // he did start one — the expired cover is honest

        // The whole evening at the machine, actively: nothing left to drain, and the tick
        // that would have drained it is the one this test exists to prove harmless.
        var cursor = evening
        for _ in 0..<60 {
            cursor += 60
            state.advance(to: cursor, snapshot: sensors(idleSeconds: 0), config: config,
                          calendar: warsaw)
        }
        #expect(state.remainingSeconds == 0)

        // Morning: the day key turns over and the allowance comes back whole — two sessions
        // and no leftover, which is the point of ending it rather than banking it.
        state.advance(to: morning, snapshot: sensors(idleSeconds: 0), config: config,
                      calendar: warsaw)
        #expect(state.sessionsUsedToday == 0)
        #expect(state.selfServiceLeft(config) == 1)
        #expect(state.remainingSeconds == 0)
        #expect(!state.wasRunning)
    }

    /// **T21 must not have touched this.** `disable(until:)` zeroes the remainder and
    /// deliberately leaves `wasRunning` set, so a stand-down lifted before 06:00 returns the
    /// *expired* cover rather than re-offering a session he already started. The unconditional
    /// clear T21 put in the rollover is the only thing that undoes it, and it does so at the
    /// boundary, which is exactly where the allowance comes back to pay for it.
    @Test("a stand-down lifted the same evening still gives the expired cover")
    func standDownLiftedEarlyIsStillExpired() {
        let evening = warsaw.at(2026, 8, 22, 20, 0, 0)
        var state = SessionState(dayKey: "2026-08-22", lastHeartbeat: evening)
        state.startSelfService(configuredWithPIN)
        state.disable(until: warsaw.at(2026, 8, 23, 6, 0, 0))

        // The parent changes their mind an hour later, well short of the boundary.
        state.disable(until: nil)
        state.advance(to: evening + 3600, snapshot: sensors(idleSeconds: 0),
                      config: configuredWithPIN, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(state.wasRunning)          // he did start one, and it is gone
        #expect(decide(sensors().applying(state, configuredWithPIN), configuredWithPIN)
                == .expired(selfServiceLeft: 0))
    }

    /// Lifting a stand-down is the same call with `nil`, and it must not be able to end a
    /// session — only the standing-down direction ends anything.
    @Test("clearing a stand-down leaves the session alone")
    func clearingAStandDownIsNotDestructive() {
        let config = Config()
        var state = SessionState(dayKey: "2026-08-22",
                                 lastHeartbeat: warsaw.at(2026, 8, 22, 20, 0, 0))
        state.startSelfService(config)
        state.disable(until: nil)
        #expect(state.disabledUntil == nil)
        #expect(state.remainingSeconds == 1800)
        #expect(state.isLive)
    }

    // MARK: - Classify

    @Test("no gap when no time passed, or when the clock went backwards")
    func classifyNone() {
        let now = warsaw.at(2026, 8, 22, 18, 0, 0)
        #expect(SessionState.classify(lastHeartbeat: now, now: now,
                                      exitKind: .unknown, bootTime: now - 86_400) == .none)
        #expect(SessionState.classify(lastHeartbeat: now + 60, now: now,
                                      exitKind: .unknown, bootTime: now - 86_400) == .none)
    }

    @Test("a clean-exit marker excuses the whole gap")
    func classifyExpected() {
        let now = warsaw.at(2026, 8, 22, 18, 0, 0)
        let gap = SessionState.classify(lastHeartbeat: now - 3600, now: now,
                                        exitKind: .expected, bootTime: now - 86_400)
        #expect(gap == .expected(3600))
        #expect(gap.chargedSeconds == 0)
    }

    @Test("a clean exit is still clean when the machine rebooted inside the gap")
    func classifyExpectedBeatsReboot() {
        let now = warsaw.at(2026, 8, 22, 18, 0, 0)
        #expect(SessionState.classify(lastHeartbeat: now - 3600, now: now,
                                      exitKind: .expected, bootTime: now - 600)
                == .expected(3600))
    }

    @Test("a reboot inside the gap charges only the part the machine was up for")
    func classifyRebooted() {
        let now = warsaw.at(2026, 8, 22, 18, 0, 0)
        let gap = SessionState.classify(lastHeartbeat: now - 3600, now: now,
                                        exitKind: .unknown, bootTime: now - 600)
        #expect(gap == .rebooted(charge: 600))
        #expect(gap.chargedSeconds == 600)
    }

    @Test("a boot time in the future charges nothing rather than a negative")
    func classifyRebootedInTheFuture() {
        let now = warsaw.at(2026, 8, 22, 18, 0, 0)
        #expect(SessionState.classify(lastHeartbeat: now - 3600, now: now,
                                      exitKind: .unknown, bootTime: now + 60)
                == .rebooted(charge: 0))
    }

    /// The incentive is the entire point: killing the app costs exactly as much screen time
    /// as not killing it, so there is no reason to try.
    @Test("no marker and no reboot means it was killed, and the whole gap is charged")
    func classifyUnexplained() {
        let now = warsaw.at(2026, 8, 22, 18, 0, 0)
        let gap = SessionState.classify(lastHeartbeat: now - 288, now: now,
                                        exitKind: .unknown, bootTime: now - 86_400)
        #expect(gap == .unexplained(288))
        #expect(gap.chargedSeconds == 288)
    }

    // MARK: - Reconciling a gap

    @Test("a killed app is charged in full on the next launch")
    func reconcileAfterAKill() {
        let killed = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: killed)          // 30 minutes, live, heartbeat at the kill
        state.setRemainingSeconds(1200)

        // Relaunched ten minutes later. Nothing wrote a marker, because nothing could.
        let gap = state.reconcile(at: killed + 600, bootTime: killed - 86_400,
                                  config: config, calendar: warsaw).gap

        #expect(gap == .unexplained(600))
        #expect(state.remainingSeconds == 600)
        #expect(state.lastHeartbeat == killed + 600)
        #expect(state.exitKind == .unknown)
        // The child takes the screen back through `Wznów` rather than finding it counting.
        #expect(!state.isLive)
        #expect(state.wasRunning)
    }

    @Test("a logout mid-session preserves the remainder and consumes no session")
    func reconcileAfterALogout() {
        let out = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: out)
        state.setRemainingSeconds(1200)
        let usedBefore = state.sessionsUsedToday

        state.markExpectedExit(at: out)
        #expect(state.exitKind == .expected)

        // Back an hour later. The Mac is shared: if logging out cost him time he would stop
        // doing it, and the sharing would break.
        let gap = state.reconcile(at: out + 3600, bootTime: out - 86_400,
                                  config: config, calendar: warsaw).gap

        #expect(gap == .expected(3600))
        #expect(state.remainingSeconds == 1200)
        #expect(state.sessionsUsedToday == usedBefore)
        #expect(!state.isLive)          // offered `Wznów`, not resumed behind his back

        state.resume()
        #expect(state.isLive)
        #expect(state.sessionsUsedToday == usedBefore)
    }

    @Test("a gap spanning a reboot charges only the post-boot part")
    func reconcileAcrossAReboot() {
        let last = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: last)
        state.setRemainingSeconds(1200)

        // Off for half an hour, up for ten minutes before the app started.
        let gap = state.reconcile(at: last + 2400, bootTime: last + 1800,
                                  config: config, calendar: warsaw).gap

        #expect(gap == .rebooted(charge: 600))
        #expect(state.remainingSeconds == 600)
    }

    /// The case that silently produces a child with no screen time on a Tuesday morning.
    @Test("a gap spanning 06:00 does not charge yesterday's time to today's allowance")
    func reconcileAcrossTheDayBoundary() {
        let last = warsaw.at(2026, 8, 22, 5, 0, 0)      // still 2026-08-21
        var state = SessionState(dayKey: "2026-08-21", remainingSeconds: 1200,
                                 selfServiceStarts: ["2026-08-21": 2], wasRunning: true,
                                 lastHeartbeat: last, isLive: true)

        let gap = state.reconcile(at: warsaw.at(2026, 8, 22, 7, 0, 0),
                                  bootTime: last - 86_400, config: config, calendar: warsaw).gap

        #expect(gap == .unexplained(7200))
        #expect(state.dayKey == "2026-08-22")
        // Yesterday's two stay yesterday's; today opens with a full allowance.
        #expect(state.sessionsUsedToday == 0)
        #expect(state.selfServiceLeft(config) == 1)
        #expect(state.selfServiceStarts["2026-08-21"] == 2)
        // And the session it ate is gone, floored rather than negative.
        #expect(state.remainingSeconds == 0)
    }

    @Test("a gap longer than the remaining time floors at zero, never negative")
    func reconcileLongerThanTheSession() {
        let last = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: last)
        state.setRemainingSeconds(60)

        state.reconcile(at: last + 7200, bootTime: last - 86_400,
                        config: config, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(state.wasRunning)   // it expired this evening; it was not never started
    }

    @Test("a gap of a whole day floors the session and opens a fresh morning")
    func reconcileAcrossAWholeDay() {
        let last = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = running(at: last)
        state.setRemainingSeconds(60)

        state.reconcile(at: last + 86_400, bootTime: last - 86_400,
                        config: config, calendar: warsaw)

        #expect(state.remainingSeconds == 0)
        #expect(state.dayKey == "2026-08-23")
        #expect(state.sessionsUsedToday == 0)
        // A new day is a fresh offer — `Rozpocznij sesję`, not yesterday's `Czas minął`.
        #expect(!state.wasRunning)
    }

    // MARK: - wasRunning across a restart

    /// `Czas minął` and `Rozpocznij sesję` are different covers, and both are
    /// `remainingSeconds == 0`. Without this flag a child who let a session expire and then
    /// logged out would be offered a fresh start as though nothing had happened.
    @Test("wasRunning distinguishes expired from awaiting-start across a restart")
    func wasRunningSurvivesARestart() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            let expiry = warsaw.at(2026, 8, 22, 18, 30, 0)

            var expired = running(at: expiry)
            expired.setRemainingSeconds(0)
            try store.save(expired)

            let reloaded = store.load()
            #expect(reloaded.state.remainingSeconds == 0)
            #expect(reloaded.state.wasRunning)          // → .expired

            // A day he has not started anything on looks identical but for this flag.
            let fresh = SessionState(dayKey: "2026-08-22")
            try store.save(fresh)
            #expect(store.load().state.wasRunning == false)   // → .awaitingStart
        }
    }

    // MARK: - The remainder cannot be made absurd

    /// **The crash this ceiling exists for.** `Int(_:)` on a `Double` past `Int.max` traps,
    /// and `AppController.start` prints `Int(state.remainingSeconds.rounded())` on every
    /// launch. `session.json` is in the child's home directory, so before the clamp one
    /// hand-edited number killed the app at launch, every launch. Found reviewing T10.
    @Test("a hand-edited remaining_seconds cannot crash the launch line")
    func decodedRemainderIsClamped() throws {
        let json = #"{"day_key": "2026-08-23", "remaining_seconds": 1e30}"#
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        #expect(state.remainingSeconds == SessionState.secondsCeiling)
        // Verbatim the expression `AppController.start` and `AppController` on wake both
        // evaluate. It is the conversion that traps, so reaching the `#expect` is the test.
        #expect(Int(state.remainingSeconds.rounded()) == 1_000_000_000_000)
    }

    /// The other route in, and the one that needs no corrupt ledger at all: `config.json` is
    /// the child's too, and `fullSession` multiplies `session_minutes` by 60 unbounded. The
    /// app dies on the first tick after `Rozpocznij` rather than at launch.
    @Test("an absurd session_minutes cannot crash the first tick")
    func absurdSessionLengthIsClamped() {
        var absurd = config
        absurd.sessionMinutes = .max
        var state = SessionState(dayKey: "2026-08-23",
                                 lastHeartbeat: warsaw.at(2026, 8, 23, 18, 0, 0))
        state.startSelfService(absurd)
        #expect(state.remainingSeconds == SessionState.secondsCeiling)
        #expect(Int(state.remainingSeconds.rounded()) == 1_000_000_000_000)
        // Still an ordinary session in every other respect — the clamp bounds the number,
        // it does not refuse the start or spend a second self-service.
        #expect(state.isLive && state.wasRunning)
        #expect(state.sessionsUsedToday == 1)
    }

    /// **§2.5's unlimited grant is untouched and this is where that is checked.** A parent
    /// typing any number a parent could mean gets exactly it; only the absurd is bounded.
    @Test("a grant is clamped only where the arithmetic would break")
    func extendIsClampedOnlyAtTheCeiling() {
        var state = SessionState(dayKey: "2026-08-23", remainingSeconds: 300, wasRunning: true,
                                 lastHeartbeat: warsaw.at(2026, 8, 23, 18, 0, 0), isLive: true)
        // A fortnight of screen time, typed by hand. Absurd parenting, sound arithmetic —
        // and the app is not the thing that argues about it.
        state.extend(minutes: 20_160)
        #expect(state.remainingSeconds == 300 + 20_160 * 60)

        state.extend(minutes: .max)
        #expect(state.remainingSeconds == SessionState.secondsCeiling)
        // Repeated grants at the ceiling stay there rather than accumulating past it.
        state.extend(minutes: .max)
        #expect(state.remainingSeconds == SessionState.secondsCeiling)
    }

    @Test("the initialiser and the setter clamp on the same rule, NaN included")
    func everyWriteIsClamped() {
        #expect(SessionState(remainingSeconds: 1e30).remainingSeconds == SessionState.secondsCeiling)
        #expect(SessionState(remainingSeconds: .infinity).remainingSeconds == SessionState.secondsCeiling)
        #expect(SessionState(remainingSeconds: .nan).remainingSeconds == 0)
        #expect(SessionState(remainingSeconds: -1e30).remainingSeconds == 0)

        var state = SessionState(dayKey: "2026-08-23")
        state.setRemainingSeconds(.greatestFiniteMagnitude)
        #expect(state.remainingSeconds == SessionState.secondsCeiling)
        state.setRemainingSeconds(1800)
        #expect(state.remainingSeconds == 1800)      // and an ordinary value is untouched
    }

    /// A clamped remainder must survive the file it is written to, or the next launch reads
    /// back something the decoder has to clamp all over again.
    @Test("the ceiling round-trips through JSON")
    func ceilingRoundTrips() throws {
        let state = SessionState(dayKey: "2026-08-23", remainingSeconds: 1e30)
        let reloaded = try JSONDecoder().decode(SessionState.self,
                                                from: try JSONEncoder().encode(state))
        #expect(reloaded.remainingSeconds == SessionState.secondsCeiling)
    }

    // MARK: - Helpers

    /// A live session with the full 30 minutes, its heartbeat at `start`.
    private func running(at start: Date) -> SessionState {
        var state = SessionState(dayKey: DayWindow.dayKey(for: start, resetHour: config.dayResetHour,
                                                          calendar: warsaw),
                                 lastHeartbeat: start)
        state.startSelfService(config)
        return state
    }
}

/// `session.json` is written every fifteen seconds by a process the watchdog is entitled to
/// kill, and read at launch by an app that has to keep enforcing whatever it finds.
@Suite("SessionStore")
struct SessionStoreTests {

    private let warsaw = ledgerCalendar(in: "Europe/Warsaw")

    @Test("a saved ledger comes back identical, minus the liveness")
    func roundTrip() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            let now = warsaw.at(2026, 8, 22, 18, 30, 15)
            let state = SessionState(dayKey: "2026-08-22", remainingSeconds: 942.5,
                                     selfServiceStarts: ["2026-08-21": 2, "2026-08-22": 1],
                                     wasRunning: true, lastHeartbeat: now, exitKind: .expected,
                                     disabledUntil: now + 7200, isLive: true)

            try store.save(state)
            let loaded = store.load()

            #expect(loaded.outcome == .loaded)
            #expect(loaded.state.dayKey == state.dayKey)
            #expect(loaded.state.remainingSeconds == state.remainingSeconds)
            #expect(loaded.state.selfServiceStarts == state.selfServiceStarts)
            #expect(loaded.state.sessionsUsedToday == 1)
            #expect(loaded.state.wasRunning)
            #expect(loaded.state.lastHeartbeat == state.lastHeartbeat)
            #expect(loaded.state.exitKind == .expected)
            #expect(loaded.state.disabledUntil == state.disabledUntil)
            // Liveness belongs to a run, and a decoded state is from a previous one.
            #expect(!loaded.state.isLive)
        }
    }

    @Test("the file is text a parent can read")
    func fileIsReadable() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            let now = warsaw.at(2026, 8, 22, 18, 30, 0)
            try store.save(SessionState(dayKey: "2026-08-22", remainingSeconds: 600,
                                        lastHeartbeat: now))

            let text = try String(contentsOf: store.url, encoding: .utf8)
            #expect(text.contains("\"day_key\" : \"2026-08-22\""))
            #expect(text.contains("\"remaining_seconds\" : 600"))
            // ISO 8601, in UTC: `RSTCore` may not ask the system what zone it is in.
            #expect(text.contains("2026-08-22T16:30:00.000Z"))
        }
    }

    @Test("a missing file is a first run, not a failure, and writes nothing")
    func missingFile() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            let loaded = store.load()

            #expect(loaded.outcome == .missing)
            #expect(loaded.state.remainingSeconds == 0)
            #expect(!loaded.state.wasRunning)
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    /// §3.5: a `session.json` that fails to parse ends any running session and returns to
    /// `awaitingStart`. The file is moved aside so the parent can see what was there, and
    /// the caller logs it — a file that will not parse is indistinguishable from one
    /// somebody edited badly, and the period it covers is unexplained by definition.
    @Test("a corrupt ledger is quarantined, the session is lost, and the app keeps going")
    func corruptFile() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            try Data("{ this is not json".utf8).write(to: store.url)

            let loaded = store.load()

            #expect(loaded.outcome == .reset(backup: store.backupURL))
            #expect(loaded.state.remainingSeconds == 0)
            #expect(!loaded.state.wasRunning)
            #expect(!loaded.state.isLive)
            #expect(loaded.state.exitKind == .unknown)   // nothing said it was a clean exit
            #expect(FileManager.default.fileExists(atPath: store.backupURL.path))

            // The task doc asks that a corrupt ledger be "treated as `.unexplained` for the
            // whole period". It is not, and cannot be: the reset state's heartbeat is
            // `.distantPast`, so every real boot time is after it and `classify` reads a
            // reboot. The doc's intent is met by a stronger route — the session is gone
            // outright, which costs more than any charge against it could — but the *tamper
            // signal* therefore travels on `.reset`, not on `Gap`. **T06 must log from the
            // load outcome**; waiting for an `.unexplained` here would log nothing.
            let gap = SessionState.classify(lastHeartbeat: loaded.state.lastHeartbeat,
                                            now: warsaw.at(2026, 8, 22, 18, 0, 0),
                                            exitKind: loaded.state.exitKind,
                                            bootTime: warsaw.at(2026, 8, 22, 8, 0, 0))
            #expect(gap == .rebooted(charge: 36_000))
            #expect(loaded.state.remainingSeconds == 0)   // nothing left for it to charge
        }
    }

    @Test("a file from an older build is defaults, not corruption")
    func partialFile() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            try Data(#"{"day_key":"2026-08-22","remaining_seconds":300}"#.utf8)
                .write(to: store.url)

            let loaded = store.load()

            #expect(loaded.outcome == .loaded)
            #expect(loaded.state.dayKey == "2026-08-22")
            #expect(loaded.state.remainingSeconds == 300)
            #expect(loaded.state.sessionsUsedToday == 0)
            #expect(loaded.state.exitKind == .unknown)
            #expect(loaded.state.disabledUntil == nil)
        }
    }

    @Test("a hand-typed timestamp without fractional seconds is a time somebody meant")
    func lenientTimestamps() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            try Data(#"{"day_key":"2026-08-22","last_heartbeat":"2026-08-22T06:00:00Z"}"#.utf8)
                .write(to: store.url)

            let loaded = store.load()

            #expect(loaded.outcome == .loaded)
            #expect(loaded.state.lastHeartbeat
                    == ledgerCalendar(in: "UTC").at(2026, 8, 22, 6, 0, 0))
        }
    }

    @Test("a timestamp that is not a time is corruption, and quarantined as such")
    func nonsenseTimestamp() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            try Data(#"{"day_key":"2026-08-22","last_heartbeat":"tuesday"}"#.utf8)
                .write(to: store.url)

            #expect(store.load().outcome == .reset(backup: store.backupURL))
        }
    }

    /// The whole launch sequence in one test: load, reconcile the gap, resume, tick.
    /// The order matters — `reconcile` is what establishes the day key, and nothing may
    /// grant or start a session before it has.
    @Test("load, reconcile, resume, tick")
    func launchSequence() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            let config = Config()
            let killed = warsaw.at(2026, 8, 22, 20, 0, 0)

            var before = SessionState(dayKey: "2026-08-22", remainingSeconds: 900,
                                      selfServiceStarts: ["2026-08-22": 1], wasRunning: true,
                                      lastHeartbeat: killed, isLive: true)
            try store.save(before)
            before.advance(to: killed + 1, snapshot: sensors(), config: config, calendar: warsaw)

            var after = store.load().state
            let gap = after.reconcile(at: killed + 300, bootTime: killed - 86_400,
                                      config: config, calendar: warsaw).gap
            #expect(gap == .unexplained(300))
            #expect(after.remainingSeconds == 600)
            #expect(after.sessionsUsedToday == 1)

            after.resume()
            after.advance(to: killed + 360, snapshot: sensors(idleSeconds: 2),
                          config: config, calendar: warsaw)
            #expect(after.remainingSeconds == 540)

            try store.save(after)
            #expect(store.load().state.remainingSeconds == 540)
        }
    }
}

/// The applied remote-grant set (DESIGN §2.6, §2.7): its prune, the rollover clear, and its
/// round-trip through `session.json`. The `record`-then-`decide` interaction lives in
/// `RemoteGrantTests` beside the decision it feeds.
@Suite("SessionState remote grants")
struct SessionStateRemoteGrantTests {

    private let warsaw = ledgerCalendar(in: "Europe/Warsaw")

    @Test("pruneRemoteGrants drops entries older than the TTL and keeps the rest")
    func prunesByTTL() {
        let now = warsaw.at(2026, 8, 22, 14, 0, 0)
        let ttl: TimeInterval = 900
        var state = SessionState()
        state.recordRemoteGrant(id: "old", at: now.addingTimeInterval(-(ttl + 1)))   // just past
        state.recordRemoteGrant(id: "edge", at: now.addingTimeInterval(-ttl))         // exactly TTL
        state.recordRemoteGrant(id: "fresh", at: now.addingTimeInterval(-60))

        state.pruneRemoteGrants(olderThan: ttl, now: now)

        // The edge is kept — an entry exactly `ttl` old is still within it.
        #expect(Set(state.appliedRemoteGrants.keys) == ["edge", "fresh"])
    }

    @Test("06:00 rollover clears the applied remote-grant set")
    func rolloverClearsAppliedRemoteGrants() {
        let config = Config()
        let evening = warsaw.at(2026, 8, 22, 22, 0, 0)
        var state = SessionState(dayKey: "2026-08-22", lastHeartbeat: evening,
                                 appliedRemoteGrants: ["g1": evening, "g2": evening])
        #expect(!state.appliedRemoteGrants.isEmpty)

        // Next morning, past 06:00: the day key changes and every day-bound field resets.
        state.advance(to: warsaw.at(2026, 8, 23, 7, 0, 0), snapshot: sensors(),
                      config: config, calendar: warsaw)

        #expect(state.dayKey == "2026-08-23")
        #expect(state.appliedRemoteGrants.isEmpty)
    }

    @Test("the applied remote-grant set round-trips through session.json")
    func appliedRemoteGrantsRoundTrip() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            let now = warsaw.at(2026, 8, 22, 18, 30, 15)
            let state = SessionState(dayKey: "2026-08-22", lastHeartbeat: now,
                                     appliedRemoteGrants: ["g1": now, "g2": now + 5])

            try store.save(state)
            let loaded = store.load()

            #expect(loaded.outcome == .loaded)
            #expect(loaded.state.appliedRemoteGrants == state.appliedRemoteGrants)
        }
    }

    /// The deliberate departure from `last_heartbeat`, which quarantines the whole file on a
    /// bad timestamp: a garbled dedupe entry is dropped instead, because losing one such entry
    /// (worst case, one grant re-applies) is far cheaper than ending the child's live session.
    @Test("a garbled applied-grant timestamp is dropped, not fatal to the ledger")
    func garbledAppliedGrantEntryIsLenient() throws {
        try withLedgerDirectory { directory in
            let store = SessionStore(directory: directory)
            try Data(#"{"day_key":"2026-08-22","remaining_seconds":300,"applied_remote_grants":{"good":"2026-08-22T12:00:00Z","bad":"tuesday"}}"#.utf8)
                .write(to: store.url)

            let loaded = store.load()

            #expect(loaded.outcome == .loaded)               // the session survives the bad entry
            #expect(loaded.state.remainingSeconds == 300)
            #expect(Set(loaded.state.appliedRemoteGrants.keys) == ["good"])
        }
    }
}

// MARK: - Shared helpers

/// A fixed-zone calendar. Duplicated from `DayWindowTests` rather than shared: the helper
/// is four lines, and a test-support file that both suites import is a larger commitment
/// than the duplication saves.
/// Sensor-only `Snapshot`, for the half of it `isActive` reads.
///
/// T05 moved `Snapshot` to `Policy.swift` and gave it a required `now` — a defaulted one
/// compared against `disabledUntil` would stand the whole app down (see the doc comment
/// there). `isActive` reads no timestamp at all, so these tests say so explicitly rather
/// than threading a date through forty call sites that would ignore it.
private func sensors(idleSeconds: TimeInterval = 0,
                     screenLocked: Bool = false,
                     sessionOnConsole: Bool = true,
                     mediaPlaying: Bool = false) -> Snapshot {
    Snapshot(now: .distantPast, idleSeconds: idleSeconds, screenLocked: screenLocked,
             sessionOnConsole: sessionOnConsole, mediaPlaying: mediaPlaying)
}

/// `decide` returns `.dormant` without a PIN (§2.5), which would mask every T20 assertion.
private let configuredWithPIN: Config = {
    var config = Config()
    config.pinHash = "x"
    config.pinSalt = Data("saltsalt".utf8).base64EncodedString()
    return config
}()

private func ledgerCalendar(in identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

/// A fresh directory per test, removed afterwards. Nothing here may touch the real
/// `~/Library/Application Support/RealScreenTime` — a test that eats the child's session is
/// a test that costs somebody an argument.
private func withLedgerDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rst-ledger-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private extension Calendar {
    /// A date from wall-clock components in this calendar's time zone.
    func at(_ year: Int, _ month: Int, _ day: Int,
            _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let parts = DateComponents(year: year, month: month, day: day,
                                   hour: hour, minute: minute, second: second)
        guard let date = date(from: parts) else {
            fatalError("no such local time: \(year)-\(month)-\(day) \(hour):\(minute):\(second)")
        }
        return date
    }
}
