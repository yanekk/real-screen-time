import Foundation

/// Sensor readings and session state, both declared in `Policy.swift`.
///
/// `Snapshot` used to live here, because ``SessionState/isActive(_:_:)`` is
/// a T04 rule and needed something to read from. DESIGN §3.2 gives them to the decision
/// function, and T05 moved them there when it added the state-derived half — one home for
/// the policy's inputs rather than two.

/// Did the app go away on purpose.
///
/// The whole of §2.3 turns on this one byte. An orderly shutdown writes `.expected` before
/// going away; a `SIGKILL` cannot write anything, so `.unknown` is what a killed process
/// leaves behind. That asymmetry is what separates "the Mac slept" from "the app was
/// killed" without having to ask the system anything.
public enum ExitKind: String, Codable, Sendable {
    case expected, unknown
}

/// What happened while the app was not running (DESIGN §2.3).
///
/// The point is not to prevent the kill — nothing in user space can. It is to make killing
/// cost exactly as much session time as not killing, so there is no reason to try.
public enum Gap: Equatable, Sendable {
    /// No time passed, or the clock stepped backwards.
    case none
    /// Clean exit — logged out, slept, or quit properly. Not charged.
    case expected(TimeInterval)
    /// The machine was off for part of it; only the portion after boot is charged.
    case rebooted(charge: TimeInterval)
    /// Killed. Charged in full, and worth a `tamper_gap` event.
    case unexplained(TimeInterval)

    /// Seconds to take off the running session.
    public var chargedSeconds: TimeInterval {
        switch self {
        case .none, .expected: return 0
        case .rebooted(let charge): return charge
        case .unexplained(let seconds): return seconds
        }
    }
}

/// What ``SessionState/reconcile(at:bootTime:config:calendar:)`` closed the books on.
///
/// Two numbers rather than one because they mean opposite things to the child, and are
/// indistinguishable in the ledger once written: a **charge** is time he is held to have
/// spent, and a **discard** is time 06:00 took back off him. `Engine` has to tell them apart
/// to keep `used_s` honest and to stay silent about the second (T21).
public struct Reconciliation: Equatable, Sendable {
    /// What happened while the app was not running.
    public let gap: Gap
    /// Seconds the day boundary discarded on the way past. 0 when the day did not change.
    public let discardedSeconds: TimeInterval

    public init(gap: Gap, discardedSeconds: TimeInterval) {
        self.gap = gap
        self.discardedSeconds = discardedSeconds
    }
}

/// The running session, the day's self-service count, and the heartbeat that makes a gap
/// classifiable.
///
/// Persisted to `session.json` atomically — every state change, and every 15 seconds
/// regardless (DESIGN §3.5). Fifteen seconds is also the bound on how wrong an unexplained
/// gap can be: a killed process is charged from its last written heartbeat.
public struct SessionState: Codable, Equatable, Sendable {

    /// The day this state belongs to, `"YYYY-MM-DD"` from ``DayWindow/dayKey(for:resetHour:calendar:)``.
    public var dayKey: String

    /// Seconds left in the current session. `0` means no session is running.
    ///
    /// **Never written directly, and `private(set)` so the compiler says so.** Every path
    /// that *raises* it — ``begin(seconds:)``, ``extend(minutes:)``, the initialiser and the
    /// decoder — runs it through ``clampedSeconds(_:)`` first. See ``secondsCeiling`` for
    /// what that is defending against. The two paths that only ever lower it need no clamp
    /// and have none: ``charge(_:)`` floors at zero, and ``rollOverIfNeeded(at:config:calendar:)``
    /// assigns zero outright.
    public private(set) var remainingSeconds: TimeInterval

    /// **Self-service starts, keyed by day.**
    ///
    /// The task doc specifies a plain `sessionsUsedToday: Int` reset when the day key
    /// changes. That is the one shape this must not have, and T03's review says why: the
    /// day key is *not monotonic*. A backwards NTP correction, a hand-set clock or a
    /// time-zone change steps it back to yesterday, and a counter that resets on every
    /// change hands out two fresh sessions each time it happens — the free-screen-time bug
    /// the 06:00 rollover exists to avoid. Keyed by the day string it is self-healing
    /// instead: stepping back to yesterday finds yesterday's count still sitting there.
    ///
    /// Bounded to the most recent ``historyLimit`` days, so a file that lives for years
    /// does not grow a key per day of it.
    public var selfServiceStarts: [String: Int]

