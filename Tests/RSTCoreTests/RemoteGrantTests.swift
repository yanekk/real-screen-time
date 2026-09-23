import Foundation
import Testing
@testable import RSTCore

/// The pure heart of the remote channel: apply-or-skip for a fetched grant, and the poll
/// cadence. Every case runs in a fixed `Europe/Warsaw` calendar with a `now` handed in — the
/// day-boundary check is calendar arithmetic and a test on the machine's own zone would pass
/// or fail by where the Mac sat. Nothing here touches a clock, a socket or a file.
@Suite("RemoteGrant")
struct RemoteGrantTests {

    private let warsaw = Calendar.calendar(in: "Europe/Warsaw")
    private let ttl: TimeInterval = 900   // 15 min, the shipped default

    private func grant(id: String = "g1", minutes: Int = 30, at issuedAt: Date) -> RemoteGrant {
        RemoteGrant(id: id, minutes: minutes, issuedAt: issuedAt)
    }

    // MARK: - Apply

    @Test("fresh, positive, unseen, within TTL and same day → apply")
    func appliesFreshGrant() {
        let issued = warsaw.wall(2026, 9, 22, 14, 0, 0)
        let now = issued.addingTimeInterval(60)   // one minute later, well inside the TTL
        let decision = decideRemoteGrant(grant(minutes: 30, at: issued),
                                         applied: [], now: now, ttl: ttl,
                                         dayResetHour: 6, calendar: warsaw)
        #expect(decision == .apply(minutes: 30))
    }

