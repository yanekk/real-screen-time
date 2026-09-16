import AppKit
import RSTCore

/// **The tick.** DESIGN §3.4's loop, with everything that is a *rule* delegated to
/// `RSTCore`'s `Engine` and everything that is a *system fact* kept here.
///
/// What is left on this side is genuinely platform-shaped and nothing else: a timer, a
/// sensor read, four notifications, two signals, and the decision about when to write
/// `session.json`. Every question about what the app should *do* is one `engine.tick(_:)`
/// away, where `make test` can reach it.
///
/// `@MainActor` throughout. `Engine` is deliberately not `Sendable` — it is driven from one
/// place — and this is that place; the timer and the notification blocks arrive `@Sendable`
/// and hop back with `MainActor.assumeIsolated`, which is what they already are, being
/// scheduled on the main queue.
@MainActor
final class AppController {

    /// One second, as DESIGN §3.4 says. Under `RST_TIME_SCALE` this stays one *real*
    /// second and the clock hands out more simulated ones — that is the whole mechanism.
    static let tickInterval: TimeInterval = 1
    /// Lets the system coalesce our wake-ups with other timers. A tick that lands 200 ms
    /// late costs nothing: every calculation is done from the clock, never from a count of
    /// ticks.
    static let tickTolerance: TimeInterval = 0.2
    /// DESIGN §2.3's heartbeat, and the bound on how much of a killed process's last
    /// moments goes uncharged.
    static let heartbeatInterval: TimeInterval = 15

    private let clock: any Clock
    private let engine: Engine
    private let sensors: any Sensing
    private let store: SessionStore
    private let diagnostics: Diagnostics
    /// T10's status item, or `nil` for a run with no menu bar. Optional rather than
    /// required because the controller is the tick and the tick is the thing worth being
    /// able to drive without a screen attached to it.
    private let menuBar: MenuBarController?
    /// The app-global lockdown, so the two exit routes this class owns can hand the machine
    /// back before they take it (T12). `nil` in tests, which lock nothing.
    private let kiosk: KioskLock?
    /// T15's hang detector. `nil` for a run assembled without one — nothing else in this
    /// class changes, which is the point: petting it is one line and forgetting to is a
    /// process killed thirty seconds into its first cover.
    private let watchdog: Watchdog?
    /// Read once. A wake from sleep is not a boot, and a reboot is not something this
    /// process lives through.
    private let bootTime: Date

    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []
    private var signalSources: [any DispatchSourceSignal] = []

    /// The last state actually written, and when. Together they are the answer to "has
    /// anything happened, and is the heartbeat due".
    private var savedState: SessionState?
    private var savedAt: Date = .distantPast

    /// When the running idle break began — the moment of the *last input*, not the moment
    /// the grace was crossed — or `nil` when there is no break running. Only ever read by
    /// ``narrateIdle(_:at:)``: the decision itself is `decide`'s, and this is the narration
    /// of it.
    private var idleBreakBegan: Date?

    init(clock: any Clock,
         engine: Engine,
         sensors: any Sensing,
         store: SessionStore,
         diagnostics: Diagnostics,
         bootTime: Date,
         menuBar: MenuBarController? = nil,
         kiosk: KioskLock? = nil,
         watchdog: Watchdog? = nil) {
        self.clock = clock
        self.engine = engine
        self.sensors = sensors
        self.store = store
        self.diagnostics = diagnostics
        self.bootTime = bootTime
        self.menuBar = menuBar
        self.kiosk = kiosk
        self.watchdog = watchdog
    }

    // MARK: - Lifecycle

    /// Close the books on however long the app was away, then start ticking.
    func start() {
        let now = clock.now
        let gap = engine.launch(at: now, bootTime: bootTime)
        diagnostics("launch: \(Self.describe(gap)), \(Int(engine.state.remainingSeconds.rounded())) s left",
                    at: now)

        // Immediately, and before the first timer fires: the heartbeat `launch` just
        // re-armed is the thing a kill in the next second would be measured against.
        persist(at: now, force: true)

        observeLifecycle()
        catchTerminationSignals()
        startTicking()

        // One tick now rather than in a second's time, so the log carries the decision this
        // launch arrived at rather than the one a second later — they differ exactly when
        // the gap just ended the session, which is the case worth reading.
        tick()
    }

