import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **The shared PIN flow, in memory** (DESIGN §2.1 Tier 1, §2.2 faithful-in-memory band; T03).
///
/// The prompt behind every gate — the cover, the menu-bar panel, the wizard, the Settings
/// PIN-change sheet — is one `PINFlow`, so covering it once here protects all four. These
/// checks are the digit boxes accepting digits only and submitting themselves on the fourth,
/// the rate-limit wait shutting entry and re-opening it once the gate's delay has elapsed, and
/// each outcome the flow reports — extend with a chosen amount, disable, settings-unlock,
/// cancel — every visible word of it resolving through ``Strings``.
///
/// **Fully synchronous, no run-loop pump.** The two things that make the shipping flow need a
/// run loop are injected away through the T00 seam: a scripted ``PINVerifying`` answers `ok`
/// inline instead of running 200 000 rounds of HMAC on a background queue and hopping back,
/// and a hand-driven ``Countdown`` stands in for the `Timer` that never fires with no run loop
/// (FINDINGS 2026-09-16). So the wrong-PIN wait is advanced off the injected `clock` and each
/// path runs to completion on the main actor without a pump — which is also why the suite
/// stays fast enough to be worth running on every build.
///
/// Serialized to match the cover suite and because each test swaps the process-global
/// `RST_DATA_DIR` through `HeadedHarness.withApp`; each body is synchronous, so the swap
/// cannot interleave with another headed test (T01 env-swap finding).
@Suite("PIN flow headed", .serialized)
@MainActor
struct PINFlowHeadedTests {

    // MARK: - The boxes

    /// Digits fill boxes, everything else is ignored, and the fourth digit is the whole
    /// submission — there is no other way to confirm, and it must fire exactly once.
    @Test("PINBoxes take digits only and fire onComplete once, on the fourth digit")
    func boxesTakeDigitsOnlyAndCompleteOnce() {
        HeadedHarness.withApp { _ in
            let boxes = PINBoxes(scale: 1)
            var completions: [String] = []
            boxes.onComplete = { completions.append($0) }

            Self.type("12", into: boxes)
            #expect(boxes.digits == "12")
            #expect(completions.isEmpty)          // three short of a submission

            Self.type("ab!.", into: boxes)        // letters, symbols: none of them a slot
            #expect(boxes.digits == "12")

            Self.type("34", into: boxes)          // the fourth digit submits
            #expect(completions == ["1234"])

            // The boxes go inert on the fourth digit, so a fifth keystroke is swallowed and
            // cannot fire a second attempt.
            #expect(!boxes.isEnabled)
            Self.type("9", into: boxes)
            #expect(completions == ["1234"])
        }
    }

    // MARK: - The rate-limit wait

    /// A wrong PIN empties the boxes, shuts them for the gate's delay with the countdown line
    /// showing, and — once the injected clock has passed that delay and the countdown ticks —
    /// re-opens them showing `Nieprawidłowy PIN`. The real-time counting-down of the label is
    /// a Tier 2 / hand check: T00 found the `Timer` does not fire in memory, so only the
    /// re-enable at the end of the wait is asserted here (task T03, "Tests").
    @Test("a wrong PIN disables entry, then the elapsed gate re-enables it showing pinWrong")
    func wrongPINWaitsThenReEnables() {
        HeadedHarness.withApp { _ in
            let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
            let verifier = ScriptedVerifier(accept: false)
            let countdown = ManualCountdown()
            let flow = Self.makeFlow(.extend, clock: clock,
                                     verifier: verifier, countdown: countdown)
            let boxes = try! #require(flow.keyboardTarget as? PINBoxes)

            Self.type("0000", into: boxes)

            // The scripted verifier was actually consulted — the wiring under test, not the
            // no-PIN short-circuit that also holds back.
            #expect(verifier.offered == ["0000"])
            #expect(boxes.digits == "")                       // emptied, so the next four can land
            #expect(!boxes.isEnabled)                         // shut for the wait
            #expect(Self.strings(of: flow).contains(Strings.pinWait(seconds: 1)))
            #expect(countdown.running)                        // and the countdown is arming it

            // Nothing has re-opened it yet: a tick while the gate is still shut leaves it shut.
            countdown.fire()
            #expect(!boxes.isEnabled)

            // Advance past the one-second delay and tick again: the gate is open, so the boxes
            // re-enable and the line becomes the plain wrong-PIN message.
            clock.advance(1)
            countdown.fire()
            #expect(boxes.isEnabled)
            #expect(!countdown.running)                       // the flow stopped it on re-open
            #expect(Self.strings(of: flow).contains(Strings.pinWrong))
        }
    }

