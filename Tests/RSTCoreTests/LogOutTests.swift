import Foundation
import Testing
@testable import RSTCore

/// `Engine.logOut(at:)` — the record half of `Wyloguj` (cover-buttons-logout §2.2, §2.3).
///
/// The log-out itself kills the process and cannot be tested here; what can is that the
/// record is exactly one line, stamped with the decision, and that writing it decides nothing.
@Suite("Log out")
@MainActor
struct LogOutTests {

    @Test("logOut writes one logged_out event stamped with the decision time, and nothing else")
    func logOutRecordsAndChangesNothing() {
        let day = Calendar.warsaw
        let h = Harness(start: day.wall(2026, 8, 21, 19, 0, 0))
        h.launch(bootTime: day.wall(2026, 8, 21, 18, 0, 0))
        h.engine.startSelfService(at: h.now)
        h.run(until: day.wall(2026, 8, 21, 19, 30, 1))
        let before = h.engine.lastDecision
        #expect(before == .expired(selfServiceLeft: 0))

        let state = h.engine.state
        let count = h.events.count
        let decidedAt = h.now
        h.engine.logOut(at: decidedAt)

        let added = Array(h.events.dropFirst(count))
        #expect(added == [Event(.loggedOut, at: decidedAt)])
        #expect(h.engine.state == state, "a log-out charges and grants nothing")

        h.tick()
        #expect(h.engine.lastDecision == before)
    }

    @Test("logged_out is the wire name and round-trips through the log")
    func wireName() throws {
        #expect(EventType.loggedOut.rawValue == "logged_out")
        let event = Event(.loggedOut, at: Date(timeIntervalSince1970: 1_800_000_000))
        let line = event.line(timeZone: Calendar.warsaw.timeZone)
        #expect(line.contains("\"type\":\"logged_out\""))
        #expect(Event(line: line) == event)
    }
}
