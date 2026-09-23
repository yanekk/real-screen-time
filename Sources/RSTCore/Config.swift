import Foundation

/// Persisted settings.
///
/// Every value here is something a parent may reasonably want to change; anything that is
/// not is a constant in code. There are no wall-clock times left — the curfew went with
/// DESIGN §2.1's move to sessions, and a *start window* (the recorded way to close §2.1's
/// accepted gap, should it ever be wanted) would arrive as `ClockText` in T03.
public struct Config: Codable, Equatable, Sendable {
    public var sessionMinutes: Int = 30
    /// Sessions he may start unaided. **One**, since 2026-08-22 — see DESIGN §2.1. Still a
    /// setting, and still the only thing the app itself rations: 2 restores the old rhythm,
    /// 0 makes every minute of the day a PIN decision.
    public var selfServiceSessionsPerDay: Int = 1
    public var dayResetHour: Int = 6
    public var idleGraceSeconds: Int = 600       // 10 min — no input at all
    public var mediaGraceSeconds: Int = 1800     // 30 min — something is playing
    public var warningMinutes: [Int] = [10, 5, 1]    // 15 would be halfway through 30 min
    /// **The amounts `Dodaj minuty…` offers**, in the order it offers them (DESIGN §2.5,
    /// changed 2026-08-23 from a free-text box).
    ///
    /// A list rather than a number field because the grant is made at arm's length with a
    /// child watching: two taps beats typing. It stays a *setting* rather than a constant
    /// so the app still never refuses its owner — a parent who needs 90 puts 90 in the list,
    /// which is §2.5's rule moved from the moment of the grant to the shape of the menu.
    ///
    /// **Order is the parent's and is preserved**, because the first entry is what the
    /// dialog pre-selects: reordering the list is how you change the one-keystroke default.
    /// Read it through ``extensionChoices``, never directly.
    public var extensionOptions: [Int] = Config.defaultExtensionOptions

    /// What ships, and the fallback for a list edited down to nothing usable.
    public static let defaultExtensionOptions = [15, 30, 60]
    public var pinHash: String = ""
    public var pinSalt: String = ""

    /// The remote channel (DESIGN §3.5). No new file: these live in `config.json` beside the
    /// PIN hash. Both the endpoint and the token are readable by the child and harmless to
    /// him — the token is read-only (§2.3) — so they are stored in cleartext deliberately,
    /// the same call that put `pin_hash` here rather than in a Keychain (initial-build §2.5).
    public var remoteEndpoint: String = ""
    public var remoteDeviceToken: String = ""
    /// How often the poller asks the backend for grants — fast while a grant is expected,
    /// slow otherwise. Read the clamped values through ``remotePollFastInterval`` /
    /// ``remotePollSlowInterval``, never these raw fields.
    public var remotePollFastSeconds: Int = 4
    public var remotePollSlowSeconds: Int = 45
    /// How long an applied remote grant stays live before it is pruned (§3.5). Read it through
    /// ``remoteGrantTTLInterval``, never raw.
    public var remoteGrantTTLSeconds: Int = 900

    /// The shipped defaults.
    public init() {}

    /// DESIGN §6: configured means a PIN exists. §2.5 turns that into a hard rule — with
    /// no PIN the app must not cover the screen, because nothing could then uncover it.
    ///
    /// **The salt is checked by decoding it, not by measuring it.** `pinSalt` is base64, and
    /// a non-empty string that is not base64 — one hand-edit away, since nothing validates
    /// `config.json` (T03) — decodes to nothing: ``pinSaltData`` returns `nil` and
    /// `verifyPIN` can never be called with it. Measured with `!pinSalt.isEmpty` this read
    /// as configured, so the cover went up and T13's prompt then rejected every PIN that
    /// was ever typed into it. A cover with no key is the one outcome §2.5 exists to
    /// prevent, and the only way out of it is the reboot in `RECOVERY.md`.
    public var isConfigured: Bool { !pinHash.isEmpty && pinSaltData != nil }