    @Test("a grant issued in the future is not stale — applies if same-day and unseen")
    func appliesFutureIssuedGrant() {
        // Clock skew: server ahead of the Mac. §2.7 does not defend skew beyond the TTL.
        let now = warsaw.wall(2026, 9, 22, 14, 0, 0)
        let issued = now.addingTimeInterval(30)
        #expect(decideRemoteGrant(grant(at: issued), applied: [], now: now, ttl: ttl,
                                  dayResetHour: 6, calendar: warsaw) == .apply(minutes: 30))
    }

    // MARK: - Skip

    @Test("zero minutes → nonPositive")
    func skipsZero() {
        let now = warsaw.wall(2026, 9, 22, 14, 0, 0)
        #expect(decideRemoteGrant(grant(minutes: 0, at: now), applied: [], now: now, ttl: ttl,
                                  dayResetHour: 6, calendar: warsaw) == .skip(.nonPositive))
    }

    @Test("negative minutes → nonPositive")
    func skipsNegative() {
        let now = warsaw.wall(2026, 9, 22, 14, 0, 0)
        #expect(decideRemoteGrant(grant(minutes: -30, at: now), applied: [], now: now, ttl: ttl,
                                  dayResetHour: 6, calendar: warsaw) == .skip(.nonPositive))
    }

    @Test("id already applied → alreadyApplied")
    func skipsDuplicate() {
        let issued = warsaw.wall(2026, 9, 22, 14, 0, 0)
        let now = issued.addingTimeInterval(60)
        #expect(decideRemoteGrant(grant(id: "g1", at: issued), applied: ["g1"], now: now,
                                  ttl: ttl, dayResetHour: 6, calendar: warsaw)
                == .skip(.alreadyApplied))
    }

    @Test("issued before the last 06:00, applied after → pastDayBoundary")
    func skipsPastDayBoundary() {
        // Issued at 05:50 (belongs to the 21st's window), seen at 06:10 (the 22nd's).
        let issued = warsaw.wall(2026, 9, 22, 5, 50, 0)
        let now = warsaw.wall(2026, 9, 22, 6, 10, 0)
        // Widen the TTL past the 20-minute gap so only the boundary, not staleness, is the reason.
        let wideTTL: TimeInterval = 3600
        #expect(decideRemoteGrant(grant(at: issued), applied: [], now: now, ttl: wideTTL,
                                  dayResetHour: 6, calendar: warsaw) == .skip(.pastDayBoundary))
    }

    @Test("issued more than the TTL ago, same day → stale")
    func skipsStale() {
        let issued = warsaw.wall(2026, 9, 22, 14, 0, 0)
        let now = issued.addingTimeInterval(ttl + 1)   // one second past the TTL, same day
        #expect(decideRemoteGrant(grant(at: issued), applied: [], now: now, ttl: ttl,
                                  dayResetHour: 6, calendar: warsaw) == .skip(.stale))
    }

    @Test("a grant exactly at the TTL boundary is still fresh")
    func ttlBoundaryIsFresh() {
        let issued = warsaw.wall(2026, 9, 22, 14, 0, 0)
        let now = issued.addingTimeInterval(ttl)   // exactly the TTL: > ttl is false
        #expect(decideRemoteGrant(grant(at: issued), applied: [], now: now, ttl: ttl,
                                  dayResetHour: 6, calendar: warsaw) == .apply(minutes: 30))
    }

    // MARK: - Order of the checks

    @Test("already-applied wins over stale — the duplicate is the truer reason")
    func dedupeBeatsStaleness() {
        // Both true: id is in the set AND it is well past the TTL. Order says alreadyApplied.
        let issued = warsaw.wall(2026, 9, 22, 14, 0, 0)
        let now = issued.addingTimeInterval(ttl + 600)
        #expect(decideRemoteGrant(grant(id: "g1", at: issued), applied: ["g1"], now: now,
                                  ttl: ttl, dayResetHour: 6, calendar: warsaw)
                == .skip(.alreadyApplied))
    }

    @Test("non-positive wins over already-applied")
    func nonPositiveBeatsDuplicate() {
        let now = warsaw.wall(2026, 9, 22, 14, 0, 0)
        #expect(decideRemoteGrant(grant(id: "g1", minutes: 0, at: now), applied: ["g1"],
                                  now: now, ttl: ttl, dayResetHour: 6, calendar: warsaw)
                == .skip(.nonPositive))
    }

    @Test("already-applied wins over past-day-boundary")
    func dedupeBeatsBoundary() {
        let issued = warsaw.wall(2026, 9, 22, 5, 50, 0)
        let now = warsaw.wall(2026, 9, 22, 6, 10, 0)
        #expect(decideRemoteGrant(grant(id: "g1", at: issued), applied: ["g1"], now: now,
                                  ttl: 3600, dayResetHour: 6, calendar: warsaw)
                == .skip(.alreadyApplied))
    }

    @Test("recording a grant then deciding it again reads as already-applied")
    func recordThenDecideIsDuplicate() {
        let issued = warsaw.wall(2026, 9, 22, 14, 0, 0)
        let now = issued.addingTimeInterval(60)
        var state = SessionState()
        state.recordRemoteGrant(id: "g1", at: now)
        let decision = decideRemoteGrant(grant(id: "g1", at: issued),
                                         applied: Set(state.appliedRemoteGrants.keys),
                                         now: now, ttl: ttl, dayResetHour: 6, calendar: warsaw)
        #expect(decision == .skip(.alreadyApplied))
    }

    // MARK: - Poll cadence

    @Test("not paired → idle, whatever else is true")
    func notPairedIsIdle() {
        #expect(pollCadence(paired: false, coversScreen: true, onConsole: true, locked: false)
                == .idle)
        #expect(pollCadence(paired: false, coversScreen: false, onConsole: false, locked: true)
                == .idle)
    }

    @Test("paired, cover up, on-console, unlocked → fast")
    func someoneWaitingIsFast() {
        #expect(pollCadence(paired: true, coversScreen: true, onConsole: true, locked: false)
                == .fast)
    }

    @Test("paired but any of no-cover / off-console / locked → slow")
    func paredButNobodyWaitingIsSlow() {
        // No cover: a session is running, nobody is staring at a cover to drop.
        #expect(pollCadence(paired: true, coversScreen: false, onConsole: true, locked: false)
                == .slow)
        // Off-console: switched away by fast user switching.
        #expect(pollCadence(paired: true, coversScreen: true, onConsole: false, locked: false)
                == .slow)
        // Locked: nobody can see the cover drop.
        #expect(pollCadence(paired: true, coversScreen: true, onConsole: true, locked: true)
                == .slow)
        // Everything off but paired.
        #expect(pollCadence(paired: true, coversScreen: false, onConsole: false, locked: true)
                == .slow)
    }
}
