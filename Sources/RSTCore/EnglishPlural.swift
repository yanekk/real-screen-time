import Foundation

/// Which form of a counted noun English wants — `1 session` / `2 sessions`.
///
/// **A rule, so it lives here**, mirroring ``PolishPlural``: the words are assembled in
/// `RSTApp`, but the choice of singular or plural is invisible to `make test` when it is made
/// inside a view. English has no *few* form, so this is simpler than its Polish twin — but the
/// wizard's final screen (CR-01 §4) agrees a noun *and* a pronoun with the same count, and
/// `it` where it should be `them` is exactly the kind of wrong a test should hold.
public enum EnglishPlural: Equatable, Sendable {
    /// `1 session`, `it`
    case one
    /// `0 sessions`, `2 sessions`, `5 sessions`, `them`
    case many

    /// 1 is singular; everything else, including 0, is plural. Negatives never reach here —
    /// the only count this serves is `sessionsPerDay`, which ``SessionLimits/problem`` refuses
    /// below zero — and `0` is legal and reads `0 sessions`, so no magnitude guard is needed.
    public static func form(_ count: Int) -> EnglishPlural {
        count == 1 ? .one : .many
    }
}