    /// A session has been started at some point and not yet re-offered.
    ///
    /// Carries the difference between "his session ran out" (`remainingSeconds == 0`,
    /// `wasRunning`) and "he has not started one yet" (`remainingSeconds == 0`, not
    /// `wasRunning`). Both look identical otherwise, and they need different covers —
    /// `Czas minął` versus `Rozpocznij sesję`. Without it a child who lets a session expire
    /// and then logs out would be offered a fresh start as though nothing had happened.
    public var wasRunning: Bool

    /// The accounting cursor: time up to here has been charged or deliberately not.
    ///
    /// Advanced on every tick, not every write — `advance` charges the interval since this
    /// instant, so leaving it behind between the 15-second saves would charge each tick's
    /// seconds again on the next one. What the 15-second cadence bounds is how much of a
    /// killed process's final moments goes uncharged.
    public var lastHeartbeat: Date

    /// `.expected` only while the app is deliberately away. `advance` clears it back to
    /// `.unknown` on every tick, so a marker written before a clean exit cannot survive
    /// into the next run and excuse a kill.
    public var exitKind: ExitKind

    /// A PIN-granted stand-down (§2.5). Stored here, interpreted by T05's `decide`.
    public var disabledUntil: Date?

    /// **Not persisted.** A session is live only inside the run that started or resumed it.
    ///
    /// This is the other half of the four-quadrant reading T05 needs, and it is why a
    /// logout does not cost anything: after a restart the remainder is still there but the
    /// session is not live, so the cover offers `Wznów` and `advance` charges nothing while
    /// he looks at it. Charging a session whose own cover is blocking the screen is the
    /// defect this field exists to prevent.
    ///
    /// | | `isLive` | not `isLive` |
    /// |---|---|---|
    /// | `remainingSeconds > 0` | allowed / warning | awaiting resume |
    /// | `remainingSeconds == 0` | `wasRunning` ? expired : awaiting start | *same* |
    ///
    /// **The bottom row does not read this flag at all** — it reads ``wasRunning``, and it
    /// has to: a session that ran out and was then logged out comes back `remaining == 0`,
    /// `wasRunning`, *not* `isLive`, and it is still `Czas minął` rather than a fresh offer.
    /// Only ``wasRunning`` survives the logout. Corrected reviewing T05, where `decide`
    /// spells the same reading out.
    public var isLive: Bool

    /// How many days of self-service counts to keep. Two would do for the rollover; the
    /// margin is for a clock that went somewhere strange and came back.
    public static let historyLimit = 14

    /// The largest remainder the ledger will hold — about 31 000 years.
    ///
    /// **An arithmetic guard, not a cap on anybody's judgement.** `Int(_:)` on a `Double`
    /// past `Int.max` is a **trap**: the process dies rather than saturating. Two of the
    /// numbers that reach this field come out of files the child owns (§8) and neither had
    /// an upper bound — `session_minutes` is multiplied by 60, and `remaining_seconds` in
    /// `session.json` was decoded straight — so `9223372036854775807` in either one made a
    /// remainder of 5.5 × 10²⁰ seconds, and the first thing that printed or displayed it
    /// killed the app. Found reviewing T10 (2026-08-23) and fixed at the user's direction.
    ///
    /// **§2.5's "unlimited extension" is untouched**, and that is why the number is absurd
    /// rather than tidy: the ceiling sits eleven orders of magnitude above the largest grant
    /// a parent could mean, so it can never be the thing that refuses one. It exists only so
    /// that every `Int` conversion downstream — the launch line, the wake line, the observer
    /// enforcer, the menu bar — is safe by construction rather than by inspection. How long
    /// a countdown can legibly be *displayed* is a separate and much smaller number, and it
    /// lives in `MenuBarModel`.
    public static let secondsCeiling: TimeInterval = 1e12

