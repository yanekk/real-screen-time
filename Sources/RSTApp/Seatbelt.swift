import Foundation

/// **The thing that gives the screen back** — `RST_MAX_COVER_SECONDS`.
///
/// This is the most important class in the target and it is nine lines of logic, because
/// the failure it prevents cost a hard reboot on 2026-08-21. The spike released its cover
/// with an `NSTimer` scheduled at the *end* of the cover routine, and an early `return`
/// above that line left the windows up with nothing left alive to take them down.
///
/// So, three properties, each one a lesson from that afternoon:
///
/// - **A detached thread, not a timer.** It survives a wedged main run loop, an exception
///   `NSApplication` swallowed, and a code path that returned early.
/// - **Started before the first window exists.** It runs from launch whenever the flag is
///   set, so there is no ordering left to get wrong — nothing has to remember to arm it.
/// - **`exit(0)`, not a teardown.** A crashed app frees the screen; a hung one does not
///   (CLAUDE.md). Trying to clean up is how you end up hanging inside the cleanup.
///
/// It measures **real** seconds and ignores `RST_TIME_SCALE` deliberately: the seatbelt
/// exists for the person at the keyboard, and an accelerated run that shortened it by sixty
/// would be a seatbelt that is not there. `DispatchTime` rather than a `Date` — monotonic,
/// unmoved by a clock correction, and it keeps `Clock.swift`'s one-`Date()`-in-the-program
/// rule literally true.
final class Seatbelt: @unchecked Sendable {

    /// How often the watcher looks. Quarter-second granularity on a flag that is checked
    /// for tens of seconds costs nothing and keeps the overshoot invisible.
    private static let pollInterval: TimeInterval = 0.25

    /// How long the main thread gets to hand the machine back before the process is taken
    /// down regardless — **the T00 spike's two-stage shape, restored at T12**.
    ///
    /// The spike released in two places: a main-thread timer that cleared
    /// `presentationOptions` and exited, and this detached backstop two seconds behind it
    /// in case the first never ran. Until T12 the app needed only the backstop, because
    /// windows die with the process and there was nothing else to give back. Presentation
    /// options are app-global system state, and *probably* die with the process too — but
    /// "probably" is a Mac with no Dock and no menu bar until it is rebooted, so the
    /// graceful stage is worth two seconds.
    private static let releaseGrace: TimeInterval = 2

    private let limit: TimeInterval
    private let note: @Sendable (String) -> Void

    /// When the cover currently on the screen went up, or `nil` when nothing is covered.
    ///
    /// An `NSLock` around one integer rather than anything cleverer: the watcher thread
    /// reads it four times a second and the main thread writes it twice per cover, and the
    /// one thing this must never do is block on a main thread that has stopped answering.
    private let lock = NSLock()
    private var coveredSince: UInt64?

    /// What to hand back before exiting, run on the main thread. `nil` until `main.swift`
    /// wires the kiosk lock in, and `nil` for the whole of a run that never locks anything.
    private var release: (@Sendable () -> Void)?

    private init(limit: TimeInterval, note: @escaping @Sendable (String) -> Void) {
        self.limit = limit
        self.note = note
    }

    /// Start watching. Call once, at launch, before anything can cover anything.
    ///
    /// - Parameters:
    ///   - limit: seconds a cover may stay up — `RST_MAX_COVER_SECONDS`, already validated
    ///     positive and finite by ``Flags``.
    ///   - note: where to say what happened, on the way out. Called from the watcher
    ///     thread, so it must be safe there — `Diagnostics` writes one `O_APPEND` line.
    @discardableResult
    static func start(limit: TimeInterval, note: @escaping @Sendable (String) -> Void) -> Seatbelt {
        let seatbelt = Seatbelt(limit: limit, note: note)
        let thread = Thread { seatbelt.watch() }
        thread.name = "RealScreenTime.seatbelt"
        // Above the default so a busy main thread cannot starve the one thread whose job
        // is to survive a busy main thread.
        thread.qualityOfService = .userInitiated
        thread.start()
        return seatbelt
    }

    /// The cover has gone up — or is about to. **Call before the first window is shown**,
    /// never after: between these two statements is the only window in which a wedge would
    /// leave a cover the seatbelt does not know about.
    func coverBegan() {
        lock.withLock {
            guard coveredSince == nil else { return }   // already timing this cover
            coveredSince = DispatchTime.now().uptimeNanoseconds
        }
    }

    /// **What to give back on the way out**, called on the main queue and never waited on.
    ///
    /// Set after construction because the seatbelt is armed at launch — before the kiosk
    /// lock, before `NSApplication`, before anything it could hand back exists. That
    /// ordering is the point: nothing may be required to happen before the watcher starts.
    func onRelease(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { release = body }
    }

    /// The cover has come down of its own accord, so the countdown stops.
    ///
    /// Without this the app would exit `limit` seconds after the *first* cover of the run,
    /// including the case where the child pressed `Rozpocznij` two seconds in and is now
    /// happily inside a session — which would make every manual test of a session
    /// impossible. A wedge while nothing is covered leaves no cover on the screen, so
    /// there is nothing for the seatbelt to rescue.
    func coverEnded() {
        lock.withLock { coveredSince = nil }
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            let elapsed = lock.withLock { coveredSince }.map {
                Double(DispatchTime.now().uptimeNanoseconds &- $0) / 1e9
            }
            guard let elapsed, elapsed >= limit else { continue }
            note("seatbelt: cover up for \(Int(elapsed.rounded())) s, limit \(Int(limit)) s — exiting")

            // **Ask, then leave anyway.** The windows are not torn down — process death
            // frees the screen and a teardown is one more thing that can hang while the
            // screen is still covered. What is asked for is the app-global state that
            // might *not* die with the process: the presentation options (T12).
            //
            // `async`, never `sync`: a wedged main thread is the exact case this class
            // exists for, and waiting on one would turn the seatbelt into another thing
            // that hangs. If the ask never runs, the two seconds pass and the process goes
            // regardless — which is precisely the arrangement the T00 spike had, and the
            // arrangement whose absence cost a hard reboot on 2026-08-21.
            if let release = lock.withLock({ release }) {
                DispatchQueue.main.async { release() }
                Thread.sleep(forTimeInterval: Self.releaseGrace)
            }
            exit(0)
        }
    }
}
