import Foundation

/// What the app did, one JSON object per line (DESIGN §3.5).
///
/// **This is the report.** There is no report UI and there will not be one — `jq` reads
/// the file, and the three recipes in the README answer the questions a parent actually
/// asks. Charting was considered and declined.
///
/// The names are the wire format: they are what a parent greps for six months from now,
/// so they are `snake_case` and English (DESIGN §2.4.2 — the log is behind the PIN in
/// spirit even though nothing gates the file).
public enum EventType: String, Codable, Sendable, CaseIterable {
    case sessionStart  = "session_start"
    case sessionResume = "session_resume"
    case sessionEnd    = "session_end"
    case warned, blocked, uncovered, extended
    case screenLocked  = "screen_locked"
    case disabled, rearmed
    case tamperGap     = "tamper_gap"
    case configReset   = "config_reset"
    /// **A setting was changed on purpose** — T17's window, DESIGN §2.5's list, the PIN.
    ///
    /// Deliberately *not* ``configReset``, which means the opposite: that the file was
    /// unparseable and the app threw it away. One type for both would make `config_reset`
    /// unreadable as evidence — a parent grepping it six weeks later could no longer tell
    /// their own edit from a corruption — and the schema comment on ``Event/Field`` makes
    /// that exact drift the thing this vocabulary exists to prevent.
    ///
    /// **Extends DESIGN §3.5's list of types**, which was written before this window
    /// existed and does not name it. See the 2026-08-27 finding.
    case configChanged = "config_changed"
    case watchdogExit  = "watchdog_exit"
    case appQuit       = "app_quit"
    /// `Wyloguj` confirmed on the cover. Written **before** the log-out runs, stamped with
    /// the decision time: a real log-out kills this process within seconds, so a line
    /// written after it would never be written at all (cover-buttons-logout §2.2).
    ///
    /// Recorded for a dry run too — the decision was made; `app.log` says whether the
    /// log-out itself was real.
    case loggedOut     = "logged_out"
    /// Observer mode: the app decided to cover and deliberately did not (`RST_ENFORCE=0`).
    /// Distinct from `blocked` so a development run cannot be mistaken for a real block
    /// when the log is read months later.
    case wouldCover    = "would_cover"
}

/// A value in an event's payload.
///
/// Three cases, not four: **there is no separate integer**. A `Double` that happens to be
/// whole is written as `5400` rather than `5400.0`, so `used_s` reads the way the design's
/// examples read — and because JSON has one number type, a decoded `5400` would otherwise
/// come back as an `Int` and fail to equal the `Double` that produced it. One case makes
/// the round-trip exact instead of nearly exact.
public enum EventValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

extension EventValue: ExpressibleByStringLiteral,
                      ExpressibleByIntegerLiteral,
                      ExpressibleByFloatLiteral,
                      ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// One line of the log.
///
/// `timestamp` is the time of the **decision**, not of the write — see ``EventSink`` and
/// DESIGN §3.5. It arrives as a parameter like every other time in `RSTCore`; there is no
/// initialiser that reads a clock, deliberately, because the whole point of the rule is
/// that the two moments differ.
public struct Event: Equatable, Sendable {

