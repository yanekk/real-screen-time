import Foundation
import Testing
import RSTCore
@testable import RSTApp

/// **The poller — the one place a cover drops from the network** (DESIGN §2.6, §3.4), driven
/// against a stubbed `URLProtocol` so no socket is ever opened and against a recording enforcer
/// so no window is ever ordered onto a screen. The rules under test are the fail-closed ones:
/// a fresh grant drops the cover through the real `Engine` path and is logged `source:"remote"`;
/// a duplicate is skipped; every `RemoteClientError` leaves the cover up; a 401 raises the
/// re-pair flag; and the async fetch never blocks the tick.
///
/// `.serialized` because the stub answers from class-wide state on ``PollerStubURLProtocol``;
/// one test at a time keeps each test's stub its own.
@Suite("RemotePoller", .serialized)
@MainActor
struct RemotePollerTests {

    // MARK: - A fresh grant

    @Test("a fresh grant drops the cover through Engine.applyRemoteGrant and logs it remote")
    func freshGrantDropsTheCover() async {
        let h = PollerHarness()
        h.stubGrants([(id: "g1", minutes: 15, issuedAt: h.now)])

        // The cover is up before the poll.
        #expect(h.enforcer.calls.last?.decision.coversScreen == true)

        await h.poll(cadence: .fast, onConsole: true)

        #expect(h.engine.state.remainingSeconds == 15 * 60)
        // The cover came down: the last decision the enforcer saw does not cover.
        #expect(h.enforcer.calls.last?.decision.coversScreen == false)
        // Logged as remote — the marker a parent reads to tell it from a grant typed at the Mac.
        let extended = h.events.last { $0.type == .extended }
        #expect(extended?[.minutes] == .number(15))
        #expect(extended?[.source] == .string("remote"))
        // On-console, so it is spoken.
        #expect(h.enforcer.grantedAnnouncements == [15])
    }

    @Test("the same grant re-served on the next poll is not applied twice")
    func duplicateGrantIsSkipped() async {
        let h = PollerHarness()
        h.stubGrants([(id: "g1", minutes: 15, issuedAt: h.now)])
        await h.poll(cadence: .fast, onConsole: true)
        #expect(h.engine.state.remainingSeconds == 15 * 60)

        // Move past the fast interval and serve the very same grant again.
        h.advance(10)
        h.stubGrants([(id: "g1", minutes: 15, issuedAt: h.now)])
        await h.poll(cadence: .fast, onConsole: true)

        // Minutes unchanged: the dedupe id skipped it. One `extended` line, not two.
        #expect(h.engine.state.remainingSeconds == 15 * 60)
        #expect(h.events.filter { $0.type == .extended }.count == 1)
    }

    // MARK: - Off-console suppression

    @Test("a grant applied off-console adds the minutes and logs them but does not speak")
    func offConsoleGrantIsSilent() async {
        let h = PollerHarness(onConsole: false)
        h.stubGrants([(id: "g1", minutes: 30, issuedAt: h.now)])

        await h.poll(cadence: .slow, onConsole: false)

        #expect(h.engine.state.remainingSeconds == 30 * 60)
        #expect(h.events.last { $0.type == .extended }?[.source] == .string("remote"))
        // Nothing spoken at all — no chime over whoever the parent switched in to.
        #expect(h.enforcer.grantedAnnouncements.isEmpty)
    }

    // MARK: - Every failure keeps the cover up

    @Test("offline, timeout, 5xx and malformed all apply nothing and leave the cover up",
          arguments: [
            PollerFailure.transport(URLError(.cannotConnectToHost)),   // offline
            PollerFailure.transport(URLError(.timedOut)),              // timeout
            PollerFailure.http(500),
            PollerFailure.body("{not json"),                          // malformed
          ])
    func everyFailureKeepsTheCoverUp(_ failure: PollerFailure) async {
        let h = PollerHarness()
        h.stubFailure(failure)

        await h.poll(cadence: .fast, onConsole: true)

        #expect(h.engine.state.remainingSeconds == 0)
        #expect(h.enforcer.calls.last?.decision.coversScreen == true)
        #expect(!h.events.contains { $0.type == .extended })
        // No failure but a 401 raises the re-pair flag.
        #expect(h.tokenRejectedCount == 0)
    }

