import Foundation
import RSTCore

/// Why a call did nothing (DESIGN §2.7). **Every case means "no grant, no change".** The client
/// never throws to its caller and never returns a partial result — a failure is always the safe
/// direction, the cover staying up, and the poller (T04) and pairing (T05) treat any `.failure`
/// as "do nothing" without having to know which one it was.
///
/// The cases are the error *classes* DESIGN §2.7 enumerates, not one-per-HTTP-code: a 500, a 503
/// and a 418 are all `.http(code)`, because the caller does the same thing for all of them. Only
/// the ones that change what the caller does are split out — `.unauthorized` (re-pair) from the
/// rest, `.timeout` from `.offline` only because they read differently in the log.
public enum RemoteClientError: Error, Equatable {
    /// Connection refused, DNS failure, no route — the network is not reachable.
    case offline
    /// The request did not complete in time.
    case timeout
    /// Any non-2xx status that is not 401 — a 5xx, a 404, a 400. The caller waits and retries.
    case http(Int)
    /// 401 — the device token is missing, rejected or revoked. The caller stops treating the Mac
    /// as paired and surfaces "re-pair" (DESIGN §2.4, §2.7).
    case unauthorized
    /// A 2xx whose body did not parse. Fail closed: a grant we cannot read is a grant we do not
    /// apply. A date or key that does not match the server contract lands here and is skipped, so
    /// a contract mismatch can only ever *miss* a grant, never manufacture one.
    case malformed
}

/// The long-lived, read-only credential a pairing redemption returns (DESIGN §2.4). Read-only by
/// construction: the backend accepts it for `GET /grants` and consume, and refuses it for
/// `POST /grant` (DESIGN §2.3), so leaking it grants nothing.
public struct DeviceToken: Equatable, Sendable {
    public let token: String
    public init(token: String) { self.token = token }
}

/// **The one place `RSTApp` talks to the backend** (DESIGN §3.2) — a thin, fail-closed HTTP
/// wrapper over the three calls the poller and pairing make. It holds no policy: freshness,
/// dedupe and the day rule are `decideRemoteGrant`'s (T02); what to do with a token rejection is
/// the poller's and Settings'. This layer only turns an HTTP round-trip into a `Result`, and
/// turns every failure into a ``RemoteClientError`` the caller reads as "do nothing".
///
/// **The wire contract this file defines, for the backend (T08) to match.** `RemoteGrant`
/// (T02, Core) is a plain `Codable` and deliberately leaves the JSON shape to whichever side
/// meets a real payload first — that is this client. So T03 pins it here, and T08 conforms:
///
/// - **Base URL** comes from ``RemoteClient/baseURL(configEndpoint:override:)``:
///   `Config.remoteEndpoint`, or `RST_REMOTE_ENDPOINT` when it is set (DESIGN §5.2). Paths are
///   appended to it, so a stage prefix in the endpoint (`…/prod`) is preserved.
/// - **Auth** is `Authorization: Bearer <device-token>` on `GET /grants` and the consume call.
///   `POST /pair/redeem` carries no token — the pairing code in the body is the credential.
/// - **Dates** are ISO-8601 with a time zone and no fractional seconds (`2026-09-22T14:03:00Z`),
///   decoded with `JSONDecoder.DateDecodingStrategy.iso8601`. Keys are the property names as
///   written (`id`, `minutes`, `issuedAt`); no snake_case conversion.
/// - **`GET /grants`** returns a bare JSON array of grants: `[{"id","minutes","issuedAt"}, …]`.
/// - **`POST /grants/{id}/consume`** takes no body; any 2xx is success, its body ignored.
/// - **`POST /pair/redeem`** takes `{"code": "…"}` and returns `{"token": "…"}`.
///
/// `Sendable` because the poller (T04) is `@MainActor` and `await`s these methods off a
/// non-isolated `URLSession`, which sends the client across the isolation boundary. Every
/// stored value is already `Sendable` — `URLSession` is, and `URL` is a value type — so the
/// conformance is a promise the type already keeps; it is spelled out because a `public`
/// struct gets no cross-module inference.
public struct RemoteClient: Sendable {

    /// **The backend the parent's Mac talks to, baked into the build** (DESIGN §2.4, §8).
    ///
    /// One family, one deployed stack — T00 pinned that the web page and the API share a single
    /// same-origin URL (FINDINGS 2026-09-22) — so the endpoint is a build constant, not a URL the
    /// parent copies into a field. Settings (T06) takes only the pairing code, and pairing stores
    /// this endpoint into `config.json` beside the redeemed token so the poller (T04) can resolve
    /// it through ``baseURL(configEndpoint:override:)``.
    ///
    /// **Not in the source (2026-09-23).** The address is deployment-specific, so it lives in SSM
    /// Parameter Store, and `make bundle` reads it there and stamps it into the bundle's
    /// Info.plist under `RSTRemoteEndpoint`; this reads it back. A `swift run` has no bundle
    /// plist, so it is empty there and `RST_REMOTE_ENDPOINT` supplies it (DESIGN §5.2); with
    /// neither, a pair attempt reaches nothing and fails closed rather than guessing an address.
    static let productionEndpoint: String =
        (Bundle.main.object(forInfoDictionaryKey: "RSTRemoteEndpoint") as? String) ?? ""


    private let session: URLSession
    private let baseURL: URL

