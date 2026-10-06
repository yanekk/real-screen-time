import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **The cover's button style** (cover-buttons-logout T05): every button the child can reach
/// on the cover, on `Wylogować?` and in the amount step is a ``CoverButton`` with the role
/// the parent's chosen look gives it, and the restyle cost the keyboard nothing — the button
/// that holds the keyboard still takes first responder, answers Return and Space, and has a
/// focus ring to show it.
///
/// In memory, on views and `CoverWindow`s that are built and never ordered on screen.
@Suite("Cover button style headed", .serialized)
@MainActor
struct CoverButtonStyleHeadedTests {

    typealias Role = CoverButton.Role

    // MARK: - Every button, styled, with its role

    @Test("every face's buttons are CoverButtons with blue forward, grey neutral, red out")
    func faceButtonsAreStyled() {
        HeadedHarness.withApp { _ in
            let faces: [(Decision, [String: Role])] = [
                (.awaitingStart(selfServiceLeft: 1), ["start": .primary]),
                (.awaitingResume(remaining: 600), ["resume": .primary]),
                (.expired(selfServiceLeft: 1),
                 ["pin": .primary, "lock": .neutral, "logout": .warning]),
                (.awaitingStart(selfServiceLeft: 0),
                 ["pin": .primary, "lock": .neutral, "logout": .warning]),
            ]
            for (decision, expected) in faces {
                let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
                content.frame = NSRect(origin: .zero, size: CoverDrillHeadedTests.coverSize)
                content.render(CoverModel(decision: decision, sessionsUsedToday: 0,
                                          config: Config())!)
                #expect(Self.roles(in: content) == expected, "\(decision)")
            }
        }
    }

