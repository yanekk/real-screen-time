import Foundation

/// **What the cover shows this tick**, as a value — T11's four rows, decided here rather
/// than in AppKit.
///
/// The same argument that moved ``MenuBarModel`` across the boundary, and it is stronger
/// here: the cover is the app's entire interface for the child, and every one of its rows
/// is a rule. Which face is shown, whether `Rozpocznij` is drawn at all, and how many
/// minutes the resume offer names are all things `make test` can check in microseconds and
/// a person can only check by taking the screen.
///
/// **No Polish crosses the boundary.** This file holds numbers and cases; `Strings.swift`
/// in `RSTApp` turns them into the sentences the child reads (DESIGN §2.4.2).
///
/// `Equatable` is load-bearing: the cover rebuilds its content only when this changes, so
/// a tick that decides the same thing again does not steal focus from a button the child
/// is about to press.
public struct CoverModel: Equatable, Sendable {

    /// The three faces of DESIGN §2.6, with the third split in two.
    ///
    /// `.awaitingStart` splits on `n`, which is where §2.6's table already put the line
    /// ("no session, *self-service left*" against "session over, *or none left*"). The
    /// condition was lost translating that table into `Decision` cases and restored
    /// 2026-08-22 — see ``Decision/offersSelfServiceStart``.
    public enum Face: Equatable, Sendable {
        /// `Rozpocznij sesję — 30 minut` · `Sesja 1 z 1`.
        ///
        /// `index` is the session he is about to start, not the count already spent: on a
        /// fresh day with one session a day it reads `Sesja 1 z 1`, which is what §2.6's
        /// table draws. The menu bar's line counts the other way — it reports what has
        /// been *used* — and the two are deliberately different sentences from different
        /// functions, because they answer different questions.
        case start(sessionMinutes: Int, index: Int, limit: Int)
        /// `Wznów sesję — pozostało 20 minut`.
        case resume(minutesLeft: Int)
        /// `Czas minął` — a session ran and is over.
        case expired
        /// `Na dziś koniec sesji` — nothing left to start, whether or not one ran first.
        ///
        /// Same dead end as ``expired``, and it wears the same buttons. The difference is
        /// only that no session ran, which is why `Czas minął` would be a lie here.
        case exhausted
    }

    /// What the child can press. Every one of these is drawn by `RSTApp`; the list is here
    /// so that "which buttons does this state offer" is a tested property rather than a
    /// switch in a view.
    public enum Button: String, Equatable, Sendable, CaseIterable {
        /// `Rozpocznij` — starts one of the day's own sessions. **No PIN.**
        case start
        /// `Wznów` — takes back time already granted. **No PIN.**
        case resume
        /// `Wprowadź PIN` ▸ `Dodaj minuty…` (T13). The only gated button on the cover.
        case pin
        /// `Zablokuj ekran` — his own way to hand the machine back. **No PIN** (§2.6).
        case lock
        /// `Wyloguj` — the other way to hand it back, which also closes the game. **No PIN**,
        /// like `.lock`; the app asks for a confirmation in place before it acts, because a
        /// hard log-out loses unsaved work (cover-buttons-logout DESIGN §2.2, §2.3).
        ///
        /// The raw value is the button's Accessibility identifier, which `make ui-gate` finds
        /// it by — renaming it breaks the gate, not the build.
        case logout
    }

    public let face: Face
    /// In the order they are drawn, primary first.
    public let buttons: [Button]