    /// Every field name the log is allowed to use.
    ///
    /// **This enum is the log's schema.** Nothing else stops one call site writing `used_s`
    /// and another `usedSeconds`, and a log whose field names drift is a log `jq` cannot
    /// query — the drift would only surface months later, in the file that exists to be
    /// read months later. Adding a field is a deliberate one-line edit here, where it is
    /// visible in review, rather than a string typed at a call site.
    ///
    /// The wire spellings are `snake_case` because that is what a parent greps. Where a
    /// name is not fixed by DESIGN §3.5 or a task doc it says so, and the first caller is
    /// free to argue — in a commit that changes this file.
    public enum Field: String, Sendable, CaseIterable, Comparable {
        /// `session_start`, `extended`: how many so far today, on the 06:00 day (DESIGN §3.5).
        case countToday = "n_today"
        /// `extended`: the size of the grant, in minutes.
        ///
        /// **Whatever the parent typed** — DESIGN §2.5 stopped fixing it at 15 on
        /// 2026-08-22, which is what makes this field worth reading rather than a constant.
        case minutes
        /// `tamper_gap`: the unexplained gap, charged in full (DESIGN §3.5).
        case seconds
        /// `blocked`, `would_cover`, `session_end`: why. Closed by T07's two enums —
        /// ``CoverReason`` (`no_session`, `paused`, `expired`) for a cover, ``EndReason``
        /// (`expired`, `gap`, `disabled`) for a session. T08's `would_cover` reuses the
        /// former, since it records the cover that a debug run declined to put up.
        case reason
        /// `blocked`, `would_cover`, `session_end`: seconds of the session spent.
        /// **Charged in this run**, not since the session was granted: liveness and the
        /// original grant are both absent from `session.json`, so a session resumed after a
        /// logout cannot know its earlier minutes (T07). Written on `session_end`; T08 and
        /// T11 decide whether `blocked` carries it too.
        case usedSeconds = "used_s"
        /// `warned`, `session_resume`: seconds of the session left.
        case remainingSeconds = "remaining_s"
        /// `warned`: which threshold fired — 10, 5 or 1 (DESIGN §2.6).
        case threshold
        /// `warned`: the voice actually resolved, because `say` falls back silently on an
        /// unknown one and a Mac quietly speaking English is invisible otherwise (T14).
        case voice
        /// `app_quit`: what was quit, and whether it had to be forced (DESIGN §7, T11).
        case name
        case forced
        /// `uncovered`: what lifted it. Not in any doc; T07's ``UncoverReason`` is the
        /// first caller and closes the vocabulary at `started`, `resumed`, `extended`,
        /// `disabled` — the three commands that hand the screen back, plus the stand-down
        /// that takes the app out of the way entirely.
        case by
        /// `disabled`: when the stand-down re-arms, which is the next 06:00 (DESIGN §2.7).
        case until
        /// `config_reset`, `tamper_gap`: where an unparseable file was moved to.
        ///
        /// `config.json` at T02; T08 is the second caller, for the `session.json` that
        /// `SessionStore.load()` had to quarantine — DESIGN §3.5 makes that an unexplained
        /// gap, and where the evidence went is the only detail the line can add.
        case backup
        /// `watchdog_exit`: how long the cover had been up when it left (T15).
        case coveredSeconds = "covered_s"
        /// `config_changed`: which settings moved, and from what to what —
        /// `session_minutes 30→45, warning_minutes [10, 5, 1]→[5]` (T17).
        ///
        /// One string rather than a field per setting, because the interesting query is
        /// "what changed, and when" rather than any one value: `jq` selects the type and a
        /// person reads the line. Built by ``Config/changes(to:)``, which never prints a
        /// PIN in either direction.
        case changed
        /// `extended`: `"remote"` when the grant arrived over the network (DESIGN §2.6).
        ///
        /// **Absent on a grant typed at the Mac**, deliberately: a local `extended` line stays
        /// byte-for-byte what it is today, so the existing `jq` recipes and log lines are
        /// untouched, and only a remote grant carries the marker. That is the whole of the
        /// field — one value, one type, and a missing field means "typed here". Written by
        /// ``Engine/applyRemoteGrant(id:minutes:at:announce:)``; the PIN path (``Engine/extend(minutes:at:announce:)``)
        /// writes no `source`.
        case source

        public static func < (lhs: Field, rhs: Field) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The keys `ts` and `type` are the record's own and cannot appear in ``fields``.
    /// A duplicate key in a JSON object is a thing parsers disagree about, and `jq`
    /// silently keeping the last one is the worst possible outcome for a log read as
    /// evidence — so they are filtered out at construction rather than at write time.
    ///
    /// No ``Field`` spells either of them, so the typed initialiser cannot trip this; it
    /// exists for the string-keyed one, which the parser and the tests use.
    public static let reservedKeys: Set<String> = ["ts", "type"]

    public let timestamp: Date
    public let type: EventType
    /// Keyed by the wire name rather than by ``Field`` so that reading a line is lossless:
    /// a field written by a newer build survives a round-trip through this one instead of
    /// being dropped on the floor of an append-only record. Writing goes the other way —
    /// through ``Field`` — so only reading is open-ended.
    public let fields: [String: EventValue]

