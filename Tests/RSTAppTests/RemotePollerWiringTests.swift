import Foundation
import Testing
import RSTCore
@testable import RSTApp

/// **The assembly `main.swift` was always meant to own** (T11, DESIGN §3.2): turning the remote
/// channel on in the running app. Every piece exists after T03–T06, but nothing constructed a
/// ``RemotePoller`` or set `controller.remotePoller`, so as shipped the feature never polled. These
/// tests drive ``AppController/configureRemotePoller(config:endpointOverride:)`` directly — no
/// `NSApplication`, no socket, no window — and assert exactly the wiring: paired builds a poller at
/// the right endpoint, unpaired builds none, the `RST_REMOTE_ENDPOINT` override wins, a re-pair
/// replaces the poller and an unpair clears it, and a fresh pairing clears a stale rejection.
///
/// The end-to-end — a real grant dropping a real cover through the live tick — is T10 (user-hands);
/// the fetch-apply-consume behaviour of an installed poller is already `RemotePollerTests`.
@Suite("RemotePoller wiring")
@MainActor
struct RemotePollerWiringTests {

    /// A quiet, on-console world. The wiring tests never tick, so this only satisfies
    /// `AppController.init`; `configureRemotePoller` never reads a sensor.
    private struct QuietSensors: Sensing {
        func read() -> SensorReading {
            SensorReading(idleSeconds: 0, screenLocked: false, sessionOnConsole: true,
                          mediaPlaying: false)
        }
    }

    /// A controller with no menu bar, no kiosk and no watchdog — the assembly touches none of them.
    /// The store points at the temp dir but is never written: only `init` holds it, and these tests
    /// call neither `start()` nor `tick()`.
    private func makeController(config: Config) -> AppController {
        let engine = Engine(state: SessionState(), config: config, sink: NullEventSink(),
                            enforcer: PollRecordingEnforcer(), calendar: .current)
        return AppController(
            clock: FakeClock(Date(timeIntervalSince1970: 1_700_000_000)),
            engine: engine,
            sensors: QuietSensors(),
            store: SessionStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: .discarded,
            bootTime: .distantPast)
    }

    /// A paired config — an endpoint *and* a token, the pair `Config.isRemotePaired` keys on.
    private func paired(endpoint: String = "https://backend.test/prod",
                        token: String = "device-token") -> Config {
        var config = Config()
        config.remoteEndpoint = endpoint
        config.remoteDeviceToken = token
        return config
    }

    @Test("a paired config installs a poller whose client targets the configured endpoint")
    func pairedInstallsPoller() {
        let controller = makeController(config: paired())
        controller.configureRemotePoller(config: paired(), endpointOverride: nil)

        #expect(controller.remotePoller != nil)
        #expect(controller.configuredRemoteBaseURL == URL(string: "https://backend.test/prod"))
    }

    @Test("RST_REMOTE_ENDPOINT wins over the stored config endpoint")
    func overrideWins() {
        let controller = makeController(config: paired(endpoint: "https://stored.test/prod"))
        controller.configureRemotePoller(config: paired(endpoint: "https://stored.test/prod"),
                                         endpointOverride: "https://override.test/prod")

        #expect(controller.remotePoller != nil)
        #expect(controller.configuredRemoteBaseURL == URL(string: "https://override.test/prod"))
    }

    @Test("an endpoint with no redeemed token is not paired — no poller")
    func endpointWithoutTokenInstallsNothing() {
        var half = Config()
        half.remoteEndpoint = "https://backend.test/prod"
        let controller = makeController(config: half)
        controller.configureRemotePoller(config: half, endpointOverride: nil)

        #expect(controller.remotePoller == nil)
        #expect(controller.configuredRemoteBaseURL == nil)
    }

    @Test("an override alone, with no redeemed token, still installs nothing")
    func overrideWithoutTokenInstallsNothing() {
        let controller = makeController(config: Config())
        controller.configureRemotePoller(config: Config(),
                                         endpointOverride: "https://override.test/prod")

        #expect(controller.remotePoller == nil)
        #expect(controller.configuredRemoteBaseURL == nil)
    }

    @Test("a re-pair replaces the poller with the new endpoint; an unpair clears it")
    func rePairReplacesUnpairClears() {
        let controller = makeController(config: paired(endpoint: "https://old.test/prod"))
        controller.configureRemotePoller(config: paired(endpoint: "https://old.test/prod"),
                                         endpointOverride: nil)
        let first = controller.remotePoller
        #expect(first != nil)

        // Re-pair to a new endpoint: a different poller instance, pointed at the new URL.
        controller.configureRemotePoller(config: paired(endpoint: "https://new.test/prod"),
                                         endpointOverride: nil)
        #expect(controller.remotePoller != nil)
        #expect(controller.remotePoller !== first)
        #expect(controller.configuredRemoteBaseURL == URL(string: "https://new.test/prod"))

        // Unpair: nothing left to talk to.
        controller.configureRemotePoller(config: Config(), endpointOverride: nil)
        #expect(controller.remotePoller == nil)
        #expect(controller.configuredRemoteBaseURL == nil)
    }

    @Test("a successful re-pair clears a stale token-rejected flag")
    func rePairClearsTokenRejected() {
        let controller = makeController(config: paired())
        controller.remoteTokenRejected = true

        controller.configureRemotePoller(config: paired(), endpointOverride: nil)

        #expect(controller.remoteTokenRejected == false)
    }
}
