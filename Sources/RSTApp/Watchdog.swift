import Foundation
import RSTCore

/// **The only automatic safety net in the app** — DESIGN §2.8, T15.
///
/// A crash frees the screen; a hang does not. If the main thread stops answering while a
/// cover is up, nothing left in the process can take the cover down, accept a PIN, or even
/// notice — so a background thread counts the silence and, at thirty seconds, ends the
/// process. `launchd` starts it again within seconds and the fresh instance re-decides. A
/// hang becomes a blink instead of a dead Mac.
///
/// The shape is ``Seatbelt``'s, and for the same three reasons, each one paid for on
/// 2026-08-21 when the T00 spike's `NSTimer` release was skipped and the machine had to be
/// power-cycled:
///
/// - **A detached thread, not a run-loop timer.** A timer cannot rescue a wedged run loop;
///   it is the thing that is wedged.
/// - **Started at launch**, before anything can cover anything, so there is no ordering
///   left to get wrong.
/// - **`exit(0)`, not a teardown.** Anything that needs the main thread will wedge on the
///   main thread. It does not ask ``KioskLock`` to hand the presentation options back
///   either: that ask runs on the main thread, and process death was measured releasing
///   them anyway (2026-08-24, findings log).
///
/// **It deliberately does not consult `applicationShouldTerminate`.** That method refuses
/// every quit while a cover is up (T12), and an escape hatch blockable by the thing it is
/// escaping is not an escape hatch. `exit(0)` bypasses it, as `SIGKILL` does.
///
/// **And it deliberately does not write the clean-exit marker.** A hang is an unexplained
/// gap and is charged in full, so that hanging the app is not a way to farm free time
/// (T15). The 2026-08-22 finding asked whether the watchdog should mark its own kill as
/// expected, since unlike a `SIGKILL` it knows the kill is its own; the task doc answers
/// no, and the asymmetry is the same one that makes killing the app pointless.
final class Watchdog: @unchecked Sendable {

    /// How often the watcher looks, and therefore the granularity of the count. One second,
    /// matching the tick it is watching for.
    private static let pollInterval: TimeInterval = 1

    /// The rule, in `RSTCore` where `make test` can reach it. Guarded by ``lock`` because
    /// the main thread pets it and the watcher thread advances it.
    private let lock = NSLock()
    private var model: WatchdogModel

    private let sink: any EventSink
    private let clock: any Clock
    private let note: @Sendable (String) -> Void

    private init(stallSeconds: TimeInterval,
                 sink: any EventSink,
                 clock: any Clock,
                 note: @escaping @Sendable (String) -> Void) {
        self.model = WatchdogModel(stallSeconds: stallSeconds)
        self.sink = sink
        self.clock = clock
        self.note = note
    }

    /// Start watching. Call once, at launch, before anything can cover anything.
    ///
    /// - Parameters:
    ///   - stallSeconds: seconds of main-thread silence under a cover before the process
    ///     goes. `RST_WATCHDOG_SECONDS`, or DESIGN §2.8's thirty.
    ///   - sink: where `watchdog_exit` goes. Written from the watcher thread, which
    ///     `FileEventSink` is safe for — one `O_APPEND` write per line.
    ///   - clock: for the event's timestamp only. The count itself is monotonic and
    ///     ignores `RST_TIME_SCALE`; see ``WatchdogModel``.
    ///   - note: `app.log`, from the watcher thread.
    @discardableResult
    static func start(stallSeconds: TimeInterval,
                      sink: any EventSink,
                      clock: any Clock,
                      note: @escaping @Sendable (String) -> Void) -> Watchdog {
        let watchdog = Watchdog(stallSeconds: stallSeconds, sink: sink, clock: clock, note: note)
        let thread = Thread { watchdog.watch() }
        thread.name = "RealScreenTime.watchdog"
        // Above the default, like the seatbelt's: the one thread whose job is to survive a
        // sick main thread must not be starved by it.
        thread.qualityOfService = .userInitiated
        thread.start()
        return watchdog
    }

    /// **The main thread is alive.** Called at the end of every tick — at the *end*, so a
    /// wedge inside the tick itself is silence rather than a heartbeat.
    func pet() {
        lock.withLock { model.pet() }
    }

    /// A cover is going up. Called beside ``Seatbelt/coverBegan()``, before the windows.
    func coverBegan() {
        lock.withLock { model.coverBegan() }
    }

    /// The cover has come down.
    func coverEnded() {
        lock.withLock { model.coverEnded() }
    }

    /// What the thread does for the life of the process.
    private func watch() {
        // Monotonic, and measured rather than assumed: `Thread.sleep` guarantees a floor,
        // not a period, and a loaded machine can hand back two seconds for one. Counting
        // iterations would make the threshold "30 sleeps", which is at least 30 seconds and
        // possibly rather more. `DispatchTime` also stands still across system sleep, which
        // is exactly right here — the main thread is not ticking then either, by design.
        var last = DispatchTime.now().uptimeNanoseconds

        while true {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now &- last) / 1e9
            last = now

            let verdict = lock.withLock { model.advance(by: elapsed) }
            guard case .leave(let covered, let stalled) = verdict else { continue }

            // **The event before the exit**, and both from this thread. The main thread is
            // by definition not going to write it, and a line written after the action —
            // or not at all — is the case the log exists to record.
            sink.append(Event(.watchdogExit, at: clock.now,
                              [.coveredSeconds: .number(covered.rounded())]))
            note("watchdog: main thread silent for \(Int(stalled.rounded())) s "
                 + "with a cover up for \(Int(covered.rounded())) s — exiting")
            exit(0)
        }
    }
}