    /// ``extensionOptions`` as the dialog should draw it: positive, no duplicates, in the
    /// parent's own order, and **never empty**.
    ///
    /// The empty case is the one that matters. Nothing validates `config.json` (T03 finding),
    /// so `[]` or `[0, -30]` is one hand-edit away — and a `Dodaj minuty…` dialog with no
    /// amounts on it is a PIN prompt that can grant nothing, which is the single thing this
    /// list must never become. It falls back to what ships rather than to no answer.
    public var extensionChoices: [Int] {
        var seen = Set<Int>()
        let cleaned = extensionOptions.filter { $0 > 0 && seen.insert($0).inserted }
        return cleaned.isEmpty ? Self.defaultExtensionOptions : cleaned
    }

    /// Paired means both an endpoint to reach and a token to reach it with. Derived, not
    /// stored: either one alone is a half-finished pairing that can talk to nothing.
    public var isRemotePaired: Bool { !remoteEndpoint.isEmpty && !remoteDeviceToken.isEmpty }

    /// The poll intervals and the TTL as the code should actually use them: never zero or
    /// negative. `config.json` is hand-editable with nothing validating it (T03 finding), so
    /// `remote_poll_fast_seconds: 0` is one edit away — and a zero poll interval is a spinning
    /// timer, a zero TTL expires every grant the instant it lands. The floor is 1 second: the
    /// smallest value that is still a poll rather than a busy-loop. This mirrors
    /// ``extensionChoices`` and ``pinSaltData`` — the raw field is preserved and round-trips,
    /// the sanitised value is what callers read.
    public var remotePollFastInterval: TimeInterval { Self.secondsFloor(remotePollFastSeconds) }
    public var remotePollSlowInterval: TimeInterval { Self.secondsFloor(remotePollSlowSeconds) }
    public var remoteGrantTTLInterval: TimeInterval { Self.secondsFloor(remoteGrantTTLSeconds) }

    private static func secondsFloor(_ seconds: Int) -> TimeInterval { TimeInterval(max(1, seconds)) }

    /// The salt as bytes, or `nil` if it is absent or not base64. A malformed salt is not
    /// a configured PIN, and callers must treat it as "no PIN" rather than guessing.
    public var pinSaltData: Data? {
        guard !pinSalt.isEmpty, let data = Data(base64Encoded: pinSalt), !data.isEmpty else {
            return nil
        }
        return data
    }

    /// Snake_case on the wire, matching the event log and DESIGN §6's `pin_hash`. Spelled
    /// out rather than left to a key-encoding strategy so the file format is readable here
    /// and cannot drift when a property is renamed.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionMinutes = "session_minutes"
        case selfServiceSessionsPerDay = "self_service_sessions_per_day"
        case dayResetHour = "day_reset_hour"
        case idleGraceSeconds = "idle_grace_seconds"
        case mediaGraceSeconds = "media_grace_seconds"
        case warningMinutes = "warning_minutes"
        case extensionOptions = "extension_options"
        case pinHash = "pin_hash"
        case pinSalt = "pin_salt"
        case remoteEndpoint = "remote_endpoint"
        case remoteDeviceToken = "remote_device_token"
        case remotePollFastSeconds = "remote_poll_fast_seconds"
        case remotePollSlowSeconds = "remote_poll_slow_seconds"
        case remoteGrantTTLSeconds = "remote_grant_ttl_seconds"
    }

    static let jsonKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    /// Every key is optional on the way in.
    ///
    /// The synthesised initialiser would reject a file written by an *older* build — one
    /// missing whatever key was added since — and a missing key is not corruption, it is a
    /// default. Combined with `ConfigStore`'s unknown-key preservation this makes the
    /// format tolerant in both directions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        sessionMinutes = try value(.sessionMinutes, defaults.sessionMinutes)
        selfServiceSessionsPerDay = try value(.selfServiceSessionsPerDay, defaults.selfServiceSessionsPerDay)
        dayResetHour = try value(.dayResetHour, defaults.dayResetHour)
        idleGraceSeconds = try value(.idleGraceSeconds, defaults.idleGraceSeconds)
        mediaGraceSeconds = try value(.mediaGraceSeconds, defaults.mediaGraceSeconds)
        warningMinutes = try value(.warningMinutes, defaults.warningMinutes)
        extensionOptions = try value(.extensionOptions, defaults.extensionOptions)
        pinHash = try value(.pinHash, defaults.pinHash)
        pinSalt = try value(.pinSalt, defaults.pinSalt)
        remoteEndpoint = try value(.remoteEndpoint, defaults.remoteEndpoint)
        remoteDeviceToken = try value(.remoteDeviceToken, defaults.remoteDeviceToken)
        remotePollFastSeconds = try value(.remotePollFastSeconds, defaults.remotePollFastSeconds)
        remotePollSlowSeconds = try value(.remotePollSlowSeconds, defaults.remotePollSlowSeconds)
        remoteGrantTTLSeconds = try value(.remoteGrantTTLSeconds, defaults.remoteGrantTTLSeconds)
    }
}

