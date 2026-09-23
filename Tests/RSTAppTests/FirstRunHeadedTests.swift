import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **The first-run wizard, in memory** (DESIGN §2.1 Tier 1, §2.2 faithful-in-memory band; T05).
///
/// The rules — which step follows which, whether a typed PIN pair is acceptable, the session
/// numbers — are ``FirstRunStep``, ``firstRunPINProblem`` and ``SessionLimits`` in `RSTCore`,
/// unit-tested there. What is under test here is the AppKit wiring in `FirstRun.swift`: that the
/// nav buttons walk the step machine welcome → PIN → sessions → login → done, that the PIN step
/// takes a PIN entered twice through the shared ``PINBoxes`` and refuses a mismatch, and that the
/// primary button's title tracks the step.
///
/// Everything is built through ``FirstRunWindow/buildForTesting(isConfigured:...)`` — the
/// build-but-do-not-show seam (§3.1) — so no window is ordered onto a display and the activation
/// policy is never taken to `.regular`. **Nothing here clicks `Install login item`**: that runs
/// the real `launchctl` install, so the walk to the terminal screen goes through `Finish without
/// it`, and the install button is only ever read, never pressed. The scan in `WindowScanTests`
/// guards that this file names none of the ordering calls.
///
/// **The walk is `async`, the mismatch is not.** Leaving the sessions step hashes the PIN off the
/// main thread and hops back to show the login step (`saveAnswers`), so that one test pumps the
/// main queue for the transition (the same shape the cover PIN tests use); a mismatch is decided
/// synchronously in `pinEntered` with no hop. Serialized like the other headed suites.
@Suite("First-run wizard headed", .serialized)
@MainActor
struct FirstRunHeadedTests {

    // MARK: - The whole walk

    /// welcome → PIN → sessions → login → done, driven entirely through the nav buttons, with the
    /// primary's title asserted at each step. The one asynchronous edge is sessions → login, where
    /// the PIN is hashed; the pump waits it out. The login step's install button is read for its
    /// title and left alone — `Finish without it` is what carries the wizard to the terminal
    /// screen without touching `launchctl`.
    @Test("the nav buttons walk every step and the primary's title tracks them")
    func navButtonsWalkTheSteps() async throws {
        _ = NSApplication.shared
        let recorder = SaveRecorder()
        let wizard = FirstRunWindow.buildForTesting(isConfigured: false, clock: Self.clock,
                                                    save: recorder.save)

        // Step 1 — welcome.
        #expect(wizard.testStep == .welcome)
        #expect(wizard.testNextButton.title == "Continue")
        wizard.testNextButton.performClick(nil)

        // Step 2 — PIN. Cannot be walked past until a PIN is settled.
        #expect(wizard.testStep == .pin)
        #expect(wizard.testNextButton.title == "Continue")
        #expect(!wizard.testNextButton.isEnabled)
        Self.type("1379", into: wizard.testPINBoxes)      // first entry
        Self.type("1379", into: wizard.testPINBoxes)      // and again — a matching pair
        #expect(wizard.testNextButton.isEnabled)          // the PIN is stored; the step opens
        wizard.testNextButton.performClick(nil)

        // Step 3 — sessions. Continue hashes the PIN (off-main) and lands on step 4.
        #expect(wizard.testStep == .sessions)
        #expect(wizard.testNextButton.title == "Continue")
        wizard.testNextButton.performClick(nil)
        await Self.pump(until: { wizard.testStep == .login })

        // Step 4 — login. Install is the primary (read, never pressed); Finish without it carries on.
        #expect(wizard.testStep == .login)
        #expect(wizard.testNextButton.title == "Install login item")
        #expect(wizard.testAltButton.title == "Finish without it")
        wizard.testAltButton.performClick(nil)

        // The terminal screen — one Finish, which commits the answers on the way out.
        #expect(wizard.testStep == .done)
        #expect(wizard.testNextButton.title == "Finish")
        wizard.testNextButton.performClick(nil)
        #expect(recorder.saved.count == 1)
        #expect(recorder.saved.first?.limits == SessionLimits.suggested)
    }

    // MARK: - The PIN step

    /// A mismatched pair is refused: the PIN is not stored, the step does not advance, and a
    /// press of Continue while it is unsettled does nothing — the exact silent-no-op shape the
    /// wizard's `isARepeat` guard also protects. Synchronous, since a mismatch never hashes.
    @Test("a mismatched PIN does not settle and does not advance")
    func mismatchedPINDoesNotAdvance() {
        HeadedHarness.withApp { _ in
            let wizard = FirstRunWindow.buildForTesting(isConfigured: false, clock: Self.clock)
            wizard.testNextButton.performClick(nil)           // welcome → pin
            #expect(wizard.testStep == .pin)

            Self.type("1379", into: wizard.testPINBoxes)      // first entry
            Self.type("0000", into: wizard.testPINBoxes)      // a different second entry

            #expect(!wizard.testNextButton.isEnabled)          // nothing settled
            wizard.testNextButton.performClick(nil)            // and Continue is inert
            #expect(wizard.testStep == .pin)                   // still on the PIN step
        }
    }

    /// A matching pair, entered on a fresh wizard, settles the PIN and enables Continue — the
    /// positive twin of the mismatch above, isolated so the storing itself is not proven only by
    /// the walk. Synchronous: settling happens in `pinEntered`, and only the later Continue hashes.
    @Test("a matching PIN entered twice settles and enables Continue")
    func matchingPINSettles() {
        HeadedHarness.withApp { _ in
            let wizard = FirstRunWindow.buildForTesting(isConfigured: false, clock: Self.clock)
            wizard.testNextButton.performClick(nil)           // welcome → pin
            #expect(!wizard.testNextButton.isEnabled)

            Self.type("2468", into: wizard.testPINBoxes)
            #expect(!wizard.testNextButton.isEnabled)          // one entry is not enough
            Self.type("2468", into: wizard.testPINBoxes)
            #expect(wizard.testNextButton.isEnabled)           // the pair matched; the PIN is set
        }
    }

    // MARK: - Fixtures

    static let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))

    /// Feed digits to the boxes as separate key-down events, exactly as a real keyboard would;
    /// the fourth submits the entry (the shared `PINBoxes` path T00 verified faithful in memory).
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

    /// Yield the main actor until `condition` holds, or give up after `timeout`. The sessions →
    /// login transition hashes the PIN on a background queue and hops back through the main queue;
    /// suspending the actor is what lets that queue drain, exactly as the cover PIN tests do.
    static func pump(until condition: () -> Bool, timeout: TimeInterval = 15) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms
        }
    }
}

// MARK: - The save recorder

/// **Stands in for `main.swift`'s `ConfigStore`** (T05). The wizard hands its answers to a
/// `Save` closure when the window closes; this records them so a headed test can assert what was
/// committed, and returns `nil` — the success the wizard expects.
@MainActor
final class SaveRecorder {
    private(set) var saved: [FirstRunAnswers] = []
    lazy var save: FirstRunWindow.Save = { [weak self] answers in
        self?.saved.append(answers)
        return nil
    }
}
