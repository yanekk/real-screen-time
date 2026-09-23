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

    /// A correct PIN for `.extend` shows the amounts, first pre-selected; choosing one and
    /// confirming yields `.extend(minutes:)` with that amount.
    @Test("a right PIN to extend shows amounts, and a chosen one yields .extend(minutes:)")
    func extendYieldsChosenAmount() {
        HeadedHarness.withApp { _ in
            var outcome: PINFlow.Outcome?
            let flow = Self.makeFlow(.extend, verifier: ScriptedVerifier(accept: true)) {
                outcome = $0
            }
            let boxes = try! #require(flow.keyboardTarget as? PINBoxes)

            Self.type("1379", into: boxes)

            // The default extension choices, drawn in order, each as a Strings amount.
            let amounts = Config().extensionChoices
            for amount in amounts {
                #expect(Self.button(Strings.minutes(amount), in: flow) != nil, "\(amount) missing")
            }
            #expect(outcome == nil)   // nothing granted until an amount is confirmed

            // Pick the second amount rather than the pre-selected first, so the assertion
            // proves the chosen value flows through and not just the default.
            let chosen = amounts[1]
            Self.button(Strings.minutes(chosen), in: flow)?.performClick(nil)
            Self.button(Strings.grantConfirmButton, in: flow)?.performClick(nil)

            #expect(outcome == .extend(minutes: chosen))
        }
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
            expected = [Strings.grantTitle, Strings.pinCancelButton, Strings.grantConfirmButton]
            for amount in Config().extensionChoices { expected.insert(Strings.minutes(amount)) }
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
                         clock: any Clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000)),
                         verifier: any PINVerifying,
                         countdown: any Countdown = ManualCountdown(),
                         finish: @escaping (PINFlow.Outcome) -> Void = { _ in }) -> PINFlow {
        PINFlow(action: action, config: configuredPIN, clock: clock,
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
