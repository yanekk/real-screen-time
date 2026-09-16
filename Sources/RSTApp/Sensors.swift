import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import RSTCore

/// What the app asks the system about the world, once a second.
///
/// The whole point of it being this small is that it is the only part of the app that
/// cannot be tested headlessly. Everything downstream takes these four numbers as
/// parameters, which is what lets `make test` play a whole evening in milliseconds.
///
/// `@MainActor` because every read below is a main-thread system call driven from the
/// main-thread timer, and because the notification observers that feed the fallbacks have
/// to land somewhere. The protocol carries the annotation rather than the conformer: a
/// `@MainActor` conformer cannot satisfy a non-isolated requirement, and pretending the
/// read is non-isolated would only move `MainActor.assumeIsolated` to every call site.
@MainActor
protocol Sensing: Sendable {
    func read() -> SensorReading
}

/// One read of the world. The sensor half of `RSTCore`'s `Snapshot`, minus the time, which
/// comes from the `Clock`.
struct SensorReading: Equatable, Sendable {
    var idleSeconds: TimeInterval
    var screenLocked: Bool
    /// `false` while another user is switched in (DESIGN §2.2).
    var sessionOnConsole: Bool
    /// Something holds `kIOPMAssertionTypePreventUserIdleDisplaySleep` — a film or a game.
    var mediaPlaying: Bool
}

/// The real thing: idle time, lock state, fast user switching and media playback.
///
/// **Every field defaults towards charging when a read fails.** An unreadable sensor must
/// not be a way to buy free screen time — a child who can make `CGSessionCopyCurrentDictionary`
/// fail would otherwise have found a bypass, and DESIGN §8's list of accepted bypasses is
/// deliberately closed. `mediaPlaying` is the exception in form but not in spirit: `false`
/// there *shortens* the grace from 30 minutes to 10, so failing to read it is also the
/// answer that charges rather than the one that gifts.
///
/// None of it needs a permission prompt, an Accessibility grant or a TCC dialog, which is
/// the reason each of these APIs was chosen over the more obvious one that watches input.
@MainActor
final class SystemSensors: Sensing {

    private let clock: any Clock
    private let diagnostics: Diagnostics
    private var observers: [any NSObjectProtocol] = []

    /// What the notifications last said, used **only** when the session dictionary cannot
    /// be read at all. The dictionary is the source of truth in every other tick: it is a
    /// poll, so it cannot miss an edge, and it is right at launch without having had to
    /// witness the transition — the app can perfectly well start up locked, or start up
    /// while the parent is switched in.
    private var lockedByNotification = false
    private var onConsoleByNotification = true

    /// The previous reading, for the transition lines in `app.log`. `nil` until the first
    /// read, which logs the whole state rather than a change.
    private var previous: SensorReading?

    init(clock: any Clock, diagnostics: Diagnostics) {
        self.clock = clock
        self.diagnostics = diagnostics
        observeLockState()
        observeFastUserSwitching()
    }

    // MARK: - The read

    func read() -> SensorReading {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let reading = SensorReading(
            idleSeconds: Self.idleSeconds(),
            screenLocked: session.map(Self.locked(in:)) ?? lockedByNotification,
            sessionOnConsole: session.map(Self.onConsole(in:)) ?? onConsoleByNotification,
            mediaPlaying: Self.mediaPlaying())
        report(reading)
        previous = reading
        return reading
    }

    // MARK: - Idle