    @Test("a 401 raises the token-rejected flag and applies nothing")
    func unauthorizedRaisesTheFlag() async {
        let h = PollerHarness()
        h.stubFailure(.http(401))

        await h.poll(cadence: .fast, onConsole: true)

        #expect(h.tokenRejectedCount == 1)
        #expect(h.engine.state.remainingSeconds == 0)
        #expect(h.enforcer.calls.last?.decision.coversScreen == true)
        #expect(!h.events.contains { $0.type == .extended })
    }

    // MARK: - Staleness

    @Test("a grant older than the TTL is skipped — no extend, no cover change")
    func staleGrantIsSkipped() async {
        let h = PollerHarness()
        // Issued well past the default 15-minute TTL — the Mac saw it too late.
        let stale = h.now.addingTimeInterval(-(h.config.remoteGrantTTLInterval + 60))
        h.stubGrants([(id: "g1", minutes: 15, issuedAt: stale)])

        await h.poll(cadence: .fast, onConsole: true)

        #expect(h.engine.state.remainingSeconds == 0)
        #expect(h.enforcer.calls.last?.decision.coversScreen == true)
        #expect(!h.events.contains { $0.type == .extended })
    }

    // MARK: - Cadence gating

    @Test("idle never fetches; slow and fast fetch only after their own interval")
    func cadenceGatesTheFetch() async {
        let h = PollerHarness()
        h.stubGrants([])   // an empty array: a clean fetch that applies nothing

        // Idle: not paired's cadence — never a request.
        await h.poll(cadence: .idle, onConsole: true)
        #expect(h.requestCount == 0)

        // Fast: the first call fetches; an immediate second is inside the 4 s interval.
        await h.poll(cadence: .fast, onConsole: true)
        #expect(h.requestCount == 1)
        await h.poll(cadence: .fast, onConsole: true)
        #expect(h.requestCount == 1)

        // Past the fast interval, it fetches again.
        h.advance(5)
        await h.poll(cadence: .fast, onConsole: true)
        #expect(h.requestCount == 2)

        // Slow: a call just after that is inside the 45 s slow interval and does not fetch.
        h.advance(5)
        await h.poll(cadence: .slow, onConsole: true)
        #expect(h.requestCount == 2)
        // Past the slow interval, it fetches.
        h.advance(50)
        await h.poll(cadence: .slow, onConsole: true)
        #expect(h.requestCount == 3)
    }

    // MARK: - The fetch does not block the tick

    @Test("a hung fetch does not stall maybePoll's return or apply anything")
    func hungFetchDoesNotBlock() {
        let h = PollerHarness()
        h.stubHang()

        // No `await`: maybePoll must return synchronously even though the fetch never completes.
        h.poller.maybePoll(now: h.now, cadence: .fast, onConsole: true, config: h.config)

        // Nothing has been applied — the return did not wait for the (hung) fetch.
        #expect(h.engine.state.remainingSeconds == 0)
        #expect(h.enforcer.calls.last?.decision.coversScreen == true)
        #expect(!h.events.contains { $0.type == .extended })
    }
}

// MARK: - The harness

/// Builds the real ``Engine`` and ``RemotePoller`` against a stubbed client, a recording
/// enforcer and a hand-driven clock, seeded in an expired-cover state so a grant has a cover to
/// drop. No windows, no sockets — the two edges are faked and nothing in between.
@MainActor
final class PollerHarness {
    let calendar = Calendar.warsawRemote
    let clock: FakeClock
    let sink = MemoryEventSink()
    let enforcer = PollRecordingEnforcer()
    var config: Config
    let engine: Engine
    var poller: RemotePoller!

