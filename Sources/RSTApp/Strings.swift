import Foundation
import RSTCore

/// **Every Polish string in the app, and the only file that may hold one** (DESIGN §2.4.2).
///
/// The split is one rule: if a string can appear *without anyone typing the PIN*, it is
/// Polish. The cover, the banners, the spoken lines, the menu-bar dropdown and the PIN
/// prompt are the child's; Settings, the wizard, `events.jsonl` and `app.log` are the
/// parent's and stay English.
///
/// One file rather than a literal at each call site, because a stray English string on the
/// cover is the exact mistake a bilingual app invites, and this makes finding one a
/// five-second read instead of a hunt through `CoverWindow`, `Banner` and `MenuBar`.
///
/// Not `Localizable.strings`: there is no second locale and never will be — the child reads
/// Polish and the parent reads English, both at once, which is not what a locale is.
enum Strings {

    // MARK: - Menu bar (T10)

    /// `Pozostały czas: 00:18:32`. The clock text is built in `RSTCore` — see
    /// ``MenuBarModel/clockText(_:)`` — so the padding rule stays testable and this line
    /// stays a translation.
    static func menuRemaining(_ clockText: String) -> String {
        "Pozostały czas: \(clockText)"
    }

    /// `Sesja 1 z 1` — self-service sessions started today against the day's allowance.
    static func menuSessionCount(used: Int, of limit: Int) -> String {
        "Sesja \(used) z \(limit)"
    }

    static let menuSettings = "Ustawienia…"
    static let menuExtend = "Dodaj minuty…"
    static let menuDisable = "Wyłącz do jutra"

    // MARK: - The cover (T11)

    /// `Rozpocznij sesję — 30 minut`. The minutes are the session length from `config.json`.
    static func coverStart(minutes: Int) -> String {
        "Rozpocznij sesję — \(self.minutes(minutes))"
    }

    /// `Sesja 1 z 1` — the session he is **about to start**, against the day's allowance.
    ///
    /// Not ``menuSessionCount(used:of:)``, which counts the ones already spent. Two
    /// sentences that look alike and answer different questions, so they are two functions:
    /// a shared one would have to be read twice to know which way round it counts.
    static func coverSessionCount(index: Int, of limit: Int) -> String {
        "Sesja \(index) z \(limit)"
    }

    /// `Wznów sesję — pozostało 20 minut`.
    static func coverResume(minutes: Int) -> String {
        "Wznów sesję — pozostało \(self.minutes(minutes))"
    }

    /// A session ran and is over.
    static let coverExpired = "Czas minął"
    /// Nothing left to start today, whether or not a session ran first.
    static let coverExhausted = "Na dziś koniec sesji"

    static let coverStartButton = "Rozpocznij"
    static let coverResumeButton = "Wznów"
    /// The one gated button on the cover — T13 puts the field behind it.
    static let coverPINButton = "Wprowadź PIN"
    /// Locks the screen. **No PIN**: ending your own turn is the intended exit (§2.6).
    static let coverLockButton = "Zablokuj ekran"
    /// What ``coverLockButton`` becomes when `SACLockScreenImmediate` cannot be resolved.
    /// A button that lies is worse than a blunter one, so the label follows the mechanism.
    static let coverLogOutButton = "Wyloguj"

    // MARK: - The PIN prompt and the two grants (T13)

    /// The prompt's headline. The same words as ``coverPINButton``, and deliberately so:
    /// the button the child pressed and the box that opened should say the same thing.
    static let pinTitle = "Wprowadź PIN"

    /// What the PIN is being asked for, under the headline. Naming it matters most on the
    /// menu-bar path, where the prompt is a panel with nothing else on screen to say which
    /// of the two items opened it.
    static func pinFor(_ action: PINAction) -> String {
        switch action {
        case .extend: return grantTitle
        case .disable: return menuDisable
        // The window behind it is English (§2.4.2), but the box asking for the PIN is not:
        // it can appear in front of the child, and it is the child who reads it.
        case .settings: return menuSettings
        }
    }

    /// After a wrong PIN. Never says how many attempts are left, because there is no limit
    /// — DESIGN §2.5 refuses a lockout, and a counter would imply one.
    static let pinWrong = "Nieprawidłowy PIN"

    /// While the rate limit is holding an attempt back (``PINGate``). Shown with the number
    /// counting down, so a field that has stopped responding says why rather than looking
    /// broken — which is the whole difference between a delay and a fault.
    static func pinWait(seconds: Int) -> String {
        // **"za" takes the accusative**, so one second is `sekundę` — not the nominative
        // `sekunda` that ``minutes(_:)``'s pattern would hand back. The three-form rule is
        // the same (``PolishPlural``); only the singular changes with the case, which is
        // exactly the kind of thing a bilingual app gets wrong for years without noticing.
        let noun: String
        switch PolishPlural.form(seconds) {
        case .one: noun = "sekundę"
        case .few: noun = "sekundy"
        case .many: noun = "sekund"
        }
        return "Spróbuj ponownie za \(seconds) \(noun)"
    }

    /// Backs out of the prompt. On the cover this returns to the face underneath — it does
    /// **not** lift the cover, so it is not a way out of anything (T11: no Escape, no Cancel
    /// on the cover itself).
    ///
    /// **The only button on the PIN stage**, since the boxes confirm themselves. It stays
    /// because without it a child who pressed `Wprowadź PIN` by mistake would be left in
    /// front of a box he can neither fill nor leave.
    static let pinCancelButton = "Anuluj"