    /// Invalidate the timer without touching the ledger. Used for sleep, where the next
    /// tick must not arrive before the wake has been reconciled.
    ///
    /// **T15's watchdog keeps counting through this, and that is the right bias.** The tick
    /// is the only thing that pets it, so a cover left standing while the system takes its
    /// time going to sleep is thirty seconds from a self-kill. From the watchdog's seat a
    /// main thread that has deliberately stopped speaking is indistinguishable from a wedged
    /// one — and if the sleep never arrives *because* the app is wedged, the kill is exactly
    /// right. The cost of the spurious case is bounded: `markExpectedExit` has already run at
    /// every call site above, so the gap is charged nothing and `launchd` starts a fresh
    /// instance. The cost of the missed case is the Mac. Do not disarm it here.
    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Self.tickTolerance
        // `.common`, not the default mode: from T10 there is a menu, and a run loop tracking
        // an open menu leaves the default mode entirely. A countdown that stops whenever the
        // menu is open — and a ledger that stops with it — is a bug worth one word here.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - One tick

    /// Read the world, hand it to the engine, write the ledger if it is due.
    ///
    /// The state half of the `Snapshot` is deliberately left empty here: `Engine.tick`
    /// advances the ledger to `now` and then calls `Snapshot.applying(_:_:)` itself, which
    /// is the only ordering that satisfies that method's obligation — the day key it counts
    /// sessions against has to have been rolled over first.
    func tick() {
        let now = clock.now
        let reading = sensors.read()
        engine.tick(Snapshot(now: now,
                             idleSeconds: reading.idleSeconds,
                             screenLocked: reading.screenLocked,
                             sessionOnConsole: reading.sessionOnConsole,
                             mediaPlaying: reading.mediaPlaying))
        narrateIdle(reading, at: now)
        persist(at: now)

        // Last, as DESIGN §3.4 draws it. The menu bar is a view of the tick that just
        // happened, so it reads `lastDecision` rather than being handed one — and it is
        // refreshed on *every* tick, including the ones where nothing changed, because
        // deciding whether anything changed is `MenuBarController.update(_:)`'s job and it
        // needs a model each second to answer with.
        menuBar?.update(MenuBarModel(decision: engine.lastDecision,
                                     sessionsUsedToday: engine.state.sessionsUsedToday,
                                     config: engine.config))

        // **Last of all, and that is the whole of T15's main-thread half.** The watchdog
        // counts the seconds since this line and ends the process at thirty of them while a
        // cover is up. Petting at the *end* rather than the start is deliberate: a tick that
        // wedges halfway through is silence, not a heartbeat, and it is exactly the tick
        // that would wedge — the sensor read, the engine, the cover.
        watchdog?.pet()
    }

    /// The lunch break, in words.
    ///
    /// T09's acceptance is that a day of observer mode produces a log matching what was
    /// actually done with the Mac, *including the pauses* — and a pause is otherwise
    /// invisible: `events.jsonl` records what the session did, never the ten quiet minutes
    /// when it stopped counting. Two lines per break, against `SystemSensors`' lines for
    /// the lock and the user switch.
    ///
    /// The grace is read from `engine.config` every tick rather than captured once, so a
    /// value changed in Settings (T17) narrates with the number actually in force, and it
    /// is clamped exactly as `Ledger.isActive` clamps it — the two must agree on the
    /// boundary or the log contradicts the ledger. `> grace` here is the precise complement
    /// of that method's `<= grace`. Idle is monotonic until the next input and then drops to
    /// zero, so there is no boundary to flap around.
    ///
    /// The break is measured from the **wall clock**, not from the idle counter: ticks stop
    /// while the Mac sleeps, so on waking, the counter's last value is whatever it read
    /// before the lid closed. Reporting that would call an overnight absence ten minutes —
    /// the one line in `app.log` a parent is most likely to read the next morning, and the
    /// exact thing T09 is judged on.
    private func narrateIdle(_ reading: SensorReading, at now: Date) {
        let grace = TimeInterval(max(0, engine.config.idleGraceSeconds))
        let idle = reading.idleSeconds > grace
        guard idle != (idleBreakBegan != nil) else { return }
        if idle {
            // Back-dated to the last input, so the resume line reports the whole break and
            // not just the part of it past the grace.
            idleBreakBegan = now.addingTimeInterval(-reading.idleSeconds)
            diagnostics("no input for \(Int((grace / 60).rounded())) min — "
                        + "the session stops counting unless something is playing", at: now)
        } else {
            let minutes = Int((now.timeIntervalSince(idleBreakBegan ?? now) / 60).rounded())
            idleBreakBegan = nil
            diagnostics("input resumed after \(minutes) min idle", at: now)
        }
    }

    // MARK: - Persistence

