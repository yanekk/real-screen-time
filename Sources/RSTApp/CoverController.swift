import AppKit
import RSTCore

/// **One opaque window per display, and the machinery that keeps that true.**
///
/// The window shape is DESIGN §2.6's, verified in the T00 spike: `.screenSaver` level puts
/// it above ordinary windows and above the Dock; `.canJoinAllSpaces` makes it follow a
/// Space switch instead of being left behind; `.fullScreenAuxiliary` lets it draw over an
/// app in its own fullscreen Space — as far as that is possible at all, which §2.6.1 found
/// it is not, and is why `FullscreenEvictor` exists; `.stationary` keeps it still during a
/// Mission Control transition.
///
/// The whole of T11 is built inside `RST_COVER_FRAME=600x400+80+80`. Nearly every bug in
/// this file is findable in a box, and finding it there costs a keystroke instead of a
/// reboot.
@MainActor
final class CoverController {

    private let frame: CoverFrame?
    private let diagnostics: Diagnostics
    private let clock: any Clock
    private let seatbelt: Seatbelt?
    /// T15's hang detector, and **not optional**: the seatbelt is a development flag the
    /// shipping app runs without, while the watchdog is always armed. It is told about the
    /// cover for the same reason the seatbelt is — it only fires while one is up.
    private let watchdog: Watchdog
    /// The app-global lockdown (T12). Engaged as the cover goes up and released before it
    /// comes down; it is told whether this cover is the real fullscreen one, because
    /// presentation options cannot be scoped to a box.
    private let kiosk: KioskLock
    private let onPress: (CoverModel.Button) -> Void
    /// Handed to every content view: the PIN prompt is a view inside the cover's own window
    /// (T13), so it is built per window rather than presented over the top.
    private let makePINFlow: (CGFloat, @escaping () -> Void) -> PINFlow?

    private var windows: [CoverWindow] = []
    /// The screen layout the current windows were built for. See ``screenLayoutChanged()``.
    private var layout: String = ""
    private var showing: CoverModel?
    private var observer: (any NSObjectProtocol)?

    var isCovering: Bool { !windows.isEmpty }

    init(frame: CoverFrame?,
         clock: any Clock,
         seatbelt: Seatbelt?,
         watchdog: Watchdog,
         kiosk: KioskLock,
         diagnostics: Diagnostics = .discarded,
         onPress: @escaping (CoverModel.Button) -> Void,
         makePINFlow: @escaping (CGFloat, @escaping () -> Void) -> PINFlow?) {
        self.frame = frame
        self.clock = clock
        self.seatbelt = seatbelt
        self.watchdog = watchdog
        self.kiosk = kiosk
        self.diagnostics = diagnostics
        self.onPress = onPress
        self.makePINFlow = makePINFlow
        observeScreenChanges()
    }

    // MARK: - Up and down

    /// Put the cover up, or update the face it is showing.
    ///
    /// Called on **every** tick that decides to cover, not only the first — the cover has
    /// to be re-asserted while it is up, and `CoverContentView.render(_:)` is the thing
    /// that makes the repeat free.
    func show(_ model: CoverModel) {
        if windows.isEmpty {
            // **Before the first window exists**, and this ordering is the T00 lesson
            // written down: between arming and covering is the only interval in which a
            // wedged main thread could leave a cover the seatbelt does not know about.
            coverBegan()
            build(model)
            diagnostics("cover: up on \(windows.count) window(s)\(frame == nil ? "" : ", windowed")",
                        at: clock.now)
        } else if currentLayout() != layout {
            // A display was plugged in or unplugged while covered. Rebuild rather than
            // patch: the alternative is bookkeeping that has to be right about which
            // window belonged to which screen, and the rebuild is imperceptible.
            diagnostics("cover: screen layout changed while covered — rebuilding", at: clock.now)
            tearDown()
            coverBegan()
            build(model)
        }

        showing = model
        for window in windows {
            (window.contentView as? CoverContentView)?.render(model)
        }
        // **On every tick that covers, not only the first.** The options lapse whenever the
        // app is not frontmost, so re-asserting is continuous rather than exceptional
        // (DESIGN §2.6.1) — and `engage` is what activates the app, which a borderless
        // window also needs before it can take the keyboard at all.
        kiosk.engage(fullscreen: frame == nil, at: clock.now)
    }

    /// Take the cover down and leave the screen in a state the child can use.
    func hide() {
        guard !windows.isEmpty else { return }
        // Options off before the windows go, never after: a Mac with no Dock, no menu bar
        // and no cover is a Mac with no explanation of what happened to it.
        kiosk.release(at: clock.now)
        tearDown()
        showing = nil
        coverEnded()
        diagnostics("cover: down", at: clock.now)
    }

    /// **Both watchers, in one place.** Two detached threads care whether a cover is up —
    /// the seatbelt, which tears one down after `RST_MAX_COVER_SECONDS`, and the watchdog,
    /// which ends the process if the main thread goes silent under one. Neither can be told
    /// by the other, and a call site that remembered one of them would be a cover invisible
    /// to the other for as long as it stood.
    private func coverBegan() {
        seatbelt?.coverBegan()
        watchdog.coverBegan()
    }

    private func coverEnded() {
        seatbelt?.coverEnded()
        watchdog.coverEnded()
    }

    // MARK: - Windows

