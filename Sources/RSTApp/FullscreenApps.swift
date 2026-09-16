import AppKit
import RSTCore

/// **Apps that cannot be covered — or cannot be silenced — are quit** (DESIGN §2.6.2, §2.2).
///
/// Two kinds of app defeat the cover. A **fullscreen** app owns a Space no window level reaches
/// into — measured against a real game on 2026-08-21, which kept its display entirely while the
/// cover appeared only on the other screen — and `hide()` is refused outright. An app **making
/// sound** is covered perfectly well, but the cover hides only its picture: a Chrome tab playing
/// YouTube keeps playing behind it, and locking the screen does not help because the app is still
/// alive. Both are handled the same way here — quit the app — because for both, covering is not
/// enough. §2.2 added the audio half on top of the foundational §2.6.2 fullscreen half; the
/// eviction machinery (grace, force, per-tick re-check, `app_quit`) is shared and unchanged.
///
/// Three options remained for the fullscreen case: accept the gap, buy an Accessibility grant,
/// or close the app. The app is closed, and the decision rests on the warnings: by the time
/// anything is quit the child has had a banner at 10, 5 and 1 minutes. A game closed after three
/// warnings is a consequence; the forced logout rejected in §7 was rejected because it closed
/// everything with no warning at all.
///
/// Three rules from §2.6.2 are implemented here and each one matters:
///
/// - **Only apps owning a fullscreen Space, or making sound.** An ordinary silent windowed app
///   is covered perfectly well, and quitting it would be gratuitous. The target set is the
///   union of the two (``evictionTargets()``), deduplicated by pid so an app that is both
///   fullscreen and loud is asked once and gets one grace.
/// - **`terminate()` first, `forceTerminate()` after ten seconds.** Let the app save — but a
///   modal "save changes?" sheet must not be able to hold the cover off indefinitely, which
///   would be a trivial bypass.
/// - **Re-checked on every tick while covered, not once.** Some game launchers relaunch
///   themselves, and a background tab can start playing after the cover is up; either would
///   otherwise slip past. The check is cheap.
///
/// Gating is the caller's: this type is only ever constructed by `CoverEnforcer`, which
/// exists only in an enforcing run. A debug build must never quit a real app — this is
/// destructive in a way the cover is not.
@MainActor
final class FullscreenEvictor {

    /// How long an app gets to put its save dialog away. Real seconds, from the monotonic
    /// clock rather than the app's — `RST_TIME_SCALE=60` would otherwise hand a real app
    /// with a real dialog a sixth of a second, and the grace exists for that dialog.
    static let graceSeconds: TimeInterval = 10

    /// A CG window's bounds and an `NSScreen` frame are both derived from the same display
    /// mode, so they agree exactly — but a point of slack costs nothing and a scaled display
    /// rounding one of them half a point would otherwise silently disable the whole check.
    private static let tolerance: CGFloat = 1

    private let sink: any EventSink
    private let diagnostics: Diagnostics
    /// pid → when `terminate()` was asked, on the monotonic clock.
    private var asked: [pid_t: UInt64] = [:]

    init(sink: any EventSink, diagnostics: Diagnostics = .discarded) {
        self.sink = sink
        self.diagnostics = diagnostics
    }

