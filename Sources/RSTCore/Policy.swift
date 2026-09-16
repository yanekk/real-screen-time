import Foundation

/// Everything ``decide(_:_:)`` is allowed to know, and nothing else.
///
/// Two halves that arrive from two places. The **sensor** half is read by `RSTApp` —
/// `RSTCore` can no more ask whether the screen is locked than it can ask what time it is.
/// The **state** half is derived from ``SessionState`` and ``Config``; ``applying(_:_:)``
/// does that derivation so no caller has to remember which field maps to which.
///
/// `now` has no default on purpose. Every other field can be wrong in a way that costs a
/// tick; a defaulted `now` compared against ``disabledUntil`` would stand the whole app
/// down, and that is the one failure this struct must not make cheap.
public struct Snapshot: Equatable, Sendable {

    // MARK: Sensors — read by RSTApp

    /// The current time, from the caller's `Clock`. Never `Date()`.
    public var now: Date
    /// Seconds since the last HID event — `CGEventSource.secondsSinceLastEventType`.
    public var idleSeconds: TimeInterval
    public var screenLocked: Bool
    /// `false` while another user is switched in. The Mac is shared; see §2.2.
    public var sessionOnConsole: Bool
    /// Something holds `kIOPMAssertionTypePreventUserIdleDisplaySleep` — a film or a game.
    public var mediaPlaying: Bool

    // MARK: State — derived from SessionState and Config

    /// Seconds left in the current session. `0` means none is running.
    public var sessionRemaining: TimeInterval

    /// The session is live *in this run* — ``SessionState/isLive``.
    ///
    /// Not in the task doc's `Snapshot`, and it has to be: without it `sessionRemaining >
    /// 0` cannot tell "counting down" from "waiting behind `Wznów`", and the app would
    /// charge a session whose own cover is on the screen (T04 finding, 2026-08-22).
    public var sessionLive: Bool

    /// A session was started and has not been re-offered — ``SessionState/wasRunning``.
    ///
    /// Also absent from the doc, and the discriminator for the whole `sessionRemaining ==
    /// 0` row: it is the difference between `Czas minął` and `Rozpocznij sesję`, and unlike
    /// ``sessionLive`` it survives a logout, which is exactly when the two are confused.
    public var sessionWasRunning: Bool

    /// Self-service starts today. PIN-granted sessions are deliberately not counted.
    public var sessionsUsedToday: Int

    /// A PIN-granted stand-down (§2.5). Compared against ``now``, never against a clock.
    public var disabledUntil: Date?

    /// A usable PIN exists — ``Config/isConfigured``, which is stricter than a non-empty
    /// hash: a malformed salt cannot verify anything, so it is not a PIN.
    public var hasPIN: Bool

    public init(now: Date,
                idleSeconds: TimeInterval = 0,
                screenLocked: Bool = false,
                sessionOnConsole: Bool = true,
                mediaPlaying: Bool = false,
                sessionRemaining: TimeInterval = 0,
                sessionLive: Bool = false,
                sessionWasRunning: Bool = false,
                sessionsUsedToday: Int = 0,
                disabledUntil: Date? = nil,
                hasPIN: Bool = true) {
        self.now = now
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
        self.sessionOnConsole = sessionOnConsole
        self.mediaPlaying = mediaPlaying
        self.sessionRemaining = sessionRemaining
        self.sessionLive = sessionLive
        self.sessionWasRunning = sessionWasRunning
        self.sessionsUsedToday = sessionsUsedToday
        self.disabledUntil = disabledUntil
        self.hasPIN = hasPIN
    }

    /// Fill the state half from the ledger, leaving the sensor half alone.
    ///
    /// One place where the mapping lives, so a caller cannot quietly read `sessionsUsedToday`
    /// off the wrong day key or take `hasPIN` from a hash without a salt. `RSTApp` builds a
    /// sensor snapshot each tick and calls this.
    ///
    /// **`state` must already have been reconciled or advanced to `now`** — its `dayKey` is
    /// what `sessionsUsedToday` is counted against, and a state loaded from yesterday's file
    /// reports yesterday's count (T04 finding, 2026-08-22). This function cannot check that:
    /// rolling the day over is a mutation, and a snapshot is a reading.
    public func applying(_ state: SessionState, _ config: Config) -> Snapshot {
        var copy = self
        copy.sessionRemaining = state.remainingSeconds
        copy.sessionLive = state.isLive
        copy.sessionWasRunning = state.wasRunning
        copy.sessionsUsedToday = state.sessionsUsedToday
        copy.disabledUntil = state.disabledUntil
        copy.hasPIN = config.isConfigured
        return copy
    }
}