    /// The sensor half the harness ticks with. `onConsole` is what the poller's suppression is
    /// tested against; the rest keep the session active so nothing charges under the test.
    var onConsole: Bool
    var locked = false

    private(set) var tokenRejectedCount = 0

    var now: Date { clock.now }
    var events: [Event] { sink.events }
    var requestCount: Int { PollerStubURLProtocol.requestCount }

    init(onConsole: Bool = true) {
        self.onConsole = onConsole
        // 19:00 Warsaw, mid-day and on a whole second, so the day key is stable and ISO-8601
        // truncation to whole seconds cannot make a fresh grant read as skewed.
        self.clock = FakeClock(calendar.remoteWall(2026, 8, 21, 19, 0, 0))

        var config = Config()
        config.pinHash = String(repeating: "a", count: 64)
        config.pinSalt = Data(repeating: 7, count: 16).base64EncodedString()
        // Paired: an endpoint and a token, so the poller has something to authenticate with.
        config.remoteEndpoint = "https://backend.test/prod"
        config.remoteDeviceToken = "device-token-xyz"
        self.config = config

        // An expired cover: a session was started and has run out.
        let dayKey = DayWindow.dayKey(for: clock.now, resetHour: config.dayResetHour,
                                      calendar: calendar)
        let state = SessionState(dayKey: dayKey, remainingSeconds: 0,
                                 selfServiceStarts: [dayKey: 1],
                                 wasRunning: true, lastHeartbeat: clock.now,
                                 isLive: false)
        self.engine = Engine(state: state, config: config, sink: sink,
                             enforcer: enforcer, calendar: calendar)

        let client = RemoteClient(session: PollerStubURLProtocol.makeSession(),
                                  baseURL: URL(string: config.remoteEndpoint)!)
        self.poller = RemotePoller(client: client, engine: engine, clock: clock,
                                   calendar: calendar,
                                   onApplied: { [weak self] in self?.tick() },
                                   onTokenRejected: { [weak self] in self?.tokenRejectedCount += 1 })

        // One tick to put the expired cover on the (recording) enforcer before any poll.
        tick()
    }

    /// A tick with the current sensors. The session is kept "active" so the only thing the poll
    /// changes is what the grant does — nothing charges under the harness.
    func tick() {
        let snapshot = Snapshot(now: clock.now, idleSeconds: 0, screenLocked: locked,
                                sessionOnConsole: onConsole, mediaPlaying: false)
        engine.tick(snapshot)
    }

    func advance(_ seconds: TimeInterval) { clock.advance(seconds) }

    /// Call `maybePoll` and wait for the whole fetch-apply-consume cycle it launched, so the
    /// assertions see a settled state. A poll that launched no fetch (gated, or idle) awaits
    /// nothing.
    func poll(cadence: PollCadence, onConsole: Bool) async {
        poller.maybePoll(now: clock.now, cadence: cadence, onConsole: onConsole, config: config)
        await poller.currentPoll?.value
    }

    // MARK: Stubbing

    func stubGrants(_ grants: [(id: String, minutes: Int, issuedAt: Date)]) {
        PollerStubURLProtocol.respond(status: 200, body: Self.grantsBody(grants))
    }

    func stubFailure(_ failure: PollerFailure) {
        switch failure {
        case .transport(let error): PollerStubURLProtocol.fail(with: error)
        case .http(let code): PollerStubURLProtocol.respond(status: code, body: "")
        case .body(let text): PollerStubURLProtocol.respond(status: 200, body: text)
        }
    }

    func stubHang() { PollerStubURLProtocol.hang() }

