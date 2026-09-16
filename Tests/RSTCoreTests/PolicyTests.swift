import Foundation
import Testing
@testable import RSTCore

/// `decide` is the one function in this project that can lock a child out of a machine with
/// no way back, and it does it from ten fields and no side effects. Every branch is a
/// struct literal and an assertion, which is the whole argument for the Core/App boundary:
/// a day of behaviour checked in milliseconds, on a machine where UI automation does not
/// exist.
@Suite("Policy")
struct PolicyTests {

    private let config = Config()      // 30 min, 1 a day, warnings at 10/5/1
    private let warsaw = policyCalendar(in: "Europe/Warsaw")

    // MARK: - 1. No PIN beats everything

    /// §2.5's derived rule, and the only fail-open in the app: with no PIN nothing could
    /// uncover the screen, so nothing may cover it. Asserted against the states that would
    /// otherwise each produce a cover, so a reordering of the guards fails here first.
    @Test("no PIN stands the app down, whatever else is true")
    func noPINBeatsEverything() {
        let wouldOtherwiseCover = [
            snap(hasPIN: false),                                              // awaitingStart
            snap(wasRunning: true, hasPIN: false),                            // expired
            snap(wasRunning: true, used: 2, hasPIN: false),                   // expired(0)
            snap(remaining: 1200, hasPIN: false),                             // awaitingResume
        ]
        for s in wouldOtherwiseCover { #expect(decide(s, config) == .dormant) }

        // And the states that would not cover: still dormant, not allowed. The difference
        // matters to T10 — a stood-down app has no countdown to show.
        #expect(decide(snap(remaining: 1800, live: true, wasRunning: true, hasPIN: false),
                       config) == .dormant)
        #expect(decide(snap(remaining: 60, live: true, wasRunning: true, hasPIN: false),
                       config) == .dormant)
    }

    /// A PIN hash with an unusable salt is not a PIN: it can verify nothing, so treating it
    /// as configured would cover a screen that no PIN could then open.
    @Test("hasPIN follows Config.isConfigured, not a non-empty hash")
    func hasPINComesFromIsConfigured() {
        var halfConfigured = Config()
        halfConfigured.pinHash = String(repeating: "a", count: 64)
        halfConfigured.pinSalt = ""
        let sensors = snap(now: reference)
        #expect(sensors.applying(SessionState(), halfConfigured).hasPIN == false)
        #expect(decide(sensors.applying(SessionState(), halfConfigured), halfConfigured)
                == .dormant)

        // **And a salt that is present but not base64.** `Config.pinSaltData` reads it as
        // no salt at all, so `verifyPIN` can never be called and T13's prompt rejects every
        // entry for ever — while a `pinSalt.isEmpty` check would have called this
        // configured and put the cover up over it. Nothing validates `config.json` (T03),
        // which is the whole reason this case is reachable.
        var mangled = Config()
        mangled.pinHash = String(repeating: "a", count: 64)
        mangled.pinSalt = "not base64!!"
        #expect(mangled.pinSaltData == nil)
        #expect(sensors.applying(SessionState(), mangled).hasPIN == false)
        #expect(decide(sensors.applying(SessionState(), mangled), mangled) == .dormant)
    }

    // MARK: - 2. Disable

    @Test("a stand-down in the future is dormant; in the past it does not suppress")
    func disableWindow() {
        // Beats a running session, an expired one and a fresh day alike.
        #expect(decide(snap(remaining: 900, live: true, wasRunning: true,
                            disabledUntil: reference + 60), config) == .dormant)
        #expect(decide(snap(wasRunning: true, disabledUntil: reference + 60), config)
                == .dormant)
        #expect(decide(snap(disabledUntil: reference + 1), config) == .dormant)

        // Expired to the second: strictly greater, so the 06:00 re-arm is exact rather
        // than a tick late.
        #expect(decide(snap(disabledUntil: reference), config) == .awaitingStart(selfServiceLeft: 1))
        #expect(decide(snap(disabledUntil: reference - 1), config) == .awaitingStart(selfServiceLeft: 1))
        #expect(decide(snap(disabledUntil: nil), config) == .awaitingStart(selfServiceLeft: 1))
    }

    // MARK: - 3 and 6. The four quadrants

    /// The reading T04 built `isLive` for. `wasRunning` — not `isLive` — separates the
    /// bottom row, because only `wasRunning` survives a logout.
    @Test("live × remaining × wasRunning, in full")
    func quadrants() {
        var checked = 0
        for live in [true, false] {
            for wasRunning in [true, false] {
                for remaining in [TimeInterval(0), 1200] {
                    let decision = decide(
                        snap(remaining: remaining, live: live, wasRunning: wasRunning), config)
                    let expected: Decision
                    if remaining > 0 {
                        expected = live ? .allowed(remaining: remaining)
                                        : .awaitingResume(remaining: remaining)
                    } else {
                        expected = wasRunning ? .expired(selfServiceLeft: 1)
                                              : .awaitingStart(selfServiceLeft: 1)
                    }
                    #expect(decision == expected,
                            "live=\(live) wasRunning=\(wasRunning) remaining=\(remaining)")
                    checked += 1
                }
            }
        }
        #expect(checked == 8)
    }

    /// The defect `isLive` exists to prevent, seen from the policy end: a session waiting
    /// behind `Wznów` must not warn, or the child hears "five minutes left" at a cover he
    /// has not pressed yet.
    @Test("a paused session inside a warning threshold still only offers Wznów")
    func pausedSessionDoesNotWarn() {
        #expect(decide(snap(remaining: 60, live: false, wasRunning: true), config)
                == .awaitingResume(remaining: 60))
        #expect(decide(snap(remaining: 1, live: false, wasRunning: true), config)
                == .awaitingResume(remaining: 1))
    }

    /// Charging is the ledger's job (`SessionState.isActive`); the decision is not a
    /// function of the sensors at all. Pinned so a later session does not "fix" `decide`
    /// into stopping the countdown itself and charge the rule twice.
    @Test("the sensor half does not move the decision")
    func sensorsDoNotDecide() {
        for locked in [true, false] {
            for onConsole in [true, false] {
                for idle in [TimeInterval(0), 5000] {
                    var s = snap(remaining: 1200, live: true, wasRunning: true)
                    s.screenLocked = locked
                    s.sessionOnConsole = onConsole
                    s.idleSeconds = idle
                    s.mediaPlaying = true
                    #expect(decide(s, config) == .allowed(remaining: 1200))
                }
            }
        }
    }

    // MARK: - 4. Warnings

    /// The whole ladder, including the two the task doc calls out to prove 15 is *not* a
    /// threshold on the shipped config (DESIGN §2.4: on a 30-minute session it is a
    /// progress report, not a warning).
    @Test("warning thresholds, at the boundary and either side of it")
    func warningLadder() {
        let cases: [(TimeInterval, Decision)] = [
            (1800, .allowed(remaining: 1800)),                       // 30:00
            (900,  .allowed(remaining: 900)),                        // 15:00 — not a warning
            (899,  .allowed(remaining: 899)),                        // 14:59
            (601,  .allowed(remaining: 601)),                        // 10:01
            (600,  .warning(remaining: 600, threshold: 10)),         // 10:00 — inclusive
            (599,  .warning(remaining: 599, threshold: 10)),         // 9:59
            (301,  .warning(remaining: 301, threshold: 10)),         // 5:01 — still the ten
            (300,  .warning(remaining: 300, threshold: 5)),          // 5:00
            (240,  .warning(remaining: 240, threshold: 5)),          // 4:00 — the smallest
            (61,   .warning(remaining: 61, threshold: 5)),           // 1:01 — still the five
            (60,   .warning(remaining: 60, threshold: 1)),           // 1:00
            (59,   .warning(remaining: 59, threshold: 1)),           // 0:59
            (1,    .warning(remaining: 1, threshold: 1)),            // 0:01
        ]
        for (remaining, expected) in cases {
            #expect(decide(snap(remaining: remaining, live: true, wasRunning: true), config)
                    == expected, "remaining=\(remaining)")
        }
    }

    /// Exactly at the boundary, and one second either side. Zero is not a warning — it is
    /// the cover, and `Czas minął` is spoken by the enforcer rather than warned about here.
    @Test("the session boundary: 1, 0 and a value that should not exist")
    func sessionBoundary() {
        #expect(decide(snap(remaining: 1, live: true, wasRunning: true), config)
                == .warning(remaining: 1, threshold: 1))
        #expect(decide(snap(remaining: 0, live: true, wasRunning: true), config)
                == .expired(selfServiceLeft: 1))
        // `SessionState` floors at zero, so this is unreachable through the ledger. It is
        // asserted anyway: `decide` is total, and a negative must land on the cover rather
        // than on `.allowed(-1)`.
        #expect(decide(snap(remaining: -1, live: true, wasRunning: true), config)
                == .expired(selfServiceLeft: 1))
    }

    @Test("a hand-edited warning list cannot produce a nonsense warning")
    func warningListIsSanitised() {
        var none = Config(); none.warningMinutes = []
        #expect(decide(snap(remaining: 30, live: true, wasRunning: true), none)
                == .allowed(remaining: 30))

        // Zero and negatives would fire at or after the cover appears — dropped.
        var junk = Config(); junk.warningMinutes = [0, -5, 10]
        #expect(junk.warningThresholds == [10])
        #expect(decide(snap(remaining: 30, live: true, wasRunning: true), junk)
                == .warning(remaining: 30, threshold: 10))

        // Unsorted and duplicated: the smallest match still wins, exactly once.
        var messy = Config(); messy.warningMinutes = [5, 10, 5, 1, 10]
        #expect(messy.warningThresholds == [1, 5, 10])
        #expect(decide(snap(remaining: 240, live: true, wasRunning: true), messy)
                == .warning(remaining: 240, threshold: 5))

        // Reverting to [15, 5, 1] is documented in §2.4 as the supported knob for a longer
        // session; 15:00 then warns where it did not above.
        var long = Config(); long.warningMinutes = [15, 5, 1]
        #expect(decide(snap(remaining: 900, live: true, wasRunning: true), long)
                == .warning(remaining: 900, threshold: 15))
    }

    // MARK: - 5 and 7. The self-service count

    @Test("selfServiceLeft counts down and floors at zero, on both covers")
    func selfServiceLeftCountsDown() {
        for (used, left) in [(0, 1), (1, 0), (2, 0), (7, 0)] {
            #expect(decide(snap(used: used), config) == .awaitingStart(selfServiceLeft: left))
            #expect(decide(snap(wasRunning: true, used: used), config)
                    == .expired(selfServiceLeft: left))
        }
    }

    /// The state is the same; only the cover's text and buttons differ (§2.6's table).
    @Test("expired(0) when the day's sessions are spent")
    func expiredWithNothingLeft() {
        #expect(decide(snap(wasRunning: true, used: 1), config) == .expired(selfServiceLeft: 0))
        #expect(decide(snap(wasRunning: true, used: 1), config).coversScreen)
    }

    @Test("a hand-edited session count cannot go negative or hand out extra sessions")
    func selfServiceLimitIsClamped() {
        var negative = Config(); negative.selfServiceSessionsPerDay = -3
        #expect(negative.selfServiceLimit == 0)
        #expect(decide(snap(used: 0), negative) == .awaitingStart(selfServiceLeft: 0))

        // Zero is a legitimate setting, not an error: every session behind the PIN.
        var pinOnly = Config(); pinOnly.selfServiceSessionsPerDay = 0
        #expect(decide(snap(used: 0), pinOnly) == .awaitingStart(selfServiceLeft: 0))
    }

    // MARK: - The enum's own answers

    @Test("which decisions put the cover on the screen")
    func coversScreenMapping() {
        #expect(Decision.dormant.coversScreen == false)
        #expect(Decision.allowed(remaining: 60).coversScreen == false)
        #expect(Decision.warning(remaining: 60, threshold: 1).coversScreen == false)
        #expect(Decision.awaitingStart(selfServiceLeft: 1).coversScreen)
        #expect(Decision.awaitingResume(remaining: 60).coversScreen)
        #expect(Decision.expired(selfServiceLeft: 0).coversScreen)
    }

    @Test("remainingSeconds is present exactly where there is a session")
    func remainingSecondsAccessor() {
        #expect(Decision.allowed(remaining: 60).remainingSeconds == 60)
        #expect(Decision.warning(remaining: 59, threshold: 1).remainingSeconds == 59)
        #expect(Decision.awaitingResume(remaining: 1200).remainingSeconds == 1200)
        #expect(Decision.dormant.remainingSeconds == nil)
        #expect(Decision.awaitingStart(selfServiceLeft: 1).remainingSeconds == nil)
        #expect(Decision.expired(selfServiceLeft: 0).remainingSeconds == nil)
    }

    // MARK: - Against the real ledger

    /// The mapping in one place, so no caller has to remember it. `now` and the sensors are
    /// deliberately untouched — they come from the other side of the boundary.
    @Test("applying fills the state half and leaves the sensors alone")
    func applyingMapsTheState() {
        var state = SessionState(dayKey: "2026-08-22", remainingSeconds: 640,
                                 selfServiceStarts: ["2026-08-22": 1, "2026-08-21": 2],
                                 wasRunning: true, disabledUntil: reference + 3600,
                                 isLive: true)
        state.lastHeartbeat = reference

        var sensors = snap(now: reference)
        sensors.idleSeconds = 42
        sensors.screenLocked = true
        sensors.mediaPlaying = true

        let s = sensors.applying(state, configured())
        #expect(s.sessionRemaining == 640)
        #expect(s.sessionLive)
        #expect(s.sessionWasRunning)
        #expect(s.sessionsUsedToday == 1)          // today's key, not yesterday's 2
        #expect(s.disabledUntil == reference + 3600)
        #expect(s.hasPIN)
        #expect(s.now == reference && s.idleSeconds == 42 && s.screenLocked
                && s.mediaPlaying)
    }

    /// One evening, end to end, through the real `SessionState`: start, count down, warn,
    /// expire, extend behind the PIN, spend it, and take the second self-service session.
    @Test("an evening, decided tick by tick against the real ledger")
    func anEveningEndToEnd() {
        let config = configured()
        let start = warsaw.at(2026, 8, 22, 18, 0, 0)
        var state = SessionState(lastHeartbeat: start)
        state.reconcile(at: start, bootTime: start - 7200, config: config, calendar: warsaw)

        func decision(at now: Date) -> Decision {
            decide(snap(now: now).applying(state, config), config)
        }
        /// Charge `seconds` of ordinary active use, a minute at a time.
        func use(_ seconds: TimeInterval, from now: Date) -> Date {
            var cursor = now
            for _ in 0..<Int(seconds / 60) {
                cursor += 60
                state.advance(to: cursor, snapshot: snap(now: cursor), config: config,
                              calendar: warsaw)
            }
            return cursor
        }

        #expect(decision(at: start) == .awaitingStart(selfServiceLeft: 1))

        state.startSelfService(config)
        #expect(decision(at: start) == .allowed(remaining: 1800))

        var now = use(1200, from: start)                       // 20 minutes in
        #expect(decision(at: now) == .warning(remaining: 600, threshold: 10))

        now = use(540, from: now)                              // 1:00 left
        #expect(decision(at: now) == .warning(remaining: 60, threshold: 1))

        now = use(60, from: now)                               // spent, and it was the day's one
        #expect(decision(at: now) == .expired(selfServiceLeft: 0))

        // The PIN beats the limit: minutes granted make it live again without touching the
        // count, however many of them there are (§2.5).
        state.extend(minutes: 15)
        #expect(decision(at: now) == .allowed(remaining: 900))
        #expect(state.sessionsUsedToday == 1)

        now = use(900, from: now)
        #expect(decision(at: now) == .expired(selfServiceLeft: 0))

        // A whole further session is the same act with a bigger number typed into it.
        state.extend(minutes: 30)
        #expect(decision(at: now) == .allowed(remaining: 1800))
        #expect(state.sessionsUsedToday == 1)

        now = use(1800, from: now)
        #expect(decision(at: now) == .expired(selfServiceLeft: 0))
    }

    /// The doc's arithmetic check: grants stack rather than replace.
    @Test("three stacked grants of 15 give 45 minutes, not 15")
    func extensionsStack() {
        let config = configured()
        var state = SessionState(dayKey: "2026-08-22", remainingSeconds: 0,
                                 selfServiceStarts: ["2026-08-22": 1], wasRunning: true,
                                 lastHeartbeat: reference)
        #expect(decide(snap(now: reference).applying(state, config), config)
                == .expired(selfServiceLeft: 0))

        for _ in 0..<3 { state.extend(minutes: 15) }
        #expect(decide(snap(now: reference).applying(state, config), config)
                == .allowed(remaining: 2700))
        #expect(state.sessionsUsedToday == 1)      // still not a self-service start
    }

    /// Minutes granted past the cap allow, and cost the count nothing — §2.5's one
    /// consistent rule, seen from the decision end. Since 2026-08-22 this is the *only* PIN
    /// grant there is: "a whole new session" is `minutes: 30` and reads identically here.
    @Test("minutes granted past the cap allow, and the count stays spent")
    func grantedMinutesPastTheCap() {
        let config = configured()
        var state = SessionState(dayKey: "2026-08-22", selfServiceStarts: ["2026-08-22": 1],
                                 wasRunning: true, lastHeartbeat: reference)
        state.extend(minutes: config.sessionMinutes)
        let s = snap(now: reference).applying(state, config)
        #expect(decide(s, config) == .allowed(remaining: 1800))
        #expect(s.sessionsUsedToday == 1)
        #expect(s.selfServiceLeft(config) == 0)
    }

    /// §2.1: logging out must never cost him time, and must never silently give the screen
    /// back either. A relaunch finds the remainder not live, so the cover offers `Wznów`.
    @Test("a session survives a restart as awaitingResume, and resumes on the button")
    func resumeAfterRestart() {
        let config = configured()
        let evening = warsaw.at(2026, 8, 22, 19, 0, 0)
        var state = SessionState(dayKey: "2026-08-22", remainingSeconds: 1800,
                                 selfServiceStarts: ["2026-08-22": 1], wasRunning: true,
                                 lastHeartbeat: evening, isLive: true)
        state.markExpectedExit(at: evening)

        // Round-tripped through JSON, because `isLive` has no coding key and that is what
        // makes the restart case real rather than simulated.
        let encoded = try! JSONEncoder().encode(state)
        var reloaded = try! JSONDecoder().decode(SessionState.self, from: encoded)
        let relaunch = evening + 1800                    // half an hour away, clean exit
        reloaded.reconcile(at: relaunch, bootTime: evening - 3600, config: config,
                           calendar: warsaw)

        #expect(decide(snap(now: relaunch).applying(reloaded, config), config)
                == .awaitingResume(remaining: 1800))     // the clean exit charged nothing

        reloaded.resume()
        #expect(decide(snap(now: relaunch).applying(reloaded, config), config)
                == .allowed(remaining: 1800))
        #expect(reloaded.sessionsUsedToday == 1)         // resuming consumed nothing
    }

    /// The morning after: an expired session that sat on screen through 06:00 becomes a
    /// fresh offer, not yesterday's `Czas minął` (the T04 rollover finding, from the
    /// decision end this time).
    @Test("the 06:00 rollover turns yesterday's expired cover into a fresh start")
    func rolloverReoffers() {
        let config = configured()
        let lastNight = warsaw.at(2026, 8, 22, 23, 0, 0)
        var state = SessionState(dayKey: "2026-08-22", remainingSeconds: 0,
                                 selfServiceStarts: ["2026-08-22": 1], wasRunning: true,
                                 lastHeartbeat: lastNight, isLive: true)
        #expect(decide(snap(now: lastNight).applying(state, config), config)
                == .expired(selfServiceLeft: 0))

        let morning = warsaw.at(2026, 8, 23, 6, 0, 0)
        state.advance(to: morning, snapshot: snap(now: morning), config: config,
                      calendar: warsaw)
        #expect(decide(snap(now: morning).applying(state, config), config)
                == .awaitingStart(selfServiceLeft: 1))
    }

    // MARK: - Helpers

    private func configured() -> Config {
        var config = Config()
        config.pinHash = String(repeating: "a", count: 64)
        config.pinSalt = Data(repeating: 7, count: 16).base64EncodedString()
        #expect(config.isConfigured)
        return config
    }
}

/// A fixed instant. The policy has no calendar in it at all — `disabledUntil` is the only
/// date it compares, and it compares it against the `now` it was handed — so an arbitrary
/// epoch is enough for everything except the ledger cases, which build real local times.
private let reference = Date(timeIntervalSince1970: 1_787_000_000)

/// A `Snapshot` with the sensor half left at its harmless defaults, so each test states
/// only the fields its case turns on.
private func snap(remaining: TimeInterval = 0,
                  live: Bool = false,
                  wasRunning: Bool = false,
                  used: Int = 0,
                  disabledUntil: Date? = nil,
                  hasPIN: Bool = true,
                  now: Date = reference) -> Snapshot {
    Snapshot(now: now, sessionRemaining: remaining, sessionLive: live,
             sessionWasRunning: wasRunning, sessionsUsedToday: used,
             disabledUntil: disabledUntil, hasPIN: hasPIN)
}

private func policyCalendar(in identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
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