    /// Into `0...secondsCeiling`, with a NaN landing on zero.
    ///
    /// `max` before `min` is what does that: every comparison against NaN is false, so
    /// `max(0, .nan)` returns the `0` it was given rather than the NaN. Written in this
    /// order deliberately — the other way round returns the NaN and `Int(.nan)` traps too.
    static func clampedSeconds(_ seconds: TimeInterval) -> TimeInterval {
        min(max(0, seconds), secondsCeiling)
    }

    /// Seed the remainder. **Deliberately not public**: the app has no business assigning
    /// this — it goes through `startSelfService`, `extend`, `charge` and the decoder — and
    /// the tests build mid-scenario states, which is the only reason it exists. Clamped
    /// like every other write, so the guarantee holds even here.
    mutating func setRemainingSeconds(_ seconds: TimeInterval) {
        remainingSeconds = Self.clampedSeconds(seconds)
    }

    public init(dayKey: String = "",
                remainingSeconds: TimeInterval = 0,
                selfServiceStarts: [String: Int] = [:],
                wasRunning: Bool = false,
                lastHeartbeat: Date = .distantPast,
                exitKind: ExitKind = .unknown,
                disabledUntil: Date? = nil,
                isLive: Bool = false) {
        self.dayKey = dayKey
        self.remainingSeconds = Self.clampedSeconds(remainingSeconds)
        self.selfServiceStarts = selfServiceStarts
        self.wasRunning = wasRunning
        self.lastHeartbeat = lastHeartbeat
        self.exitKind = exitKind
        self.disabledUntil = disabledUntil
        self.isLive = isLive
    }

    /// Self-service sessions started today — the number `selfServiceSessionsPerDay` gates.
    ///
    /// Computed, never stored: see ``selfServiceStarts``. Minutes granted behind the PIN do
    /// not appear here, because the count exists to gate what he can do alone.
    public var sessionsUsedToday: Int { selfServiceStarts[dayKey] ?? 0 }

    /// Self-service sessions he can still start unaided.
    ///
    /// The inner clamp was `max(0, config.selfServiceSessionsPerDay)` spelled out here;
    /// T05 owns the general config-clamp question and answered it with
    /// ``Config/selfServiceLimit``, so this reads it rather than repeating it.
    public func selfServiceLeft(_ config: Config) -> Int {
        max(0, config.selfServiceLimit - sessionsUsedToday)
    }

    // MARK: - Advancing

    /// One tick: roll the day over if it changed, charge the elapsed interval if the
    /// session is being used, and move the heartbeat.
    ///
    /// The `calendar` parameter is the same deliberate departure from the task doc's
    /// snippet that `DayWindow` made at T03, and for the same reason: without one this
    /// would have to read `Calendar.current`, which is a system query `RSTCore` may not
    /// make and would leave every DST case untestable.
    ///
    /// **Between two calls, the whole interval is charged if active.** That is right for
    /// the one-second tick it is built for, and wrong for a wake from sleep, where hours
    /// pass between ticks with input that looks recent. The wake path belongs to
    /// ``reconcile(at:bootTime:config:calendar:)`` — sleep writes the clean-exit marker
    /// and waking reconciles against it, exactly as a launch does.
    ///
    /// - Returns: the seconds the 06:00 boundary discarded on the way in, 0 on an ordinary
    ///   tick. See ``rollOverIfNeeded(at:config:calendar:)`` — the caller cannot otherwise
    ///   tell a session the boundary took from one he played to the end (T21).
    @discardableResult
    public mutating func advance(to now: Date, snapshot: Snapshot, config: Config,
                                 calendar: Calendar) -> TimeInterval {
        let discarded = rollOverIfNeeded(at: now, config: config, calendar: calendar)

        let elapsed = now.timeIntervalSince(lastHeartbeat)
        let remainingBefore = remainingSeconds
        if elapsed > 0, isLive, Self.isActive(snapshot, config) {
            charge(elapsed)
        }
        retireIfSpent(from: remainingBefore, config: config)

        // Assigned unconditionally, so a clock that stepped backwards resumes charging from
        // the new now rather than sitting out the difference as free time.
        lastHeartbeat = now
        exitKind = .unknown
        return discarded
    }

