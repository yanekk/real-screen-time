import Foundation

/// A box to render the cover into instead of the whole screen — `RST_COVER_FRAME`.
///
/// Plain integers rather than a `CGRect`: `CoreGraphics` is not a module `RSTCore` may
/// import, and the conversion is one line on the other side of the boundary.
public struct CoverFrame: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Bottom-left in screen coordinates, and signed: a second display can sit at a
    /// negative origin, so `600x400-1200+80` is a frame on it rather than a typo.
    public var x: Int
    public var y: Int

    public init(width: Int, height: Int, x: Int, y: Int) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}

/// The `RST_*` environment flags, parsed.
///
/// **In Core, although DESIGN §3.2 gives "env-var flags" to `main.swift`.** The *reading*
/// of the environment stays there — asking `ProcessInfo` anything is a system query, and
/// `RSTCore` makes none. What lives here is the grammar and the defaults, and they live
/// here for the reason the boundary exists at all: "`swift run` never covers the screen"
/// is a rule, and a rule in `RSTApp` is a rule that can only be checked by hand on a
/// machine with no UI automation. This way the safety default, the clamps and the frame
/// syntax are all covered by `make test`.
///
/// Every value is clamped or dropped at the point of parsing rather than trusted, the same
/// judgement `Config` makes for a hand-edited file: these strings are typed on a command
/// line at midnight, and `RST_TIME_SCALE=0` must not be able to trap `ScaledClock`'s
/// precondition.
public struct Flags: Equatable, Sendable {

    /// Whether the app is allowed to really cover the screen.
    ///
    /// The default is the caller's, because it is the one thing here that depends on how
    /// the binary was built — `#if DEBUG` belongs in `RSTApp`, and passing it in is what
    /// lets a test assert both halves of the rule.
    public var enforcing: Bool

    /// Tear any cover down after this many seconds. `nil` for no seatbelt.
    public var maxCoverSeconds: TimeInterval?

    /// Render the cover into a box instead of fullscreen. `nil` for fullscreen.
    public var coverFrame: CoverFrame?

    /// Arm the seatbelt, show nothing, and wait to be killed by it — `RST_SEATBELT_SELFTEST`.
    ///
    /// The one part of the cover that must never be wrong is the thing that takes it down
    /// again, and the T00 spike proved that testing it *by covering the screen* is how a
    /// machine ends up power-cycled (2026-08-21, findings log). This mode runs the release
    /// path — the same detached thread, armed the same way — with no window, no
    /// `NSApplication` and no cover, so `make seatbelt` can prove after every edit that the
    /// process really does exit on time.
    public var seatbeltSelfTest: Bool

    /// Seconds of main-thread silence under a cover before the watchdog ends the process —
    /// `RST_WATCHDOG_SECONDS`, DESIGN §2.8's thirty unless a test shortens it.
    ///
    /// Not optional, unlike the seatbelt: the seatbelt is a development seatbelt and the
    /// shipping app runs without one, while the watchdog is the app's only automatic safety
    /// net and is always armed. The flag moves the threshold; it cannot remove it.
    public var watchdogSeconds: TimeInterval

    /// Arm the watchdog, say a cover is up, park the main thread, and wait to be killed by
    /// it — `RST_WATCHDOG_SELFTEST`.
    ///
    /// ``seatbeltSelfTest``'s twin, for the same reason: the mechanism that rescues a hung
    /// app can otherwise only be tested by hanging one in front of a real screen. This mode
    /// runs the real detached watcher with no window and no `NSApplication`, so `make
    /// watchdog` can prove after every edit that a wedged main thread really does end the
    /// process — and that `watchdog_exit` is written before it goes.
    public var watchdogSelfTest: Bool

    /// Park the main thread for this many seconds once a cover is up — `RST_STALL_SECONDS`,
    /// and **`nil` for every run that is not deliberately breaking itself.**
    ///
    /// The manual half of T15: the self-test above proves the watcher fires, and this is
    /// what proves the screen comes *back*, on a real cover, with the process really wedged.
    /// Read only by a debug build — `main.swift` says so out loud in a release one rather
    /// than ignoring it quietly.
    public var stallSeconds: TimeInterval?

    /// Simulated seconds per real second. Always > 0; `1` is real time.
    public var timeScale: Double

    /// `RST_DATA_DIR` exactly as it was typed, or `nil`.
    ///
    /// Not resolved to a `URL` here: expanding `~` reads `HOME`, which is a system query.
    /// `RSTApp` turns this into a directory.
    public var dataDirectory: String?

    /// `RST_REMOTE_ENDPOINT` — point the remote client at a local fake or scratch server so no
    /// test or manual run reaches the real backend (DESIGN §5.2). `nil` when unset or invalid.
    ///
    /// Validated as an absolute `http`/`https` URL with a host and dropped otherwise, the same
    /// judgement the rest of this file makes for a hand-typed value: a malformed endpoint that
    /// silently did nothing would let a run believe it was hitting the scratch server while it
    /// fell back to whatever `config.json` names. Kept as the string as typed rather than a
    /// `URL` — `RemoteClient` resolves the effective base URL from this and `Config`, and doing
    /// the precedence in one place (App) keeps this to grammar alone.
    public var remoteEndpointOverride: String?