    /// The cover for this decision, or `nil` where no cover belongs on the screen.
    ///
    /// Optional rather than a `.none` face: `.dormant`, `.allowed` and `.warning` are not
    /// states of the cover, they are states of *not covering*, and an enforcer that has to
    /// remember which faces mean "hide" is an enforcer that will one day forget.
    ///
    /// - Parameters:
    ///   - decision: ``Engine/lastDecision``. `nil` before the first tick, which covers
    ///     nothing.
    ///   - sessionsUsedToday: self-service starts on today's day key.
    ///   - config: read for the session length and the day's allowance.
    ///   - canLock: whether `SACLockScreenImmediate` resolved at launch. When it did not,
    ///     `.lock` is dropped rather than relabelled: a lock button that logs out would put
    ///     a second, unconfirmed `Wyloguj` beside the real one (cover-buttons-logout §2.4).
    public init?(decision: Decision?, sessionsUsedToday: Int, config: Config,
                 canLock: Bool = true) {
        guard let decision, decision.coversScreen else { return nil }

        let used = max(0, sessionsUsedToday)
        let limit = config.selfServiceLimit
        // The dead-end faces' buttons, in drawing order. One list for both faces, because
        // `.expired` and `.exhausted` differ only in the sentence above them.
        let endOfTurn: [Button] = canLock ? [.pin, .lock, .logout] : [.pin, .logout]

        switch decision {
        case .awaitingStart where decision.offersSelfServiceStart:
            // Clamped exactly as `SessionState.fullSession` clamps it, and for the same
            // reason: nothing validates `config.json`, and a hand-edited `-30` must not be
            // offered on a button. The two must agree or the cover promises minutes the
            // ledger will not grant.
            face = .start(sessionMinutes: max(0, config.sessionMinutes),
                          index: min(used + 1, max(1, limit)),
                          limit: limit)
            buttons = [.start]
        case .awaitingStart:
            // `n == 0`. **This row is the daily cap, and it is the only thing that is.**
            // `SessionState.startSelfService` is ungated on purpose and `decide` reports
            // `.awaitingStart(selfServiceLeft: 0)` like any other state, so a `Rozpocznij`
            // drawn without consulting `offersSelfServiceStart` deletes the one limit the
            // app enforces for itself — and no test below this layer would fail.
            face = .exhausted
            buttons = endOfTurn
        case .awaitingResume(let remaining):
            // Rounded **up**, so the last part-minute reads `1 minuta` rather than
            // `0 minut`. An offer of nothing is what the child would read as broken, and
            // the ledger really does still hold those seconds.
            face = .resume(minutesLeft: Self.minutes(remaining))
            buttons = [.resume]
        case .expired(let left):
            face = max(0, left) > 0 ? .expired : .exhausted
            buttons = endOfTurn
        case .dormant, .allowed, .warning:
            // Unreachable: `coversScreen` above is the one place that says which three
            // cases put the cover up. Returning nil rather than trapping — a face nobody
            // asked for is not worth a crash on a covered screen.
            return nil
        }
    }

    /// Seconds as whole minutes, rounded up and bounded.
    ///
    /// The same clamp `MenuBarModel.clockText` applies, for the same reason: this takes
    /// whatever a `Decision` carries, and an `Int` conversion with no ceiling **traps**.
    /// The ledger clamps its own remainder since 2026-08-23, so this is the second belt.
    static func minutes(_ seconds: TimeInterval) -> Int {
        // `max` before `min` is what makes a NaN read zero: every comparison against NaN
        // is false, so `max(0, .nan)` hands back the 0 it was given.
        let bounded = min(max(0, seconds), MenuBarModel.ceiling)
        return Int((bounded / 60).rounded(.up))
    }
}

// MARK: - Polish plurals

/// Which form of a counted noun Polish wants — `1 minuta`, `2 minuty`, `5 minut`.
///
/// **A rule, so it lives here**; the three words live in `Strings.swift` where every other
/// Polish string does. Getting this wrong is invisible to `make test` if the choice is made
/// in a view, and it is the kind of wrong a child reads every single day.
///
/// The rule itself: 1 is singular; 2–4 take the *few* form, **except** the teens 12–14,
/// which take *many* along with everything else. It applies to the last two digits, so 22
/// is *few* and 112 is *many*.
public enum PolishPlural: Equatable, Sendable {
    /// `1 minuta`
    case one
    /// `2 minuty`, `22 minuty`
    case few
    /// `0 minut`, `5 minut`, `12 minut`, `25 minut`
    case many

    public static func form(_ count: Int) -> PolishPlural {
        // Negatives read as their magnitude. Nothing here should ever be handed one — the
        // callers clamp — but "minus one minuta" is the right answer if anything does.
        //
        // `magnitude`, not `abs`: `abs(Int.min)` **traps**, because the positive of it does
        // not fit in an `Int`. The same shape as the crash the T10 review found in the
        // countdown (2026-08-23), and cheaper to close than to prove unreachable — this is
        // a `public` function on a value that arrives from a hand-edited `config.json`.
        let n = count.magnitude
        if n == 1 { return .one }
        let lastTwo = n % 100
        if lastTwo >= 12, lastTwo <= 14 { return .many }
        let last = n % 10
        return (last >= 2 && last <= 4) ? .few : .many
    }
}