    /// The amount picker's headline. ``menuExtend`` with its ellipsis dropped: the ellipsis
    /// promises a dialog, and this *is* the dialog.
    static let grantTitle = "Dodaj minuty"
    static let grantConfirmButton = "Dodaj"

    /// `1 minuta`, `2 minuty`, `20 minut` — Polish counts its nouns in three forms.
    ///
    /// Which form is a rule and lives in ``PolishPlural`` over in `RSTCore`, where
    /// `make test` can reach it; the three words are Polish and so they live here, like
    /// every other Polish word in the app.
    static func minutes(_ count: Int) -> String {
        switch PolishPlural.form(count) {
        case .one: return "\(count) minuta"
        case .few: return "\(count) minuty"
        case .many: return "\(count) minut"
        }
    }

    // MARK: - The warnings, the expiry and the grant (T14)

    /// **What the app says out loud, and prints on the banner** (DESIGN §2.4, §2.5).
    ///
    /// One function for both channels because they carry the same words on purpose: the
    /// banner exists for a muted Mac and headphones round the neck, and a banner that said
    /// something *different* from the speech would make the two impossible to check against
    /// each other — which is exactly what the manual pass has to do.
    static func spoken(_ announcement: Announcement) -> String {
        switch announcement {
        case .warning(let minutes, let suggestsSaving):
            return warningLine(minutes) + (suggestsSaving ? " " + saveYourGame : "")
        case .expired:
            // §2.4's 0 row. Deliberately not the strings table's `Czas minął. Do zobaczenia
            // jutro.`: the cover that arrives with it already says `Czas minął`, and "see
            // you tomorrow" is a promise the app cannot keep — a second self-service session
            // or a PIN grant may put him straight back on, and T11 dropped the same half of
            // the sentence from the cover for the same reason.
            return coverExpired + "."
        case .granted(let minutes):
            // **Accusative** — `Dodano jedną minutę`, not the nominative `jedna minuta` that
            // ``minutes(_:)`` hands back. Same trap as ``pinWait(seconds:)``.
            let noun: String
            switch PolishPlural.form(minutes) {
            case .one: noun = "minutę"
            case .few: noun = "minuty"
            case .many: noun = "minut"
            }
            return "Dodano \(numeral(minutes, accusative: true)) \(noun)."
        }
    }

    /// What the banner shows, or `nil` where there is nothing to show.
    ///
    /// The expiry has no banner because §2.4's table gives that row **the cover** instead —
    /// and a banner floating over the cover a second later would be the same sentence twice.
    static func banner(_ announcement: Announcement) -> String? {
        if case .expired = announcement { return nil }
        return spoken(announcement)
    }

    /// `Zostało Ci 10 minut.` — and the verb agrees with the count, which is the part a
    /// table of three sentences would have got wrong the first time `warningMinutes` changed.
    private static func warningLine(_ minutes: Int) -> String {
        // The design's own line for the last threshold, and better than `Została Ci 1 minuta`
        // for the same reason `Ostatnia` exists as a word.
        guard minutes != 1 else { return "Ostatnia minuta." }
        switch PolishPlural.form(minutes) {
        case .one:  return "Została Ci \(numeral(minutes)) minuta."
        case .few:  return "Zostały Ci \(numeral(minutes)) minuty."
        case .many: return "Zostało Ci \(numeral(minutes)) minut."
        }
    }

    /// **The only thing the app ever tells him to do**, on the one threshold that still
    /// leaves time to do it (``Config/warningSuggestsSaving(_:)``).
    ///
    /// Three words, and deliberately not the eight-word sentence that stood here until
    /// 2026-08-25 — *"Zapisz grę — gra na pełnym ekranie zostanie zamknięta"* explained the
    /// consequence as well as the instruction, and the user cut it after hearing it three
    /// times in one session. §2.4's own wording is what is left.
    private static let saveYourGame = "Zapisz swoją grę."

    /// The number, as a numeral or as a word where a numeral would be read in the wrong
    /// gender — see ``PolishNumeral``, which owns the rule.
    private static func numeral(_ count: Int, accusative: Bool = false) -> String {
        switch PolishNumeral.form(count) {
        case .digits:
            return "\(count)"
        case .one:
            return accusative ? "jedną" : "jedna"
        case .two(let tens):
            // `dwie` in both cases: the feminine accusative and the nominative are the same
            // word, which is why only ``one`` above needs to know which case it is in. A
            // tens of `0` — the number two itself — has no word in front of it.
            guard let word = tensWord[tens] else { return "dwie" }
            return "\(word) dwie"
        }
    }

    /// The tens, for the numbers ending in two that ``PolishNumeral`` spells out.
    private static let tensWord: [Int: String] = [
        20: "dwadzieścia", 30: "trzydzieści", 40: "czterdzieści", 50: "pięćdziesiąt",
        60: "sześćdziesiąt", 70: "siedemdziesiąt", 80: "osiemdziesiąt", 90: "dziewięćdziesiąt"
    ]

    /// The padlock the design's menu sketch draws in a right-hand column. `NSMenu` has no
    /// second column, so it goes on the end of the label — visible either way, which is the
    /// point: the child can see which doors need a parent before pressing one.
    static func gated(_ label: String) -> String { "\(label) 🔒" }
}
