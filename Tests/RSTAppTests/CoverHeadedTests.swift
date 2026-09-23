import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **The cover, in memory** (DESIGN §2.1 Tier 1, §2.2 faithful-in-memory band; T02).
///
/// These are the checks the project has historically only caught by hand or not at all: that
/// the borderless window can take the keyboard, that there is one cover per display, that
/// every button carries its identifier and its Polish title, that no English literal has
/// leaked onto the cover, and that a PIN takes the cover down only when it is right.
///
/// Everything runs through the real `CoverController` / `CoverWindow` / `CoverContentView` /
/// `PINFlow` types, built through the ``CoverController/buildWindows(_:screens:)`` seam so no
/// window is ever ordered onto a display and the kiosk is never engaged (§3.1). The scan in
/// `WindowScanTests` guards that this file names none of the ordering calls.
///
/// **Serialized on purpose.** The PIN checks drive the real off-main-thread verifier and pump
/// the run loop for its answer (T00 anticipated this). Serializing keeps two pumping tests
/// from interleaving; each is `@MainActor`, and none reads `RST_DATA_DIR` — the injected
/// `config` is the PIN they check against — so a pump cannot disturb another test's scratch
/// tree (T01 env-swap finding).
@Suite("Cover headed", .serialized)
@MainActor
struct CoverHeadedTests {

    // MARK: - Key-ability