    /// Does this tick consume session time (DESIGN §2.2)?
    ///
    /// Four separate reasons not to charge, each for its own case: he walked away from a
    /// running game; the screen is locked; another user is switched in and charging him
    /// while the parent works would be theft; or something is playing but nothing has been
    /// touched for half an hour, which is a game left running rather than a film.
    ///
    /// The media grace is the *only* thing separating "watching a film" from "went to bed
    /// with a game running" — the display assertion a game holds is byte-for-byte the one a
    /// video player holds, so no further signal exists to tell them apart. A camera was
    /// specified to answer it directly and then dropped (T19, 2026-08-27); the cap is now
    /// the answer rather than the fallback, and both errors it can make are bounded by it.
    public static func isActive(_ s: Snapshot, _ c: Config) -> Bool {
        // Off-console and locked beat everything, with no grace at all — not even one tick.
        guard s.sessionOnConsole, !s.screenLocked else { return false }

        // Recent input settles it on its own, before anything else gets a say.
        if s.idleSeconds <= Double(max(0, c.idleGraceSeconds)) { return true }

        // Idle beyond the grace with nothing playing is a paused game in an empty room.
        guard s.mediaPlaying else { return false }

        return s.idleSeconds <= Double(max(0, c.mediaGraceSeconds))
    }

    /// Start a session he asked for himself: one off the day's allowance.
    ///
    /// Ungated on purpose — whether he *may* is T05's decision, and the PIN paths below
    /// beat every limit. A state object that enforced the policy too would be a second
    /// place for the rule to live and disagree.
    public mutating func startSelfService(_ config: Config) {
        selfServiceStarts[dayKey, default: 0] += 1
        begin(seconds: Self.fullSession(config))
    }

    /// Minutes from behind the PIN. Adds to whatever is left — including nothing, which is
    /// the expired cover's case — and makes the session live again.
    ///
    /// **The amount is the caller's, not the config's** (DESIGN §2.5, changed 2026-08-22).
    /// A fixed grant was the app arbitrating a number it knows nothing about, and
    /// `grantSession` went with it — "a whole new session" is thirty granted through here,
    /// and two ways to do one thing is two places for the rule to live and disagree.
    ///
    /// Where the number *comes from* changed again on 2026-08-23 and this signature did not
    /// notice, which is the point of it taking minutes: T13's dialog now offers a list
    /// (`Config.extensionChoices`, shipping 15/30/60) instead of a text field. Any amount a
    /// parent puts on that list arrives here unargued with, and repeated grants stack.
    ///
    /// Clamped at the point of use, as everything off disk is: a negative would hand back
    /// time rather than add it, and the dialog is not the only possible caller.
    public mutating func extend(minutes: Int) {
        remainingSeconds = Self.clampedSeconds(remainingSeconds + Double(max(0, minutes)) * 60)
        wasRunning = true
        isLive = true
    }

    /// Take back a session that was already granted: after a logout, a restart, or the
    /// resume button on the cover. Consumes nothing — the time was granted once already.
    public mutating func resume() {
        wasRunning = true
        isLive = true
    }

    /// Stand down until `date` (§2.5). Clearing a stand-down is `disable(until: nil)`.
    ///
    /// **Standing down ends the running session outright**, rather than suspending it.
    /// `decide` returns `.dormant` for the whole stand-down, but it is a pure function and
    /// `advance` runs before it on every tick (DESIGN §3.4) reading neither `disabledUntil`
    /// nor the decision — so a session left live would go on being charged behind a free
    /// screen, and the child would lose minutes he never got to use. Zeroing it here is one
    /// place rather than a second copy of the `disabledUntil > now` comparison in T08's
    /// tick loop, one tick away from disagreeing with `decide`.
    ///
    /// Ended, not banked: the count is keyed by day, so 06:00 refills the full allowance
    /// regardless, and carrying a remainder across would hand out that allowance *plus* the
    /// leftover. Decided 2026-08-22 — each day starts with new sessions and nothing else.
    ///
    /// `wasRunning` deliberately stays set, so a stand-down lifted before 06:00 returns the
    /// expired cover — the honest reading — rather than an offer of a session he already
    /// started. Only the standing-down direction ends anything; `disable(until: nil)` must
    /// not wipe a session, which is why this is conditional. A `date` already in the past
    /// stands nothing down and is a caller error; it is not worth a `now` parameter to
    /// detect.
    public mutating func disable(until date: Date?) {
        disabledUntil = date
        guard date != nil else { return }
        remainingSeconds = 0
        isLive = false
    }

