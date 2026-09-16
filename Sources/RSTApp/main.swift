import AppKit
import RSTCore

// The wiring, and nothing else: DESIGN §3.2 gives `main.swift` the flags, the single
// instance and the assembly of everything below it. The tick lives in `AppController`, the
// rules live in `RSTCore`.
//
// **All of it runs before `NSApplication.run()`, deliberately.** T00 established that
// `NSApplication` catches an exception raised in `applicationDidFinishLaunching`, logs it
// somewhere nobody looks, and keeps its run loop going — so a startup failure inside a
// delegate is a hang rather than a crash. Out here a failure is loud, and there is nothing
// left in the delegate to fail.

// MARK: - Flags

// The safety default, and the most important four lines in the target. `swift run` never
// covers the screen; the installed release .app always does. See CLAUDE.md.
#if DEBUG
let enforcementDefault = false
#else
let enforcementDefault = true
#endif

let flags = Flags.parse(ProcessInfo.processInfo.environment,
                        enforcementDefault: enforcementDefault)

/// Real time, or `RST_TIME_SCALE` simulated seconds per real one.
///
/// `SystemClock().now` for the origin rather than `Date()`: the one-call rule in
/// `Clock.swift` is what keeps an accelerated run honest, and this is the one place in
/// `RSTApp` that needs a starting instant.
let clock: any Clock = flags.timeScale == 1
    ? SystemClock()
    : ScaledClock(origin: SystemClock().now, scale: flags.timeScale)

