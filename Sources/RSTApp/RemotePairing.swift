import Foundation
import RSTCore

/// The three states Settings (T06) shows for the remote channel (DESIGN §2.4, §2.7).
///
/// `expired` is a **runtime observation, never a stored field.** A device token that the backend
/// accepted at pairing time can be revoked later — a re-pair on another Mac invalidates it
/// (§2.4) — and the Mac only learns that on the next 401. So `.expired` is derived from a stored
/// token *plus* the live rejection flag, and can never be read off `config.json` alone: the
/// config would always say `.paired` while a token is present.
public enum PairingStatus: Equatable {
    case notPaired
    case paired
    /// A token is stored, but the server has rejected it (a 401) since launch. Settings shows
    /// "re-pair"; the poller (T04) is the one that raises the flag this reads.
    case expired
}

/// **The Mac side of pairing** (DESIGN §2.4): redeem a parent-typed code for a read-only device
/// token, persist the token and endpoint through the same config-commit path as every other
/// setting, and report whether the app is paired, unpaired, or paired-but-rejected. There is no
/// UI here — this is the logic Settings (T06) drives.
///
/// It holds no network policy of its own: the redemption round-trip and its fail-closed error
/// mapping are ``RemoteClient``'s (T03). This layer turns a redeemed token into a persisted
/// pairing, and turns config plus a runtime flag into a ``PairingStatus``.
@MainActor
public final class RemotePairing {

    private let config: () -> Config
    private let client: (String) -> RemoteClient
    private let commitConfig: (Config) -> Void
    private let clearTokenRejected: () -> Void

    /// - Parameters:
    ///   - config: reads the **live** config to mutate. It is the same source `status` is handed,
    ///     so pairing overwrites only the two remote fields and leaves every other setting
    ///     untouched, rather than committing a config this object remembered and let go stale.
    ///   - client: builds a ``RemoteClient`` against the endpoint the parent just typed. Until the
    ///     first pairing the app has no stored endpoint (DESIGN §2.5), so the endpoint arrives
    ///     with the call rather than from config — which is why `pair` takes it as a parameter.
    ///   - commitConfig: persists a changed config through the app's existing commit path — the
    ///     one that writes atomically, logs `config_changed` and re-ticks (`commitConfig` in
    ///     `main.swift`) — so a redeemed token survives restart like any other setting.
    ///   - clearTokenRejected: clears the runtime token-rejected flag
    ///     (`AppController.remoteTokenRejected`, which the poller raises on a 401, T04). It is not
    ///     a stored field, so it cannot ride along in `commitConfig`; a fresh token makes any
    ///     earlier rejection stale, so a successful pair clears it through here.
    ///
    /// `config` and `clearTokenRejected` are not in the T05 task-doc interface sketch, which named
    /// only `client` and `commitConfig`. Both are needed for the behaviour the same doc specifies:
    /// storing the token without clobbering other settings needs the current config, and "a
    /// successful pair clears the flag" needs a handle to a flag that lives outside config.
    public init(config: @escaping () -> Config,
                client: @escaping (String) -> RemoteClient,
                commitConfig: @escaping (Config) -> Void,
                clearTokenRejected: @escaping () -> Void) {
        self.config = config
        self.client = client
        self.commitConfig = commitConfig
        self.clearTokenRejected = clearTokenRejected
    }

    /// Redeem `code` against `endpoint`. On success, store the endpoint and the returned token
    /// through `commitConfig`, clear the token-rejected flag, and return `.success`.
    ///
    /// On **any** failure, write nothing and hand back the ``RemoteClientError`` for Settings to
    /// explain. This is the fail-closed contract (DESIGN §2.7) at the pairing layer: a redemption
    /// that did not clearly succeed leaves the app exactly as it was — no half-written endpoint,
    /// no token — so a network hiccup can never look like a pairing.
    ///
    /// Re-pairing at any time overwrites the previous token, which is how a parent moves the
    /// pairing to a new endpoint or replaces a token; the backend's single-active-token rule
    /// (§2.4) then invalidates whatever the old token was.
    public func pair(endpoint: String, code: String) async -> Result<Void, RemoteClientError> {
        switch await client(endpoint).redeemPairingCode(code) {
        case .success(let deviceToken):
            var updated = config()
            updated.remoteEndpoint = endpoint
            updated.remoteDeviceToken = deviceToken.token
            commitConfig(updated)
            clearTokenRejected()
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Disconnect this Mac locally: clear the stored token and endpoint through the same commit
    /// path (DESIGN §2.4). `status` then reads `.notPaired` whatever the token-rejected flag says,
    /// because with no token there is nothing left to reject — so the flag is left untouched here
    /// rather than reached for.
    public func unpair() {
        var updated = config()
        updated.remoteEndpoint = ""
        updated.remoteDeviceToken = ""
        commitConfig(updated)
    }

    /// The state Settings shows. `.expired` needs both a stored pairing and the live
    /// `tokenRejected` flag; a stored pairing with the flag clear is `.paired`; anything else is
    /// `.notPaired`.
    ///
    /// The "is there a pairing" test is `Config.isRemotePaired` — endpoint *and* token — rather
    /// than the token alone. The two always move together through `pair`/`unpair`, and keying on
    /// the same derived property the rest of the app uses means a hand-edited config with only one
    /// of the pair (§ Config, which nothing validates) reads as `.notPaired` rather than claiming
    /// a pairing that could talk to nothing.
    public func status(_ config: Config, tokenRejected: Bool) -> PairingStatus {
        guard config.isRemotePaired else { return .notPaired }
        return tokenRejected ? .expired : .paired
    }
}