    // MARK: - The outcomes

    /// A correct PIN for `.extend` shows `Dodaj minuty`, one `+N` button per default amount
    /// and `Anuluj`, and no radio button anywhere: the picker-plus-confirm shape is gone
    /// (cover-buttons-logout DESIGN §2.1).
    @Test("a right PIN to extend shows +15 +30 +60 and Anuluj, and no radio button")
    func extendShowsAmountButtons() {
        HeadedHarness.withApp { _ in
            let flow = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: true))
            Self.type("1379", into: try! #require(flow.keyboardTarget as? PINBoxes))

            #expect(Self.strings(of: flow) == [Strings.grantTitle, "+15", "+30", "+60",
                                               Strings.pinCancelButton])
            for button in flow.view.allDescendants(of: NSButton.self) {
                #expect(!Self.isRadio(button), "‘\(button.title)’ is a radio button")
                // The cover's style, in the panel too (T05: the parent chose it to follow).
                // All neutral: no amount is a default (sort-grant-amounts).
                #expect((button as? CoverButton)?.role == .neutral, "‘\(button.title)’")
            }
            for amount in [15, 30, 60] {
                let button = Self.button("+\(amount)", in: flow)
                #expect(button?.accessibilityIdentifier() == "amount-\(amount)")
            }
        }
    }

    /// One press on `+30` grants exactly 30, at once; a second press after it is ignored,
    /// so a double click cannot grant twice.
    @Test("+30 finishes the flow with .extend(minutes: 30) exactly once")
    func amountButtonGrantsOnce() {
        HeadedHarness.withApp { _ in
            var outcomes: [PINFlow.Outcome] = []
            let flow = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: true)) {
                outcomes.append($0)
            }
            Self.type("1379", into: try! #require(flow.keyboardTarget as? PINBoxes))
            #expect(outcomes.isEmpty)   // nothing granted until an amount is pressed

            let plus30 = try! #require(Self.button(Strings.grantAmountButton(30), in: flow))
            plus30.performClick(nil)
            #expect(outcomes == [.extend(minutes: 30)])

            plus30.performClick(nil)
            Self.button(Strings.grantAmountButton(15), in: flow)?.performClick(nil)
            #expect(outcomes == [.extend(minutes: 30)])
        }
    }

    /// `Anuluj` on the amount step backs out with `.cancelled`, granting nothing.
    @Test("Anuluj on the amount step finishes with .cancelled")
    func cancelOnAmountStep() {
        HeadedHarness.withApp { _ in
            var outcomes: [PINFlow.Outcome] = []
            let flow = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: true)) {
                outcomes.append($0)
            }
            Self.type("1379", into: try! #require(flow.keyboardTarget as? PINBoxes))
            #expect(Self.strings(of: flow).contains(Strings.grantTitle))

            Self.button(Strings.pinCancelButton, in: flow)?.performClick(nil)
            #expect(outcomes == [.cancelled])
        }
    }

    /// The parent's list, ascending whatever order it was typed in (sort-grant-amounts).
    /// Above three amounts the buttons stack vertically so a long list does not run off a
    /// 600×400 boxed cover; none carries Return.
    @Test("config [15, 30, 60, 5, 10]: five buttons ascending, vertical, none on Return")
    func customAmountsVerticalAscending() {
        HeadedHarness.withApp { _ in
            var config = Self.configuredPIN()
            config.extensionOptions = [15, 30, 60, 5, 10]
            let flow = Self.makeFlow(.extend, config: config,
                                     verifier: ScriptedVerifier(accept: true))
            Self.type("1379", into: try! #require(flow.keyboardTarget as? PINBoxes))

            let amounts = Self.amountButtons(in: flow)
            #expect(amounts.map(\.title) == ["+5", "+10", "+15", "+30", "+60"])
            #expect(amounts.map(\.tag) == [5, 10, 15, 30, 60])
            let grid = amounts.first?.superview as? NSStackView
            #expect(grid?.orientation == .vertical)
            #expect(amounts.allSatisfy { $0.keyEquivalent.isEmpty })
            #expect(amounts.allSatisfy { ($0 as? CoverButton)?.role == .neutral })
            #expect(Self.button(Strings.pinCancelButton, in: flow)?.keyEquivalent == "")
        }
    }

    /// Three or fewer amounts sit in one horizontal row; none carries Return there either.
    @Test("the default three amounts sit in a horizontal row, none on Return")
    func defaultAmountsHorizontal() {
        HeadedHarness.withApp { _ in
            let flow = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: true))
            Self.type("1379", into: try! #require(flow.keyboardTarget as? PINBoxes))

            let amounts = Self.amountButtons(in: flow)
            #expect((amounts.first?.superview as? NSStackView)?.orientation == .horizontal)
            #expect(amounts.map(\.keyEquivalent) == ["", "", ""])
        }
    }

    /// **Enter grants nothing on the amount step** (sort-grant-amounts): with the list
    /// sorted, the first amount is not a choice, so Return must not pick it.
    @Test("Return on the amount step completes nothing")
    func returnOnAmountStepGrantsNothing() {
        HeadedHarness.withApp { _ in
            var outcomes: [PINFlow.Outcome] = []
            let flow = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: true)) {
                outcomes.append($0)
            }
            let window = CoverDrillHeadedTests.window(holding: flow.view)
            Self.type("1379", into: try! #require(flow.keyboardTarget as? PINBoxes))
            #expect(!Self.amountButtons(in: flow).isEmpty)

            _ = window.performKeyEquivalent(with: CoverDrillHeadedTests.key("\r", code: 36))
            #expect(outcomes.isEmpty)
        }
    }

    /// A config with no usable amounts falls back to `+15 +30 +60`. ``GrantModel`` owns the
    /// fallback; this proves it reaches the screen.
    @Test("no usable amounts in config falls back to +15 +30 +60 on screen")
    func unusableAmountsFallBack() {
        HeadedHarness.withApp { _ in
            var config = Self.configuredPIN()
            config.extensionOptions = [0, -5]
            let flow = Self.makeFlow(.extend, config: config,
                                     verifier: ScriptedVerifier(accept: true))
            Self.type("1379", into: try! #require(flow.keyboardTarget as? PINBoxes))

            #expect(Self.amountButtons(in: flow).map(\.title) == ["+15", "+30", "+60"])
        }
    }

    @Test("Strings.grantAmountButton(15) is +15")
    func grantAmountButtonString() {
        #expect(Strings.grantAmountButton(15) == "+15")
    }

    /// The three non-extend paths, each straight from a correct PIN with no second stage:
    /// `.disable` stands the app down, `.settings` unlocks, and cancelling at the boxes backs
    /// out with `.cancelled`.
    @Test("disable, settings and cancel each report their own outcome")
    func disableSettingsAndCancelOutcomes() {
        HeadedHarness.withApp { _ in
            // .disable
            var disableOutcome: PINFlow.Outcome?
            let disable = Self.makeFlow(.disable, verifier: ScriptedVerifier(accept: true)) {
                disableOutcome = $0
            }
            Self.type("1379", into: try! #require(disable.keyboardTarget as? PINBoxes))
            #expect(disableOutcome == .disable)

            // .settings
            var settingsOutcome: PINFlow.Outcome?
            let settings = Self.makeFlow(.settings, verifier: ScriptedVerifier(accept: true)) {
                settingsOutcome = $0
            }
            Self.type("1379", into: try! #require(settings.keyboardTarget as? PINBoxes))
            #expect(settingsOutcome == .unlocked)

            // Cancel — from the boxes, before any digit. The way out is always present.
            var cancelOutcome: PINFlow.Outcome?
            let cancel = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: false)) {
                cancelOutcome = $0
            }
            Self.button(Strings.pinCancelButton, in: cancel)?.performClick(nil)
            #expect(cancelOutcome == .cancelled)
        }
    }

    // MARK: - No inline literals

    /// Every visible string in the flow — both stages — resolves through ``Strings``. An
    /// inline English literal on a control the child can read is the exact mistake the
    /// bilingual split forbids (DESIGN §2.4.2); one would not be in the expected set below.
    @Test("no flow string is an inline literal — every one resolves through Strings")
    func everyStringComesFromStrings() {
        HeadedHarness.withApp { _ in
            // Entry stage.
            let entry = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: true))
            var expected: Set<String> = [
                Strings.pinTitle, Strings.pinFor(.extend), Strings.pinCancelButton,
            ]
            for shown in Self.strings(of: entry) {
                #expect(expected.contains(shown), "‘\(shown)’ on the PIN stage is not a Strings value")
            }

            // Amount stage — reached by a correct PIN.
            Self.type("1379", into: try! #require(entry.keyboardTarget as? PINBoxes))
            expected = [Strings.grantTitle, Strings.pinCancelButton]
            for amount in Config().extensionChoices {
                expected.insert(Strings.grantAmountButton(amount))
            }
            for shown in Self.strings(of: entry) {
                #expect(expected.contains(shown), "‘\(shown)’ on the amount stage is not a Strings value")
            }
        }
    }

    // MARK: - Fixtures

    /// A config carrying a usable PIN, so `attempt` reaches the verifier rather than the
    /// no-PIN short-circuit. The salt and hash are placeholders: the scripted verifier ignores
    /// both — its whole point is to answer without the real 200 000-round hash — but they must
    /// be present and well-formed for `pinSaltData`/`pinHash` to read as configured.
    static func configuredPIN() -> Config {
        var config = Config()
        config.pinSalt = Data([1, 2, 3, 4]).base64EncodedString()
        config.pinHash = "placeholder — the scripted verifier never checks it"
        return config
    }

    /// Build a flow with the two seam doubles injected and a default no-op `finish`.
    static func makeFlow(_ action: PINAction,
                         config: Config = configuredPIN(),
                         clock: any Clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000)),
                         verifier: any PINVerifying,
                         countdown: any Countdown = ManualCountdown(),
                         finish: @escaping (PINFlow.Outcome) -> Void = { _ in }) -> PINFlow {
        PINFlow(action: action, config: { config }, clock: clock,
                verifier: verifier, countdown: countdown, finish: finish)
    }

    // MARK: - Driving the flow

    /// Feed digits to the boxes as separate key-down events, exactly as a real keyboard would.
    /// **Real keystrokes, not a direct setter**: T00 verified that a synthesised
    /// `NSEvent.keyEvent` through `keyDown` registers the digit and fires `onComplete` on the
    /// fourth, faithfully in memory (FINDINGS 2026-09-16) — so the tests drive the same path a
    /// child does rather than a shortcut around it.
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

    /// Every visible string in the flow's view — labels and button titles — with the blank
    /// placeholder hint (`" "`) dropped, so only strings actually shown are checked.
    static func strings(of flow: PINFlow) -> [String] {
        let labels = flow.view.allDescendants(of: NSTextField.self).map(\.stringValue)
        let titles = flow.view.allDescendants(of: NSButton.self).map(\.title)
        return (labels + titles).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func button(_ title: String, in flow: PINFlow) -> NSButton? {
        flow.view.allDescendants(of: NSButton.self).first { $0.title == title }
    }

    /// The `+N` buttons, in drawn order, found by their Accessibility identifier rather than
    /// by title, the way a Tier 2 driver would find them.
    static func amountButtons(in flow: PINFlow) -> [NSButton] {
        flow.view.allDescendants(of: NSButton.self)
            .filter { $0.accessibilityIdentifier().hasPrefix("amount-") }
    }

    /// AppKit has no public getter for a button's type. The cell answers `buttonType` by
    /// key-value coding, and `.radio` is what `NSButton(radioButtonWithTitle:)` set on the
    /// pickers this step used to draw.
    static func isRadio(_ button: NSButton) -> Bool {
        (button.cell?.value(forKey: "buttonType") as? UInt) == NSButton.ButtonType.radio.rawValue
    }
}