/// What the app should be doing this tick (DESIGN §3.3).
///
/// `awaitingStart` and `awaitingResume` are distinct because they are different offers: one
/// consumes a session, the other returns time already granted. Collapsing them would make
/// the resume-after-logout rule impossible to express.
public enum Decision: Equatable, Sendable {
    /// Disabled until morning, or no PIN set. The app stands down entirely.
    case dormant
    /// No session; the cover offers `Rozpocznij`. `selfServiceLeft == 0` still shows a
    /// cover — only the text and the buttons differ.
    case awaitingStart(selfServiceLeft: Int)
    /// Time remains but nothing is running: the cover offers `Wznów`.
    case awaitingResume(remaining: TimeInterval)
    case allowed(remaining: TimeInterval)
    /// Inside a `warningMinutes` threshold. `threshold` is the one this tick falls into,
    /// reported again on every tick — de-duplication belongs to the enforcer (§2.4).
    case warning(remaining: TimeInterval, threshold: Int)
    /// The session ran out. The cover offers the PIN, or `Zablokuj ekran`.
    case expired(selfServiceLeft: Int)

    /// Does this decision put the cover on the screen?
    ///
    /// Here rather than in the enforcer because it is a property of the decision, and T10's
    /// menu bar needs the same answer T11's enforcer does. Note `.dormant` does **not**
    /// cover — that is §2.5's derived rule, and the reason it is not `.allowed` is only
    /// that a stood-down app has no countdown to show.
    public var coversScreen: Bool {
        switch self {
        case .dormant, .allowed, .warning: return false
        case .awaitingStart, .awaitingResume, .expired: return true
        }
    }

    /// Does the cover draw `Rozpocznij` for this decision?
    ///
    /// **The daily cap lives here and nowhere else.** ``SessionState/startSelfService(_:)``
    /// is ungated on purpose, and ``decide(_:_:)`` does not refuse either — it reports
    /// `.awaitingStart(selfServiceLeft: 0)` like any other state, because whether the button
    /// is offered is a question about the cover. So a `Rozpocznij` wired without consulting
    /// this property deletes the one limit the app enforces for itself, and no test below
    /// this layer would fail (found reviewing T05, 2026-08-22).
    ///
    /// A property beside ``coversScreen`` rather than a count re-derived in `RSTApp`: the
    /// rule then lives in the one layer this project can test headless, and the cover can
    /// only get it wrong by ignoring it outright.
    ///
    /// `.awaitingStart(0)` is reachable without a session having run — `self_service_sessions_per_day: 0`
    /// is a supported setting meaning *every* session needs the PIN, and it produces that
    /// case from the very first tick.
    public var offersSelfServiceStart: Bool {
        guard case .awaitingStart(let left) = self else { return false }
        return left > 0
    }

    /// Seconds left on the session this decision saw, or `nil` where there is no session.
    public var remainingSeconds: TimeInterval? {
        switch self {
        case .allowed(let remaining), .warning(let remaining, _), .awaitingResume(let remaining):
            return remaining
        case .dormant, .awaitingStart, .expired:
            return nil
        }
    }
}

/// **The heart of the app.** State in, decision out — no clock, no I/O, no side effects.
///
/// The order below is load-bearing: get it wrong and the app locks someone out with no way
/// back. Each step is numbered as T05's task doc numbers it.
public func decide(_ s: Snapshot, _ c: Config) -> Decision {

    // 1. No PIN, no cover — first and non-negotiable (§2.5). Not a general fail-open
    //    policy: a corrupt config is repaired and enforcement continues. This is the one
    //    case where blocking is a trap with no key, because nothing could then unlock it.
    guard s.hasPIN else { return .dormant }

    // 2. A stand-down beats every other rule (§2.5). Strictly greater: at the instant it
    //    expires the app is armed again, which is what makes the 06:00 re-arm exact.
    if let until = s.disabledUntil, until > s.now { return .dormant }

    // 3. Time on the clock. Live or not is the whole question — see `Snapshot.sessionLive`.
    if s.sessionRemaining > 0 {
        // 6. Paused: the app restarted, or he logged out and back in. He presses `Wznów`
        //    rather than finding the screen already counting down under him.
        guard s.sessionLive else { return .awaitingResume(remaining: s.sessionRemaining) }

        if let threshold = c.warningThreshold(for: s.sessionRemaining) {
            return .warning(remaining: s.sessionRemaining, threshold: threshold)
        }
        return .allowed(remaining: s.sessionRemaining)
    }

    // 4 and 5. Nothing left. `wasRunning` — not `sessionLive` — separates "it ran out" from
    //    "he has not started one", because only `wasRunning` survives the logout in between.
    //    A negative `sessionRemaining` cannot arise (`SessionState` floors at zero) but
    //    lands here rather than anywhere surprising if it ever does.
    let left = s.selfServiceLeft(c)
    return s.sessionWasRunning ? .expired(selfServiceLeft: left)
                               : .awaitingStart(selfServiceLeft: left)
}