    /// **Build the cover's windows without putting any on a display** — the Tier 1 seam
    /// (DESIGN §3.1, T02).
    ///
    /// One `CoverWindow` per display, or exactly one box at absolute coordinates under
    /// `RST_COVER_FRAME`, which is a rect in screen space and not a thing per screen. Each is
    /// rendered with `model` and handed back **unordered**: `show(_:)` owns the tail that
    /// orders them and engages the kiosk, so a headed test can assert the window set, the
    /// buttons and every string on them without a screen lighting up. The screen set is
    /// passed in rather than read here, so a test's window count is deterministic —
    /// `NSScreen.screens` works off-screen but is the real hardware (T00, FINDINGS), and
    /// production hands it exactly that.
    func buildWindows(_ model: CoverModel, screens: [NSScreen]) -> [CoverWindow] {
        let rects: [NSRect]
        if let frame {
            rects = [NSRect(x: CGFloat(frame.x), y: CGFloat(frame.y),
                            width: CGFloat(frame.width), height: CGFloat(frame.height))]
        } else {
            // The whole `screen.frame`, menu bar and notch included: `visibleFrame` leaves
            // a strip at the top, and a strip is somewhere to click.
            rects = screens.map(\.frame)
        }
        return rects.map { rect in
            let window = makeWindow(rect)
            (window.contentView as? CoverContentView)?.render(model)
            return window
        }
    }

    private func build(_ model: CoverModel) {
        layout = currentLayout()
        let screens = NSScreen.screens
        windows = buildWindows(model, screens: screens)

        // The key window goes on the screen the keyboard is already pointing at. Every
        // other display gets `orderFrontRegardless`, which shows a window without asking for
        // key status — two windows fighting over the keyboard is a PIN field that sometimes
        // takes keystrokes and sometimes does not. Under `RST_COVER_FRAME` there is one
        // window and it is the key one.
        let keyIndex = frame == nil
            ? (screens.firstIndex(where: { $0 == NSScreen.main }) ?? 0)
            : 0

        for (index, window) in windows.enumerated() {
            if index == keyIndex {
                window.makeKeyAndOrderFront(nil)
                // `contentView` first, `makeKeyAndOrderFront` second, `makeFirstResponder`
                // third. In any other order the focus lands nowhere at all.
                if let responder = (window.contentView as? CoverContentView)?.initialResponder {
                    window.makeFirstResponder(responder)
                }
            } else {
                window.orderFrontRegardless()
            }
        }
    }

    private func makeWindow(_ rect: NSRect) -> CoverWindow {
        let window = CoverWindow(contentRect: rect,
                                 styleMask: .borderless,
                                 backing: .buffered,
                                 defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        // **Forced dark, so the controls T13 puts on this window are drawn for it.** A
        // borderless window inherits the *system* appearance, which on a light Mac would
        // give the PIN field a white box and black text on a near-black cover. The labels
        // this file draws are explicitly coloured and would not have noticed; an
        // `NSSecureTextField` very much does.
        window.appearance = NSAppearance(named: .darkAqua)
        // Never `close()`d — `orderOut` plus ARC is what takes these away — but the default
        // would hand AppKit a second release if anything ever did.
        window.isReleasedWhenClosed = false
        // Kept off Mission Control's window list and out of screenshots of other apps'
        // windows; also stops the cover being cycled to with Cmd+`.
        window.isExcludedFromWindowsMenu = true
        // Set before the window is ordered in, per the gotcha above.
        window.contentView = CoverContentView(onPress: onPress, makePINFlow: makePINFlow)
        return window
    }

    private func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        forceRedraw()
    }

    /// **Give every display something to redraw**, not just `orderOut`.
    ///
    /// Measured in T00 (2026-08-21): quitting a fullscreen app while covered orphaned its
    /// fullscreen Space and left a stale frame on that display with **no process owning
    /// it** — nothing to kill, and it had to be closed by hand in Mission Control. A
    /// child's Mac stuck showing a frozen frame after the cover lifts looks exactly like
    /// the app broke the machine, and it would be the app's fault.
    ///
    /// A momentary window per display is the cheapest thing that makes the WindowServer
    /// recomposite that display. **Whether it actually clears an orphaned Space can only be
    /// established with a real game on a real screen** — it is on the handover list, not
    /// asserted here.
    private func forceRedraw() {
        for screen in NSScreen.screens {
            let poke = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
            poke.level = .screenSaver
            poke.isOpaque = false
            poke.backgroundColor = .clear
            poke.alphaValue = 0.01
            poke.ignoresMouseEvents = true
            poke.isReleasedWhenClosed = false
            poke.orderFrontRegardless()
            poke.displayIfNeeded()
            poke.orderOut(nil)
        }
    }

    // MARK: - Displays coming and going

    /// **Debounced by comparing the layout, never with a boolean.**
    ///
    /// The app's own `hideDock`/`hideMenuBar` post this notification (T12), and so does
    /// `toggleFullScreen`. A re-entrancy flag does not help: the notification arrives
    /// asynchronously *after* the rebuild has finished and cleared the flag, which is how
    /// the T00 spike rebuilt hundreds of times in twenty seconds. The signature is the
    /// actual answer — if no frame moved, there is nothing to rebuild.
    private func observeScreenChanges() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLayoutChanged() }
            }
    }

    private func screenLayoutChanged() {
        let now = currentLayout()
        guard now != layout else { return }
        guard let showing else {
            // Not covering: remember the new layout so the next cover is built for it, and
            // say nothing.
            layout = now
            return
        }
        // Plugging a monitor in while covered must not open an uncovered display, and that
        // is exactly what somebody would try.
        show(showing)
    }

    private func currentLayout() -> String {
        NSScreen.screens
            .map { NSStringFromRect($0.frame) }
            .joined(separator: "|")
    }
}
