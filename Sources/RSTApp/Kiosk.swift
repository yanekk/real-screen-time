import AppKit
import RSTCore

/// **The app-global lock that turns a cover into a cover you cannot get out of** —
/// DESIGN §2.6's presentation options, plus the two quit defences they do not provide.
///
/// Three separate mechanisms live here because macOS puts the escapes in three places:
///
/// - **Presentation options** stop `Cmd+Tab`, `Cmd+Opt+Esc`, Apple ▸ Log Out, `Cmd+H`,
///   Mission Control, the Dock and the menu bar. They are app-global, so they cannot be
///   scoped to one window and cannot be tested in a box — see ``engage(fullscreen:at:)``.
/// - **`applicationShouldTerminate`** refuses every `terminate(_:)`: `Cmd+Q`, the Dock's
///   Quit, AppleScript, another app asking politely. It sees no `SIGKILL`, and the
///   watchdog's `exit(0)` deliberately does not consult it (T15) — the escape hatch must
///   not be blockable by the thing it is escaping.
/// - **A local event monitor** swallows the quit chord before it becomes a `terminate(_:)`
///   at all. Kept *as well as* the delegate rather than instead of it, because the two see
///   different things: the monitor sees keystrokes only while this app is frontmost and
///   never sees a scripted quit; the delegate sees every quit but no keystroke.
///
/// **A raise here is a hang, not a crash.** `hideMenuBar`, `disableProcessSwitching`,
/// `disableForceQuit` and `disableSessionTermination` each raise when set without
/// `hideDock` (T00), and `NSApplication` catches exceptions thrown in its run loop, logs
/// them somewhere nobody looks, and carries on. So the whole set goes on in one assignment,
/// and it is read back and compared rather than assumed.
@MainActor
final class KioskLock: NSObject, NSApplicationDelegate {