    @Test("Wylogować?: Anuluj grey, Wyloguj red")
    func confirmationIsStyled() async {
        _ = NSApplication.shared
        let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
        content.frame = NSRect(origin: .zero, size: CoverDrillHeadedTests.coverSize)
        content.render(CoverDrillHeadedTests.expiredModel)
        await CoverHeadedTests.openLogoutConfirm(on: content)

        #expect(Self.roles(in: content) == [CoverContentView.logoutCancelID: .neutral,
                                            CoverContentView.logoutConfirmID: .warning])
    }

    @Test("the cover's PIN and amount steps: every amount and Anuluj grey")
    func amountStepIsStyled() async throws {
        let content = CoverDrillHeadedTests.coverWithPIN(amounts: [15, 30, 60])
        content.render(CoverDrillHeadedTests.expiredModel)

        await CoverHeadedTests.openPINPrompt(on: content)
        let entry = content.allButtons()
        #expect(entry.count == 1)
        #expect((entry.first as? CoverButton)?.role == .neutral)   // `Anuluj`

        let boxes = try #require(content.firstBoxes())
        PINFlowHeadedTests.type("1379", into: boxes)
        let buttons = content.allButtons()
        #expect(buttons.map(\.title) == ["+15", "+30", "+60", Strings.pinCancelButton])
        #expect(buttons.map { ($0 as? CoverButton)?.role }
                == [.neutral, .neutral, .neutral, .neutral])
    }

    // MARK: - What the restyle must not change

    @Test("identifiers, titles and key equivalents are what ui-gate and the keyboard rely on")
    func behaviourIsUnchanged() {
        HeadedHarness.withApp { _ in
            let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
            content.frame = NSRect(origin: .zero, size: CoverDrillHeadedTests.coverSize)
            content.render(CoverDrillHeadedTests.expiredModel)
            let buttons = content.allButtons()
            #expect(buttons.map { $0.accessibilityIdentifier() } == ["pin", "lock", "logout"])
            #expect(buttons.map(\.title) == [Strings.gated(Strings.coverPINButton),
                                             Strings.coverLockButton, Strings.coverLogOutButton])
            #expect(buttons.allSatisfy { $0.keyEquivalent.isEmpty })
        }
    }

    @Test("the focused button on start and resume takes the keyboard, has a ring, and answers Return and Space",
          arguments: [Decision.awaitingStart(selfServiceLeft: 1), .awaitingResume(remaining: 600)])
    func focusedButtonKeepsTheKeyboard(decision: Decision) throws {
        try HeadedHarness.withApp { _ in
            var pressed: [CoverModel.Button] = []
            let content = CoverContentView(onPress: { pressed.append($0) },
                                           makePINFlow: { _, _ in nil })
            let window = CoverDrillHeadedTests.window(holding: content)
            content.render(CoverModel(decision: decision, sessionsUsedToday: 0,
                                      config: Config())!)
            content.layoutSubtreeIfNeeded()
            let focused = try #require(content.initialResponder as? CoverButton)

            #expect(focused.keyEquivalent == "\r")
            #expect(window.makeFirstResponder(focused))
            #expect(window.firstResponder === focused)
            #expect(focused.focusRingType != .none)
            #expect(Self.hasFocusRing(focused), "no focus ring: the defect T05 names")

            #expect(window.performKeyEquivalent(with: CoverDrillHeadedTests.key("\r", code: 36)))
            focused.keyDown(with: CoverDrillHeadedTests.key(" ", code: 49))
            #expect(pressed.count == 2, "Return then Space: \(pressed)")
        }
    }

    @Test("Wylogować?: Anuluj holds the keyboard with a ring and answers Space")
    func confirmationCancelKeepsTheKeyboard() async throws {
        _ = NSApplication.shared
        let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
        let window = CoverDrillHeadedTests.window(holding: content)
        content.render(CoverDrillHeadedTests.expiredModel)
        await CoverHeadedTests.openLogoutConfirm(on: content)
        content.layoutSubtreeIfNeeded()
        let cancel = try #require(content.allButtons().first as? CoverButton)

        #expect(window.firstResponder === cancel)
        #expect(Self.hasFocusRing(cancel))
        cancel.keyDown(with: CoverDrillHeadedTests.key(" ", code: 49))
        await CoverHeadedTests.pump(until: {
            content.allButtons().map { $0.accessibilityIdentifier() } == ["pin", "lock", "logout"]
        })
        #expect(content.allButtons().map { $0.accessibilityIdentifier() }
                == ["pin", "lock", "logout"], "Space on Anuluj puts the face back")
    }

    /// `make ui-gate` reads a button's frame the moment the button appears; on `Wylogować?`
    /// it once read the stack's pre-layout placement and clicked empty cover (T05). The swap
    /// lays itself out, so no layout pass is run here before the frames are read.
    @Test("a swapped-in face or confirmation is laid out before anyone can read its frames")
    func swapsAreLaidOutAtOnce() async throws {
        _ = NSApplication.shared
        let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
        _ = CoverDrillHeadedTests.window(holding: content)
        content.render(CoverDrillHeadedTests.expiredModel)
        Self.expectPlaced(content, "the face")

        await CoverHeadedTests.openLogoutConfirm(on: content)
        Self.expectPlaced(content, "Wylogować?")

        try #require(content.allButtons().first).performClick(nil)   // Anuluj
        await CoverHeadedTests.pump(until: { content.allButtons().count == 3 })
        Self.expectPlaced(content, "the face, restored")
    }

    static func expectPlaced(_ content: NSView, _ context: String) {
        let buttons = content.allButtons()
        #expect(!buttons.isEmpty, "\(context)")
        for button in buttons {
            let frame = button.convert(button.bounds, to: content)
            #expect(frame.width >= button.intrinsicContentSize.width - 0.5,
                    "\(context): ‘\(button.title)’ not laid out, \(frame)")
            #expect(content.bounds.insetBy(dx: 24, dy: 24).contains(frame),
                    "\(context): ‘\(button.title)’ at \(frame)")
        }
        let frames = buttons.map { $0.convert($0.bounds, to: content) }
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(a.maxX < b.minX, "\(context): buttons overlap, \(a) \(b)")
        }
    }

    // MARK: - The style's own drawing contract

    @Test("a CoverButton sizes to its title and grows with its type")
    func sizesToTitle() {
        HeadedHarness.withApp { _ in
            let small = CoverButton(title: "Wyloguj", role: .warning, fontSize: 8,
                                    target: nil, action: nil)
            let large = CoverButton(title: "Wyloguj", role: .warning, fontSize: 18,
                                    target: nil, action: nil)
            #expect(large.font?.pointSize == 18 * 1.2)
            #expect(large.intrinsicContentSize.height > small.intrinsicContentSize.height)
            #expect(large.intrinsicContentSize.width
                    > NSAttributedString(string: "Wyloguj",
                                         attributes: [.font: large.font!]).size().width)
        }
    }

    // MARK: - Helpers

    /// The ring AppKit draws round the focused button is the shape the cell gives it.
    /// Asked of the cell, not the view: `NSView.focusRingMaskBounds` answers zero for every
    /// button, standard ones included, unless the system's keyboard navigation is on — the
    /// setting decides whether a ring shows, the cell decides what it looks like. So: a
    /// non-empty mask bounds, and a mask that actually paints the button's middle.
    static func hasFocusRing(_ button: CoverButton) -> Bool {
        guard let cell = button.cell, button.focusRingType != .none else { return false }
        let bounds = button.bounds
        guard !cell.focusRingMaskBounds(forFrame: bounds, in: button).isEmpty,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width),
                                         pixelsHigh: Int(bounds.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        cell.drawFocusRingMask(withFrame: bounds, in: button)
        NSGraphicsContext.restoreGraphicsState()
        let middle = rep.colorAt(x: Int(bounds.midX), y: Int(bounds.midY))
        return (middle?.alphaComponent ?? 0) > 0.5
    }

    static func roles(in view: NSView) -> [String: Role] {
        var roles: [String: Role] = [:]
        for button in view.allButtons() {
            guard let styled = button as? CoverButton else {
                Issue.record("‘\(button.title)’ is a plain NSButton")
                continue
            }
            roles[button.accessibilityIdentifier()] = styled.role
        }
        return roles
    }
}

private extension NSView {
    func allButtons() -> [NSButton] {
        subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? $0.allButtons() }
    }

    func firstBoxes() -> PINBoxes? {
        for sub in subviews {
            if let boxes = sub as? PINBoxes { return boxes }
            if let found = sub.firstBoxes() { return found }
        }
        return nil
    }
}