    /// Ask every fullscreen or sound-making app to quit, and force the ones that have run out
    /// of grace.
    ///
    /// Called on the tick that decides to cover and on every tick after it while the cover
    /// is up. Idempotent: an app already asked is not asked again, it is waited on.
    func evict(at now: Date) {
        let apps = Self.evictionTargets()
        let live = Set(apps.map(\.pid))

        for app in apps {
            guard let running = NSRunningApplication(processIdentifier: app.pid) else { continue }
            guard let askedAt = asked[app.pid] else {
                // Written before the action, as every event in this app is: the app may
                // take ten seconds to go, and the record belongs to the moment of the
                // decision (CLAUDE.md).
                sink.append(Event(.appQuit, at: now,
                                  [.name: .string(app.name), .forced: .bool(false)]))
                diagnostics("cover: asking \(app.name) to quit — it owns a fullscreen display or is making sound",
                            at: now)
                running.terminate()
                asked[app.pid] = DispatchTime.now().uptimeNanoseconds
                continue
            }

            let waited = Double(DispatchTime.now().uptimeNanoseconds &- askedAt) / 1e9
            guard waited >= Self.graceSeconds else { continue }
            // Still there, still fullscreen, and out of time: something is holding a sheet
            // open in front of the cover.
            sink.append(Event(.appQuit, at: now,
                              [.name: .string(app.name), .forced: .bool(true)]))
            diagnostics("cover: \(app.name) ignored the quit for \(Int(waited.rounded())) s — forcing",
                        at: now)
            running.forceTerminate()
            asked[app.pid] = nil
        }

        // An app that went away, or came out of fullscreen on its own, starts again from
        // nothing if it ever comes back — a relaunched launcher must get its ten seconds
        // rather than inheriting a deadline from its predecessor.
        asked = asked.filter { live.contains($0.key) }
    }

    /// Nothing is covered any more, so nothing is being waited on.
    func reset() { asked.removeAll() }

    // MARK: - Detection

    struct App {
        let pid: pid_t
        let name: String
    }

    /// The union of the fullscreen apps and the sound-making apps, deduplicated by pid.
    ///
    /// One target set, not two evictors, on purpose: the grace bookkeeping (`asked[pid]`), the
    /// force-after-ten-seconds and the reset-on-relaunch all key on pid and must be shared. An
    /// app that is both fullscreen *and* loud must be one entry here, or it would be asked to
    /// quit twice and handed two graces. Fullscreen comes first so its name wins the dedup;
    /// the two names are the same app anyway.
    static func evictionTargets() -> [App] {
        var seen = Set<pid_t>()
        var union: [App] = []
        for app in fullscreenApps() + audioEmittingApps() where seen.insert(app.pid).inserted {
            union.append(app)
        }
        return union
    }

    /// Apps owning a window the exact size and place of a whole display.
    ///
    /// `CGWindowListCopyWindowInfo` needs no Accessibility grant and no Screen Recording
    /// grant for **bounds and owner** — only window *titles* are privileged, and this asks
    /// for none. That is what makes this detector usable at all; the Accessibility route
    /// was the option §2.6.2 declined to buy.
    ///
    /// Three filters, and each one removes a specific false positive: layer 0 drops the
    /// desktop picture, the menu bar and every panel; `.regular` activation policy drops
    /// agents and our own `.accessory` self; and the exact frame match drops a merely
    /// zoomed window, which is `visibleFrame`-sized and covers no menu bar.
    static func fullscreenApps() -> [App] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        let displays = screenBoundsInCGSpace()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [App] = []
        var seen = Set<pid_t>()

        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID, !seen.contains(pid),
                  let raw = window[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary)
            else { continue }

            guard displays.contains(where: { matches($0, bounds) }) else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }

            seen.insert(pid)
            found.append(App(pid: pid,
                             name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"))
        }
        return found
    }

    /// Every display's frame in **CoreGraphics** coordinates — origin top-left of the
    /// primary display, y growing downwards.
    ///
    /// `NSScreen` speaks the opposite convention (origin bottom-left, y up), and comparing
    /// the two without this conversion is a check that passes on a single-display Mac and
    /// silently stops matching the moment a second display sits above or below the first.
    private static func screenBoundsInCGSpace() -> [CGRect] {
        let screens = NSScreen.screens
        // The primary display is the one at the origin — it is what both coordinate spaces
        // are measured from. `first` is the documented fallback if none reports (0, 0).
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
        else { return [] }
        let flipAxis = primary.frame.maxY
        return screens.map {
            CGRect(x: $0.frame.origin.x, y: flipAxis - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height)
        }
    }

    private static func matches(_ display: CGRect, _ window: CGRect) -> Bool {
        abs(display.origin.x - window.origin.x) <= tolerance
            && abs(display.origin.y - window.origin.y) <= tolerance
            && abs(display.width - window.width) <= tolerance
            && abs(display.height - window.height) <= tolerance
    }
}
