import Foundation
import Testing
@testable import RSTCore

/// The `RST_*` flags, and above all the safety default.
///
/// "`swift run` never covers the screen unless `RST_ENFORCE=1` is typed on purpose" is the
/// rule standing between a development session and a locked-out Mac, and it is a rule about
/// a string. Parsing it in `RSTCore` is what makes it assertable here rather than by
/// starting the app and watching — which is the one way it must never be checked.
@Suite("Flags")
struct FlagsTests {

    // MARK: - The safety default

    @Test("a debug build with no flag does not enforce")
    func debugDefaultObserves() {
        #expect(Flags.parse([:], enforcementDefault: false).enforcing == false)
    }

    @Test("a release build with no flag enforces")
    func releaseDefaultEnforces() {
        #expect(Flags.parse([:], enforcementDefault: true).enforcing == true)
    }

    @Test("RST_ENFORCE=1 enforces whatever the build default is")
    func oneEnforces() {
        #expect(Flags.parse(["RST_ENFORCE": "1"], enforcementDefault: false).enforcing == true)
        #expect(Flags.parse(["RST_ENFORCE": "1"], enforcementDefault: true).enforcing == true)
    }

    @Test("RST_ENFORCE=0 observes even in a release build")
    func zeroObserves() {
        #expect(Flags.parse(["RST_ENFORCE": "0"], enforcementDefault: true).enforcing == false)
    }

    /// The failure that matters: anything that is not exactly `1` must not enforce, because
    /// the dangerous behaviour is the one that has to be asked for precisely.
    @Test("anything other than 1 does not enforce, and says so", arguments: ["yes", "true", "TRUE", "01", " 1", ""])
    func nearMissesDoNotEnforce(_ value: String) {
        let flags = Flags.parse(["RST_ENFORCE": value], enforcementDefault: true)
        #expect(flags.enforcing == false)
        #expect(flags.warnings.count == 1, "a typo that silently disarms the app must be reported")
    }

    @Test("0 and 1 are not worth warning about")
    func exactValuesAreQuiet() {
        #expect(Flags.parse(["RST_ENFORCE": "1"], enforcementDefault: false).warnings.isEmpty)
        #expect(Flags.parse(["RST_ENFORCE": "0"], enforcementDefault: false).warnings.isEmpty)
    }

    // MARK: - The seatbelt

    @Test("RST_MAX_COVER_SECONDS takes a positive number of seconds")
    func maxCoverSeconds() {
        #expect(parse(["RST_MAX_COVER_SECONDS": "30"]).maxCoverSeconds == 30)
        #expect(parse(["RST_MAX_COVER_SECONDS": "0.5"]).maxCoverSeconds == 0.5)
    }

    /// An infinite seatbelt is the one that would actually cost a power cycle: the run
    /// believes it is protected, takes the screen, and nothing ever tears it down. `inf`
    /// and `1e400` both parse as `Double.infinity` and both pass a bare `> 0`.
    @Test("a seatbelt that is not a positive number is dropped, loudly",
          arguments: ["0", "-30", "abc", "30s", "", "inf", "infinity", "-inf", "nan", "1e400"])
    func brokenSeatbeltIsReported(_ value: String) {
        let flags = parse(["RST_MAX_COVER_SECONDS": value])
        #expect(flags.maxCoverSeconds == nil)
        // Silence here would be the worst case of the lot: the run believes it has a
        // seatbelt, takes the screen, and nothing tears it down.
        #expect(flags.warnings.count == 1)
    }

    // MARK: - Accelerated time

    @Test("RST_TIME_SCALE takes a positive multiplier")
    func timeScale() {
        #expect(parse(["RST_TIME_SCALE": "60"]).timeScale == 60)
        #expect(parse(["RST_TIME_SCALE": "0.5"]).timeScale == 0.5)
        #expect(parse([:]).timeScale == 1)
    }

    /// `ScaledClock` has a `precondition(scale > 0)`, so a bad value here is not a wrong
    /// number, it is a crash before the app has written a line of its log.
    @Test("a scale that would trap ScaledClock falls back to real time",
          arguments: ["0", "-1", "abc", "inf", "nan", ""])
    func brokenScaleFallsBackToRealTime(_ value: String) {
        let flags = parse(["RST_TIME_SCALE": value])
        #expect(flags.timeScale == 1)
        #expect(flags.warnings.count == 1)
    }

    // MARK: - The cover frame

