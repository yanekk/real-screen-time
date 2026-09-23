import Foundation
import Testing
import RSTCore
@testable import RSTApp

/// **The fail-closed HTTP wrapper** (DESIGN §2.7, §3.2), driven against a stubbed `URLProtocol`
/// so no socket is ever opened. The one rule under test is that *every* failure — a 5xx, a
/// dropped connection, a stall, a body that will not parse — comes back as a `.failure` the
/// caller reads as "no grant, no change", and only a decoded 2xx is a `.success`. A network that
/// hiccups must never read as a grant.
///
/// The suite is `.serialized` because the stub's response is class-wide state on
/// ``StubURLProtocol``; running the tests one at a time keeps each test's stub its own.
@Suite("RemoteClient", .serialized)
struct RemoteClientTests {

    private static let baseURL = URL(string: "https://backend.test/prod")!
    private let token = "device-token-xyz"

    private func client() -> RemoteClient {
        RemoteClient(session: StubURLProtocol.makeSession(), baseURL: Self.baseURL)
    }

    // MARK: - fetchGrants

    @Test("200 with a valid grant array decodes to the grants")
    func fetchGrantsSuccess() async {
        let body = """
            [{"id":"g1","minutes":30,"issuedAt":"2026-09-22T14:03:00Z"},
             {"id":"g2","minutes":15,"issuedAt":"2026-09-22T14:05:30Z"}]
            """
        StubURLProtocol.respond(status: 200, body: body)

        let result = await client().fetchGrants(token: token)

        let iso = ISO8601DateFormatter()
        #expect(result == .success([
            RemoteGrant(id: "g1", minutes: 30, issuedAt: iso.date(from: "2026-09-22T14:03:00Z")!),
            RemoteGrant(id: "g2", minutes: 15, issuedAt: iso.date(from: "2026-09-22T14:05:30Z")!),
        ]))

        // The device token rides as a bearer credential, and the path is appended to the base.
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
                == "Bearer \(token)")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/prod/grants")
        #expect(StubURLProtocol.lastRequest?.httpMethod == "GET")
    }

    @Test("200 with an empty array is a success, not a failure")
    func fetchGrantsEmpty() async {
        StubURLProtocol.respond(status: 200, body: "[]")
        #expect(await client().fetchGrants(token: token) == .success([]))
    }

    @Test("200 with a garbage body is malformed, not applied")
    func fetchGrantsGarbage() async {
        StubURLProtocol.respond(status: 200, body: "{not json at all")
        #expect(await client().fetchGrants(token: token) == .failure(.malformed))
    }

    @Test("a body whose date does not match the contract is malformed, never a bad grant")
    func fetchGrantsWrongDateFormat() async {
        // Epoch seconds instead of ISO-8601: fails closed rather than decoding to a wrong instant.
        StubURLProtocol.respond(status: 200, body: #"[{"id":"g1","minutes":30,"issuedAt":1758549780}]"#)
        #expect(await client().fetchGrants(token: token) == .failure(.malformed))
    }

    @Test("401 is unauthorized — the re-pair signal, not a generic http error")
    func fetchGrantsUnauthorized() async {
        StubURLProtocol.respond(status: 401, body: "")
        #expect(await client().fetchGrants(token: token) == .failure(.unauthorized))
    }

    @Test("500 is http(500)")
    func fetchGrantsServerError() async {
        StubURLProtocol.respond(status: 500, body: "")
        #expect(await client().fetchGrants(token: token) == .failure(.http(500)))
    }

    @Test("a 404 is http(404), not swallowed")
    func fetchGrantsNotFound() async {
        StubURLProtocol.respond(status: 404, body: "")
        #expect(await client().fetchGrants(token: token) == .failure(.http(404)))
    }

    @Test("a dropped connection is offline")
    func fetchGrantsOffline() async {
        StubURLProtocol.fail(with: URLError(.cannotConnectToHost))
        #expect(await client().fetchGrants(token: token) == .failure(.offline))
    }

    @Test("a stalled response is timeout, distinct from offline")
    func fetchGrantsTimeout() async {
        StubURLProtocol.fail(with: URLError(.timedOut))
        #expect(await client().fetchGrants(token: token) == .failure(.timeout))
    }

    // MARK: - consumeGrant

    @Test("consume returns success on a 2xx and sends no body")
    func consumeSuccess() async {
        StubURLProtocol.respond(status: 204, body: "")
        let result = await client().consumeGrant(id: "g1", token: token)
        #expect(isSuccess(result))
        #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/prod/grants/g1/consume")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
                == "Bearer \(token)")
    }

    @Test("consume maps the same error classes as fetch")
    func consumeMapsErrors() async {
        StubURLProtocol.respond(status: 401, body: "")
        #expect(failure(of: await client().consumeGrant(id: "g1", token: token)) == .unauthorized)

        StubURLProtocol.respond(status: 500, body: "")
        #expect(failure(of: await client().consumeGrant(id: "g1", token: token)) == .http(500))

        StubURLProtocol.fail(with: URLError(.timedOut))
        #expect(failure(of: await client().consumeGrant(id: "g1", token: token)) == .timeout)

        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        #expect(failure(of: await client().consumeGrant(id: "g1", token: token)) == .offline)
    }

    // MARK: - redeemPairingCode

    @Test("a redeemed code returns the device token")
    func redeemSuccess() async {
        StubURLProtocol.respond(status: 200, body: #"{"token":"new-device-token"}"#)
        let result = await client().redeemPairingCode("ABC123")
        #expect(result == .success(DeviceToken(token: "new-device-token")))
        // The redeem call carries no bearer credential — the code in the body is the credential.
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(StubURLProtocol.lastRequest?.url?.path == "/prod/pair/redeem")
        #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
    }

    @Test("a rejected code returns the failure and no token")
    func redeemRejected() async {
        // An invalid or expired code comes back non-2xx; 401 stays reserved for a rejected
        // device token, so a bad pairing code is a 400.
        StubURLProtocol.respond(status: 400, body: "")
        #expect(await client().redeemPairingCode("BADCODE") == .failure(.http(400)))
    }

    @Test("a 200 redeem body without a token is malformed")
    func redeemMalformed() async {
        StubURLProtocol.respond(status: 200, body: #"{"unexpected":"shape"}"#)
        #expect(await client().redeemPairingCode("ABC123") == .failure(.malformed))
    }

    @Test("redeem is offline when the network is down")
    func redeemOffline() async {
        StubURLProtocol.fail(with: URLError(.cannotFindHost))
        #expect(await client().redeemPairingCode("ABC123") == .failure(.offline))
    }

    // MARK: - baseURL resolution

    @Test("RST_REMOTE_ENDPOINT overrides Config.remoteEndpoint for the base URL")
    func overrideBeatsConfig() {
        let config = "https://api.real.example.com/prod"
        let override = "http://127.0.0.1:8080"
        #expect(RemoteClient.baseURL(configEndpoint: config, override: override)
                == URL(string: override))
        // No override, or an empty one, falls back to the configured endpoint.
        #expect(RemoteClient.baseURL(configEndpoint: config, override: nil) == URL(string: config))
        #expect(RemoteClient.baseURL(configEndpoint: config, override: "") == URL(string: config))
        // Neither configured nor overridden — nothing to talk to, so no base URL.
        #expect(RemoteClient.baseURL(configEndpoint: "", override: nil) == nil)
    }

    // MARK: - small Result helpers for the Void success

    private func isSuccess(_ result: Result<Void, RemoteClientError>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private func failure(of result: Result<Void, RemoteClientError>) -> RemoteClientError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

/// A `URLProtocol` that answers from a class-wide stub instead of the network, so `RemoteClient`
/// can be driven end to end with no socket. Set the next response with ``respond(status:body:)``
/// or make the round-trip fail with ``fail(with:)`` before each call; the suite that uses it is
/// `.serialized`, so the shared stub is never contended.
final class StubURLProtocol: URLProtocol {

    private struct Stub {
        var status: Int?
        var body: Data?
        var error: URLError?
    }

    // Guarded by `lock`; `nonisolated(unsafe)` because a `URLProtocol`'s statics are the only
    // channel the loading system leaves for a stub, and the serialized suite plus the lock make
    // the access safe.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub()
    nonisolated(unsafe) private static var captured: URLRequest?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func respond(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        stub = Stub(status: status, body: Data(body.utf8), error: nil)
        captured = nil
    }

    static func fail(with error: URLError) {
        lock.lock(); defer { lock.unlock() }
        stub = Stub(status: nil, body: nil, error: error)
        captured = nil
    }

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client else { return }

        Self.lock.lock()
        let stub = Self.stub
        Self.captured = request
        Self.lock.unlock()

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