    /// The `GET /grants` wire shape (a bare array), built from Swift so the dates always match
    /// the clock and the client's `.iso8601` (whole-second) decoding.
    static func grantsBody(_ grants: [(id: String, minutes: Int, issuedAt: Date)]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let items = grants.map { grant in
            "{\"id\":\"\(grant.id)\",\"minutes\":\(grant.minutes),"
                + "\"issuedAt\":\"\(formatter.string(from: grant.issuedAt))\"}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }
}

/// The failure classes the poller must all treat as "no grant, no change" — plus the 401 that
/// additionally raises the re-pair flag.
enum PollerFailure: Sendable {
    case transport(URLError)
    case http(Int)
    case body(String)
}

// MARK: - The recording enforcer

/// The App-side twin of `RSTCoreTests`' `RecordingEnforcer`: records every decision and every
/// announcement so a test can assert the cover dropped and whether anything was spoken, without
/// a real window. `@unchecked Sendable` behind an `NSLock`, matching the Core one — the protocol
/// methods are synchronous because the decision path calls them inline.
final class PollRecordingEnforcer: Enforcing, @unchecked Sendable {
    private let lock = NSLock()
    private var applied: [(now: Date, decision: Decision)] = []
    private var announcements: [Announcement] = []

    var calls: [(now: Date, decision: Decision)] { lock.withLock { applied } }

    /// The minute counts of every grant actually spoken. A suppressed grant appears in neither
    /// this nor the log's speech, which is the point of asserting it.
    var grantedAnnouncements: [Int] {
        lock.withLock {
            announcements.compactMap { if case .granted(let minutes) = $0 { return minutes }; return nil }
        }
    }

    func apply(_ decision: Decision, at now: Date) {
        lock.withLock { applied.append((now, decision)) }
    }

    func announce(_ announcement: Announcement, at now: Date) {
        lock.withLock { announcements.append(announcement) }
    }
}

// MARK: - The stubbed transport

/// A `URLProtocol` that answers from class-wide state instead of the network, so ``RemoteClient``
/// — and the poller above it — runs end to end with no socket. Distinct from `RemoteClientTests`'
/// own stub so the two suites never share state. Set the next response with ``respond(status:body:)``,
/// fail the round-trip with ``fail(with:)``, or make it never answer with ``hang()``. The suite
/// that uses it is `.serialized`, so the shared stub is never contended.
final class PollerStubURLProtocol: URLProtocol {

    private struct Stub {
        var status: Int?
        var body: Data?
        var error: URLError?
        var hang = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub()
    nonisolated(unsafe) private static var requests = 0

    /// A fresh session, and a fresh stub: the request counter and the pending response are zeroed
    /// so each harness starts from a known baseline (the cadence test asserts absolute counts).
    static func makeSession() -> URLSession {
        lock.withLock { stub = Stub(); requests = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PollerStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func respond(status: Int, body: String) {
        lock.withLock { stub = Stub(status: status, body: Data(body.utf8), error: nil) }
    }

    static func fail(with error: URLError) {
        lock.withLock { stub = Stub(status: nil, body: nil, error: error) }
    }

    /// Never answer: the round-trip stays in flight for ever, which is how the "does not block
    /// the tick" test proves `maybePoll` returned without waiting.
    static func hang() {
        lock.withLock { stub = Stub(hang: true) }
    }

    /// How many requests the stub has served since the harness built its session (``makeSession``
    /// zeroes it). The cadence test asserts the absolute count as it climbs.
    static var requestCount: Int { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client else { return }

        let stub: Stub = Self.lock.withLock {
            Self.requests += 1
            return Self.stub
        }

        // Never call back: the task stays pending, the fetch never returns.
        if stub.hang { return }

        if let error = stub.error {
            client.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status ?? 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - A calendar the App tests own

/// `RSTCoreTests` defines `Calendar.warsaw`, but that lives in the other test target. The poller
/// tests need the same zone for the day-boundary check, so they carry their own copy under a
/// distinct name rather than reaching across targets.
extension Calendar {
    static let warsawRemote: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    func remoteWall(_ year: Int, _ month: Int, _ day: Int,
                    _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        let parts = DateComponents(year: year, month: month, day: day,
                                   hour: hour, minute: minute, second: second)
        guard let date = date(from: parts) else {
            fatalError("no such local time: \(year)-\(month)-\(day) \(hour):\(minute):\(second)")
        }
        return date
    }
}