    /// Seconds since the last HID event of **any** type.
    ///
    /// `~0` is the documented sentinel for "any event type" — there is no enum case for it,
    /// and asking for the types one at a time would miss the ones Apple adds next.
    ///
    /// Clamped at zero: the API is documented to return a negative number if the event
    /// source cannot be created, and a negative idle would read as *more* recent than now
    /// and quietly hold the session open forever.
    private static func idleSeconds() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!
        return max(0, CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent))
    }

    // MARK: - Lock and console

    /// - Note: `CGSSessionScreenIsLocked` is **unofficial**. Verified present on macOS 26.5
    ///   (absent when unlocked, `true` when locked), but it is not in any header, so absence
    ///   is read as unlocked rather than as an error. If a future macOS drops it the app
    ///   degrades to input-only idle, which covers a locked screen approximately — the same
    ///   fallback DESIGN §2.2 already relies on, not a new failure mode.
    private static func locked(in session: [String: Any]) -> Bool {
        session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// - Important: the key must come from the constant, never from a literal spelled the
    ///   way the constant is. `kCGSessionOnConsoleKey` expands to `kCGSSessionOnConsoleKey`
    ///   — with a second `S` — so the obvious literal silently returns `nil` on every read,
    ///   and the default below would then be the only thing anyone ever saw.
    ///
    /// Defaults to on-console, which is the answer that keeps charging. See the type's note.
    private static func onConsole(in session: [String: Any]) -> Bool {
        session[kCGSessionOnConsoleKey as String] as? Bool ?? true
    }

    /// Lock and unlock, from `DistributedNotificationCenter`.
    ///
    /// Unofficial names, long stable, and here only as the fallback for a session dictionary
    /// that will not read — see ``lockedByNotification``. Two independent signals for the
    /// same fact, and the poll wins, because a missed unlock notification would strand the
    /// app believing the screen is locked and hand out an evening of free time.
    private func observeLockState() {
        observe("com.apple.screenIsLocked", on: DistributedNotificationCenter.default()) {
            $0.lockedByNotification = true
        }
        observe("com.apple.screenIsUnlocked", on: DistributedNotificationCenter.default()) {
            $0.lockedByNotification = false
        }
    }

    /// Fast user switching (DESIGN §2.2). The Mac is shared and the two accounts are
    /// switched back and forth all evening; his session stays live in the background the
    /// whole time, so without this every switch would charge him up to the full idle grace.
    private func observeFastUserSwitching() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.sessionDidResignActiveNotification.rawValue, on: workspace) {
            $0.onConsoleByNotification = false
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification.rawValue, on: workspace) {
            $0.onConsoleByNotification = true
        }
    }

    // MARK: - Media

    /// Is anything holding the display awake — a film, or a game.
    ///
    /// The **display** assertion, deliberately, not the system one: `PreventUserIdleSystemSleep`
    /// is held by `powerd` on an idle machine (measured on this Mac: count 1 with nothing
    /// playing at all), so checking it would read as "always playing" and stretch every
    /// pause to the 30-minute cap.
    ///
    /// - Important: **nothing in this app may ever hold that assertion.** The aggregate
    ///   count cannot tell our own process from a video player, so a cover window that
    ///   disabled display sleep, or a speech call that took an audio assertion, would read
    ///   as a film playing forever and charge every idle evening at the 30-minute grace.
    ///   Relevant from T11 onwards.
    private static func mediaPlaying() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&assertions) == kIOReturnSuccess,
              let counts = assertions?.takeRetainedValue() as? [String: Int] else {
            // Unreadable: fall back to input-only idle, which is §2.2 without the media
            // clause rather than a broken §2.2.
            return false
        }
        return (counts[kIOPMAssertionTypePreventUserIdleDisplaySleep as String] ?? 0) > 0
    }

    // MARK: - Saying what changed

    /// One line in `app.log` per change of a boolean sensor, and one for the initial state.
    ///
    /// This is what makes T09's acceptance criterion checkable at all: "a day of observer
    /// mode produces a log that matches what you actually did with the Mac" needs the lock,
    /// the switch and the film to be visible in the file. Idle seconds are deliberately not
    /// logged — they change every tick, and the events that matter are already in
    /// `events.jsonl`.
    private func report(_ reading: SensorReading) {
        let now = clock.now
        guard let previous else {
            diagnostics("""
                sensors: idle \(Int(reading.idleSeconds.rounded())) s, \
                \(reading.screenLocked ? "locked" : "unlocked"), \
                \(reading.sessionOnConsole ? "on console" : "off console"), \
                \(reading.mediaPlaying ? "media playing" : "nothing playing")
                """, at: now)
            return
        }
        if previous.screenLocked != reading.screenLocked {
            diagnostics("screen \(reading.screenLocked ? "locked" : "unlocked")", at: now)
        }
        if previous.sessionOnConsole != reading.sessionOnConsole {
            diagnostics(reading.sessionOnConsole
                            ? "session back on the console"
                            : "session left the console — another user switched in", at: now)
        }
        if previous.mediaPlaying != reading.mediaPlaying {
            diagnostics(reading.mediaPlaying
                            ? "something is holding the display awake — media or a game"
                            : "nothing is holding the display awake any more", at: now)
        }
    }

    // MARK: - Plumbing

    /// The observers arrive `@Sendable` on the main queue, which is where this object already
    /// lives — the same hop `AppController` makes, for the same reason.
    private func observe(_ name: String,
                         on center: NotificationCenter,
                         _ handler: @escaping @MainActor (SystemSensors) -> Void) {
        let observer = center.addObserver(forName: Notification.Name(name),
                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(observer)
    }
}

/// When the machine last booted, for T04's gap classification.
///
/// `nil` if the read fails, which in practice it does not — `kern.boottime` has been in
/// every BSD for thirty years. The caller decides what an unknown boot time means, because
/// the answer is a policy question rather than a plumbing one (see `main.swift`).
///
/// - Note: `Date(timeIntervalSince1970:)` is not the initialiser CLAUDE.md bans. The rule
///   is that nothing outside `SystemClock` may read the wall clock; this converts a number
///   the kernel handed us, and reads no clock at all.
func systemBootTime() -> Date? {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
        return nil
    }
    return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
}