/// What `ConfigStore.load()` had to do to produce a `Config`.
///
/// Returned rather than logged: `RSTCore` has no event log and no clock, so the caller
/// writes the `config_reset` event (DESIGN §3.5) stamped with the decision's time.
public enum ConfigLoadOutcome: Equatable, Sendable {
    /// Parsed from disk.
    case loaded
    /// No file yet — shipped defaults, and nothing written. First run owns the first write.
    case missing
    /// Unparseable. Moved aside and replaced with shipped defaults; `backup` is where the
    /// original went, or `nil` if even that failed. **Log `config_reset` when you see this.**
    case reset(backup: URL?)
}

public struct ConfigLoad: Sendable {
    public let config: Config
    public let outcome: ConfigLoadOutcome
}

/// Reads and writes `config.json`.
///
/// The directory is injected: resolving `RST_DATA_DIR` is a question about the
/// environment, and the environment is `RSTApp`'s half of the boundary.
public struct ConfigStore: Sendable {
    public let directory: URL
    public let url: URL
    /// Where an unparseable file is moved. One slot, overwritten: the most recent
    /// corruption is the one worth keeping.
    public var backupURL: URL { url.appendingPathExtension("bad") }

    public init(directory: URL, fileName: String = "config.json") {
        self.directory = directory
        self.url = directory.appendingPathComponent(fileName)
    }

    /// Never throws. A config that cannot be read is repaired from shipped defaults and
    /// the app carries on enforcing — DESIGN §3.5. This is not a general fail-open rule:
    /// the one place the app *does* stand down is a missing PIN (§2.5), and that is a
    /// property of the resulting `Config`, not of this function.
    public func load() -> ConfigLoad {
        guard let data = try? Data(contentsOf: url) else {
            // Absent and unreadable are different things, and only absence is ordinary.
            if FileManager.default.fileExists(atPath: url.path) {
                return ConfigLoad(config: Config(), outcome: .reset(backup: quarantine()))
            }
            return ConfigLoad(config: Config(), outcome: .missing)
        }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return ConfigLoad(config: Config(), outcome: .reset(backup: quarantine()))
        }
        return ConfigLoad(config: config, outcome: .loaded)
    }

    /// Moves the bad file aside and writes shipped defaults in its place, so the next
    /// launch does not repeat the quarantine and the parent has a valid file to edit.
    /// Returns where the original went, or `nil` if the move failed.
    private func quarantine() -> URL? {
        let fm = FileManager.default
        var backup: URL? = backupURL
        do {
            try? fm.removeItem(at: backupURL)
            try fm.moveItem(at: url, to: backupURL)
        } catch {
            backup = nil
        }
        // Best effort: a defaults file we could not write is a config we will default
        // again next launch, which is the same outcome one launch later.
        try? save(Config())
        return backup
    }

    /// Atomic. Temp file, then rename — `Data.write(options: .atomic)` is precisely that,
    /// into the same directory, and hand-rolling it only adds an unlink race on failure.
    /// The watchdog kills this process by design, so a torn write is a real scenario.
    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let encoded = try JSONEncoder().encode(config)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw ConfigError.encodingProducedNonObject
        }

        // Keys a newer build wrote are copied through, so an older build downgrading
        // someone's Mac for an afternoon does not silently truncate their settings. Read
        // at save time rather than remembered from `load()`: this store may never have
        // loaded, and the file on disk is the thing actually at risk.
        for (key, value) in unknownKeysOnDisk() where object[key] == nil {
            object[key] = value
        }

        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private func unknownKeysOnDisk() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.filter { !Config.jsonKeys.contains($0.key) }
    }

    public enum ConfigError: Error {
        case encodingProducedNonObject
    }
}