    /// The single most load-bearing fact about the cover: a borderless window that could not
    /// become key would hold a PIN field that silently refuses every keystroke.
    @Test("CoverWindow takes the keyboard where a bare borderless window does not")
    func coverWindowBecomesKey() {
        HeadedHarness.withApp { _ in
            let cover = CoverWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                    styleMask: .borderless, backing: .buffered, defer: true)
            #expect(cover.canBecomeKey)
            #expect(cover.canBecomeMain)

            // The control that makes the override matter.
            let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: .borderless, backing: .buffered, defer: true)
            #expect(!plain.canBecomeKey)
        }
    }

    // MARK: - The window set

    @Test("the seam builds one window per screen, one box under a frame, none on screen, no kiosk")
    func seamBuildsUnorderedWindows() {
        HeadedHarness.withApp { _ in
            let screens = NSScreen.screens
            let model = Self.model(.expired(selfServiceLeft: 0))

            let perScreen = Self.makeRig()
            let all = perScreen.controller.buildWindows(model, screens: screens)
            #expect(all.count == screens.count)
            for window in all { #expect(!window.isVisible) }   // nothing ordered
            #expect(perScreen.kiosk.isCovering == false)       // and nothing locked down

            // A frame is a rect in screen space, so exactly one box regardless of the screens.
            let boxed = Self.makeRig(frame: Self.box)
            let one = boxed.controller.buildWindows(model, screens: screens)
            #expect(one.count == 1)
            #expect(!one[0].isVisible)
            #expect(boxed.kiosk.isCovering == false)
        }
    }

    // MARK: - Buttons and their Polish titles

    @Test("every cover button carries its identifier and its Polish title from Strings")
    func buttonsCarryIdentifierAndPolishTitle() {
        HeadedHarness.withApp { _ in
            var seen: Set<CoverModel.Button> = []
            for decision in Self.coveringDecisions {
                let model = Self.model(decision)
                let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
                content.render(model)

                let buttons = content.allDescendants(of: NSButton.self)
                #expect(buttons.count == model.buttons.count, "\(decision)")
                for button in buttons {
                    let raw = button.identifier?.rawValue ?? ""
                    let kind = CoverModel.Button(rawValue: raw)
                    #expect(kind != nil, "button identifier ‘\(raw)’ is not a CoverModel.Button")
                    if let kind {
                        #expect(model.buttons.contains(kind), "\(decision) drew a \(kind) it did not offer")
                        #expect(button.title == Self.expectedTitle(kind))
                        seen.insert(kind)
                    }
                }
            }
            // The three faces together must exercise every button the cover can draw.
            #expect(seen == Set(CoverModel.Button.allCases))
        }
    }

    // MARK: - Accessibility identifiers (T06)

    /// Every cover button carries a real `accessibilityIdentifier` equal to its
    /// `CoverModel.Button` raw value — the name the real-click gate (T07) locates it by from
    /// another process. The internal `NSUserInterfaceItemIdentifier` `pressed(_:)` reads is set
    /// to the same value and must survive alongside it, so this asserts both: a drift between
    /// the two, or a dropped AX identifier, fails the suite before it can silently break T07.
    @Test("every cover button carries a matching accessibility identifier and keeps its item identifier")
    func buttonsCarryAccessibilityIdentifier() {
        HeadedHarness.withApp { _ in
            var seen: Set<CoverModel.Button> = []
            for decision in Self.coveringDecisions {
                let model = Self.model(decision)
                let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
                content.render(model)

                for button in content.allDescendants(of: NSButton.self) {
                    let itemID = button.identifier?.rawValue
                    let kind = try! #require(itemID.flatMap(CoverModel.Button.init(rawValue:)),
                                             "\(String(describing: itemID)) is not a button kind")
                    // The AX identifier is the raw value, and it agrees with the item identifier
                    // the action path still reads.
                    #expect(button.accessibilityIdentifier() == kind.rawValue)
                    #expect(button.accessibilityIdentifier() == itemID)
                    seen.insert(kind)
                }
            }
            #expect(seen == Set(CoverModel.Button.allCases))
        }
    }

    /// The cover's PIN boxes report the stable identifier the gate targets when they hold the
    /// keyboard — driven through the cover's own prompt so it is the boxes the app really builds.
    /// Runs `async`, outside `withApp`, because opening the prompt pumps the main queue (T02).
    @Test("the cover's PIN boxes carry the stable accessibility identifier")
    func pinBoxesCarryAccessibilityIdentifier() async throws {
        _ = NSApplication.shared
        let rig = Self.makeRig(frame: Self.box, config: Self.configuredPIN)
        let windows = rig.controller.buildWindows(Self.model(.expired(selfServiceLeft: 0)),
                                                  screens: NSScreen.screens)
        let content = try #require(windows.first?.contentView as? CoverContentView)

        await Self.openPINPrompt(on: content)
        let boxes = try #require(content.firstDescendant(of: PINBoxes.self))
        #expect(boxes.accessibilityIdentifier() == PINBoxes.accessibilityID)

        // Nothing is left holding the flow (no run loop fires the countdown here anyway).
        Self.button(titled: Strings.pinCancelButton, in: content)?.performClick(nil)
    }

    // MARK: - No English on the cover

    /// Every visible string on the cover must resolve through ``Strings``. An inline English
    /// literal — the exact mistake the bilingual split invites (DESIGN §2.4.2) — would not be
    /// in the expected set and fails the suite.
    @Test("no cover string is an inline literal — every one resolves through Strings")
    func everyCoverStringComesFromStrings() {
        HeadedHarness.withApp { _ in
            for decision in Self.coveringDecisions {
                let model = Self.model(decision)
                let content = CoverContentView(onPress: { _ in }, makePINFlow: { _, _ in nil })
                content.render(model)

                let expected = Self.expectedStrings(for: model)
                let labels = content.allDescendants(of: NSTextField.self).map(\.stringValue)
                let titles = content.allDescendants(of: NSButton.self).map(\.title)
                for shown in labels + titles where !shown.isEmpty {
                    #expect(expected.contains(shown),
                            "‘\(shown)’ on the \(decision) cover is not a Strings value")
                }
            }
        }
    }

    // MARK: - The PIN dismissal path

    /// A wrong PIN empties the boxes and holds them for the rate-limit wait, and it never
    /// reaches the enforcer — the cover stays exactly where it is.
    ///
    /// Driven end to end through the cover's own window: press `Wprowadź PIN`, type four wrong
    /// digits, and pump the run loop while the off-main-thread verifier rejects them. The flow
    /// internals — digits-only, the growing wait, the disable/settings/cancel outcomes — are
    /// T03's; this asserts only the cover-level outcome.
    ///
    /// **Runs `async`, outside `withApp`.** It pumps the run loop (see ``pump(until:timeout:)``),
    /// which needs an `await` its synchronous body cannot host; it touches no scratch state —
    /// the injected `config` is the PIN — so it needs neither the data dir nor the teardown.
    @Test("a wrong PIN clears the entry and does not take the cover down")
    func wrongPINHoldsTheCover() async throws {
        _ = NSApplication.shared
        let rig = Self.makeRig(frame: Self.box, config: Self.configuredPIN)
        let windows = rig.controller.buildWindows(Self.model(.expired(selfServiceLeft: 0)),
                                                  screens: NSScreen.screens)
        let content = try #require(windows.first?.contentView as? CoverContentView)

        await Self.openPINPrompt(on: content)
        let boxes = try #require(content.firstDescendant(of: PINBoxes.self))

        Self.type("0000", into: boxes)   // the configured PIN is 1379
        // The fourth digit makes the boxes inert immediately; the clear comes only once the
        // verifier has rejected the guess, so wait on the emptied field, not on that.
        await Self.pump(until: { boxes.digits.isEmpty })

        #expect(boxes.digits == "")
        #expect(!boxes.isEnabled)                     // shut for the rate-limit wait
        #expect(rig.enforcer.outcomes.isEmpty)        // a wrong PIN produces no outcome
        #expect(!rig.enforcer.dismissed)              // and the cover was never taken down

        // Cancel stops the rate-limit countdown synchronously, so nothing is left holding the
        // flow. (No app loop runs in the test process, so the timer would never fire anyway,
        // but this keeps the flow from being retained for the rest of the run.)
        Self.button(titled: Strings.pinCancelButton, in: content)?.performClick(nil)
    }

    /// A right PIN, then the amount picked and confirmed, reaches the enforcer's grant — which
    /// is what takes the cover down on the next tick. Modelled here by a recording double
    /// standing in for the enforcer and the tick, so the dismissal is asserted without one.
    /// Runs `async`, outside `withApp`, for the same reason as the wrong-PIN check above.
    @Test("a right PIN reaches the dismissal path")
    func rightPINReachesDismissal() async throws {
        _ = NSApplication.shared
        let rig = Self.makeRig(frame: Self.box, config: Self.configuredPIN)
        let windows = rig.controller.buildWindows(Self.model(.expired(selfServiceLeft: 0)),
                                                  screens: NSScreen.screens)
        let content = try #require(windows.first?.contentView as? CoverContentView)

        await Self.openPINPrompt(on: content)
        let boxes = try #require(content.firstDescendant(of: PINBoxes.self))

        Self.type("1379", into: boxes)
        // A correct PIN swaps the boxes for the amount picker; its confirm button is `Dodaj`.
        await Self.pump(until: { Self.button(titled: Strings.grantConfirmButton, in: content) != nil })
        let confirm = try #require(Self.button(titled: Strings.grantConfirmButton, in: content))
        confirm.performClick(nil)

        await Self.pump(until: { rig.enforcer.dismissed })
        #expect(rig.enforcer.dismissed)
        if case .extend = rig.enforcer.outcomes.last {} else {
            Issue.record("expected an extend outcome, got \(rig.enforcer.outcomes)")
        }
    }

    // MARK: - Escape

    /// Escape is routed nowhere: the cover has no Cancel and no close, so ``CoverWindow`` makes
    /// `cancelOperation` a no-op. Whether it holds under a real key window is a Tier 2 check
    /// (TESTING.md); here it is enough that the call does nothing to the window.
    @Test("Escape does nothing — cancelOperation is a no-op")
    func escapeIsANoOp() {
        HeadedHarness.withApp { _ in
            let window = CoverWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                     styleMask: .borderless, backing: .buffered, defer: true)
            window.cancelOperation(nil)
            #expect(!window.isVisible)   // never shown, never closed, nothing routed
        }
    }

    // MARK: - Fixtures

    /// A frame withholds the kiosk lockdown and keeps the seam to a single window (FINDINGS).
    static let box = CoverFrame(width: 600, height: 400, x: 80, y: 80)

    /// The three faces that between them draw every button: start · resume · pin+lock.
    static let coveringDecisions: [Decision] = [
        .awaitingStart(selfServiceLeft: 1),
        .awaitingResume(remaining: 1200),
        .expired(selfServiceLeft: 0),
    ]

    /// A real PIN, hashed once at the shipped rounds — `1379`, checked by the real verifier.
    static let configuredPIN: Config = {
        var config = Config()
        let salt = newPINSalt()
        config.pinSalt = salt.base64EncodedString()
        config.pinHash = hashPIN("1379", salt: salt)
        return config
    }()

    static func model(_ decision: Decision, used: Int = 0, config: Config = Config()) -> CoverModel {
        CoverModel(decision: decision, sessionsUsedToday: used, config: config)!
    }

    /// The title the cover draws for a button, computed the same way the view does, so the
    /// assertion follows the lock mechanism actually resolved rather than guessing it.
    static func expectedTitle(_ kind: CoverModel.Button) -> String {
        switch kind {
        case .start: return Strings.coverStartButton
        case .resume: return Strings.coverResumeButton
        case .pin: return Strings.gated(Strings.coverPINButton)
        case .lock:
            return ScreenLock.mechanism == .lockImmediately
                ? Strings.coverLockButton : Strings.coverLogOutButton
        }
    }

    /// Every string the cover is allowed to show for a face, derived from ``Strings``.
    static func expectedStrings(for model: CoverModel) -> Set<String> {
        var set: Set<String> = []
        switch model.face {
        case .start(let minutes, let index, let limit):
            set.insert(Strings.coverStart(minutes: minutes))
            set.insert(Strings.coverSessionCount(index: index, of: limit))
        case .resume(let minutesLeft):
            set.insert(Strings.coverResume(minutes: minutesLeft))
        case .expired:
            set.insert(Strings.coverExpired)
        case .exhausted:
            set.insert(Strings.coverExhausted)
        }
        for button in model.buttons { set.insert(expectedTitle(button)) }
        return set
    }

    // MARK: - Driving the cover

    /// Press the gated `Wprowadź PIN` button and pump until the prompt's boxes appear — the
    /// press dispatches to the prompt one hop late (T00), so the pump is required.
    static func openPINPrompt(on content: CoverContentView) async {
        let pin = button(withIdentifier: CoverModel.Button.pin.rawValue, in: content)
        pin?.performClick(nil)
        await pump(until: { content.firstDescendant(of: PINBoxes.self) != nil })
    }

    /// Feed digits to the boxes as separate key-down events, exactly as a real keyboard would;
    /// the fourth submits the attempt (T00 verified this path faithful in memory).
    static func type(_ digits: String, into boxes: PINBoxes) {
        for character in digits {
            let key = String(character)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: key, charactersIgnoringModifiers: key,
                                         isARepeat: false, keyCode: 0)!
            boxes.keyDown(with: event)
        }
    }

    /// Yield the main actor until `condition` holds, or give up after `timeout`. The button and
    /// flow hops go through the main queue and the verifier answers off the main thread, so a
    /// headed test that touches the PIN flow has to let the main queue drain for either to land.
    ///
    /// **An `await`, not a `RunLoop` pump.** No app run loop services the main queue in the test
    /// process, so `RunLoop.run` does not drain a `DispatchQueue.main.async` here (measured);
    /// suspending the actor does, because the executor that resumes the task is the one draining
    /// that queue. This is why the two PIN tests are `async`.
    static func pump(until condition: () -> Bool, timeout: TimeInterval = 15) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms
        }
    }

    static func button(withIdentifier identifier: String, in view: NSView) -> NSButton? {
        view.allDescendants(of: NSButton.self).first { $0.identifier?.rawValue == identifier }
    }

    static func button(titled title: String, in view: NSView) -> NSButton? {
        view.allDescendants(of: NSButton.self).first { $0.title == title }
    }
}