/// `~/Library/Application Support/RealScreenTime`, or `RST_DATA_DIR`.
///
/// Resolved here rather than in `Flags`: expanding `~` reads `HOME`, and `RSTCore` asks the
/// system nothing.
func resolveDataDirectory(_ override: String?) -> URL {
    if let override {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("RealScreenTime", isDirectory: true)
}

let dataDirectory = resolveDataDirectory(flags.dataDirectory)

// MARK: - The files

let sink = FileEventSink(directory: dataDirectory, timeZone: .current)
let diagnostics = Diagnostics(sink)
let startedAt = clock.now

diagnostics("""
    launch: pid \(ProcessInfo.processInfo.processIdentifier), \
    \(flags.enforcing ? "ENFORCING" : "observer") mode, \
    data \(dataDirectory.path), time scale \(flags.timeScale)
    """, at: startedAt)

// A mistyped flag that silently does nothing is worse than one that refuses: the run looks
// exactly like the run that was asked for.
for warning in flags.warnings {
    diagnostics("flag ignored: \(warning)", at: startedAt)
    FileHandle.standardError.write(Data("RealScreenTime: \(warning)\n".utf8))
}

// MARK: - The seatbelt

// **Started here, before anything can cover anything.** T00 released its cover with a timer
// scheduled at the end of the cover routine and an early `return` above it skipped the
// timer while the windows were already up; the machine had to be power-cycled. Running the
// watcher from launch removes the ordering that failure depended on — there is nothing left
// to remember to arm. See `Seatbelt`.
let seatbelt = flags.maxCoverSeconds.map { limit in
    Seatbelt.start(limit: limit) { [diagnostics, clock] message in
        diagnostics(message, at: clock.now)
    }
}

// MARK: - The watchdog

// **The only automatic safety net in the app** (DESIGN §2.8, T15), and armed here for the
// same reason the seatbelt is: before anything exists that could cover anything. Unlike the
// seatbelt it is not a flag — every run has one, observer runs included, where it simply
// never sees a cover and therefore never fires.
let watchdog = Watchdog.start(stallSeconds: flags.watchdogSeconds,
                              sink: sink,
                              clock: clock) { [diagnostics, clock] message in
    diagnostics(message, at: clock.now)
}

// `RST_SEATBELT_SELFTEST=1`: prove the release path works without taking the screen.
//
// The same watcher, armed the same way, with no window and no `NSApplication` — so `make
// seatbelt` can check after every edit that the process really does exit on time. Nothing
// below this line runs in that mode, deliberately: a self-test that started the app would
// be testing the app.
if flags.seatbeltSelfTest {
    guard let seatbelt else {
        FileHandle.standardError.write(Data(
            "RealScreenTime: \(Flags.Name.seatbeltSelfTest)=1 needs \(Flags.Name.maxCoverSeconds)\n".utf8))
        exit(2)
    }
    // **The release path is exercised here too, and exercised failing.** The loop below
    // parks the main thread with no run loop at all, so the `DispatchQueue.main.async` the
    // watcher makes can never run — which is precisely the wedge this class exists for.
    // What `make seatbelt` then measures is that asking does not *hold* the exit: the
    // process still goes, two seconds late rather than never.
    seatbelt.onRelease {
        // If this ever runs, the assumption above is wrong and the self-test is no longer
        // testing what it says it tests. Better said out loud than passed quietly.
        FileHandle.standardError.write(Data(
            "RealScreenTime: self-test — the release ran; the main thread was not parked\n".utf8))
    }
    print("RealScreenTime: seatbelt self-test — no windows, expecting exit in "
          + "\(Int(flags.maxCoverSeconds ?? 0)) s plus the release grace")
    seatbelt.coverBegan()
    // Park. The watcher thread is what ends this process, and if it does not, the harness
    // around this mode reports exactly the failure the mode exists to catch.
    while true { Thread.sleep(forTimeInterval: 3600) }
}

// `RST_WATCHDOG_SELFTEST=1`: prove the hang detector works without hanging a real app.
//
// The seatbelt self-test's twin, and it measures the one thing `make test` cannot reach —
// that the watcher thread really does outlive a main thread that has stopped answering, and
// really does write `watchdog_exit` before it goes. No window, no `NSApplication`, nothing
// below this line.
if flags.watchdogSelfTest {
    print("RealScreenTime: watchdog self-test — no windows, main thread about to park, "
          + "expecting exit in \(Int(flags.watchdogSeconds)) s")
    // Exactly what `CoverController` says as the first window goes up, and then the wedge
    // that would leave that window standing for ever.
    watchdog.coverBegan()
    while true { Thread.sleep(forTimeInterval: 3600) }
}

if flags.enforcing {
    // Resolved at startup, never at click time, so the cover's button can be labelled from
    // what was actually found (DESIGN §2.6).
    ScreenLock.resolve(diagnostics, at: startedAt)

    if seatbelt == nil {
        // Not a refusal: the installed release .app enforces with no seatbelt by design,
        // and that is the shipping configuration. A development run without one is what
        // CLAUDE.md tells a session never to start, so it is worth one loud line.
        let bare = "enforcing with no \(Flags.Name.maxCoverSeconds) — nothing will take the cover down"
        diagnostics(bare, at: startedAt)
        FileHandle.standardError.write(Data("RealScreenTime: \(bare)\n".utf8))
    }
}

// MARK: - One instance

// Held for the life of the process; `flock` is released by the kernel when it exits.
let instanceLock: InstanceLock?
switch InstanceLock.acquire(at: dataDirectory.appendingPathComponent("instance.lock")) {
case .acquired(let lock):
    instanceLock = lock
case .alreadyRunning:
    diagnostics("another instance holds the lock — exiting", at: startedAt)
    print("RealScreenTime: already running")
    exit(0)
case .unavailable(let reason):
    // Enforcement is not given up over a lock file. See `InstanceLock.Outcome`.
    instanceLock = nil
    diagnostics("single-instance lock unavailable, continuing unprotected: \(reason)",
                at: startedAt)
}
_ = instanceLock

// MARK: - State

let configStore = ConfigStore(directory: dataDirectory)
let configLoad = configStore.load()
if case .reset(let backup) = configLoad.outcome {
    // DESIGN §3.5: the file was unparseable, has been moved aside and replaced with shipped
    // defaults. `RSTCore` returned the outcome rather than logging it because it has no
    // clock — this is the caller that does (T02).
    sink.append(Event(.configReset, at: startedAt,
                      backup.map { [.backup: .string($0.path)] } ?? [:]))
}

let sessionStore = SessionStore(directory: dataDirectory)
let sessionLoad = sessionStore.load()
if case .reset(let backup) = sessionLoad.outcome {
    // §3.5 makes an unparseable ledger an unexplained gap, and `Engine` cannot notice this
    // one: the replacement state has no heartbeat at all, so `classify` sees a boot inside
    // the gap and returns `.rebooted`. Written here or not at all.
    //
    // `seconds: 0` is the charge, not the length. How long the app was away died with the
    // heartbeat, and 0 is the honest number for what it cost — the session itself is gone,
    // which is the part that actually hurt. Zero rather than omitted so that summing the
    // field across the log stays arithmetic.
    var fields: [Event.Field: EventValue] = [.seconds: .number(0)]
    if let backup { fields[.backup] = .string(backup.path) }
    sink.append(Event(.tamperGap, at: startedAt, fields))
}

if !configLoad.config.isConfigured {
    // §2.5's first rule: with no PIN nothing may cover the screen, because nothing could
    // then uncover it. `decide` returns `.dormant` all day. T16's wizard opens by itself
    // further down and is what ends this state.
    let notice = "no PIN configured — standing down until the first-run wizard is answered"
    diagnostics(notice, at: startedAt)

    // **On stderr too, but only when enforcing** (T13, 2026-08-25). An observer run stands
    // down quietly because that is what an observer run does. An enforcing run that stands
    // down looks *identical to a broken app*: the command was typed, the process is alive,
    // the menu bar is there, and nothing ever covers anything. That cost the user a
    // verification run, and the answer was already sitting in `app.log` where nobody was
    // looking. Same shape as the bare-seatbelt line below.
    if flags.enforcing {
        FileHandle.standardError.write(Data("RealScreenTime: \(notice)\n".utf8))
    }
}

let bootTime = systemBootTime()
if bootTime == nil {
    // Erring towards charging: an unknown boot time makes every gap `.unexplained`, which
    // costs the child time he may not owe. The alternative — pretending the machine booted
    // just now — makes every gap free and is a bypass anyone could reach by breaking
    // `sysctl`. `kern.boottime` has been in every BSD for thirty years; if this line ever
    // appears in `app.log`, something much larger is wrong.
    diagnostics("kern.boottime unreadable — gaps will be charged in full", at: startedAt)
}

// MARK: - Assembly

// The cover, or the log of the cover that would have been. One of the two, chosen once:
// everything destructive in T11 — taking the screen, quitting a fullscreen app, locking —
// lives inside `CoverEnforcer`, so a debug run cannot reach any of it (DESIGN §2.6.2).
// T12's app-global lockdown, and the app delegate — the same object, because the only
// question the delegate answers is one this type already holds (`isCovering`). Built
// unconditionally and cheaply: it touches `NSApp` for the first time inside `engage`, which
// only an enforcing run can reach, so an observer run assembles it and never locks anything.
let kiosk = KioskLock(clock: clock, diagnostics: diagnostics)

let coverEnforcer: CoverEnforcer? = flags.enforcing
    ? CoverEnforcer(frame: flags.coverFrame, clock: clock, seatbelt: seatbelt,
                    watchdog: watchdog, kiosk: kiosk, sink: sink, diagnostics: diagnostics)
    : nil

// `RST_STALL_SECONDS` — T15's manual test, and the one flag in this file that exists to
// make the app fail. Only an enforcing debug run can reach it: there is no cover to park
// under otherwise, and a release build says so rather than ignoring it quietly.
#if DEBUG
if let stall = flags.stallSeconds {
    coverEnforcer?.stallSeconds = stall
    if coverEnforcer == nil {
        diagnostics("\(Flags.Name.stallSeconds) set but this run does not enforce — nothing will be parked",
                    at: startedAt)
    }
}
#else
if flags.stallSeconds != nil {
    let ignored = "\(Flags.Name.stallSeconds) is a debug-build flag — ignored"
    diagnostics(ignored, at: startedAt)
    FileHandle.standardError.write(Data("RealScreenTime: \(ignored)\n".utf8))
}
#endif

let engine = Engine(state: sessionLoad.state,
                    config: configLoad.config,
                    sink: sink,
                    enforcer: coverEnforcer ?? ObserverEnforcer(sink: sink, diagnostics: diagnostics),
                    // The one system query `RSTCore` needs and cannot make: the day
                    // boundary, the DST arithmetic and the log's UTC offset all come from
                    // here (T03).
                    calendar: .current)

// Before the status item, and that ordering is the reason these two lines moved up from
// the run section: `NSStatusBar.system` needs an `NSApplication` to exist, and asking for
// one it has not got is not a diagnosable failure — it is an empty menu bar.
let app = NSApplication.shared
// Menu-bar app: no Dock icon, no menu bar of its own. It switches to `.regular` only while
// covering, because presentation options require it (T12).
app.setActivationPolicy(.accessory)
// `delegate` is weak; `kiosk` is a top-level binding, so it outlives the process's interest
// in it. Set before `run()` like everything else in this file, and the delegate implements
// exactly one method — an `applicationDidFinishLaunching` that failed would be a hang
// rather than a crash, so there is deliberately nothing in there to fail.
app.delegate = kiosk

// T10. Held for the life of the process — a status item whose owner goes away takes the
// icon with it and says nothing about why.
let menuBar = MenuBarController(clock: clock, diagnostics: diagnostics)

let controller = AppController(clock: clock,
                               engine: engine,
                               sensors: SystemSensors(clock: clock, diagnostics: diagnostics),
                               store: sessionStore,
                               diagnostics: diagnostics,
                               bootTime: bootTime ?? .distantPast,
                               menuBar: menuBar,
                               kiosk: kiosk,
                               watchdog: watchdog)

// **What the seatbelt hands back before it exits** (T12). The T00 spike released in two
// places — a main-thread clear of `presentationOptions`, and a detached backstop two
// seconds behind it — and until T12 the app needed only the backstop, because windows die
// with the process. Presentation options are app-global state that very probably dies with
// it too, and "very probably" is not good enough for a Mac with no Dock and no menu bar.
//
// Wired here rather than at `Seatbelt.start` because the seatbelt is armed at launch,
// before `NSApplication` and before the kiosk lock exist. Nothing may be required to happen
// before the watcher starts.
seatbelt?.onRelease { [kiosk, clock] in
    MainActor.assumeIsolated { kiosk.surrender(at: clock.now) }
}

// The two references the enforcer cannot be built with: `Engine.init` takes the enforcer,
// and the tick is built after both. `refresh` runs a tick the moment a button is pressed,
// so `Rozpocznij` lifts the cover now rather than within the second.
coverEnforcer?.engine = engine
coverEnforcer?.refresh = { [weak controller] in controller?.tick() }

// T13's other host. The cover builds its own prompt inside its own window; the menu bar has
// no window to build one in, so it opens a panel — see `PINPanel`. Both hand the answer to
// the same `GrantCommand`, which is the only thing that touches the engine.
//
// `engine.config` is read at each attempt rather than captured, so a PIN changed in Settings
// (T17) is the one the prompt checks.
menuBar.onPINAction = { [weak controller] action in
    PINPanel.present(action: action,
                     config: { engine.config },
                     clock: clock,
                     diagnostics: diagnostics) { outcome in
        // T17's `Ustawienia…` is the one that opens a window instead of moving the ledger.
        // The prompt is the same prompt — one PIN path, one rate limit — and only the answer
        // differs, so the window is opened here rather than inside `GrantCommand`.
        //
        // **One hop, and it is not decoration.** This closure runs *inside* `PINPanel.close`,
        // between that panel being ordered out and it letting go of the keyboard, and a
        // window opened there came up with a Dock icon and nothing on the screen — seen by
        // hand on 2026-08-27. Two windows cannot fight over becoming key in the same turn of
        // the run loop; the same one-hop the cover and the wizard already use for the same
        // reason. See `SettingsWindow.init`'s breadcrumbs if it ever does it again.
        if case .unlocked = outcome, action == .settings {
            DispatchQueue.main.async { MainActor.assumeIsolated { openSettings() } }
            return
        }
        GrantCommand(engine: engine, clock: clock, diagnostics: diagnostics,
                     refresh: { controller?.tick() }).apply(outcome)
    }
}

// MARK: - Settings

/// **Every setting that exists, behind the PIN** (T17).
///
/// The same shape as the wizard below it: the window edits a draft, hands it back, and this
/// closure owns the store, the engine and the tick. Nothing in `Settings.swift` writes a
/// file.
@MainActor func openSettings() {
    SettingsWindow.present(
        host: SettingsWindow.Host(
            config: { engine.config },
            // Only for the note under the session-length field: a running session keeps the
            // minutes it was granted, and the window says so rather than letting a parent
            // find out.
            sessionRunning: { engine.state.isLive },
            saveSettings: { draft in
                let updated = engine.config.applying(draft)
                return commitConfig(updated)
            },
            savePIN: { hash, salt in
                commitConfig(engine.config.changingPIN(hash: hash, salt: salt))
            },
            eventsURL: sink.url,
            dataDirectory: dataDirectory,
            uninstall: { deleteData in uninstall(deleteData: deleteData) },
            // The whole §2.3 update flow runs here rather than in the window, because a
            // successful install ends by relaunching — and the clean-exit marker that keeps
            // that gap from being charged is `controller`'s, which lives on this side. The
            // window shows whatever outcome comes back; on `.updating` this never returns.
            update: {
                let outcome = await Updater.runUpdate(clock: clock, diagnostics: diagnostics)
                if case .updating = outcome { relaunchAfterUpdate() }
                return outcome
            },
            // The window must not put the activation policy back to `.accessory` while the
            // kiosk owns it (T12) — a session can expire while Settings is open.
            isCovering: { kiosk.isCovering }),
        clock: clock,
        diagnostics: diagnostics)
}

/// Write a changed config, log what moved, and make it true now rather than within the
/// second. `nil` on success, a message for the window otherwise.
///
/// **Stamped with the decision and written after the save**, which is the one place this
/// departs from CLAUDE.md's event-before-action rule.
///
/// That rule exists because the cover blocks until a PIN arrives — possibly for hours — so a
/// line written afterwards would be misdated and lost outright if the process were killed
/// meanwhile. Neither applies to a file write that takes a millisecond, and writing first
/// here buys a worse failure than it prevents: a save that throws would leave the log
/// claiming a change that never reached disk, in the one file that is read months later *as
/// evidence*. `now` is captured before the write, so the timestamp is still the decision's.
@MainActor func commitConfig(_ updated: Config) -> String? {
    let now = clock.now
    let changes = engine.config.changes(to: updated)
    guard !changes.isEmpty else { return nil }

    do {
        try configStore.save(updated)
    } catch {
        diagnostics("settings: could not save — \(error.localizedDescription)", at: now)
        return "\(configStore.url.path) could not be written — \(error.localizedDescription)"
    }
    sink.append(Event(.configChanged, at: now, [.changed: .string(changes.joined(separator: ", "))]))
    engine.config = updated
    diagnostics("settings: saved — \(changes.joined(separator: ", "))", at: now)
    // No restart and nothing to apply: `decide` reads the config every tick, and this is
    // that tick happening now instead of within the second.
    controller.tick()
    return nil
}

/// **Take the app off the machine** (T17, T16's uninstall note).
///
/// The order matters and is the whole of the care here: the LaunchAgent goes *before* the
/// process does, or `KeepAlive` restarts the app the parent has just uninstalled.
@MainActor func uninstall(deleteData: Bool) {
    let now = clock.now
    let outcome = Uninstaller.run(dataDirectory: dataDirectory, deleteData: deleteData,
                                  diagnostics: diagnostics, at: now)

    // **Not `NSApp.terminate`.** `KioskLock` refuses every `terminate(_:)` while the cover is
    // up (T12), and a session can expire while Settings is open — an uninstall that could
    // not quit would leave a running app with no way left to reach its own menu. Surrender
    // the screen and go.
    kiosk.surrender(at: now)

    if outcome.dataRemoved {
        // Nothing to write the clean-exit marker *into*, and writing one would recreate the
        // directory that was just deleted — `SessionStore.save` makes its own.
        exit(0)
    }
    // Kept data: mark the exit expected, so a reinstall does not charge this as a gap.
    controller.markExpectedExit("uninstall")
    exit(0)
}

/// **Relaunch into a freshly installed build** (T04, DESIGN §2.3 step 5).
///
/// The updater has already backed up and swapped the bundle in `/Applications`; all that is
/// left is to hand off to the new binary. **`exit(0)` and let `KeepAlive` do it**, rather than
/// `open`ing the new app first: a second instance started while this one still holds the
/// `InstanceLock` exits quietly (``InstanceLock/Outcome/alreadyRunning``), so `open` would race
/// and very likely bounce. Exiting frees the lock, and `launchd` relaunches the installed path —
/// now the new binary — at once, since its 10 s restart throttle only bites a process that has
/// just started, and this one has been up since well before the update began.
///
/// **The gap is marked expected** so the second or two the screen is uncovered during relaunch
/// is not billed as screen time, and the screen is surrendered on the way out exactly as
/// ``uninstall(deleteData:)`` does — `KioskLock` refuses `NSApp.terminate` under a cover, but
/// `exit(0)` is the seatbelt's own route and always gives the screen back.
@MainActor func relaunchAfterUpdate() {
    let now = clock.now
    controller.markExpectedExit("update")
    kiosk.surrender(at: now)
    diagnostics("update: relaunching into the new build", at: now)
    exit(0)
}

// MARK: - First run

/// **The wizard, and the only thing that ends the stand-down logged above** (DESIGN §6, T16).
///
/// It writes `config.json` through the store this file owns, hands the result to the engine
/// and runs a tick, so the app is enforcing from the moment the last answer lands rather
/// than from the next launch.
@MainActor func openFirstRun() {
    FirstRunWindow.present(
        // Decides which step it opens on: an app that already has a PIN reopens straight
        // at the login item and cannot walk back to the PIN step (`firstRunEntryStep`).
        isConfigured: engine.config.isConfigured,
        // The already-saved limits, so a reopened wizard's terminal screen reports the real
        // settings and not the default 30/1 — the reopen path skips step 3 (T02 review).
        savedLimits: SessionLimits(minutes: engine.config.sessionMinutes,
                                   sessionsPerDay: engine.config.selfServiceSessionsPerDay),
        clock: clock,
        diagnostics: diagnostics,
        // The wizard takes a Dock icon while it is up, and must not take it back off while
        // the kiosk owns the activation policy (T12).
        isCovering: { kiosk.isCovering },
        save: { answers in
            // `applying` folds the four answers into the config already loaded, so a
            // hand-written file that was missing only its PIN keeps its own thresholds and
            // grant amounts (T16). Unknown keys survive too — that is `ConfigStore`'s.
            let updated = engine.config.applying(answers)
            do {
                try configStore.save(updated)
            } catch {
                return "\(configStore.url.path) could not be written — \(error.localizedDescription)"
            }
            engine.config = updated
            // Now, not within the second: `decide` has been returning `.dormant` all along
            // for want of a PIN, and this is the tick that stops it.
            controller.tick()
            return nil
        },
        onClose: {
            // A wizard closed half-way leaves the app exactly as it was; one closed after
            // step 3 leaves it configured. The tick is what makes the menu bar say which.
            controller.tick()
        })
}

// MARK: - Run

controller.start()

print("""
    RealScreenTime: \(flags.enforcing ? "enforcing" : "observer") mode, \
    ticking every \(Int(AppController.tickInterval))s
      state:  \(dataDirectory.path)
      events: \(sink.url.path)
      log:    \(sink.diagnosticsURL.path)
    """)

// **After the app has finished launching — and that is stricter than it sounds.**
//
// This used to be a `DispatchQueue.main.async` queued from here, which runs on the first
// pass of the run loop. In a bundled `LSUIElement` app that is too early, and the failure is
// silent: verified on the installed `.app` on 2026-08-26, started by `launchd` the setup
// window came up **empty**, and opened from Finder it **never appeared at all**. `app.log`
// said `wizard opened` both times, so the window was built and the system simply declined to
// show it. The identical code under `swift run` — not a bundle, none of this machinery — had
// drawn correctly twice, which is exactly the trap CLAUDE.md warns about.
if !engine.config.isConfigured {
    NotificationCenter.default.addObserver(
        forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { openFirstRun() }
    }

    // A backstop, because a first run that shows nothing is indistinguishable from a broken
    // app and there is no second chance to make the impression. `present` already refuses to
    // open a second window, so this costs nothing when the notification did its job.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        MainActor.assumeIsolated {
            guard !FirstRunWindow.isShowing, !engine.config.isConfigured else { return }
            diagnostics("first run: no wizard two seconds after launch — opening it anyway",
                        at: clock.now)
            openFirstRun()
        }
    }
}

app.run()
