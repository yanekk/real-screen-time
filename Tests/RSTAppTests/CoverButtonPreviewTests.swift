import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **Throwaway: the T05 button-style preview renderer** (cover-buttons-logout T05 step 1).
///
/// Off unless `RST_RENDER_PREVIEW=<dir>` is set, so `make test` never runs it. It builds the
/// real cover views at 600×400 and 1512×982, restyles their buttons with each candidate
/// style, and writes PNGs through `cacheDisplay(in:to:)` — every view is laid out in a
/// `CoverWindow` that is built and never ordered anywhere (WindowScanTests).
@Suite("Cover button preview", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RST_RENDER_PREVIEW"] != nil))
@MainActor
struct CoverButtonPreviewTests {

    static let sizes = [NSSize(width: 600, height: 400), NSSize(width: 1512, height: 982)]

    @Test("render every face in every candidate style")
    func render() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RST_RENDER_PREVIEW"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let only = ProcessInfo.processInfo.environment["RST_RENDER_STYLE"]
        for style in PreviewStyle.allCases where only == nil || style.rawValue == only {
            var sheet: [NSBitmapImageRep] = []
            for size in Self.sizes {
                for face in PreviewFace.allCases {
                    let content = try await Self.build(face, size: size)
                    style.apply(to: content)
                    let rep = Self.snapshot(content)
                    let name = "\(style.rawValue)-\(face.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
                    try rep.representation(using: .png, properties: [:])!
                        .write(to: dir.appendingPathComponent(name))
                    if size.width == 600 { sheet.append(rep) }
                }
            }
            try Self.contactSheet(sheet).representation(using: .png, properties: [:])!
                .write(to: dir.appendingPathComponent("\(style.rawValue)-sheet.png"))
        }
    }

    // MARK: - Faces

    enum PreviewFace: String, CaseIterable {
        case timesUp = "1-times-up", start = "2-start", confirm = "3-logout-confirm",
             amounts = "4-amounts"
    }

    static func build(_ face: PreviewFace, size: NSSize) async throws -> CoverContentView {
        let content = CoverDrillHeadedTests.coverWithPIN(amounts: [15, 30, 60])
        content.frame = NSRect(origin: .zero, size: size)
        let window = CoverWindow(contentRect: content.frame, styleMask: .borderless,
                                 backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        let expired = CoverModel(decision: .expired(selfServiceLeft: 1),
                                 sessionsUsedToday: 0, config: Config())!
        switch face {
        case .timesUp:
            content.render(expired)
        case .start:
            content.render(CoverModel(decision: .awaitingStart(selfServiceLeft: 1),
                                      sessionsUsedToday: 0, config: Config())!)
        case .confirm:
            content.render(expired)
            await CoverHeadedTests.openLogoutConfirm(on: content)
        case .amounts:
            content.render(expired)
            try await CoverDrillHeadedTests.reachAmounts(on: content)
        }
        content.layoutSubtreeIfNeeded()
        return content
    }

    // MARK: - Pixels

    static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        // The cover's colour is a layer background, which `cacheDisplay` does not draw.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).setFill()
        view.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The four 600×400 faces in a 2×2 grid, for comparing styles at a glance.
    static func contactSheet(_ reps: [NSBitmapImageRep]) -> NSBitmapImageRep {
        let w = reps[0].pixelsWide, h = reps[0].pixelsHigh, gap = 8
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * 2 + gap,
                                     pixelsHigh: h * 2 + gap, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                     bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: sheet.pixelsWide, height: sheet.pixelsHigh).fill()
        for (i, rep) in reps.prefix(4).enumerated() {
            let x = (i % 2) * (w + gap), y = (1 - i / 2) * (h + gap)
            rep.draw(in: NSRect(x: x, y: y, width: w, height: h))
        }
        NSGraphicsContext.restoreGraphicsState()
        return sheet
    }
}

// MARK: - The candidate styles

enum PreviewStyle: String, CaseIterable {
    /// A: today's standard button, only larger.
    case standardLarger = "A-standard-larger"
    /// B: filled, coloured by role.
    case filled = "B-filled-by-role"
    /// C: the web page's outline (1 pt border in the text colour, 12 pt corners, no fill).
    case outlined = "C-outlined-web"
    /// The shipped code as it is, restyled by nothing: compared against B, the parent's pick.
    case shipped = "shipped"

    @MainActor
    func apply(to root: NSView) {
        for button in root.previewButtons() {
            let role = PreviewRole(of: button)
            switch self {
            case .shipped:
                continue
            case .standardLarger:
                button.font = .systemFont(ofSize: button.font!.pointSize * 1.3, weight: .semibold)
                button.bezelStyle = .rounded
                if #available(macOS 26, *) { button.controlSize = .extraLarge } else { button.controlSize = .large }
            case .filled, .outlined:
                let font = NSFont.systemFont(ofSize: button.font!.pointSize * 1.2, weight: .semibold)
                let cell = PreviewCell(textCell: button.title)
                cell.keyEquivalent = button.keyEquivalent
                cell.role = role
                cell.outlined = self == .outlined
                button.cell = cell
                button.bezelStyle = .smallSquare
                button.isBordered = true
                button.font = font
                button.invalidateIntrinsicContentSize()
            }
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }
}

enum PreviewRole {
    case primary, neutral, warning

    @MainActor
    init(of button: NSButton) {
        let id = button.accessibilityIdentifier()
        if id == "logout" || id == "logout-confirm" { self = .warning }
        else if id == "pin" || button.keyEquivalent == "\r" { self = .primary }
        else { self = .neutral }
    }

    var colour: NSColor {
        switch self {
        case .primary: return NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.96, alpha: 1)
        case .neutral: return NSColor(calibratedWhite: 1, alpha: 0.16)
        case .warning: return NSColor(calibratedRed: 0.86, green: 0.36, blue: 0.24, alpha: 1)
        }
    }

    var outline: NSColor {
        switch self {
        case .primary: return NSColor(calibratedRed: 0.45, green: 0.68, blue: 1, alpha: 1)
        case .neutral: return NSColor(calibratedWhite: 0.85, alpha: 1)
        case .warning: return NSColor(calibratedRed: 1, green: 0.55, blue: 0.42, alpha: 1)
        }
    }
}

final class PreviewCell: NSButtonCell {
    var role = PreviewRole.neutral
    var outlined = false

    private var pad: NSSize {
        let size = font?.pointSize ?? 18
        return NSSize(width: size * 1.3, height: size * 0.75)
    }

    override var cellSize: NSSize { cellSize(forBounds: .zero) }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let text = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 18)]).size()
        return NSSize(width: ceil(text.width + pad.width * 2),
                      height: ceil(text.height + pad.height * 2))
    }

    private func path(_ frame: NSRect) -> NSBezierPath {
        let radius = min(12 * ((font?.pointSize ?? 18) / 18), frame.height / 2)
        return NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
    }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let shape = path(frame)
        if outlined {
            role.outline.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        } else {
            (isHighlighted ? role.colour.blended(withFraction: 0.25, of: .black)! : role.colour).setFill()
            shape.fill()
        }
    }

    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
        let colour: NSColor = outlined ? role.outline : .white
        let title = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 18), .foregroundColor: colour,
        ])
        let size = title.size()
        title.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    override func drawFocusRingMask(withFrame frame: NSRect, in controlView: NSView) {
        path(frame).fill()
    }
}

private extension NSView {
    func previewButtons() -> [NSButton] {
        subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? $0.previewButtons() }
    }
}