    /// **Measured valid on macOS 26.5.1 by `spike/kiosk-probe/probe-options.sh`**, not
    /// inferred from documentation. Never build this up incrementally (DESIGN §2.6).
    static let options: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar,
        .disableProcessSwitching,     // Cmd+Tab
        .disableForceQuit,            // Cmd+Opt+Esc
        .disableSessionTermination,   // Apple ▸ Log Out / Restart / Shut Down
        .disableHideApplication,      // Cmd+H
        .disableAppleMenu,
    ]

    /// Chords swallowed at the monitor while the cover is up.
    ///
    /// `Cmd+Q` is the one the task names and the one T00 measured getting through the full
    /// option set. The other three cost nothing and close doors nobody has personally
    /// tested: `Cmd+W` closes a window, `Cmd+H` hides the app, `Cmd+M` miniaturises it —
    /// `disableHideApplication` covers the third only while the options are actually on,
    /// which is not the case for a windowed cover.
    private static let swallowed: Set<String> = ["q", "w", "h", "m"]

    private let clock: any Clock
    private let diagnostics: Diagnostics

    /// Whether a cover is on the screen. **The one thing `applicationShouldTerminate` asks**,
    /// and the reason this type and the app delegate are the same object: splitting them
    /// would mean publishing this flag to a second class that has no other use for it.
    private(set) var isCovering = false

    /// Whether the presentation options are currently ours. Separate from ``isCovering``
    /// because a windowed cover is covering without being locked down.
    private var locked = false

    /// Set once the process is on its way out. ``engage(fullscreen:at:)`` refuses afterwards.
    ///
    /// **The tick does not stop when the seatbelt fires**, and measuring that is the only
    /// reason this exists. From the L5 run of 2026-08-24: the watcher's hand-back landed at
    /// `07:38:24.278`, and the next ordinary tick put the whole option set straight back at
    /// `07:38:25.262` — one second before `exit(0)`. The cover windows are still up at that
    /// point, deliberately, so the tick is still deciding to cover and `engage` is still the
    /// right answer to that decision; what is wrong is doing it after the process has
    /// announced it is leaving. Without this latch the graceful release stage hands the
    /// machine back and then takes it again, which is worse than not having it: it reads as
    /// working in the log.
    private var surrendered = false

    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    /// Resigns since the last one that was written down, and when that was — on the
    /// monotonic clock, so an accelerated run does not turn the throttle into a flood.
    ///
    /// A fullscreen game reclaims focus unprompted and repeatedly (DESIGN §2.6.1 measured
    /// two resigns with no keystrokes at all), so one line per resign is a `app.log` nobody
    /// can read. One line per five seconds, carrying the count, keeps the signal.
    private var resignsSinceNote = 0
    private var lastResignNote: UInt64 = 0

    init(clock: any Clock, diagnostics: Diagnostics = .discarded) {
        self.clock = clock
        self.diagnostics = diagnostics
    }

    // MARK: - Up

    /// Lock the app down. Called on the tick that covers **and on every tick after it**.
    ///
    /// - Parameter fullscreen: whether the cover is the real one covering whole displays.
    ///   **`RST_COVER_FRAME` deliberately gets the quit defences and not the presentation
    ///   options.** The options are app-global — there is no such thing as a boxed kiosk —
    ///   so applying them for a 600×400 test window would take the Dock, the menu bar and
    ///   `Cmd+Tab` away from whoever is running the box, which is the exact safety the flag
    ///   exists to provide. The quit defences have a safe way out from a terminal (Ctrl+C
    ///   is a signal, not a `terminate(_:)`), so those stay on in both modes and can be
    ///   exercised without a scratch account.
    ///
    /// Idempotent by comparison, not by a flag: if something else changed
    /// `presentationOptions` underneath us, this is the tick that puts them back.
    func engage(fullscreen: Bool, at now: Date) {
        // Past the point of no return. See ``surrendered``.
        guard !surrendered else { return }

        if !isCovering {
            isCovering = true
            installMonitor()
            // Deliberately not the words "quit refused": that phrase belongs to
            // `applicationShouldTerminate`, where it means somebody actually tried. Two
            // lines that grep alike would turn arming into an attempt in the count.
            diagnostics("kiosk: armed — delegate and event monitor will refuse a quit while covering",
                        at: now)
        }

        if fullscreen, !locked {
            // Presentation options require `.regular`; the app runs `.accessory` for its
            // menu bar (DESIGN §2.6). **Before activating**, because changing the policy is
            // itself capable of dropping the app out of frontmost, and frontmost is the
            // condition the options need. The status item is expected to survive the round
            // trip — that is on the L5 checklist, because nothing here can see it.
            NSApp.setActivationPolicy(.regular)
            observeResign()
            locked = true
        }

        // **In both modes.** A borderless window can only take the keyboard if the app is
        // active at all (T11), and presentation options only hold while it is frontmost
        // (T00) — the same call answers both, which is why it is above the split.
        NSApp.activate()

        guard fullscreen else { return }
        guard NSApp.presentationOptions != Self.options else { return }
        NSApp.presentationOptions = Self.options

        // Read back and compare. A set that did not take is a machine the child can
        // `Cmd+Tab` out of, and there is no other way to find out: an invalid set raises
        // into a run loop that swallows it.
        let readback = NSApp.presentationOptions
        if readback == Self.options {
            diagnostics("kiosk: presentation options applied (raw \(Self.options.rawValue))", at: now)
        } else {
            let complaint = "kiosk: presentation options DID NOT TAKE — "
                + "asked \(Self.options.rawValue), got \(readback.rawValue)"
            diagnostics(complaint, at: now)
            FileHandle.standardError.write(Data("RealScreenTime: \(complaint)\n".utf8))
        }
    }

    // MARK: - Down

    /// Give the machine back. **Called before the windows are dropped**, deliberately: a
    /// Mac left with no Dock, no menu bar and no cover is a Mac with no explanation, and
    /// the order that guarantees it cannot happen is options-off-first.
    func release(at now: Date) {
        guard isCovering else { return }
        isCovering = false

        if locked {
            NSApp.presentationOptions = []
            NSApp.setActivationPolicy(.accessory)
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            locked = false
            diagnostics("kiosk: presentation options released, back to accessory", at: now)
        }

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// **Hand everything back and refuse to take it again** — what the exit paths call
    /// instead of ``release(at:)``.
    ///
    /// The difference is the latch, and the latch is the whole point: an ordinary uncover is
    /// followed by more ticks that may legitimately cover again, while this one is followed
    /// only by `exit`. Called from the seatbelt's watcher thread by way of the main queue,
    /// and from the `SIGTERM`/`SIGINT` handler.
    func surrender(at now: Date) {
        surrendered = true
        release(at: now)
        diagnostics("kiosk: surrendered — nothing will lock the screen again this run", at: now)
    }

    // MARK: - Quit

    /// **The defence `presentationOptions` does not give you.** Measured in T00: `Cmd+Q`
    /// closed the spike straight through the full option set, because an app terminating
    /// itself is neither the force-quit panel nor a session termination.
    ///
    /// This catches every route into `terminate(_:)` — the chord, the Dock menu's Quit,
    /// `osascript -e 'quit app "RealScreenTime"'`, another app being polite. It does not
    /// catch `SIGKILL`, and it is not consulted by the watchdog's `exit(0)` (T15).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isCovering else { return .terminateNow }
        // Written down every time: a refused quit is somebody trying, and the count in
        // `app.log` is the only place that ever shows up.
        diagnostics("kiosk: quit refused — the cover is up", at: clock.now)
        return .terminateCancel
    }

    // MARK: - The two watchers

    /// Swallow the quit chord before `NSApplication` ever sees it.
    ///
    /// Local, so it sees only this app's own events — which is all it can see while
    /// `disableProcessSwitching` keeps this app frontmost. Returning `nil` consumes the
    /// keystroke; anything else is passed through untouched, including every key the PIN
    /// field will want from T13.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isCovering else { return event }
            guard event.modifierFlags.contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  Self.swallowed.contains(key)
            else { return event }
            return nil
        }
    }

    /// Presentation options lapse the moment this app is not frontmost, and DESIGN §2.6.1
    /// measured a fullscreen game taking focus back with no keystroke at all. So
    /// re-asserting is continuous rather than exceptional: become active again, and put the
    /// options back if they moved.
    private func observeResign() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resignedActive() }
            }
    }

    private func resignedActive() {
        guard isCovering, locked else { return }
        resignsSinceNote += 1

        let now = DispatchTime.now().uptimeNanoseconds
        let sinceNote = Double(now &- lastResignNote) / 1e9
        if lastResignNote == 0 || sinceNote >= 5 {
            let extra = resignsSinceNote > 1 ? " (\(resignsSinceNote) since the last line)" : ""
            // The spike printed `RESIGNED ACTIVE` here and the note is the same one: while
            // the cover is up and process switching is off, this should not happen, so
            // every occurrence means something got through.
            diagnostics("kiosk: resigned active while covering — re-asserting\(extra)", at: clock.now)
            lastResignNote = now
            resignsSinceNote = 0
        }

        NSApp.activate()
        if NSApp.presentationOptions != Self.options {
            NSApp.presentationOptions = Self.options
        }
    }
}