    /// What was ignored, and why — one line each, for `app.log`.
    ///
    /// A mistyped flag that silently does nothing is the worst outcome of the four
    /// possible ones: the run looks like the run that was asked for. Reporting rather than
    /// throwing, because none of these is worth refusing to start over.
    public var warnings: [String]

    public init(enforcing: Bool,
                maxCoverSeconds: TimeInterval? = nil,
                coverFrame: CoverFrame? = nil,
                seatbeltSelfTest: Bool = false,
                watchdogSeconds: TimeInterval = WatchdogModel.defaultStallSeconds,
                watchdogSelfTest: Bool = false,
                stallSeconds: TimeInterval? = nil,
                timeScale: Double = 1,
                dataDirectory: String? = nil,
                remoteEndpointOverride: String? = nil,
                warnings: [String] = []) {
        self.enforcing = enforcing
        self.maxCoverSeconds = maxCoverSeconds
        self.coverFrame = coverFrame
        self.seatbeltSelfTest = seatbeltSelfTest
        self.watchdogSeconds = watchdogSeconds
        self.watchdogSelfTest = watchdogSelfTest
        self.stallSeconds = stallSeconds
        self.timeScale = timeScale
        self.dataDirectory = dataDirectory
        self.remoteEndpointOverride = remoteEndpointOverride
        self.warnings = warnings
    }

    /// The flag names, spelled once. `RSTApp` logs them; the tests use them.
    public enum Name {
        public static let enforce = "RST_ENFORCE"
        public static let maxCoverSeconds = "RST_MAX_COVER_SECONDS"
        public static let coverFrame = "RST_COVER_FRAME"
        public static let seatbeltSelfTest = "RST_SEATBELT_SELFTEST"
        public static let watchdogSeconds = "RST_WATCHDOG_SECONDS"
        public static let watchdogSelfTest = "RST_WATCHDOG_SELFTEST"
        public static let stallSeconds = "RST_STALL_SECONDS"
        public static let timeScale = "RST_TIME_SCALE"
        public static let dataDirectory = "RST_DATA_DIR"
        public static let remoteEndpoint = "RST_REMOTE_ENDPOINT"
    }

