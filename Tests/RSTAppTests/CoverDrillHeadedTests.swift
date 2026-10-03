import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **The cover-buttons-logout drill, in memory** (T04).
///
/// The other headed suites prove what each screen *contains*. This one proves the new
/// screens *fit* where they appear: every button laid out inside the 600×400 boxed cover
/// (the smallest a cover is ever drawn, and so the smallest type `scale`, 0.45) and inside
/// the menu-bar `PINPanel`'s 400×300 content — none pushed off the view's bounds and none
/// squeezed narrower than its own title. Then the two keyboard paths DESIGN §2.1–§2.2 rely
/// on: Return grants the first amount; on `Wylogować?` neither Return nor Escape does anything.
///
/// Laid out with `layoutSubtreeIfNeeded` on views that are never ordered on screen; the
/// keyboard checks hand a key event to a `CoverWindow` that is built but never shown, which
/// is how AppKit routes a key equivalent from a real window to its buttons.
@Suite("Cover drill headed", .serialized)
@MainActor
struct CoverDrillHeadedTests {

    static let coverSize = NSSize(width: 600, height: 400)

    /// 1, 3, 4 and 6 amounts: one button, the default row, the first vertical column and a
    /// long one. Six is past anything the parent is likely to set, which is the point.
    nonisolated static let amountLists: [[Int]] = [[15], [15, 30, 60], [10, 20, 45, 90], [5, 10, 15, 20, 30, 60]]

    // MARK: - The amount step

    @Test("the cover's amount step fits 600×400 at scale 0.45", arguments: amountLists)
    func amountStepFitsTheCover(amounts: [Int]) async throws {
        let content = Self.coverWithPIN(amounts: amounts)
        content.render(Self.expiredModel)
        try await Self.reachAmounts(on: content)

        #expect(Self.amountButtons(in: content).map(\.tag) == amounts)
        Self.expectEveryButtonFits(in: content, "\(amounts.count) amounts on the cover")
    }

    /// The panel's content is laid out in a real `NSPanel`, built as `PINPanel` builds it and
    /// never shown, because the fix for six amounts is the window growing: a row of up to
    /// three fits the 400×300 as it is, and a column makes the panel taller rather than
    /// clipping `Anuluj` off its bottom edge (T04 drill, 2026-10-03). Up to four fitted with
    /// standard buttons; the cover's taller style (T05) grows the panel for four too, which
    /// the parent accepted on 2026-10-03.
    @Test("the menu-bar panel's amount step fits its content, 400×300 unless the list is long",
          arguments: amountLists)
    func amountStepFitsThePanel(amounts: [Int]) throws {
        try HeadedHarness.withApp { _ in
            let flow = PINFlow(action: .extend, config: { Self.config(amounts: amounts) },
                               clock: Self.clock(), verifier: ScriptedVerifier(accept: true),
                               countdown: ManualCountdown()) { _ in }
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: PINPanel.contentSize),
                                styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: true)
            panel.contentView = PINPanel.host(flow.view)
            panel.layoutIfNeeded()
            let host = try #require(panel.contentView)
            #expect(host.bounds.size == PINPanel.contentSize)   // the PIN step: unchanged