// MARK: - The recording enforcer double

/// **Stands in for `CoverEnforcer` and the tick it drives** (T02).
///
/// The real enforcer wires the cover's PIN prompt to `GrantCommand`, whose `.extend` runs
/// `Engine.extend` and a tick, and the tick is what calls `CoverController.hide()`. This
/// records the outcome the prompt produced and, for a granting one, calls `hide()` itself —
/// so a headed test can assert the dismissal path without a real engine or tick loop. The
/// controller here is built through the seam, so its window list is empty and `hide()` is a
/// safe no-op; the point is that the path arrives at it.
@MainActor
final class RecordingEnforcer {
    weak var controller: CoverController?
    private let config: Config
    private let clock: any Clock

    private(set) var outcomes: [PINFlow.Outcome] = []
    private(set) var pressed: [CoverModel.Button] = []

    /// True once a granting outcome has taken the cover down, as the tick would.
    var dismissed: Bool {
        outcomes.contains { if case .extend = $0 { return true } else { return false } }
    }

    init(config: Config, clock: any Clock) {
        self.config = config
        self.clock = clock
    }

    func press(_ button: CoverModel.Button) { pressed.append(button) }

    func makeFlow(scale: CGFloat, closed: @escaping () -> Void) -> PINFlow? {
        PINFlow(action: .extend, config: { [config] in config }, clock: clock,
                scale: scale) { [weak self] outcome in
            // One hop, as the real enforcer takes: taking the cover down releases the view
            // whose button action is still on the stack.
            DispatchQueue.main.async {
                closed()
                guard let self else { return }
                self.outcomes.append(outcome)
                if case .extend = outcome { self.controller?.hide() }
            }
        }
    }
}