    @Test("RST_COVER_FRAME is WxH+X+Y")
    func coverFrame() {
        #expect(parse(["RST_COVER_FRAME": "600x400+80+80"]).coverFrame
                == CoverFrame(width: 600, height: 400, x: 80, y: 80))
    }

    @Test("the origin is signed, because a second display can sit at a negative one")
    func negativeOrigin() {
        #expect(CoverFrame("600x400-1200+80") == CoverFrame(width: 600, height: 400, x: -1200, y: 80))
        #expect(CoverFrame("600x400+80-300") == CoverFrame(width: 600, height: 400, x: 80, y: -300))
    }

    @Test("anything that is not exactly the geometry is refused",
          arguments: ["600x400", "600x400+80", "600x400+80+80+80", "600X400+0+0",
                      "0x400+0+0", "600x0+0+0", "-600x400+0+0", "600x400 80 80",
                      "600x400+80+80x", " 600x400+80+80", "x400+0+0", ""])
    func brokenFramesAreRefused(_ value: String) {
        #expect(CoverFrame(value) == nil, "\(value) is not WxH+X+Y")
        let flags = parse(["RST_COVER_FRAME": value])
        #expect(flags.coverFrame == nil)
        #expect(flags.warnings.count == 1)
    }

    // MARK: - The seatbelt self-test

    @Test("RST_SEATBELT_SELFTEST=1 with a limit is the self-test")
    func seatbeltSelfTest() {
        let flags = Flags.parse(["RST_SEATBELT_SELFTEST": "1", "RST_MAX_COVER_SECONDS": "3"],
                                enforcementDefault: false)
        #expect(flags.seatbeltSelfTest)
        #expect(flags.maxCoverSeconds == 3)
        #expect(flags.warnings.isEmpty)
    }

    @Test("it is off unless it is exactly 1", arguments: ["0", "yes", "true", ""])
    func seatbeltSelfTestNeedsOne(_ value: String) {
        #expect(!Flags.parse(["RST_SEATBELT_SELFTEST": value], enforcementDefault: false)
            .seatbeltSelfTest)
    }

    /// A self-test with nothing to fire is a process that hangs for ever, which is the
    /// exact opposite of what it is for.
    @Test("a self-test with no seatbelt to fire says so")
    func seatbeltSelfTestWithoutALimit() {
        let flags = Flags.parse(["RST_SEATBELT_SELFTEST": "1"], enforcementDefault: false)
        #expect(flags.seatbeltSelfTest)
        #expect(flags.maxCoverSeconds == nil)
        #expect(flags.warnings.count == 1)
        #expect(flags.warnings[0].contains("RST_MAX_COVER_SECONDS"))
    }

    @Test("nothing set is nothing to self-test")
    func noSelfTestByDefault() {
        #expect(!Flags.parse([:], enforcementDefault: true).seatbeltSelfTest)
    }

    // MARK: - The watchdog (T15)

    @Test("with nothing set the watchdog is armed at DESIGN §2.8's thirty seconds")
    func watchdogDefault() {
        #expect(parse([:]).watchdogSeconds == WatchdogModel.defaultStallSeconds)
        #expect(!parse([:]).watchdogSelfTest)
        #expect(parse([:]).stallSeconds == nil)
    }

    @Test("RST_WATCHDOG_SECONDS moves the threshold")
    func watchdogSeconds() {
        #expect(parse(["RST_WATCHDOG_SECONDS": "3"]).watchdogSeconds == 3)
        #expect(parse(["RST_WATCHDOG_SECONDS": "3"]).warnings.isEmpty)
    }

    /// **The failure that matters here is the opposite of the seatbelt's.** A seatbelt that
    /// is dropped leaves a development run with no release; a watchdog that is dropped
    /// leaves the shipping app with no safety net at all — so a value it cannot read falls
    /// back to thirty seconds rather than to nothing, and says so.
    @Test("a threshold it cannot use falls back to thirty, loudly",
          arguments: ["0", "0.5", "-30", "inf", "1e400", "nan", "", "soon"])
    func brokenWatchdogSecondsFallsBack(_ value: String) {
        let flags = parse(["RST_WATCHDOG_SECONDS": value])
        #expect(flags.watchdogSeconds == WatchdogModel.defaultStallSeconds)
        #expect(flags.warnings.count == 1, "a watchdog on a threshold nobody asked for must be reported")
    }

    @Test("RST_WATCHDOG_SELFTEST is off unless it is exactly 1", arguments: ["0", "yes", "true", ""])
    func watchdogSelfTestNeedsOne(_ value: String) {
        #expect(!parse(["RST_WATCHDOG_SELFTEST": value]).watchdogSelfTest)
    }

    @Test("RST_WATCHDOG_SELFTEST=1 needs nothing else — the watchdog is always armed")
    func watchdogSelfTestStandsAlone() {
        let flags = parse(["RST_WATCHDOG_SELFTEST": "1"])
        #expect(flags.watchdogSelfTest)
        #expect(flags.watchdogSeconds == WatchdogModel.defaultStallSeconds)
        #expect(flags.warnings.isEmpty)
    }

    @Test("RST_STALL_SECONDS parks the main thread for a positive number of seconds")
    func stallSeconds() {
        #expect(parse(["RST_STALL_SECONDS": "60"]).stallSeconds == 60)
        #expect(parse(["RST_STALL_SECONDS": "60"]).warnings.isEmpty)
    }

    @Test("a stall that is not a positive number is dropped, loudly",
          arguments: ["0", "-1", "inf", "nan", "", "a while"])
    func brokenStallIsDropped(_ value: String) {
        let flags = parse(["RST_STALL_SECONDS": value])
        #expect(flags.stallSeconds == nil)
        #expect(flags.warnings.count == 1)
    }

    // MARK: - The data directory

    @Test("RST_DATA_DIR is passed through exactly as typed")
    func dataDirectory() {
        // Unexpanded on purpose: `~` is `HOME`, and reading it is a system query `RSTApp`
        // makes on the other side of the boundary.
        #expect(parse(["RST_DATA_DIR": "~/scratch/rst"]).dataDirectory == "~/scratch/rst")
        #expect(parse([:]).dataDirectory == nil)
    }

    @Test("an empty RST_DATA_DIR is ignored rather than turned into the root directory")
    func emptyDataDirectory() {
        let flags = parse(["RST_DATA_DIR": "   "])
        #expect(flags.dataDirectory == nil)
        #expect(flags.warnings.count == 1)
    }

    // MARK: - Everything at once

    @Test("the documented manual-testing invocation")
    func theSeatbeltedRun() {
        let flags = Flags.parse(["RST_ENFORCE": "1",
                                 "RST_MAX_COVER_SECONDS": "30",
                                 "RST_TIME_SCALE": "60",
                                 "RST_COVER_FRAME": "600x400+80+80",
                                 "RST_DATA_DIR": "/tmp/rst-test"],
                                enforcementDefault: false)

        #expect(flags.enforcing)
        #expect(flags.maxCoverSeconds == 30)
        #expect(flags.timeScale == 60)
        #expect(flags.coverFrame == CoverFrame(width: 600, height: 400, x: 80, y: 80))
        #expect(flags.dataDirectory == "/tmp/rst-test")
        #expect(flags.warnings.isEmpty)
    }

    /// T15's manual hang test, as `plans/initial-build/TESTING.md` spells it: a boxed enforcing run with a
    /// seatbelt well behind the watchdog, so that what takes the cover down is the watchdog
    /// and the seatbelt is only there if it does not.
    @Test("the documented hang-test invocation")
    func theHangTestRun() {
        let flags = Flags.parse(["RST_ENFORCE": "1",
                                 "RST_COVER_FRAME": "600x400+80+80",
                                 "RST_MAX_COVER_SECONDS": "90",
                                 "RST_STALL_SECONDS": "60"],
                                enforcementDefault: false)

        #expect(flags.enforcing)
        #expect(flags.stallSeconds == 60)
        #expect(flags.watchdogSeconds == 30)
        #expect(flags.maxCoverSeconds == 90)
        #expect(flags.watchdogSeconds < flags.maxCoverSeconds ?? 0,
                "the watchdog has to be the thing that fires, or the test measures the seatbelt")
        #expect(flags.warnings.isEmpty)
    }

    // MARK: - The remote-endpoint override

    @Test("RST_REMOTE_ENDPOINT takes an http or https URL with a host")
    func remoteEndpointAccepted() {
        #expect(parse(["RST_REMOTE_ENDPOINT": "http://127.0.0.1:8080"]).remoteEndpointOverride
                == "http://127.0.0.1:8080")
        #expect(parse(["RST_REMOTE_ENDPOINT": "https://scratch.example.com/prod"]).remoteEndpointOverride
                == "https://scratch.example.com/prod")
        #expect(parse(["RST_REMOTE_ENDPOINT": "http://localhost:9"]).warnings.isEmpty)
    }

    @Test("no RST_REMOTE_ENDPOINT means no override and no noise")
    func remoteEndpointAbsent() {
        let flags = parse([:])
        #expect(flags.remoteEndpointOverride == nil)
        #expect(flags.warnings.isEmpty)
    }

    /// The failure that matters: a malformed endpoint must be *dropped and reported*, never
    /// silently passed on. A run that believes it is hitting the scratch server while it falls
    /// back to the configured backend is the exact mistake the override exists to prevent.
    @Test("a value that is not an http(s) URL with a host is dropped and reported",
          arguments: ["ftp://host", "example.com", "/local/path", "not a url", "", "file:///tmp/x"])
    func remoteEndpointRejected(_ value: String) {
        let flags = parse(["RST_REMOTE_ENDPOINT": value])
        #expect(flags.remoteEndpointOverride == nil)
        #expect(flags.warnings.count == 1, "a dropped endpoint must be reported, never silent")
    }

    @Test("an environment with none of our variables in it is silent")
    func unrelatedEnvironment() {
        let flags = Flags.parse(["PATH": "/usr/bin", "HOME": "/Users/child"],
                                enforcementDefault: false)
        #expect(flags == Flags(enforcing: false))
    }

    private func parse(_ environment: [String: String]) -> Flags {
        Flags.parse(environment, enforcementDefault: false)
    }
}
