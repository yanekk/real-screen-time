import Foundation
import Testing
import RSTCore
@testable import RSTApp

/// **The Mac side of pairing** (DESIGN §2.4), driven against a stubbed `RemoteClient` so no socket
/// is opened. The rules under test: a redeemed code stores endpoint + token through the commit
/// path and reads `.paired`; every failure writes nothing and stays `.notPaired`; unpair clears
/// the token; and `status` folds the runtime rejection flag into `.expired` / `.paired`.
///
/// `.serialized` because the stub's response is class-wide state on ``PairingStub``. That stub is
/// a *separate* `URLProtocol` from `RemoteClientTests`' `StubURLProtocol` on purpose: Swift
/// Testing runs suites in parallel, so sharing one class-wide stub across the two suites would let
/// their responses clobber each other. Two classes, two independent stubs.
@MainActor
@Suite("RemotePairing", .serialized)
struct RemotePairingTests {

    private static let endpoint = "https://backend.test/prod"

    /// Stands in for `main.swift`'s config + flag world: `config` reads it, `commitConfig` writes
    /// it, `clearTokenRejected` flips the flag — exactly the seams `RemotePairing` drives.
    @MainActor
    private final class Fake {
        var config = Config()
        var tokenRejected = false
        var commits = 0

        func pairing() -> RemotePairing {
            RemotePairing(
                config: { self.config },
                client: { endpoint in
                    RemoteClient(session: PairingStub.makeSession(),
                                 baseURL: URL(string: endpoint)!)
                },
                commitConfig: { self.config = $0; self.commits += 1 },
                clearTokenRejected: { self.tokenRejected = false })
        }
    }

    // MARK: - pair

    @Test("a redeemed code stores endpoint + token and reads paired")
    func pairSuccess() async {
        PairingStub.respond(status: 200, body: #"{"token":"device-token-abc"}"#)
        let fake = Fake()
        let pairing = fake.pairing()

        let result = await pairing.pair(endpoint: Self.endpoint, code: "CODE123")

        #expect(isSuccess(result))
        #expect(fake.config.remoteEndpoint == Self.endpoint)
        #expect(fake.config.remoteDeviceToken == "device-token-abc")
        #expect(fake.commits == 1)
        #expect(pairing.status(fake.config, tokenRejected: fake.tokenRejected) == .paired)
        // The redeem hit the endpoint we handed in, at the pairing path.
        #expect(PairingStub.lastRequest?.url?.path == "/prod/pair/redeem")
    }

    @Test("a rejected code writes nothing and stays not-paired")
    func pairRejected() async {
        // A bad or expired pairing code comes back non-2xx (401 is reserved for a rejected device
        // token, T03), so a rejected code is an `.http`.
        PairingStub.respond(status: 400, body: "")
        let fake = Fake()
        let pairing = fake.pairing()

        let result = await pairing.pair(endpoint: Self.endpoint, code: "BADCODE")

        #expect(failure(of: result) == .http(400))
        #expect(fake.config.remoteDeviceToken.isEmpty)
        #expect(fake.config.remoteEndpoint.isEmpty)
        #expect(fake.commits == 0)
        #expect(pairing.status(fake.config, tokenRejected: fake.tokenRejected) == .notPaired)
    }

    @Test("an unreachable endpoint is offline and writes nothing")
    func pairOffline() async {
        PairingStub.fail(with: URLError(.cannotConnectToHost))
        let fake = Fake()
        let pairing = fake.pairing()

        let result = await pairing.pair(endpoint: Self.endpoint, code: "CODE123")

        #expect(failure(of: result) == .offline)
        #expect(fake.config.remoteDeviceToken.isEmpty)
        #expect(fake.commits == 0)
    }

    @Test("a successful pair clears the token-rejected flag")
    func pairClearsRejection() async {
        PairingStub.respond(status: 200, body: #"{"token":"fresh"}"#)
        let fake = Fake()
        fake.tokenRejected = true

        _ = await fake.pairing().pair(endpoint: Self.endpoint, code: "CODE123")

        #expect(fake.tokenRejected == false)
    }

    @Test("re-pairing overwrites the previous token")
    func rePairOverwrites() async {
        let fake = Fake()
        fake.config.remoteEndpoint = "https://old.test/prod"
        fake.config.remoteDeviceToken = "old-token"

        PairingStub.respond(status: 200, body: #"{"token":"new-token"}"#)
        _ = await fake.pairing().pair(endpoint: Self.endpoint, code: "CODE123")

        #expect(fake.config.remoteDeviceToken == "new-token")
        #expect(fake.config.remoteEndpoint == Self.endpoint)
    }

    // MARK: - unpair

    @Test("unpair clears the token and reads not-paired")
    func unpairClears() {
        let fake = Fake()
        fake.config.remoteEndpoint = Self.endpoint
        fake.config.remoteDeviceToken = "device-token-abc"
        let pairing = fake.pairing()

        pairing.unpair()

        #expect(fake.config.remoteDeviceToken.isEmpty)
        #expect(fake.config.remoteEndpoint.isEmpty)
        #expect(fake.commits == 1)
        #expect(pairing.status(fake.config, tokenRejected: fake.tokenRejected) == .notPaired)
    }

    // MARK: - status

    @Test("status folds the rejection flag: expired when set, paired when clear, notPaired with no token")
    func statusStates() {
        let pairing = Fake().pairing()

        var paired = Config()
        paired.remoteEndpoint = Self.endpoint
        paired.remoteDeviceToken = "device-token-abc"
        #expect(pairing.status(paired, tokenRejected: true) == .expired)
        #expect(pairing.status(paired, tokenRejected: false) == .paired)

        // No token: `.notPaired` whatever the flag says — nothing is stored to be rejected.
        let unpaired = Config()
        #expect(pairing.status(unpaired, tokenRejected: true) == .notPaired)
        #expect(pairing.status(unpaired, tokenRejected: false) == .notPaired)
    }

    // MARK: - Result helpers (Void success is not Equatable)

    private func isSuccess(_ result: Result<Void, RemoteClientError>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private func failure(of result: Result<Void, RemoteClientError>) -> RemoteClientError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

/// A `URLProtocol` that answers from a class-wide stub instead of the network, so a real
/// ``RemoteClient`` can be driven with no socket. A twin of `RemoteClientTests`' `StubURLProtocol`,
/// kept separate so the two serialized suites never share response state across parallel runs.
final class PairingStub: URLProtocol {

    private struct Stub {
        var status: Int?
        var body: Data?
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub()
    nonisolated(unsafe) private static var captured: URLRequest?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingStub.self]
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