            PINFlowHeadedTests.type("1379", into: try #require(flow.keyboardTarget as? PINBoxes))
            panel.layoutIfNeeded()

            #expect(Self.amountButtons(in: host).map(\.tag) == amounts)
            if amounts.count <= 3 {
                #expect(host.bounds.size == PINPanel.contentSize, "\(amounts.count) amounts")
            }
            #expect(host.bounds.width == PINPanel.contentSize.width)
            Self.expectEveryButtonFits(in: host, "\(amounts.count) amounts in the panel")
            for label in host.allDescendants(of: NSTextField.self) {
                Self.expectFits(label, in: host, "‘\(label.stringValue)’ in the panel")
            }
        }
    }

    // MARK: - The time's-up faces and the confirmation

    @Test("both time's-up faces fit their three buttons into 600×400 at scale 0.45",
          arguments: [Decision.expired(selfServiceLeft: 0), .awaitingStart(selfServiceLeft: 0)])
    func timesUpFaceFits(decision: Decision) {
        HeadedHarness.withApp { _ in
            let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
            content.frame = NSRect(origin: .zero, size: Self.coverSize)
            content.render(CoverModel(decision: decision, sessionsUsedToday: 0, config: Config())!)

            #expect(content.allDescendants(of: NSButton.self).map { $0.identifier?.rawValue }
                    == ["pin", "lock", "logout"])
            Self.expectEveryButtonFits(in: content, "\(decision)")
        }
    }

    @Test("the Wylogować? confirmation fits 600×400 at scale 0.45")
    func confirmationFits() async throws {
        _ = NSApplication.shared
        let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
        content.frame = NSRect(origin: .zero, size: Self.coverSize)
        content.render(Self.expiredModel)
        await CoverHeadedTests.openLogoutConfirm(on: content)

        #expect(content.allDescendants(of: NSButton.self).map { $0.identifier?.rawValue }
                == [CoverContentView.logoutCancelID, CoverContentView.logoutConfirmID])
        Self.expectEveryButtonFits(in: content, "the confirmation")
        // The headline and the warning line too: a clipped `Niezapisana praca…` is the one
        // line here the child most needs to read.
        for label in content.allDescendants(of: NSTextField.self) {
            Self.expectFits(label, in: content, "‘\(label.stringValue)’")
        }
    }

    // MARK: - The keyboard

    @Test("on the cover's amount step Return grants the first amount, once")
    func returnGrantsFirstAmount() async throws {
        var outcomes: [PINFlow.Outcome] = []
        let content = Self.coverWithPIN(amounts: [20, 40, 60]) { outcomes.append($0) }
        let window = Self.window(holding: content)
        content.render(Self.expiredModel)
        try await Self.reachAmounts(on: content)

        #expect(window.performKeyEquivalent(with: Self.key("\r", code: 36)))
        #expect(outcomes == [.extend(minutes: 20)])
    }

    @Test("on Wylogować? neither Return nor Escape does anything")
    func confirmationIgnoresReturnAndEscape() async throws {
        _ = NSApplication.shared
        var pressed: [CoverModel.Button] = []
        let content = CoverContentView(onPress: { pressed.append($0) },
                                       makePINFlow: { _, _ in nil })
        let window = Self.window(holding: content)
        content.render(Self.expiredModel)
        await CoverHeadedTests.openLogoutConfirm(on: content)
        let cancel = try #require(CoverHeadedTests.button(
            withIdentifier: CoverContentView.logoutCancelID, in: content))
        #expect(window.firstResponder === cancel)

        // Return, as a key equivalent: no button on the confirmation answers it.
        #expect(!window.performKeyEquivalent(with: Self.key("\r", code: 36)))
        // Escape, both ways AppKit can route it: as a key equivalent, and as a key press to
        // the focused `Anuluj`, which travels up the responder chain to the window's no-op
        // `cancelOperation`.
        let escape = Self.key("\u{1b}", code: 53)
        #expect(!window.performKeyEquivalent(with: escape))
        cancel.keyDown(with: escape)
        await CoverHeadedTests.pump(until: { false }, timeout: 0.1)

        #expect(pressed.isEmpty)
        // Still the question: neither key confirmed it nor cancelled it.
        #expect(CoverHeadedTests.button(withIdentifier: CoverContentView.logoutConfirmID,
                                        in: content) != nil)
    }

    // MARK: - Fixtures

    static let expiredModel = CoverModel(decision: .expired(selfServiceLeft: 0),
                                         sessionsUsedToday: 0, config: Config())!

    static func clock() -> FakeClock { FakeClock(Date(timeIntervalSince1970: 1_800_000_000)) }

    static func config(amounts: [Int]) -> Config {
        var config = PINFlowHeadedTests.configuredPIN()
        config.extensionOptions = amounts
        return config
    }

    /// A 600×400 cover whose `Wprowadź PIN` opens a real `PINFlow` at the cover's own scale,
    /// with the scripted verifier, so `1379` reaches the amount step without a hash.
    static func coverWithPIN(amounts: [Int],
                             outcome: @escaping (PINFlow.Outcome) -> Void = { _ in })
        -> CoverContentView {
        _ = NSApplication.shared
        let config = config(amounts: amounts)
        let content = CoverContentView(onPress: { _ in }, makePINFlow: { scale, closed in
            PINFlow(action: .extend, config: { config }, clock: clock(), scale: scale,
                    verifier: ScriptedVerifier(accept: true),
                    countdown: ManualCountdown()) { result in
                outcome(result)
                closed()
            }
        })
        // Before the first render: the cover's type scale is read from its height then.
        content.frame = NSRect(origin: .zero, size: coverSize)
        return content
    }

    static func reachAmounts(on content: CoverContentView) async throws {
        await CoverHeadedTests.openPINPrompt(on: content)
        let boxes = try #require(content.allDescendants(of: PINBoxes.self).first)
        PINFlowHeadedTests.type("1379", into: boxes)
        #expect(!amountButtons(in: content).isEmpty)
    }

    /// Built, given the content, and never ordered anywhere.
    static func window(holding content: NSView) -> CoverWindow {
        let window = CoverWindow(contentRect: NSRect(origin: .zero, size: coverSize),
                                 styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = content
        return window
    }

    static func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: code)!
    }

    static func amountButtons(in view: NSView) -> [NSButton] {
        view.allDescendants(of: NSButton.self)
            .filter { $0.accessibilityIdentifier().hasPrefix("amount-") }
    }

    // MARK: - Fitting

    static func expectEveryButtonFits(in container: NSView, _ context: String) {
        container.layoutSubtreeIfNeeded()
        let buttons = container.allDescendants(of: NSButton.self)
        #expect(!buttons.isEmpty, "\(context): nothing drawn")
        for button in buttons { expectFits(button, in: container, "\(context): ‘\(button.title)’") }
    }

    /// Inside the container's bounds, and at least as wide as its own content: a stack view
    /// that ran out of room would either push a view past the edge or squeeze its title.
    static func expectFits(_ view: NSView, in container: NSView, _ context: String) {
        container.layoutSubtreeIfNeeded()
        let frame = view.convert(view.bounds, to: container)
        #expect(!frame.isEmpty, "\(context): never laid out")
        #expect(container.bounds.contains(frame),
                "\(context): \(frame) is outside \(container.bounds)")
        let wants = view.intrinsicContentSize
        if wants.width != NSView.noIntrinsicMetric {
            #expect(frame.width >= wants.width - 0.5,
                    "\(context): \(frame.width) wide, needs \(wants.width)")
        }
        if wants.height != NSView.noIntrinsicMetric {
            #expect(frame.height >= wants.height - 0.5,
                    "\(context): \(frame.height) high, needs \(wants.height)")
        }
    }
}

// MARK: - Walking the view tree

private extension NSView {
    func allDescendants<T: NSView>(of type: T.Type) -> [T] {
        var found: [T] = []
        for sub in subviews {
            if let hit = sub as? T { found.append(hit) }
            found += sub.allDescendants(of: type)
        }
        return found
    }
}
