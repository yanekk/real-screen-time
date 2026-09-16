import Foundation

/// **The rule the hang watchdog follows** — DESIGN §2.8, T15.
///
/// A crashed app cannot leave the screen covered: windows belong to processes, and the
/// window server destroys them in the same instant the process dies. The failure that can
/// strand someone is a **hang** — main thread deadlocked, cover still drawn, PIN field
/// answering nothing. This type holds the arithmetic that decides one has happened; the
/// thread that survives the hang, and the `exit(0)` that ends it, are `RSTApp`'s
/// ``Watchdog``.
///
/// **The split is the boundary rule, not decoration.** A detached thread and a process exit
/// are system calls and `RSTCore` makes none — but "thirty silent seconds under a cover" is
/// a *rule*, and a rule left in `RSTApp` on this machine is a rule that can only be checked
/// by hanging a real app in front of a real screen.
///
/// Two properties matter and both are deliberate:
///
/// - **Only fires while a cover is up.** A hang with nothing covered is a bug to
///   investigate, not a reason to kill a process that is harming nobody.
/// - **Real seconds, always.** The caller feeds it a monotonic interval, never `Clock.now`:
///   thirty seconds is thirty seconds for the person at the keyboard, and an accelerated
///   run that shortened the only automatic safety net by sixty would be a safety net that
///   is not there. Same judgement as ``Flags/maxCoverSeconds``' seatbelt.
public struct WatchdogModel: Equatable, Sendable {

    /// What the watchdog does next.
    public enum Verdict: Equatable, Sendable {
        case keepWatching
        /// Write `watchdog_exit` with these numbers, then leave. `coveredSeconds` is the
        /// event's `covered_s`; `stalledSeconds` is how long the main thread has been
        /// silent, which goes in `app.log` beside it.
        case leave(coveredSeconds: TimeInterval, stalledSeconds: TimeInterval)
    }

    /// DESIGN §2.8's thirty seconds. Long enough that a slow tick is not a kill, short
    /// enough that a hang is a blink rather than an afternoon.
    public static let defaultStallSeconds: TimeInterval = 30

    /// **Never below a second.** A sub-second watchdog would fire on an ordinary
    /// scheduling hiccup — the tick is a one-second timer with a 200 ms tolerance, so any
    /// threshold near it kills a perfectly healthy app.
    public static let minimumStallSeconds: TimeInterval = 1

    public let stallSeconds: TimeInterval

    /// Whether a cover is on the screen right now.
    public private(set) var covering: Bool = false
    /// How long since the main thread last said anything.
    public private(set) var stalledSeconds: TimeInterval = 0
    /// How long the current cover has been up, or 0 when nothing is covered.
    public private(set) var coveredSeconds: TimeInterval = 0

    public init(stallSeconds: TimeInterval = defaultStallSeconds) {
        self.stallSeconds = stallSeconds.isFinite
            ? max(Self.minimumStallSeconds, stallSeconds)
            : Self.defaultStallSeconds
    }

    /// **The main thread is alive.** Called from the tick, once a second (T08).
    public mutating func pet() {
        stalledSeconds = 0
    }

    /// A cover has gone up. Call **before the first window is shown**, as the seatbelt's
    /// `coverBegan` is called — between the two statements is the only interval in which a
    /// wedge would leave a cover the watchdog does not know about.
    ///
    /// It pets, and that is not a convenience: putting a cover up is the main thread doing
    /// work, so it is proof of life. Without it a run whose ticks had been suspended —
    /// `AppController` stops them across sleep — could carry a stale count into a cover
    /// built a moment ago and kill the process for it.
    public mutating func coverBegan() {
        covering = true
        coveredSeconds = 0
        pet()
    }

    /// The cover has come down of its own accord. Also proof of life, for the same reason.
    public mutating func coverEnded() {
        covering = false
        coveredSeconds = 0
        pet()
    }

    /// A second (or however long the watcher thread really slept) has passed.
    ///
    /// - Parameter seconds: monotonic elapsed time. A negative interval is read as zero —
    ///   nothing should hand one over, and a watchdog that could be wound *backwards* by a
    ///   clock correction is a watchdog with a bypass in it.
    public mutating func advance(by seconds: TimeInterval) -> Verdict {
        let elapsed = seconds.isFinite ? max(0, seconds) : 0
        stalledSeconds += elapsed
        if covering { coveredSeconds += elapsed }

        guard covering, stalledSeconds >= stallSeconds else { return .keepWatching }
        return .leave(coveredSeconds: coveredSeconds, stalledSeconds: stalledSeconds)
    }
}