    /// The way app code builds an event.
    ///
    /// - Note: the string-keyed initialiser is deliberately **not** public. `RSTApp` is a
    ///   different module, so this is the only door it has, and the vocabulary cannot drift
    ///   without an edit to ``Field``.
    public init(_ type: EventType, at timestamp: Date, _ fields: [Field: EventValue] = [:]) {
        self.init(type, at: timestamp, Dictionary(
            uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }
        ))
    }

    /// Free-text field names, for the parser and for the tests that assert on the shape of
    /// the file rather than on its vocabulary. Internal on purpose — see ``Field``.
    init(_ type: EventType, at timestamp: Date, _ fields: [String: EventValue]) {
        self.timestamp = timestamp
        self.type = type
        self.fields = fields.filter { !Self.reservedKeys.contains($0.key) }
    }

    /// Read a field by its name rather than by its spelling.
    public subscript(field: Field) -> EventValue? { fields[field.rawValue] }

    // MARK: - The wire format

    /// The JSON object for this event, without a trailing newline.
    ///
    /// `ts` first, `type` second, then the payload in alphabetical order. Order is not
    /// cosmetic here: this file is read by eye as often as by `jq`, and a line whose
    /// timestamp is somewhere in the middle is a line nobody can scan.
    ///
    /// - Parameter timeZone: the offset the timestamp is written in. **Injected, never
    ///   `TimeZone.current`** — reading the system's zone is a system query, and `RSTCore`
    ///   does not make them (same boundary that keeps `session.json` in UTC; see
    ///   `SessionState.timestampFormatter`). `RSTApp` knows the zone and passes it.
    public func encoded(timeZone: TimeZone) -> String {
        let header = Self.jsonMembers(["ts": Self.timestampText(timestamp, timeZone),
                                       "type": type.rawValue])
        let payload = Self.jsonMembers(fields.mapValues(\.jsonValue))
        return payload.isEmpty ? "{\(header)}" : "{\(header),\(payload)}"
    }

    /// The line as it is appended: the object plus its newline, in one string, so a sink
    /// can hand the whole thing to a single `write(2)`.
    public func line(timeZone: TimeZone) -> String { encoded(timeZone: timeZone) + "\n" }

    /// Parse a line back. `nil` if it is not an event this build understands — a truncated
    /// tail, a blank line, or a `type` from a newer version.
    ///
    /// Lenient by design: this is a *reader* of an append-only file that a crash can leave
    /// half-written, and the useful behaviour is to skip the bad line and keep going. The
    /// tests round-trip through it, and T07's harness asserts against it.
    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeText = object["type"] as? String,
              let type = EventType(rawValue: typeText),
              let timestampText = object["ts"] as? String,
              let timestamp = Self.timestamp(from: timestampText)
        else { return nil }