public extension Snapshot {
    /// Sessions he can still start unaided. Mirrors ``SessionState/selfServiceLeft(_:)``,
    /// which computes the same rule from the state rather than from a snapshot of it.
    func selfServiceLeft(_ c: Config) -> Int {
        max(0, c.selfServiceLimit - sessionsUsedToday)
    }
}

// MARK: - Reading a config nobody validated

/// **Where the clamp lives: at the point of use, and this is the general answer.**
///
/// The question was left open at T02 and narrowed at T03 (`DayWindow.normalised(resetHour:)`
/// clamps the day boundary the same way); T05 inherits the rest of it, and answers it the
/// same way rather than making `Config` validate on load.
///
/// Why not validate on load. `config.json` is hand-edited — there is no Settings UI until
/// T17 — and a validating decoder would rewrite the parent's file on the next save, turning
/// `"session_minutes": 0` into `1` behind their back with no record that it happened. It
/// would also make a *decode* lossy, so the round-trip test that protects the file format
/// would have to be weakened. Clamping at the point of use keeps the file exactly as typed,
/// keeps every function total, and leaves the value visible for T17's Settings to reject
/// out loud, which is where a person can actually be told.
///
/// What must not happen is each caller inventing its own answer silently — so the readings
/// live here, in one place, next to the function that consumes them.
public extension Config {

    /// Self-service sessions a day, floored at zero. Zero is a legitimate setting: it means
    /// every session needs the PIN, which is a parent's decision, not an error.
    var selfServiceLimit: Int { max(0, selfServiceSessionsPerDay) }

    /// The warning minutes worth acting on: positive, deduplicated, ascending.
    ///
    /// A `0` or a negative would fire a warning at or after the moment the cover appears,
    /// which is `.expired`'s job and would speak over it. Duplicates are dropped so the
    /// array a parent typed twice does not make ``warningThreshold(for:)`` ambiguous.
    var warningThresholds: [Int] { Set(warningMinutes.filter { $0 > 0 }).sorted() }

    /// Which threshold `remaining` falls into, or `nil` if it is still above all of them.
    ///
    /// The **smallest** matching one, because thresholds nest: at four minutes left both
    /// 10 and 5 have passed, and the useful thing to say is "five", once, until one minute.
    /// Inclusive at the boundary — exactly 5:00 is the five-minute warning, not 4:59.
    func warningThreshold(for remaining: TimeInterval) -> Int? {
        warningThresholds.first { remaining <= Double($0) * 60 }
    }

    /// Does this threshold carry `Zapisz swoją grę.` — DESIGN §2.4's five-minute row, and
    /// the only warning that tells him to *do* anything.
    ///
    /// **Keyed to position, not to the number 5** (T14 review, at the user's direction).
    /// The instruction belongs where there is still time to act on it: the last warning is
    /// too late to start saving, and every warning above it would be nagging. That is the
    /// **second smallest**, which is 5 for the shipped `[10, 5, 1]` and stays right for
    /// `[15, 5, 1]` or a retuned `[20, 10, 2]` — where hard-coding 5 would silently drop it.
    ///
    /// A single-entry list carries it on its one threshold: that is the only notice there
    /// is, so the instruction has nowhere else to go.
    func warningSuggestsSaving(_ threshold: Int) -> Bool {
        let thresholds = warningThresholds
        guard let carrier = thresholds.count > 1 ? thresholds[1] : thresholds.first else {
            return false
        }
        return threshold == carrier
    }
}