// MARK: - The seam doubles

/// **A ``PINVerifying`` that answers inline, without a hash** (T03 seam).
///
/// The shipping verifier runs 200 000 rounds of HMAC off the main thread and delivers its
/// answer a run-loop hop later. This one records the offered text and calls `onResult`
/// synchronously with a scripted `accept`, so a headed test drives the accept and reject paths
/// with no hash and no pump.
@MainActor
final class ScriptedVerifier: PINVerifying {
    var onResult: ((String, Bool) -> Void)?
    let accept: Bool
    private(set) var offered: [String] = []

    init(accept: Bool) { self.accept = accept }

    func offer(text: String, hash: String, salt: Data) {
        offered.append(text)
        onResult?(text, accept)
    }
}

/// **A ``Countdown`` fired by hand** (T03 seam).
///
/// The shipping countdown is a repeating `Timer` on the main run loop, which never fires in
/// the test process. This stores the flow's tick and fires it only when a test asks, after the
/// test has advanced the injected clock — so the wrong-PIN → wait → re-enable path runs
/// exactly as the live tick would, without a run loop.
@MainActor
final class ManualCountdown: Countdown {
    private var tick: (() -> Void)?
    /// True between `start` and `stop`, so a test can assert the flow armed and later stopped
    /// the countdown.
    private(set) var running = false

    func start(_ tick: @escaping () -> Void) {
        guard self.tick == nil else { return }   // mirror TimerCountdown's idempotent start
        self.tick = tick
        running = true
    }

    func stop() {
        tick = nil
        running = false
    }

    /// Fire one tick, standing in for the real `Timer`'s quarter-second beat.
    func fire() { tick?() }
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