        var fields: [String: EventValue] = [:]
        for (key, value) in object where !Self.reservedKeys.contains(key) {
            guard let parsed = EventValue(json: value) else { return nil }
            fields[key] = parsed
        }
        self.init(type, at: timestamp, fields)
    }

    // MARK: - Serialisation details

    /// Serialise a dictionary and strip the braces, giving the members alone.
    ///
    /// Round-about, and deliberately so: it means every key and every string in the log is
    /// escaped by `JSONSerialization` rather than by hand, while the caller still controls
    /// the order in which groups of members appear. Hand-escaping is where log formats
    /// grow their first unparseable line.
    private static func jsonMembers(_ object: [String: Any]) -> String {
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return String(text.dropFirst().dropLast())   // "{…}" → "…"
    }

    /// ISO 8601 with milliseconds and the **local UTC offset kept**.
    ///
    /// The offset is the whole point. An evening's screen time read six months later,
    /// across a DST change, is materially harder to interpret without it — `19:42+02:00`
    /// and `19:42+01:00` are different evenings and the same wall clock.
    static func timestampText(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = formatter(fractional: true)
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Fractional seconds first, then without: a line hand-edited to `"2026-08-22T06:00:00+02:00"`
    /// is a time somebody meant. Same leniency as `SessionState.decodeTimestamp`.
    static func timestamp(from text: String) -> Date? {
        for fractional in [true, false] {
            if let date = formatter(fractional: fractional).date(from: text) { return date }
        }
        return nil
    }

    /// Built per call rather than shared. `ISO8601DateFormatter` is a mutable class and
    /// this type is `Sendable`; a cached instance whose `timeZone` is assigned per call is
    /// a data race waiting for the first background writer. A few hundred lines a day
    /// cannot afford to care.
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

private extension EventValue {
    /// A `JSONSerialization`-ready value. A whole number goes out as an `Int` so the file
    /// says `5400`, not `5400.0`; `Double.nan` and the infinities cannot be serialised at
    /// all, so they are written as their textual form rather than losing the line.
    var jsonValue: Any {
        switch self {
        case .string(let text): return text
        case .bool(let flag): return flag
        case .number(let value):
            guard value.isFinite else { return String(value) }
            guard value == value.rounded(), value.magnitude < 9.007199254740992e15 else { return value }
            return Int(value)
        }
    }

    /// The inverse. `NSNumber` bridges a JSON `true` and a JSON `1` to the same Swift type,
    /// so the boolean test has to go through CoreFoundation — `value as? Bool` succeeds for
    /// both and would turn every `1` in the log into `true`.
    init?(json: Any) {
        if CFGetTypeID(json as CFTypeRef) == CFBooleanGetTypeID(), let flag = json as? Bool {
            self = .bool(flag)
        } else if let number = json as? Double {
            self = .number(number)
        } else if let text = json as? String {
            self = .string(text)
        } else {
            return nil
        }
    }
}

// MARK: - Sinks

/// Somewhere an event goes.
///
/// **`append` cannot fail and cannot throw.** A full disk must not be able to switch
/// enforcement off: the decision path calls this and then covers the screen, and an error
/// propagating out of here would either stop the cover or need a `try?` at every call
/// site, which is the same thing written less honestly.
///
/// **Write the event before dispatching the action it describes**, stamped with the time
/// of the decision. The cover blocks until a PIN arrives, which may be hours — a line
/// written afterwards is misdated by that whole interval, and lost outright if the process
/// is killed while covered, which is precisely the case the log exists to record.
public protocol EventSink: Sendable {
    func append(_ event: Event)
}

/// Appends to `events.jsonl`.
///
/// Append-only, so no atomic temp-file-and-rename here — CLAUDE.md's atomic-write rule
/// names `config.json` and `ledger.json`, and it is about whole-file rewrites. What this
/// file needs instead is that a line either lands whole or not at all, which `O_APPEND`
/// plus one `write` per line gives even with two processes writing at once.
///
/// **No rotation.** A few hundred bytes a day.
public struct FileEventSink: EventSink {
    public let directory: URL
    public let url: URL
    /// Where a failed append is reported. Diagnostics, not evidence — DESIGN §3.5.
    public let diagnosticsURL: URL
    /// The offset written into every `ts`. Injected: see ``Event/encoded(timeZone:)``.
    public let timeZone: TimeZone

    public init(directory: URL,
                timeZone: TimeZone,
                fileName: String = "events.jsonl",
                diagnosticsFileName: String = "app.log") {
        self.directory = directory
        self.url = directory.appendingPathComponent(fileName)
        self.diagnosticsURL = directory.appendingPathComponent(diagnosticsFileName)
        self.timeZone = timeZone
    }

    /// Write a line to `app.log`: something went wrong, or something a person will want
    /// to see when they read back an observer run. **Diagnostics, not evidence** — nothing
    /// here is an event, and nothing here is queried by `jq`.
    ///
    /// On the sink rather than in `RSTApp` because the app would otherwise reimplement
    /// ``appendLine(_:to:creatingDirectory:writer:)`` — the directory creation, the single
    /// `write(2)`, the short-write handling — to put a string in a file this type already
    /// owns. Its own failure is discarded for the same reason ``append(_:)`` discards the
    /// diagnostic's: there is nowhere left to report it to.
    ///
    /// The timestamp is a parameter, like every other time in `RSTCore`.
    public func note(_ message: String, at date: Date) {
        _ = Self.appendLine("\(Event.timestampText(date, timeZone)) \(message)\n",
                            to: diagnosticsURL, creatingDirectory: directory)
    }

    public func append(_ event: Event) {
        let line = event.line(timeZone: timeZone)
        if let failure = Self.appendLine(line, to: url, creatingDirectory: directory) {
            // One attempt, at a different path, and its own failure is discarded. The
            // alternative is a retry loop inside the code path that is about to take the
            // screen, which is worse than a missing diagnostic every time.
            _ = Self.appendLine(
                "\(Event.timestampText(event.timestamp, timeZone)) events.jsonl append failed: \(failure) — dropped: \(line)",
                to: diagnosticsURL, creatingDirectory: directory
            )
        }
    }

    /// A `write(2)`, or a stand-in for one. Injected only so the short-write path — which
    /// needs a full disk to reach for real — can be tested at all.
    typealias Writer = @Sendable (Int32, UnsafeRawPointer?, Int) -> Int

    static let systemWriter: Writer = { descriptor, buffer, count in
        write(descriptor, buffer, count)
    }

    /// Returns `nil` on success, or a description of what went wrong.
    ///
    /// **One `write(2)` for the whole line including its newline.** That is the atomicity
    /// claim: with `O_APPEND` the kernel makes the seek-to-end and the write one operation,
    /// so two writers cannot splice a line into each other's. A `FileHandle` seek-to-end
    /// would race, and writing the newline separately would tear the line with one writer.
    ///
    /// Two things can still go wrong with that single call, and they are not the same:
    ///
    /// - **`EINTR` with nothing written.** A signal arrived before any byte landed. Retrying
    ///   is free and cannot interleave, because the file is exactly as it was.
    /// - **A short write.** `ENOSPC` or `RLIMIT_FSIZE` can store some bytes and return that
    ///   count, which leaves a line with no newline — and the *next* append would then be
    ///   glued onto it, costing a second event as well as the torn one. The remainder is
    ///   deliberately **not** retried: it would land after whatever another writer appended
    ///   in the meantime, turning one torn line into two. Instead the line is closed with a
    ///   newline, which bounds the damage to the line that was already lost. That write can
    ///   fail too — on a full disk it usually will — and then the caller's diagnostic is all
    ///   that is left, which is why it carries the whole dropped line.
    static func appendLine(_ line: String, to url: URL, creatingDirectory directory: URL,
                           writer: Writer = systemWriter) -> String? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return "open: \(String(cString: strerror(errno)))" }
        defer { close(descriptor) }

        let bytes = Array(line.utf8)
        var written = 0
        while true {
            written = bytes.withUnsafeBytes { writer(descriptor, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }   // nothing landed; the retry is safe
            break
        }

        if written == bytes.count { return nil }
        let failure = written < 0
            ? "write: \(String(cString: strerror(errno)))"
            : "write: short, \(written) of \(bytes.count) bytes"
        guard written > 0 else { return failure }

        // Close the torn line so it cannot swallow the next event too. One byte, one
        // attempt, its own failure folded into the message rather than retried.
        let closed = [UInt8](arrayLiteral: 0x0A).withUnsafeBytes { writer(descriptor, $0.baseAddress, 1) }
        return closed == 1 ? "\(failure) — line closed" : "\(failure) — line left open"
    }
}

/// Records events in memory, in order. For tests and for T07's harness.
///
/// `@unchecked Sendable` behind an `NSLock`, matching `FakeClock`: ``EventSink/append(_:)``
/// is synchronous by design — the decision path calls it inline, before dispatching — and
/// an actor would make every call site async for the benefit of test-only reads.
public final class MemoryEventSink: EventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Event] = []

    public init() {}

    public func append(_ event: Event) {
        lock.withLock { recorded.append(event) }
    }

    /// Everything appended, oldest first.
    public var events: [Event] { lock.withLock { recorded } }

    /// The types in order — what most assertions actually want to say.
    public var types: [EventType] { events.map(\.type) }

    public func events(ofType type: EventType) -> [Event] { events.filter { $0.type == type } }

    public func clear() { lock.withLock { recorded.removeAll() } }
}

/// Throws every event away. The app shell's stand-in before the data directory is known,
/// and the thing a test uses when it is asserting on something else entirely.
public struct NullEventSink: EventSink {
    public init() {}
    public func append(_ event: Event) {}
}