    // MARK: - Gaps

    /// What happened between the last heartbeat and now (DESIGN §2.3).
    ///
    /// `bootTime` comes from `sysctl kern.boottime`, read in `RSTApp` and passed in:
    /// `RSTCore` does not call `sysctl` any more than it reads a clock.
    public static func classify(lastHeartbeat: Date, now: Date,
                                exitKind: ExitKind, bootTime: Date) -> Gap {
        let elapsed = now.timeIntervalSince(lastHeartbeat)
        // Not `<= 0` by accident: a clock stepped backwards lands here too, and inventing
        // a negative charge out of it would hand out time rather than take it.
        guard elapsed > 0 else { return .none }

        if exitKind == .expected { return .expected(elapsed) }

        // The machine was off or restarting for the part of the gap before boot. `max` for
        // the nonsense case of a boot time in the future, which charges nothing.
        if bootTime > lastHeartbeat {
            return .rebooted(charge: max(0, now.timeIntervalSince(bootTime)))
        }

        return .unexplained(elapsed)
    }

    /// Close the books on a gap: classify it, charge what it costs, roll the day over and
    /// re-arm the heartbeat. Call this at launch, and again on wake from sleep.
    ///
    /// Returns the `Gap` rather than acting on it, because the event that goes with it —
    /// `tamper_gap` for the unexplained case — must be stamped with a time and written by
    /// something that has an event log. `RSTCore` has neither. It travels with whatever the
    /// day boundary discarded, for the reason ``Reconciliation`` gives.
    ///
    /// **This is the wake path**, not just the launch path: sleeping writes the clean-exit
    /// marker and waking reconciles against it, so a Mac shut overnight with minutes on the
    /// session comes back through here rather than through a tick. It is therefore the path
    /// the 06:00 discard has to work on first (T21).
    ///
    /// The session is deliberately left **not live**: a gap means something interrupted
    /// the run, and the child takes the screen back through `Wznów` rather than finding it
    /// already counting down.
    @discardableResult
    public mutating func reconcile(at now: Date, bootTime: Date, config: Config,
                                   calendar: Calendar) -> Reconciliation {
        let gap = Self.classify(lastHeartbeat: lastHeartbeat, now: now,
                                exitKind: exitKind, bootTime: bootTime)
        let remainingBefore = remainingSeconds
        charge(gap.chargedSeconds)
        isLive = false

        // A gap spends a session exactly as a tick does, so it retires one exactly as a tick
        // does — the fourth door, found reviewing T20. Before the rollover, so the day the
        // retirement is judged against is the day the session ran out on; the crossing case
        // is the rollover's own clear below, and the two agree.
        retireIfSpent(from: remainingBefore, config: config)

        // After the charge, not before, and deliberately still so with T21: the day a gap is
        // charged against is the session's own. Reversed, a kill that spanned the boundary
        // would be excused by the discard that was going to happen anyway, and §2.3's whole
        // point is that killing the app costs exactly what not killing it costs.
        let discarded = rollOverIfNeeded(at: now, config: config, calendar: calendar)

        lastHeartbeat = now
        exitKind = .unknown
        return Reconciliation(gap: gap, discardedSeconds: discarded)
    }

    /// Write the clean-exit marker. Called on the way out — quit, logout, sleep — and the
    /// only thing that makes the difference between `.expected` and `.unexplained`.
    public mutating func markExpectedExit(at now: Date) {
        lastHeartbeat = now
        exitKind = .expected
        isLive = false
    }

    // MARK: - Internals