extension CoverHeadedTests {
    /// Everything the tests need to drive one cover: the controller and the two objects a
    /// headed test observes it through — the kiosk it must not have engaged and the enforcer
    /// double the PIN prompt talks to.
    @MainActor
    struct Rig {
        let controller: CoverController
        let kiosk: KioskLock
        let enforcer: RecordingEnforcer
        let clock: FakeClock
    }

    static func makeRig(frame: CoverFrame? = nil, config: Config = Config()) -> Rig {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let enforcer = RecordingEnforcer(config: config, clock: clock)
        let kiosk = KioskLock(clock: clock)
        // A watchdog is required but harmless here: it only ever acts once a cover is up, and
        // the seam never tells it one is. An hour's stall keeps it from firing regardless.
        let watchdog = Watchdog.start(stallSeconds: 3600, sink: NullEventSink(),
                                      clock: clock) { _ in }
        let controller = CoverController(
            frame: frame, clock: clock, seatbelt: nil, watchdog: watchdog, kiosk: kiosk,
            onPress: { button in enforcer.press(button) },
            makePINFlow: { scale, closed in enforcer.makeFlow(scale: scale, closed: closed) })
        enforcer.controller = controller
        return Rig(controller: controller, kiosk: kiosk, enforcer: enforcer, clock: clock)
    }
}

// MARK: - Walking the view tree

private extension NSView {
    /// The first descendant of a type, depth-first — for reaching a control the cover built.
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T { return hit }
            if let hit = sub.firstDescendant(of: type) { return hit }
        }
        return nil
    }

    func allDescendants<T: NSView>(of type: T.Type) -> [T] {
        var found: [T] = []
        for sub in subviews {
            if let hit = sub as? T { found.append(hit) }
            found += sub.allDescendants(of: type)
        }
        return found
    }
}
