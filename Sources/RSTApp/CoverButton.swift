import AppKit

/// **The cover's button: filled, coloured by what it does** (cover-buttons-logout T05).
///
/// The parent picked this look on 2026-10-03 from a rendered preview of three
/// (`plans/cover-buttons-logout/prototype/B-filled-by-role-*`), reversing the plan's first
/// "standard macOS buttons" stance for the buttons only. Blue is the way forward, grey is
/// a neutral step, orange-red is the one that ends the session: a child should be able to
/// tell `Wyloguj` from `Wprowadź PIN` without reading either.
///
/// Every button on the cover and in ``PINFlow`` (and so in the menu-bar `PINPanel`, which
/// the parent chose to follow the cover) is one of these. Behaviour is a plain `NSButton`'s:
/// target/action, `keyEquivalent`, Space when focused, the Accessibility identifier. Only
/// the drawing and the size are the cell's.
@MainActor
final class CoverButton: NSButton {

    enum Role {
        /// The face's way forward: `Wprowadź PIN`, `Rozpocznij`, `Wznów`.
        case primary
        /// `Zablokuj ekran`, `Anuluj`, every amount.
        case neutral
        /// `Wyloguj`, on the face and on the confirmation.
        case warning
    }

    override class var cellClass: AnyClass? {
        get { CoverButtonCell.self }
        set {}
    }

    var role: Role {
        get { (cell as? CoverButtonCell)?.role ?? .neutral }
        set { (cell as? CoverButtonCell)?.role = newValue; needsDisplay = true }
    }

    /// - Parameter fontSize: the size a standard button would have used there. The style's
    ///   type is a fifth larger and semibold, as in the preview the parent picked.
    convenience init(title: String, role: Role, fontSize: CGFloat,
                     target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        // Not `.rounded`: its bezel has a fixed height, and this one grows with its type.
        bezelStyle = .smallSquare
        isBordered = true
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: fontSize * 1.2, weight: .semibold)
        self.role = role
    }
}

/// Draws ``CoverButton``. A cell rather than `draw(_:)` on the view, because the cell is
/// what `NSButton` asks for its size, its highlight while pressed and its focus ring.
final class CoverButtonCell: NSButtonCell {

    var role = CoverButton.Role.neutral

    private var fontSize: CGFloat { font?.pointSize ?? 18 }
    private var padding: NSSize { NSSize(width: fontSize * 1.3, height: fontSize * 0.75) }

    private var fill: NSColor {
        switch role {
        case .primary: return NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.96, alpha: 1)
        // Translucent white, so it reads as grey on the cover and on the dark `PINPanel`.
        case .neutral: return NSColor(calibratedWhite: 1, alpha: 0.16)
        case .warning: return NSColor(calibratedRed: 0.86, green: 0.36, blue: 0.24, alpha: 1)
        }
    }

    private func attributed() -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 18),
            .foregroundColor: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.5),
        ])
    }

    override var cellSize: NSSize { cellSize(forBounds: .zero) }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let text = attributed().size()
        return NSSize(width: ceil(text.width + padding.width * 2),
                      height: ceil(text.height + padding.height * 2))
    }

    private func shape(_ frame: NSRect) -> NSBezierPath {
        let inset = frame.insetBy(dx: 1, dy: 1)
        let radius = min(12 * fontSize / 18, inset.height / 2)
        return NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
    }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        var colour = fill
        if isHighlighted { colour = colour.blended(withFraction: 0.25, of: .black) ?? colour }
        if !isEnabled { colour = colour.withAlphaComponent(colour.alphaComponent * 0.5) }
        colour.setFill()
        shape(frame).fill()
    }

    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
        let text = attributed()
        let size = text.size()
        text.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    // **The focus ring is the cell's job once the bezel is custom.** Without these two the
    // button that holds the keyboard (`Rozpocznij`, `Anuluj` on `Wylogować?`) would answer
    // Space with no sign that it is the one listening — the task's named defect.
    override func drawFocusRingMask(withFrame frame: NSRect, in controlView: NSView) {
        shape(frame).fill()
    }

    override func focusRingMaskBounds(forFrame frame: NSRect, in controlView: NSView) -> NSRect {
        frame
    }
}