    static func fullSession(_ config: Config) -> TimeInterval {
        // Clamped at the point of use, as T03 decided for `day_reset_hour`: nothing
        // validates `config.json`'s values, and a hand-edited `"session_minutes": -30`
        // must not produce a negative countdown. T05 owns the general question.
        Double(max(0, config.sessionMinutes)) * 60
    }

    private mutating func begin(seconds: TimeInterval) {
        remainingSeconds = Self.clampedSeconds(seconds)
        wasRunning = true
        isLive = true
    }

    private mutating func charge(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        // Floored, never negative: a gap longer than the session simply ends it.
        remainingSeconds = max(0, remainingSeconds - seconds)
    }

    /// A session that runs out stops being "the one that ran out" if the day it ran out on
    /// still has a session to offer (T20).
    ///
    /// Without this, ``decide(_:_:)`` keeps taking the `wasRunning` branch and returns
    /// `.expired`, whose cover never offers `Rozpocznij` at any `selfServiceLeft`. Two live
    /// consequences, the first found by hand on 2026-08-30:
    ///
    /// - **A session that straddles 06:00 ate the new day's offer.** The remainder used to
    ///   survive the boundary, so it crossed with `wasRunning` still set and nothing cleared
    ///   it once the remainder was finally spent. He saw `Czas minął` with an untouched
    ///   session in the ledger until the *next* rollover. **T21 closed this door from the
    ///   other side** — nothing crosses 06:00 any more, so no session can be spent on a day
    ///   it did not start on (see ``rollOverIfNeeded(at:config:calendar:)``). Kept here
    ///   because the two doors below are same-day and untouched by that.
    /// - **`self_service_sessions_per_day: 2` could never reach the second one.** The
    ///   2026-08-22 finding retired that question on the grounds that with one session a day
    ///   expired implies none left. True for the shipped default, and not for the setting.
    ///
    /// **Called from both charging paths** — ``advance(to:snapshot:config:calendar:)`` and
    /// ``reconcile(at:bootTime:config:calendar:)``. A gap spends a session too, and on the
    /// shipped default it is reachable *within a day*: a PIN grant taken before he has used
    /// his own session, then a crash or a forced power-off that eats the grant, leaves his
    /// own untouched session unofferable until the next 06:00. T20 fixed only the tick; the
    /// review found the gap (2026-09-04).
    ///
    /// **The transition, not the value.** `before > 0` restricts this to a session charged
    /// down to zero on this tick — the same condition `Engine` uses to emit `session_end`.
    /// Reading `remainingSeconds == 0` alone would also catch
    /// ``disable(until:)``, which zeroes the remainder and **deliberately** leaves
    /// `wasRunning` set so a stand-down lifted before 06:00 returns the expired cover rather
    /// than re-offering a session he already started. That intent is preserved here.
    private mutating func retireIfSpent(from before: TimeInterval, config: Config) {
        guard before > 0, remainingSeconds <= 0, selfServiceLeft(config) > 0 else { return }
        wasRunning = false
        isLive = false
    }

