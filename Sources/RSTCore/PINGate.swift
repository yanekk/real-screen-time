import Foundation

/// **What a PIN prompt is standing in front of** (T13).
///
/// Two, because DESIGN §2.5 has two things behind the PIN: adding minutes and standing the
/// app down. `Ustawienia…` and `Zakończ` are gated in the menu too, and are deliberately
/// *not* here — T17 and T18 own them, and a case with no caller is a case nobody tests.
///
/// It carries no Polish: the two labels are `Strings.menuExtend` and `Strings.menuDisable`
/// over in `RSTApp`, like every other word the child can read (DESIGN §2.4.2).
public enum PINAction: String, Equatable, Sendable, CaseIterable {
    /// `Dodaj minuty…` — the prompt is followed by the amount picker.
    case extend
    /// `Wyłącz do jutra` — the prompt is the whole of it; a correct PIN acts immediately.
    case disable
    /// `Ustawienia…` — the prompt is the whole of it too, and what a correct PIN opens is
    /// the settings window (T17). **The one action that grants nothing**, which is why
    /// ``PINFlow`` answers it with `.unlocked` rather than with a command for the engine.
    case settings
}

/// **The rate limit on PIN attempts** — T13's "1s, growing to 5s".
///
/// Not a security measure and not sold as one: DESIGN §2.5 calls the PIN a speed bump, and
/// four digits with a patient child is a real scenario. This makes it boring rather than
/// impossible. **It never locks out**, at any number of failures — a locked-out PIN field on
/// a covered screen is precisely the trap §2.5 exists to avoid, and the delay is bounded at
/// five seconds for that reason.
///
/// **One attempt is four digits**, which is the whole of the ambiguity there used to be
/// here. The prompt was a single field verifying on every keystroke, and "a wrong attempt"
/// then had to mean either every keystroke — putting a growing delay between a parent's own
/// four digits — or only a submitted one, which needed a rule nobody could see on the
/// screen. Since 2026-08-25 the prompt is four boxes that submit themselves on the fourth
/// digit (the user's change), so there is exactly one attempt per four digits and nothing
/// left to interpret. The boxes go inert while this gate is shut, so a held-down key cannot
/// queue guesses behind the wait either.
///
/// A value rather than an object so `make test` can drive a hundred failures in
/// microseconds; the clock arrives as a parameter, as it does everywhere in `RSTCore`.
public struct PINGate: Equatable, Sendable {

    /// The delay after the first failure, in seconds, and the step by which it grows.
    public static let step: TimeInterval = 1
    /// The ceiling. Five seconds is long enough to be tedious ten thousand times over and
    /// short enough that a parent who fumbled one digit does not think the app has hung.
    public static let maxDelay: TimeInterval = 5

    /// Failed submissions in a row. Reset by a correct PIN, never by time — a child who
    /// comes back an hour later is the same child, and the delay costs an honest parent one
    /// second at most.
    public private(set) var failures = 0

    /// The instant the next attempt may run, or `nil` when nothing is being held back.
    public private(set) var openAt: Date?

    public init() {}

    /// How long after the *n*th consecutive failure: 1, 2, 3, 4, 5, 5, 5…
    ///
    /// Linear rather than doubling. A doubling backoff reaches minutes by the tenth attempt,
    /// and minutes on a covered screen is the lockout this must never become; the cap is
    /// what the schedule is really for, and it is reached in five failures either way.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // `Double(failures)` cannot overflow a `TimeInterval`, and `min` closes the case
        // where a caller has been failing since the Bronze Age.
        return min(maxDelay, Double(failures) * step)
    }

    /// A wrong PIN, submitted. Closes the gate for ``delay(afterFailures:)``.
    public mutating func failed(at now: Date) {
        // Saturating rather than wrapping: `failures &+ 1` past `Int.max` would go negative
        // and hand back a delay of zero, which is the one direction this must not fail.
        failures = failures == Int.max ? failures : failures + 1
        openAt = now.addingTimeInterval(Self.delay(afterFailures: failures))
    }

    /// The right PIN. The next prompt starts from a clean slate.
    public mutating func succeeded() {
        failures = 0
        openAt = nil
    }

    /// Seconds still to wait, or `0` when an attempt may run now.
    ///
    /// Clamped at both ends: a clock stepped backwards while the gate is closed would
    /// otherwise hold it shut for the size of the correction, and `RST_TIME_SCALE` moves the
    /// clock in leaps.
    public func wait(at now: Date) -> TimeInterval {
        guard let openAt else { return 0 }
        let remaining = openAt.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return min(remaining, Self.maxDelay)
    }

    /// May an attempt run at this instant.
    public func isOpen(at now: Date) -> Bool { wait(at: now) == 0 }
}

/// **What `Dodaj minuty…` offers, and which amount it starts on** (DESIGN §2.5, T13).
///
/// One line of rule and it is still worth a type: the pre-selection *is* the parent's
/// one-keystroke default — `Dodaj minuty…` ▸ PIN ▸ Enter grants the first entry with no
/// further choice — so which entry that is, and that reordering the list is how it changes,
/// is a property `make test` should be able to state. The alternative is a `.first!` in a
/// view, on a list off a hand-edited `config.json`.
///
/// The amounts come through ``Config/extensionChoices``, never `extensionOptions` directly:
/// that is where the non-positives, the duplicates and the empty list are dealt with, and a
/// grant dialog with no amounts on it is a PIN prompt that can grant nothing.
public struct GrantModel: Equatable, Sendable {

    /// In the parent's own order, drawn as given. **Never empty.**
    public let amounts: [Int]

    /// The index the dialog opens on. Always `0` — stated as a property rather than left
    /// implicit so that "the first entry is pre-selected" is asserted somewhere.
    public let preselected: Int

    public init(config: Config) {
        amounts = config.extensionChoices
        preselected = 0
    }

    /// The amount a parent gets by pressing Enter twice.
    ///
    /// Non-optional: ``Config/extensionChoices`` guarantees a non-empty list, and this is
    /// the one place that guarantee is worth restating — the fallback is the shipped list
    /// rather than a crash on an empty array.
    public var defaultAmount: Int {
        amounts.indices.contains(preselected)
            ? amounts[preselected]
            : (Config.defaultExtensionOptions.first ?? 15)
    }
}