    /// `session.json` on every state change, and every 15 seconds regardless (DESIGN §3.5).
    ///
    /// "Every state change" cannot be `state != savedState`: `lastHeartbeat` moves on every
    /// tick, so that comparison is true every second and the file would be rewritten sixty
    /// times a minute for nothing. What matters is everything *except* the heartbeat, with
    /// the heartbeat itself carried by the 15-second floor.
    private func persist(at now: Date, force: Bool = false) {
        let state = engine.state
        // `now < savedAt` catches a clock stepped backwards — without it a correction of an
        // hour would suspend the heartbeat for an hour.
        let heartbeatDue = now.timeIntervalSince(savedAt) >= Self.heartbeatInterval || now < savedAt
        guard force || heartbeatDue || changedIgnoringHeartbeat(state) else { return }

        do {
            try store.save(state)
            savedState = state
            savedAt = now
        } catch {
            // The app keeps running. A ledger it cannot write is a ledger the next launch
            // reads as a gap, which is the design's answer to losing state — and stopping
            // enforcement over a failed write would be the wrong way round entirely.
            diagnostics("session.json save failed: \(error)", at: now)
        }
    }

    private func changedIgnoringHeartbeat(_ state: SessionState) -> Bool {
        guard var previous = savedState else { return true }
        var current = state
        previous.lastHeartbeat = .distantPast
        current.lastHeartbeat = .distantPast
        return previous != current
    }

    // MARK: - Going away

    /// Write the clean-exit marker (DESIGN §2.3).
    ///
    /// **The one write whose absence silently punishes an innocent shutdown**, so every
    /// route out of the process comes through here: quit, logout, shutdown, sleep, and a
    /// `SIGTERM` from `launchd`. What must *not* reach it is `SIGKILL`, and nothing can —
    /// that is the whole of the discriminator.
    func markExpectedExit(_ why: String) {
        let now = clock.now
        engine.expectedExit(at: now)
        persist(at: now, force: true)
        diagnostics("expected exit: \(why)", at: now)
    }

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter

        observe(NSApplication.willTerminateNotification, on: .default) { controller in
            controller.markExpectedExit("quit")
        }
        observe(NSWorkspace.willPowerOffNotification, on: workspace) { controller in
            controller.markExpectedExit("logout or shutdown")
        }
        observe(NSWorkspace.willSleepNotification, on: workspace) { controller in
            controller.markExpectedExit("sleep")
            // Stop the clock before the lid closes. Timers do not fire across sleep, but
            // the first one after the wake can beat `didWakeNotification` — and `advance`
            // charges the whole interval between two ticks, which would bill the night as
            // screen time. Reconciling the sleep is `didWake`'s job below.
            controller.stopTicking()
        }
        observe(NSWorkspace.didWakeNotification, on: workspace) { controller in
            controller.wake()
        }
    }

    /// A wake is a gap that happens without a launch (T04 finding, 2026-08-22), so it is
    /// reconciled exactly as a launch is. The clean-exit marker written on the way down
    /// makes it `.expected`, and nothing is charged.
    private func wake() {
        let now = clock.now
        let gap = engine.launch(at: now, bootTime: bootTime)
        diagnostics("wake: \(Self.describe(gap)), \(Int(engine.state.remainingSeconds.rounded())) s left",
                    at: now)
        persist(at: now, force: true)
        startTicking()
        tick()
    }

    /// A `Gap` in words. Its synthesised description reads
    /// `rebooted(charge: 111962.75804889202)`, which is a Swift value rather than a
    /// sentence — and `app.log` is the file a parent opens when they want to know what the
    /// app thought happened while it was away.
    private static func describe(_ gap: Gap) -> String {
        switch gap {
        case .none:
            return "no gap"
        case .expected(let seconds):
            return "gap \(Int(seconds.rounded())) s, clean exit, charged nothing"
        case .rebooted(let charge):
            return "gap across a reboot, charged \(Int(charge.rounded())) s since boot"
        case .unexplained(let seconds):
            return "unexplained gap, charged \(Int(seconds.rounded())) s in full"
        }
    }

    private func observe(_ name: Notification.Name,
                         on center: NotificationCenter,
                         _ handler: @escaping @MainActor (AppController) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(observer)
    }

    /// `SIGTERM` is how `launchd` stops a LaunchAgent at logout, and `SIGINT` is Ctrl-C in
    /// the terminal an observer run was started from. Neither delivers
    /// `willTerminateNotification`, and without this both would look like a kill and charge
    /// the child for a shutdown he had nothing to do with.
    ///
    /// A `DispatchSource` rather than a `signal()` handler: almost nothing is legal inside a
    /// real signal handler, and writing a file certainly is not. `SIG_IGN` first, because
    /// the default disposition would kill the process before the source ever ran.
    private func catchTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.markExpectedExit(number == SIGTERM ? "SIGTERM" : "SIGINT")
                    // Hand the Dock and the menu bar back before going. This runs on the
                    // main thread and is allowed to, unlike the seatbelt's version — but
                    // like it, nothing downstream may depend on it: `SIGKILL` and the T15
                    // watchdog both reach `exit` without passing here, so process death
                    // still has to do the real work (T12).
                    self?.kiosk?.surrender(at: self?.clock.now ?? .distantPast)
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