    /// **Nothing crosses 06:00** (DESIGN §2.1, changed 2026-09-04; T21).
    ///
    /// Whatever is left on the clock at the boundary is discarded — his own minutes and
    /// PIN-granted ones alike, asleep or awake, playing or paused — and the day opens with a
    /// full allowance and an empty session.
    ///
    /// It used to carry the remainder across, on the grounds that a session granted at 05:50
    /// was legitimately granted. True, and it made the *overnight* case absurd: a session
    /// half-used at bedtime survives the logout (§2.1, still true) and nothing then bounded
    /// it by the day, so the morning offered `Wznów sesję — pozostało 15 minut` and only
    /// afterwards the new day's thirty. Making the loss conditional on an interruption was
    /// rejected for leaving the same hole open on a Mac left awake all night.
    ///
    /// Nobody is left short: the allowance refills on this same line, so the trade is always
    /// leftover minutes for a whole fresh session. The one household it costs anything is
    /// `self_service_sessions_per_day: 0`, which has no self-service allowance to refill and
    /// grants every minute by PIN anyway.
    ///
    /// **The clear of `wasRunning`/`isLive` is unconditional now**, where it used to guard on
    /// a spent remainder: with the remainder always zero on the far side, the two cases have
    /// collapsed into one. `wasRunning` is what `decide` reads for the expired cover, so
    /// clearing it is what makes the morning a fresh offer rather than yesterday's
    /// `Czas minął`; `isLive` goes with it because a session the boundary has just ended is
    /// not running, whatever it was doing a second ago.
    ///
    /// - Returns: the seconds discarded at the boundary — 0 when the day did not change, and
    ///   0 when there was nothing on the clock. **The caller needs this to tell a discard
    ///   from a charge**, which are byte-for-byte identical in the ledger and opposite in
    ///   meaning: one is time he spent, the other is time taken back off him. See
    ///   ``Engine/tick(_:)``, where the difference is `Czas minął` spoken into an empty room
    ///   at six in the morning, and a `used_s` inflated by minutes he never used.
    @discardableResult
    private mutating func rollOverIfNeeded(at now: Date, config: Config,
                                           calendar: Calendar) -> TimeInterval {
        let key = DayWindow.dayKey(for: now, resetHour: config.dayResetHour, calendar: calendar)
        guard key != dayKey else { return 0 }
        dayKey = key

        let discarded = remainingSeconds
        remainingSeconds = 0
        wasRunning = false
        isLive = false

        pruneHistory(keeping: key)
        return discarded
    }

    private mutating func pruneHistory(keeping key: String) {
        guard selfServiceStarts.count > Self.historyLimit else { return }
        // `"YYYY-MM-DD"` sorts lexicographically as it sorts chronologically. Today is kept
        // explicitly, because a clock that visited 2030 and came back would otherwise leave
        // its stray key sorting above the day we are actually counting against.
        var keep = Set(selfServiceStarts.keys.sorted(by: >).prefix(Self.historyLimit))
        keep.insert(key)
        selfServiceStarts = selfServiceStarts.filter { keep.contains($0.key) }
    }

    // MARK: - Coding

    /// Snake_case on the wire, matching `config.json` and the event log. Spelled out rather
    /// than left to a key strategy so the file format is readable here and cannot drift
    /// when a property is renamed.
    ///
    /// `isLive` has no key on purpose: it is true only within a run, and a decoded state is
    /// by definition from a previous one.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case dayKey = "day_key"
        case remainingSeconds = "remaining_seconds"
        case selfServiceStarts = "self_service_starts"
        case wasRunning = "was_running"
        case lastHeartbeat = "last_heartbeat"
        case exitKind = "exit_kind"
        case disabledUntil = "disabled_until"
    }

    /// Every key optional on the way in, as `Config` is: a file written by an older build
    /// is missing whatever was added since, and that is a default rather than corruption.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SessionState()
        dayKey = try container.decodeIfPresent(String.self, forKey: .dayKey) ?? defaults.dayKey
        // Clamped, not trusted: this is a file in the child's home directory and the number
        // in it feeds every `Int` conversion the app makes. See `secondsCeiling`.
        remainingSeconds = Self.clampedSeconds(
            try container.decodeIfPresent(TimeInterval.self, forKey: .remainingSeconds)
                ?? defaults.remainingSeconds)
        selfServiceStarts = try container.decodeIfPresent([String: Int].self, forKey: .selfServiceStarts)
            ?? defaults.selfServiceStarts
        wasRunning = try container.decodeIfPresent(Bool.self, forKey: .wasRunning) ?? defaults.wasRunning
        exitKind = try container.decodeIfPresent(ExitKind.self, forKey: .exitKind) ?? defaults.exitKind
        lastHeartbeat = try Self.decodeTimestamp(container, .lastHeartbeat) ?? defaults.lastHeartbeat
        disabledUntil = try Self.decodeTimestamp(container, .disabledUntil)
        isLive = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(remainingSeconds, forKey: .remainingSeconds)
        try container.encode(selfServiceStarts, forKey: .selfServiceStarts)
        try container.encode(wasRunning, forKey: .wasRunning)
        try container.encode(exitKind, forKey: .exitKind)
        let formatter = Self.timestampFormatter(fractional: true)
        try container.encode(formatter.string(from: lastHeartbeat), forKey: .lastHeartbeat)
        try container.encodeIfPresent(disabledUntil.map(formatter.string(from:)), forKey: .disabledUntil)
    }

    /// Timestamps are ISO 8601 text, not a `Date` left to the encoder's strategy: this file
    /// is one a parent may open, and `776600000.5` says nothing to anybody.
    ///
    /// **UTC, where the event log uses a local offset.** Not an inconsistency but the
    /// boundary showing: `TimeZone.current` is a system query, and `RSTCore` does not make
    /// them. `RSTApp` knows the zone and stamps the log with it.
    private static func timestampFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    /// Lenient on the way in: fractional seconds first, then without. A hand-edited file
    /// saying `"2026-08-22T06:00:00Z"` is a time somebody meant, not corruption.
    private static func decodeTimestamp(_ container: KeyedDecodingContainer<CodingKeys>,
                                        _ key: CodingKeys) throws -> Date? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        for fractional in [true, false] {
            if let date = timestampFormatter(fractional: fractional).date(from: text) { return date }
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                               debugDescription: "not an ISO 8601 timestamp: \(text)")
    }
}

