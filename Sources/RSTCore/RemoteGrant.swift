import Foundation

/// One grant the backend served, before the Mac has decided what to do with it (DESIGN §3.3).
///
/// A pure value with no behaviour — freshness, dedupe and the day rule are all in
/// ``decideRemoteGrant(_:applied:now:ttl:dayResetHour:calendar:)`` so there is one place the
/// rules live and the poller (T04) only has to obey the answer.
///
/// `Codable` is synthesised on purpose. This value crosses the wire from the backend, and the
/// exact JSON — key casing, how `issuedAt` is spelled — is the client's (T03) contract with the
/// server (T08), settled when those two meet a real payload. Nothing in Core reads or writes a
/// `RemoteGrant` to a file, so pinning snake_case keys here (the house style for `config.json`
/// and `session.json`) would guess at a wire format T02 has no test for. The client decodes with
/// whatever key/date strategy matches the deployed server; a plain `Codable` leaves that open.
public struct RemoteGrant: Equatable, Codable, Sendable {
    /// Server-assigned, and the dedupe key. The same grant may be served more than once — a
    /// retry, a poll overlapping a consume — so the id, not the minutes, is what says "seen".
    public let id: String
    public let minutes: Int
    /// The server's clock. Freshness and the day-boundary check both compare against it, never
    /// against when the Mac happened to fetch it.
    public let issuedAt: Date

    public init(id: String, minutes: Int, issuedAt: Date) {
        self.id = id
        self.minutes = minutes
        self.issuedAt = issuedAt
    }
}

/// Apply the grant, or skip it and why (DESIGN §3.3).
public enum RemoteGrantDecision: Equatable, Sendable {
    case apply(minutes: Int)
    case skip(SkipReason)

    public enum SkipReason: Equatable, Sendable {
        /// A zero or negative grant is not a grant (initial-build §2.5 refuses a zero PIN grant).
        case nonPositive
        /// Its id is already in the applied set — a duplicate delivery.
        case alreadyApplied
        /// Issued in a different 06:00 day-window than now. Minutes do not cross 06:00 for
        /// anyone (initial-build §2.1), and a remote grant is no exception.
        case pastDayBoundary
        /// Issued more than the TTL ago. A grant is a "right now" action; one the Mac only sees
        /// hours later, because it was asleep or offline, must not silently appear.
        case stale
    }
}

/// Apply-or-skip for one fetched grant (DESIGN §2.6).
///
/// **The order of the checks is fixed and it matters:** non-positive, then already-applied,
/// then past-boundary, then stale, then apply. Dedupe is deliberately checked *before*
/// freshness so a re-delivered grant reads as `.alreadyApplied` rather than `.stale` — the
/// duplicate is the truer reason, and a grant re-served long after it was applied would
/// otherwise report as stale and hide that it was already honoured.
///
/// Pure, and it stays that way: `now`, the day-reset hour and the calendar all arrive as
/// parameters, so this is testable in microseconds with no clock and no socket. The `applied`
/// set is the caller's view of ``SessionState/appliedRemoteGrants`` — the poller (T04) hands in
/// `Set(state.appliedRemoteGrants.keys)`.
///
/// - Note: A grant issued in the future (clock skew, `now < issuedAt`) is not stale — the age
///   is negative — and applies if it is same-day and unseen. That is deliberate: DESIGN §2.7
///   does not defend skew beyond the TTL, because both Macs are NTP-synced and the TTL is
///   minutes, far larger than any plausible skew.
public func decideRemoteGrant(_ g: RemoteGrant,
                              applied: Set<String>,
                              now: Date,
                              ttl: TimeInterval,
                              dayResetHour: Int,
                              calendar: Calendar) -> RemoteGrantDecision {
    if g.minutes <= 0 { return .skip(.nonPositive) }
    if applied.contains(g.id) { return .skip(.alreadyApplied) }

    // The day rule by the app's own 06:00 window, not by 24 hours of absolute time: a grant
    // issued at 05:50 and seen at 06:10 crossed the boundary and is gone, regardless of TTL.
    let issuedDay = DayWindow.dayKey(for: g.issuedAt, resetHour: dayResetHour, calendar: calendar)
    let nowDay = DayWindow.dayKey(for: now, resetHour: dayResetHour, calendar: calendar)
    if issuedDay != nowDay { return .skip(.pastDayBoundary) }

    if now.timeIntervalSince(g.issuedAt) > ttl { return .skip(.stale) }

    return .apply(minutes: g.minutes)
}

/// How often the poller asks the backend for grants (DESIGN §2.5). `.idle` means do not poll.
public enum PollCadence: Equatable, Sendable {
    /// Not paired — the remote path is dormant and nothing is fetched.
    case idle
    /// Paired, but nobody is sitting in front of a cover waiting for it to drop.
    case slow
    /// Paired, the cover is up, the child is on-console and the screen is unlocked — someone is
    /// watching, so look often enough that the cover drops promptly.
    case fast
}

/// Decide the cadence from state the app already computes every tick (DESIGN §2.5).
///
/// **Fast only when someone is actually there.** Polling fast for a logged-out, switched-away
/// or locked session spends battery, network and AWS requests dropping a cover nobody can see —
/// so `fast` requires all of cover-up, on-console and unlocked, and everything else paired is
/// `slow`. Not paired is `idle`: the remote path does not poll at all. This reuses the exact
/// signals the activity predicate reads (`sessionOnConsole`, `screenLocked`, initial-build §2.2).
public func pollCadence(paired: Bool,
                        coversScreen: Bool,
                        onConsole: Bool,
                        locked: Bool) -> PollCadence {
    guard paired else { return .idle }
    if coversScreen && onConsole && !locked { return .fast }
    return .slow
}
