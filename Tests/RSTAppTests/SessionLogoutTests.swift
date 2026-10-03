import Foundation
import Testing
@testable import RSTApp
import RSTCore

/// **The log-out performer, with a fake launcher** (cover-buttons-logout T03, DESIGN §2.5).
///
/// The `launch` closure is always a recorder here: the default one ends the login session
/// running the tests. What is proved is what *would* run, and that a dry run runs nothing.
@Suite("Session log-out")
@MainActor
struct SessionLogoutTests {

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a dry run never launches anything and says what it would have run")
    func dryRunLaunchesNothing() {
        let lines = Lines()
        var launches = 0
        let logout = SessionLogout(real: false,
                                   diagnostics: Diagnostics(writing: { line, _ in lines.append(line) }),
                                   launch: { _, _ in launches += 1 })
        #expect(logout.logOut(at: Self.now))
        #expect(launches == 0)
        #expect(lines.all == ["logout: dry run — would run launchctl bootout gui/\(getuid())"])
    }

    @Test("a real run launches /bin/launchctl bootout gui/<uid> exactly once")
    func realRunLaunchesBootout() {
        let lines = Lines()
        var launches: [(URL, [String])] = []
        let logout = SessionLogout(real: true,
                                   diagnostics: Diagnostics(writing: { line, _ in lines.append(line) }),
                                   launch: { url, arguments in launches.append((url, arguments)) })
        #expect(logout.logOut(at: Self.now))
        #expect(launches.count == 1)
        #expect(launches.first?.0.path == "/bin/launchctl")
        #expect(launches.first?.1 == ["bootout", "gui/\(getuid())"])
        #expect(lines.all == ["logout: launchctl bootout gui/\(getuid())"])
    }

    @Test("a launch that throws is logged and reported as false")
    func failedLaunchIsLogged() {
        struct Refused: Error {}
        let lines = Lines()
        let logout = SessionLogout(real: true,
                                   diagnostics: Diagnostics(writing: { line, _ in lines.append(line) }),
                                   launch: { _, _ in throw Refused() })
        #expect(!logout.logOut(at: Self.now))
        #expect(lines.all.last?.hasPrefix("logout: launchctl bootout failed — ") == true)
    }

    @Test("LogoutCommand writes logged_out, stamped with the decision, before the performer")
    func commandWritesEventFirst() {
        let sink = MemoryEventSink()
        let engine = Engine(state: SessionState(), config: Config(), sink: sink,
                            enforcer: NullEnforcer(), calendar: .current)
        let performer = RecordingLogout(sink: sink)
        LogoutCommand(engine: engine, performer: performer).apply(at: Self.now)
        #expect(performer.calls == 1)
        #expect(performer.loggedOutEventsAtCall == [1])
        #expect(sink.events(ofType: .loggedOut).map(\.timestamp) == [Self.now])
    }
}
