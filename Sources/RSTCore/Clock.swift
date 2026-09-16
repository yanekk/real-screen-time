import Foundation

/// Time, injected.
///
/// Nothing in this app reads the wall clock directly. `RST_TIME_SCALE` compresses an
/// eight-hour day into eight minutes of manual testing, and the tests replay a whole day
/// in microseconds — both work only if every `now` in the program comes through here.
///
/// **The `Date` initialiser is called exactly once in this target — in `SystemClock`
/// below — and nowhere in `RSTApp`.** A single stray call makes an accelerated run
/// silently wrong in one place while everything around it still looks right, which is the
/// worst kind of wrong. The check is a literal grep of `Sources/` for a bare `Date`
/// initialiser, and it is worth keeping literal: exactly one hit, on the line below. If a
/// scaled run behaves oddly, run it before anything else.
public protocol Clock: Sendable {
    var now: Date { get }
}

/// The real clock, and the one place in the program allowed to construct a `Date` from
/// the system time.
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock the tests move by hand.
///
/// `@unchecked Sendable` with an `NSLock` rather than an actor: `Clock.now` is a
/// synchronous property that the policy code reads inline, and an actor would make every
/// caller async for the benefit of test-only mutation. The lock is three lines and keeps
/// the protocol honest.
public final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    public init(_ start: Date) {
        instant = start
    }

    public var now: Date {
        get { lock.withLock { instant } }
        set { lock.withLock { instant = newValue } }
    }

    /// Moves `now` forward (or back, with a negative interval) and touches nothing else.
    public func advance(_ interval: TimeInterval) {
        lock.withLock { instant += interval }
    }
}

/// Accelerated time for manual testing: `RST_TIME_SCALE=60` makes one real second pass as
/// one simulated minute.
///
/// The wall-clock source is injected rather than read directly, so the scaling
/// itself is testable without sleeping — a test that proves "60× after one real second"
/// by waiting one real second is a test nobody runs twice.
public struct ScaledClock: Clock {
    private let origin: Date
    private let wallOrigin: Date
    private let scale: Double
    private let wall: any Clock

    /// - Parameters:
    ///   - origin: the simulated time at the moment of construction.
    ///   - scale: simulated seconds per real second. Must be > 0.
    ///   - wall: the real clock underneath. Injectable for tests only.
    public init(origin: Date, scale: Double, wall: any Clock = SystemClock()) {
        precondition(scale > 0, "RST_TIME_SCALE must be positive, got \(scale)")
        self.origin = origin
        self.scale = scale
        self.wall = wall
        self.wallOrigin = wall.now
    }

    public var now: Date {
        origin.addingTimeInterval(wall.now.timeIntervalSince(wallOrigin) * scale)
    }
}