    /// - Parameters:
    ///   - environment: `ProcessInfo.processInfo.environment`, passed in.
    ///   - enforcementDefault: `false` in a debug build, `true` in a release one.
    public static func parse(_ environment: [String: String],
                             enforcementDefault: Bool) -> Flags {
        var warnings: [String] = []

        // Exactly the task doc's expression: present-and-not-"1" means false. Any other
        // reading would make a typo (`RST_ENFORCE=yes`) enforce, and the whole point of
        // the default is that the dangerous behaviour takes a deliberate act.
        let enforce = environment[Name.enforce]
        let enforcing = enforce.map { $0 == "1" } ?? enforcementDefault
        if let enforce, enforce != "1", enforce != "0" {
            warnings.append("\(Name.enforce)=\(enforce) is not 1 or 0 — read as 0, not enforcing")
        }

        var maxCoverSeconds: TimeInterval?
        if let text = environment[Name.maxCoverSeconds] {
            // `isFinite` as well as `> 0`, for the same reason `RST_TIME_SCALE` checks it:
            // `Double("inf")` and `Double("1e400")` are both infinity, and an infinite
            // seatbelt is not a seatbelt — it is a run that believes it has one, takes the
            // screen, and is never torn down. The one failure mode this flag exists to
            // prevent.
            if let seconds = Double(text), seconds > 0, seconds.isFinite {
                maxCoverSeconds = seconds
            } else {
                warnings.append("\(Name.maxCoverSeconds)=\(text) is not a positive number — ignored, no seatbelt")
            }
        }

        var coverFrame: CoverFrame?
        if let text = environment[Name.coverFrame] {
            coverFrame = CoverFrame(text)
            if coverFrame == nil {
                warnings.append("\(Name.coverFrame)=\(text) is not WxH+X+Y — ignored, cover would be fullscreen")
            }
        }

        // Read like `RST_ENFORCE`, and for the same reason: a typo must not switch on a
        // mode that never draws the cover it was asked for.
        let selfTestText = environment[Name.seatbeltSelfTest]
        let seatbeltSelfTest = selfTestText == "1"
        if let selfTestText, selfTestText != "1", selfTestText != "0" {
            warnings.append("\(Name.seatbeltSelfTest)=\(selfTestText) is not 1 or 0 — read as 0")
        }
        // A self-test with nothing to fire is a process that hangs for ever, which is the
        // opposite of what it is for. `RSTApp` refuses to start in that combination; this
        // is the line that says why, in the log the run left behind.
        if seatbeltSelfTest, maxCoverSeconds == nil {
            warnings.append("\(Name.seatbeltSelfTest)=1 needs \(Name.maxCoverSeconds) — nothing would ever fire")
        }

        // DESIGN §2.8's thirty seconds, unless a run shortens them. **Refused rather than
        // clamped below a second**, and refused rather than switched off above: this is the
        // app's only automatic safety net, so the failure mode of a typo has to be the
        // default threshold rather than either a watchdog that kills a healthy app on a
        // scheduling hiccup or one that never fires at all.
        var watchdogSeconds = WatchdogModel.defaultStallSeconds
        if let text = environment[Name.watchdogSeconds] {
            if let seconds = Double(text), seconds.isFinite,
               seconds >= WatchdogModel.minimumStallSeconds {
                watchdogSeconds = seconds
            } else {
                warnings.append("""
                    \(Name.watchdogSeconds)=\(text) is not a number of seconds \
                    at or above \(Int(WatchdogModel.minimumStallSeconds)) — ignored, \
                    the watchdog stays at \(Int(WatchdogModel.defaultStallSeconds)) s
                    """)
            }
        }

        // Read like `RST_ENFORCE`, for the reason `RST_SEATBELT_SELFTEST` is read that way:
        // a typo must not switch on a mode that parks the main thread on purpose.
        let watchdogSelfTestText = environment[Name.watchdogSelfTest]
        let watchdogSelfTest = watchdogSelfTestText == "1"
        if let watchdogSelfTestText, watchdogSelfTestText != "1", watchdogSelfTestText != "0" {
            warnings.append("\(Name.watchdogSelfTest)=\(watchdogSelfTestText) is not 1 or 0 — read as 0")
        }

        var stallSeconds: TimeInterval?
        if let text = environment[Name.stallSeconds] {
            if let seconds = Double(text), seconds > 0, seconds.isFinite {
                stallSeconds = seconds
            } else {
                warnings.append("\(Name.stallSeconds)=\(text) is not a positive number — ignored, nothing will be parked")
            }
        }

        var timeScale: Double = 1
        if let text = environment[Name.timeScale] {
            if let scale = Double(text), scale > 0, scale.isFinite {
                timeScale = scale
            } else {
                // Never a precondition failure: `ScaledClock` traps on a non-positive
                // scale, and a mistyped environment variable must not be able to crash the
                // app before it has written a single line of its log.
                warnings.append("\(Name.timeScale)=\(text) is not a positive number — ignored, running in real time")
            }
        }

        var dataDirectory = environment[Name.dataDirectory]
        if let path = dataDirectory, path.trimmingCharacters(in: .whitespaces).isEmpty {
            warnings.append("\(Name.dataDirectory) is empty — ignored, using the default directory")
            dataDirectory = nil
        }

        // An absolute http(s) URL with a host, or nothing. A bare host, a `file:` path or a
        // typo is dropped rather than passed on: the whole point of the override is to be sure
        // a run is *not* touching the real backend, and a value that silently fails that would
        // defeat it. `URL(string:)` is lenient, so the scheme and host are checked explicitly.
        var remoteEndpointOverride: String?
        if let text = environment[Name.remoteEndpoint] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               let host = url.host, !host.isEmpty {
                remoteEndpointOverride = trimmed
            } else {
                warnings.append("\(Name.remoteEndpoint)=\(text) is not an http(s) URL with a host — ignored, using the configured endpoint")
            }
        }

        return Flags(enforcing: enforcing,
                     maxCoverSeconds: maxCoverSeconds,
                     coverFrame: coverFrame,
                     seatbeltSelfTest: seatbeltSelfTest,
                     watchdogSeconds: watchdogSeconds,
                     watchdogSelfTest: watchdogSelfTest,
                     stallSeconds: stallSeconds,
                     timeScale: timeScale,
                     dataDirectory: dataDirectory,
                     remoteEndpointOverride: remoteEndpointOverride,
                     warnings: warnings)
    }
}

extension CoverFrame {

    /// `WxH+X+Y`, as X11 geometry has spelled it for forty years — `600x400+80+80`.
    ///
    /// Hand-scanned rather than regex'd: the grammar is four integers and two separators,
    /// and the sign handling is the only interesting part of it. `nil` for anything that
    /// is not exactly this shape, because a half-understood frame is how a cover ends up
    /// somewhere nobody can see it.
    public init?(_ text: String) {
        var rest = Substring(text)

        func integer(signed: Bool) -> Int? {
            var digits = Substring("")
            if signed {
                guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
                digits = rest.prefix(1)
                rest = rest.dropFirst()
            }
            let body = rest.prefix { $0.isNumber }
            guard !body.isEmpty else { return nil }
            rest = rest.dropFirst(body.count)
            return Int(digits + body)
        }

        guard let width = integer(signed: false), width > 0,
              rest.first == "x" else { return nil }
        rest = rest.dropFirst()
        guard let height = integer(signed: false), height > 0,
              let x = integer(signed: true),
              let y = integer(signed: true),
              rest.isEmpty else { return nil }

        self.init(width: width, height: height, x: x, y: y)
    }
}
