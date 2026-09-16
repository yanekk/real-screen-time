import AppKit

/// **The warning you can see** — the backup channel, and the one that survives a muted Mac
/// (DESIGN §2.4).
///
/// Audio is primary here for a measured reason: §2.6.1 established that nothing can be
/// drawn over a fullscreen app's Space, so this window is *invisible* at the one moment it
/// matters most. It covers what sound cannot — headphones round the neck, volume at zero —
/// and neither channel is sufficient on its own.
///
/// **It must not steal focus, and that is most of the file.** A warning that interrupts a
/// game to say "save your game" defeats itself, and worse, teaches that the app is
/// something to be endured rather than read. So: a `.nonactivatingPanel`, never made key,
/// ignoring the mouse entirely — a banner that eats a click during a game is a lost round.
@MainActor
final class Banner {

    /// Long enough to read twice, short enough not to sit over the thing it interrupted.
    static let visibleSeconds: TimeInterval = 6
    static let fadeIn: TimeInterval = 0.25
    static let fadeOut: TimeInterval = 0.5

    /// **Real seconds, always.** Every other duration in this app runs on the `Clock` so
    /// that `RST_TIME_SCALE` can compress a day into a minute — but this one is how long a
    /// person needs to read a sentence, and a person reads at the same speed whatever the
    /// simulated clock says. The scaled run is exactly where getting this wrong would show:
    /// at 60× the three warnings are ten, five and one second apart.
    private var dismissal: Timer?
    private var panel: NSPanel?
    private var label: NSTextField?

    /// Bumped by every ``show(_:)``, and checked by the fade-out before it orders the panel
    /// out (T14 review).
    ///
    /// The fade-out is half a second long and its completion handler hides the window. A
    /// `show` landing inside that half-second re-fades the *same* panel back in — and then
    /// the previous dismissal completes and takes it down again, so the new announcement's
    /// banner appears and vanishes in one breath. Rare at real speed and ordinary under
    /// `RST_TIME_SCALE`, where the thresholds are seconds apart; a grant arriving just after
    /// a warning is the shape at real speed. The speech still plays either way, which is why
    /// this is a lost backup channel rather than a lost warning.
    private var generation = 0

    /// Put the words on the screen, replacing whatever is already there.
    ///
    /// Replacing rather than queueing: two banners in a column is a notification centre,
    /// which §2.4 explicitly does not build, and the newest line is always the more urgent.
    func show(_ text: String) {
        generation += 1
        let panel = self.panel ?? build()
        label?.stringValue = text
        layout(panel)

        // Fade in from nothing only when it was not already up — an abruptly appearing
        // rectangle reads as a glitch (§2.4), but re-fading a banner that is already on
        // screen reads as a flicker, which is worse.
        if !panel.isVisible { panel.alphaValue = 0 }
        // `orderFrontRegardless`, never `makeKeyAndOrderFront`: the second one takes the
        // keyboard away from whatever the child is doing, which is the whole thing this
        // window is not allowed to do.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            panel.animator().alphaValue = 1
        }

        dismissal?.invalidate()
        let timer = Timer(timeInterval: Self.visibleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        // `.common`, like the tick: a run loop tracking an open menu leaves the default mode,
        // and a banner that stays up until the menu is closed looks like a stuck window.
        RunLoop.main.add(timer, forMode: .common)
        dismissal = timer
    }

    /// Fade out and order out. Kept for the seatbelt and for a teardown; a banner is not
    /// state and nothing depends on it having gone.
    func dismiss() {
        dismissal?.invalidate()
        dismissal = nil
        guard let panel else { return }
        let generation = self.generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A `show` since this fade started owns the panel now. Ordering it out here
                // would hide the banner that has just been put up.
                guard self?.generation == generation else { return }
                panel.orderOut(nil)
            }
        })
    }

    // MARK: - The window

    private func build() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 84),
                            // `.nonactivatingPanel` is the one that matters: without it,
                            // ordering this in makes the app active and the game behind it
                            // is no longer frontmost.
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        // `.floating`, as §2.4 draws it — above ordinary windows, below the cover's
        // `.screenSaver`, and below a fullscreen Space either way, which is why the sound
        // is the primary channel and not this.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                                    .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // A panel hides itself when the app deactivates, which for a menu-bar app is almost
        // always. Left on, the banner would appear and vanish in the same frame.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        // Forced dark for the same reason the cover is (T13): a borderless window inherits
        // the system appearance, and these colours are chosen for one of the two.
        panel.appearance = NSAppearance(named: .darkAqua)

        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor,
                                           constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor,
                                            constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -20)
        ])

        panel.contentView = box
        self.panel = panel
        self.label = label
        return panel
    }

    /// Top-centre of the **main** display, under the menu bar (§2.4). One banner, not one
    /// per screen: it is a message, and a message repeated on every monitor reads as a fault.
    private func layout(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width = min(Self.maximumWidth, max(320, visible.width - 80))

        // **Width first, then ask for the height.** `Zapisz grę — gra na pełnym ekranie
        // zostanie zamknięta.` wraps to two lines where `Ostatnia minuta.` does not, and a
        // wrapping label cannot say how tall it is until it has been told how wide it is —
        // `preferredMaxLayoutWidth` is that telling, and without it the second line is drawn
        // outside the window.
        label?.preferredMaxLayoutWidth = width - 2 * Self.horizontalPadding
        panel.setContentSize(NSSize(width: width, height: Self.minimumHeight))
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = max(Self.minimumHeight, panel.contentView?.fittingSize.height ?? 0)
        panel.setContentSize(NSSize(width: width, height: height))

        panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2,
                                     y: visible.maxY - height - 24))
    }

    private static let maximumWidth: CGFloat = 760
    private static let minimumHeight: CGFloat = 84
    private static let horizontalPadding: CGFloat = 28
}