/// What `SessionStore.load()` found on disk.
public enum SessionLoadOutcome: Equatable, Sendable {
    case loaded
    /// No file yet — first run, or a fresh data directory. Nothing written.
    case missing
    /// Unparseable. Moved aside, and the session is gone with it: DESIGN §3.5 says a
    /// `session.json` that fails to parse ends any running session and returns to
    /// `awaitingStart`. `backup` is where the original went, or `nil` if even that failed.
    ///
    /// **Treat it as an unexplained gap and log it.** A file that will not parse is
    /// indistinguishable from a file someone edited badly, and the design's answer to both
    /// is the same: the child loses nothing he had not already spent, and the parent gets
    /// a line in the log saying so.
    case reset(backup: URL?)
}

public struct SessionLoad: Sendable {
    public let state: SessionState
    public let outcome: SessionLoadOutcome
}

/// Reads and writes `session.json`.
///
/// The directory is injected for the same reason `ConfigStore`'s is: resolving
/// `RST_DATA_DIR` is a question about the environment, and the environment is `RSTApp`'s
/// half of the boundary.
public struct SessionStore: Sendable {
    public let directory: URL
    public let url: URL
    /// One slot, overwritten: the most recent corruption is the one worth keeping.
    public var backupURL: URL { url.appendingPathExtension("bad") }

    public init(directory: URL, fileName: String = "session.json") {
        self.directory = directory
        self.url = directory.appendingPathComponent(fileName)
    }

    /// Never throws. A ledger that cannot be read costs the running session and nothing
    /// else — the app keeps enforcing, which is the point of §3.5's recovery rules.
    public func load() -> SessionLoad {
        guard let data = try? Data(contentsOf: url) else {
            // Absent and unreadable are different things, and only absence is ordinary.
            if FileManager.default.fileExists(atPath: url.path) {
                return SessionLoad(state: SessionState(), outcome: .reset(backup: quarantine()))
            }
            return SessionLoad(state: SessionState(), outcome: .missing)
        }
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return SessionLoad(state: SessionState(), outcome: .reset(backup: quarantine()))
        }
        return SessionLoad(state: state, outcome: .loaded)
    }

    /// Atomic. Temp file, then rename — `Data.write(options: .atomic)` is exactly that,
    /// into the same directory. The watchdog kills this process by design, and this file is
    /// written every 15 seconds, so a torn write is a scenario rather than a worry.
    public func save(_ state: SessionState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    /// Moves the bad file aside. Unlike `ConfigStore` this writes no replacement: the next
    /// heartbeat is at most 15 seconds away and writes one, where a config file has to be
    /// there for the parent to edit.
    private func quarantine() -> URL? {
        let fm = FileManager.default
        try? fm.removeItem(at: backupURL)
        do {
            try fm.moveItem(at: url, to: backupURL)
        } catch {
            // Best effort. If it cannot be moved it cannot be parsed either, so the next
            // launch takes this same path and loses nothing extra.
            return nil
        }
        return backupURL
    }
}