    /// **Operational timeout on every request.** Not user-facing and not a policy — the poller
    /// (T04) launches a fetch and forgets it (DESIGN §3.4), so a stuck socket must not linger
    /// across many ticks. Fifteen seconds is comfortably longer than a healthy round-trip and
    /// short enough that a dead connection is given up before the next slow poll.
    private static let requestTimeout: TimeInterval = 15

    public init(session: URLSession, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - The base URL

    /// Resolve the effective backend base URL: the `RST_REMOTE_ENDPOINT` override when present
    /// (already validated to an http(s) URL by `Flags`), otherwise `Config.remoteEndpoint`.
    /// `nil` when neither is set — an unpaired app has no endpoint and does not poll (DESIGN
    /// §2.5), so `nil` is the correct "there is nothing to talk to".
    ///
    /// The precedence lives here, in one App-layer place, rather than in `Flags`: the flag layer
    /// owns the *grammar* of the override, this owns choosing between it and config and turning
    /// the winner into a `URL`. T04 calls this to build the client.
    public static func baseURL(configEndpoint: String, override: String?) -> URL? {
        let chosen = (override?.isEmpty == false) ? override! : configEndpoint
        guard !chosen.isEmpty else { return nil }
        return URL(string: chosen)
    }

    // MARK: - The three calls

    /// `GET /grants` — the unconsumed grants the backend is holding for this Mac. The server
    /// drops only items past their own TTL; every day-boundary and staleness judgement is the
    /// Mac's (DESIGN §2.6, §3.6), so this returns whatever it is handed and the poller re-decides.
    public func fetchGrants(token: String) async -> Result<[RemoteGrant], RemoteClientError> {
        let request = authorized(get: ["grants"], token: token)
        return await perform(request) { data in
            try Self.jsonDecoder.decode([RemoteGrant].self, from: data)
        }
    }

    /// `POST /grants/{id}/consume` — tell the backend the grant has been applied so it is not
    /// re-served. At-least-once delivery plus the Mac's local dedupe (T02) makes this effectively
    /// once, so a lost consume is harmless: the grant is re-served and skipped as a duplicate.
    public func consumeGrant(id: String, token: String) async -> Result<Void, RemoteClientError> {
        // `appendingPathComponent` percent-encodes `id`, so a server-assigned id with an awkward
        // character cannot break out of the path.
        let request = authorized(post: ["grants", id, "consume"], token: token, body: nil)
        return await perform(request) { _ in () }
    }

    /// `POST /pair/redeem` — exchange a pairing code for a device token (DESIGN §2.4). No auth
    /// header: the code in the body is the credential. A rejected or expired code comes back as a
    /// non-2xx and maps to the matching error (`.http`/`.unauthorized`) — either way, no token.
    public func redeemPairingCode(_ code: String) async -> Result<DeviceToken, RemoteClientError> {
        let body: Data
        do {
            body = try JSONEncoder().encode(RedeemRequest(code: code))
        } catch {
            // Encoding a one-field struct does not realistically fail; treat it as "did nothing"
            // rather than crash, consistent with the fail-closed stance.
            return .failure(.malformed)
        }
        let request = unauthenticated(post: ["pair", "redeem"], body: body)
        return await perform(request) { data in
            DeviceToken(token: try Self.jsonDecoder.decode(RedeemResponse.self, from: data).token)
        }
    }

    // MARK: - The round-trip

    /// Run the request and classify the outcome into exactly one ``RemoteClientError`` or a
    /// decoded success. **This is the fail-closed heart:** every branch that is not a decoded 2xx
    /// body is a `.failure`, and nothing here can throw to the caller.
    private func perform<T>(_ request: URLRequest,
                            decode: (Data) throws -> T) async -> Result<T, RemoteClientError> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // A stall reads differently from an unreachable host in the log, so the two are
            // split; everything else transport-level is "offline" — the cover stays up either way.
            return .failure(error.code == .timedOut ? .timeout : .offline)
        } catch {
            // A non-URLError transport failure is not expected, but fail closed rather than throw.
            return .failure(.offline)
        }

        guard let http = response as? HTTPURLResponse else {
            // No HTTP response to read a status from — treat as unreachable.
            return .failure(.offline)
        }
        if http.statusCode == 401 { return .failure(.unauthorized) }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.http(http.statusCode))
        }
        do {
            return .success(try decode(data))
        } catch {
            return .failure(.malformed)
        }
    }

    // MARK: - Request building

    private func url(_ pathComponents: [String]) -> URL {
        pathComponents.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    private func authorized(get pathComponents: [String], token: String) -> URLRequest {
        var request = URLRequest(url: url(pathComponents), timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func authorized(post pathComponents: [String], token: String, body: Data?) -> URLRequest {
        var request = jsonPost(pathComponents, body: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func unauthenticated(post pathComponents: [String], body: Data?) -> URLRequest {
        jsonPost(pathComponents, body: body)
    }

    private func jsonPost(_ pathComponents: [String], body: Data?) -> URLRequest {
        var request = URLRequest(url: url(pathComponents), timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - Wire shapes and decoding

    private struct RedeemRequest: Encodable { let code: String }
    private struct RedeemResponse: Decodable { let token: String }

    /// A fresh decoder per use rather than a shared one: `JSONDecoder` is cheap, and a value
    /// created on demand sidesteps any question of sharing a mutable class across the concurrent
    /// calls the poller may have in flight.
    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
