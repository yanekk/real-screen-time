import Foundation

/// **What the app is about to say out loud** (DESIGN §2.4, §2.5).
///
/// A value rather than a string, because the words are Polish and Polish strings live in
/// one file on the other side of the boundary (`Strings.swift`, §2.4.2). What is decided
/// *here* is which of the four things is being said and what number goes in it — and that
/// is a rule, so it is testable. What the sentence sounds like is a translation, and
/// `RSTApp` does it.
///
/// The three of them are one type because they travel the same path: chime, then speech,
/// then a banner. An enforcer that could speak a warning but not a grant would be two
/// mechanisms with one bug each.
public enum Announcement: Equatable, Sendable {

    /// A warning threshold has been crossed — `minutes` is the threshold, not the exact
    /// remainder, because "5 minutes left" is what a person needs and `4:59` is not.
    ///
    /// `suggestsSaving` adds §2.4's `Zapisz swoją grę.` — three words, on the one threshold
    /// that still leaves time to act (``Config/warningSuggestsSaving(_:)`` owns which).
    /// Without it the five-minute warning is the ten-minute warning with a different number
    /// in it, and nothing the app says ever tells him to do anything.
    ///
    /// **It is not §2.6.2's consequence sentence, which is gone.** That one explained that a
    /// fullscreen app is quit when the cover appears, and the user cut it after hearing it on
    /// 2026-08-25 — eight words about consequences, three times a session. This is the
    /// instruction on its own, restored on 2026-08-25 at his direction after the review found
    /// §2.4 had specified it all along and the app had never said it.
    case warning(minutes: Int, suggestsSaving: Bool)

    /// The session ran out under an ordinary tick and the cover is going up. The banner
    /// row of §2.4's table for this one *is* the cover, so this announcement is heard and
    /// not seen.
    case expired

    /// The parent granted minutes behind the PIN (§2.5). `minutes` is theirs, so the
    /// sentence has to decline whatever they picked.
    case granted(minutes: Int)

    /// One line of English for `app.log`, which is the parent's file (§2.4.2).
    ///
    /// Here rather than at the two call sites that need it, and spelled out rather than
    /// interpolated: the synthesised description of this enum reads
    /// `warning(minutes: 10, suggestsSaving: false)`, which is a Swift value and not a
    /// sentence — the same objection `Gap` answered at T08.
    public var logDescription: String {
        switch self {
        case .warning(let minutes, let suggestsSaving):
            return "\(minutes) min warning" + (suggestsSaving ? ", save your game" : "")
        case .expired:
            return "time is up"
        case .granted(let minutes):
            return "granted \(minutes) min"
        }
    }
}

// MARK: - Polish numerals, and the two that a digit gets wrong

/// **Which numeral form a spoken minute count needs.**
///
/// The app writes `10` and lets the voice read it, which is right for almost every number:
/// a `pl-PL` voice says *dziesięć* for `10` and *piętnaście* for `15`. It is wrong for
/// exactly two shapes, because `minuta` is feminine and the digits are read in the
/// masculine — `1` comes out *jeden minuta* and `22` comes out *dwadzieścia dwa minuty*.
/// Those are spelled out in words instead.
///
/// The user chose this over writing a full Polish number-speller (2026-08-25): a speller is
/// new code with its own mistakes in every number, where this is a table with two rows.
///
/// Like ``PolishPlural``, the *rule* is here where `make test` reaches it and the *words*
/// are in `Strings.swift` with every other Polish word in the app.
public enum PolishNumeral: Equatable, Sendable {
    /// Read the digits. The voice declines them correctly.
    case digits
    /// `1` — *jedna* in the nominative, *jedną* in the accusative.
    case one
    /// Ends in 2 — *dwie*, after the tens word when there is one. `tens` is `0`, `20`,
    /// `30` … `90`; `0` means the word stands alone.
    case two(tens: Int)

    public static func form(_ count: Int) -> PolishNumeral {
        // `magnitude`, not `abs`: `abs(Int.min)` traps. Same guard as ``PolishPlural/form(_:)``
        // and for the same reason — this is reachable from a hand-edited `config.json`.
        let n = count.magnitude
        if n == 1 { return .one }

        // Above 99 the tens word is not enough — `102` would need *sto* as well — and a
        // hundred-minute warning threshold is not a thing anyone will set. The digits are
        // read out with the wrong gender in that one case, and that is the honest limit of
        // a two-row table.
        guard n < 100, n % 10 == 2, n % 100 != 12 else { return .digits }
        return .two(tens: Int(n / 10) * 10)
    }
}
