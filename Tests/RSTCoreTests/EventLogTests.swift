import Foundation
import Testing
@testable import RSTCore

/// T06 — the append-only JSONL event log.
///
/// The file is the report (DESIGN §3.5), so these tests care about the *text* as much as
/// the types: a log nobody can read six months later has failed whatever the round-trip
/// says.
@Suite("Event log")
struct EventLogTests {

    /// `Europe/Warsaw` throughout, fixed. The offset in the file is the thing under test,
    /// so reading it from the machine would make the assertions say nothing.
    static let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    /// 2026-08-21T19:42:03.118+02:00 — the design's own example line, to the millisecond.
    /// Millisecond precision on purpose: the format carries three decimal places, so a
    /// `Date` with more would not round-trip exactly and the test would be asserting the
    /// formatter's rounding rather than the format.
    static let instant = Date(timeIntervalSince1970: 1_787_334_123.118)

    // MARK: - The wire format

    @Test("the line matches the design's example, field for field")
    func lineMatchesTheDesignExample() {
        let event = Event(.blocked, at: Self.instant, [.reason: "expired", .usedSeconds: 5400])
        #expect(event.encoded(timeZone: Self.warsaw) ==
                #"{"ts":"2026-08-21T19:42:03.118+02:00","type":"blocked","reason":"expired","used_s":5400}"#)
    }

    @Test("ts comes first, type second, payload alphabetical after that")
    func keyOrderIsStable() {
        let event = Event(.extended, at: Self.instant, ["n_today": 1, "minutes": 15, "a": "first"])
        let encoded = event.encoded(timeZone: Self.warsaw)
        let keyOrder = ["\"ts\"", "\"type\"", "\"a\"", "\"minutes\"", "\"n_today\""]
        let positions = keyOrder.map { encoded.range(of: $0)?.lowerBound }
        #expect(!positions.contains(where: { $0 == nil }), "a key is missing from \(encoded)")
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted(),
                "keys out of order in \(encoded)")
    }

    @Test("an event with no payload is still a well-formed object")
    func emptyPayloadHasNoTrailingComma() {
        let encoded = Event(.rearmed, at: Self.instant).encoded(timeZone: Self.warsaw)
        #expect(encoded == #"{"ts":"2026-08-21T19:42:03.118+02:00","type":"rearmed"}"#)
        #expect(parsed(encoded) != nil, "not valid JSON: \(encoded)")
    }

    @Test("the line ends in exactly one newline, and the object itself does not")
    func lineIsTheObjectPlusOneNewline() {
        let event = Event(.uncovered, at: Self.instant)
        let line = event.line(timeZone: Self.warsaw)
        #expect(line == event.encoded(timeZone: Self.warsaw) + "\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
    }

    /// Hand-escaping is where a log format grows its first unparseable line. The values
    /// here are what a `reason` carrying a file path or an app name can really contain.
    @Test("quotes, backslashes, newlines and unicode survive as valid JSON")
    func stringsAreEscaped() throws {
        let nasty = "a\"b\\c\nd\te\u{1F600}ł"
        let event = Event(.appQuit, at: Self.instant, ["name": .string(nasty), "pa\"th": "/x/y"])
        let object = try #require(parsed(event.encoded(timeZone: Self.warsaw)))
        #expect(object["name"] as? String == nasty)
        #expect(object["pa\"th"] as? String == "/x/y")
        #expect(Event(line: event.line(timeZone: Self.warsaw))?.fields["name"] == .string(nasty))
    }

    /// Slashes unescaped, matching `ConfigStore` — a `backup` path reading
    /// `\/Users\/child\/…` is technically valid JSON and unreadable by eye.
    @Test("slashes are not escaped")
    func slashesStayReadable() {
        let event = Event(.configReset, at: Self.instant, [.backup: "/Users/child/config.json.bad"])
        #expect(event.encoded(timeZone: Self.warsaw).contains("/Users/child/config.json.bad"))
    }

    // MARK: - Round-trip

    /// The task doc's first test, done exhaustively: `EventType` is `CaseIterable` so a
    /// case added later cannot skip this.
    @Test("every event type round-trips", arguments: EventType.allCases)
    func everyTypeRoundTrips(type: EventType) throws {
        let event = Event(type, at: Self.instant,
                          ["text": "x", "whole": 42, "fraction": 2.5, "flag": true, "off": false])
        let decoded = try #require(Event(line: event.line(timeZone: Self.warsaw)))
        #expect(decoded == event)
        #expect(decoded.type == type)
    }

    @Test("a whole number is written without a decimal point and comes back a number")
    func wholeNumbersReadAsIntegers() throws {
        let event = Event(.warned, at: Self.instant, [.usedSeconds: 5400.0, .minutes: 15])
        let encoded = event.encoded(timeZone: Self.warsaw)
        #expect(encoded.contains(#""used_s":5400"#))
        #expect(!encoded.contains("5400.0"))
        let decoded = try #require(Event(line: encoded))
        #expect(decoded[.usedSeconds] == .number(5400))
    }

    /// `NSNumber` bridges JSON `true` and JSON `1` to the same Swift type, so a naive
    /// `as? Bool` turns every `1` in the log into `true`. This is the test that catches it.
    @Test("true is not 1 and 1 is not true")
    func booleansAndNumbersStayApart() throws {
        let event = Event(.sessionEnd, at: Self.instant, ["flag": true, "count": 1])
        let decoded = try #require(Event(line: event.line(timeZone: Self.warsaw)))
        #expect(decoded.fields["flag"] == .bool(true))
        #expect(decoded.fields["count"] == .number(1))
        #expect(event.encoded(timeZone: Self.warsaw).contains(#""flag":true"#))
        #expect(event.encoded(timeZone: Self.warsaw).contains(#""count":1"#))
    }

    @Test("ts and type cannot be shadowed by a payload field")
    func reservedKeysAreDropped() throws {
        let event = Event(.warned, at: Self.instant,
                          ["ts": "1999-01-01T00:00:00+00:00", "type": "nonsense", "kept": 1])
        #expect(event.fields == ["kept": .number(1)])
        let encoded = event.encoded(timeZone: Self.warsaw)
        #expect(!encoded.contains("nonsense"))
        // One `ts` member and one `type` member, so no parser has to choose.
        #expect(encoded.components(separatedBy: #""ts":"#).count == 2)
        #expect(encoded.components(separatedBy: #""type":"#).count == 2)
        let reparsed = try #require(Event(line: encoded))
        #expect(reparsed.type == .warned)
    }

    // MARK: - Timestamps

    @Test("the timestamp parses back to the same instant, offset intact")
    func timestampRoundTripsWithItsOffset() throws {
        let encoded = Event(.blocked, at: Self.instant).encoded(timeZone: Self.warsaw)
        #expect(encoded.contains("+02:00"), "the offset is gone from \(encoded)")
        let decoded = try #require(Event(line: encoded))
        #expect(decoded.timestamp == Self.instant)
    }

    /// The reason the offset is kept at all: the same evening on either side of a DST
    /// change reads as the same wall clock and is a different hour. Warsaw's autumn
    /// transition is 2026-10-25.
    @Test("the same instant in a different offset is the same instant, and says so")
    func offsetSurvivesADSTChange() throws {
        // 2026-10-24T19:00:00+02:00 and 2026-10-26T19:00:00+01:00 — one evening apart.
        let summerEvening = Date(timeIntervalSince1970: 1_792_861_200)
        let winterEvening = Date(timeIntervalSince1970: 1_793_037_600)

        let summer = Event(.sessionStart, at: summerEvening).encoded(timeZone: Self.warsaw)
        let winter = Event(.sessionStart, at: winterEvening).encoded(timeZone: Self.warsaw)

        #expect(summer.contains("2026-10-24T19:00:00.000+02:00"), "\(summer)")
        #expect(winter.contains("2026-10-26T19:00:00.000+01:00"), "\(winter)")
        #expect(try #require(Event(line: summer)).timestamp == summerEvening)
        #expect(try #require(Event(line: winter)).timestamp == winterEvening)
    }

    @Test("UTC writes Z and still round-trips")
    func utcRoundTrips() throws {
        let encoded = Event(.watchdogExit, at: Self.instant).encoded(timeZone: TimeZone(identifier: "UTC")!)
        #expect(encoded.contains("17:42:03.118Z"), "\(encoded)")
        let decoded = try #require(Event(line: encoded))
        #expect(decoded.timestamp == Self.instant)
    }

    /// A hand-edited line saying `"2026-08-22T06:00:00+02:00"` is a time somebody meant,
    /// not corruption — the same leniency `SessionState` grants `session.json`.
    @Test("a timestamp without fractional seconds still parses")
    func fractionalSecondsAreOptionalOnTheWayIn() throws {
        let line = #"{"ts":"2026-08-22T06:00:00+02:00","type":"rearmed"}"#
        let event = try #require(Event(line: line))
        #expect(event.type == .rearmed)
        #expect(Event.timestamp(from: "2026-08-22T06:00:00+02:00") == event.timestamp)
    }

    // MARK: - Lines this build cannot read

    @Test("unreadable lines are skipped, not guessed at", arguments: [
        "",
        "   \n",
        #"{"ts":"2026-08-21T19:42:03.118+02:00","typ"#,          // truncated by a kill
        #"{"ts":"2026-08-21T19:42:03.118+02:00"}"#,              // no type
        #"{"type":"blocked"}"#,                                  // no ts
        #"{"ts":"yesterday","type":"blocked"}"#,                 // unparseable ts
        #"{"ts":"2026-08-21T19:42:03.118+02:00","type":"teleported"}"#,  // a newer build's type
        #"{"ts":"2026-08-21T19:42:03.118+02:00","type":"blocked","x":[1,2]}"#,  // no array values
        #"{"ts":"2026-08-21T19:42:03.118+02:00","type":"blocked","x":null}"#,
        "[1,2,3]",
    ])
    func badLinesReturnNil(line: String) {
        #expect(Event(line: line) == nil, "accepted \(line)")
    }

    // MARK: - FileEventSink

    @Test("appending never rewrites earlier lines")
    func appendingOnlyAppends() throws {
        try withTemporaryDirectory { directory in
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            let first = Event(.sessionStart, at: Self.instant, [.countToday: 1])
            sink.append(first)
            let afterFirst = try String(contentsOf: sink.url, encoding: .utf8)

            for index in 1...20 {
                sink.append(Event(.warned, at: Self.instant.addingTimeInterval(Double(index)),
                                  [.threshold: .number(Double(index))]))
            }

            let text = try String(contentsOf: sink.url, encoding: .utf8)
            #expect(text.hasPrefix(afterFirst), "the first line changed")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            #expect(lines.count == 21)
            #expect(Event(line: String(lines[0])) == first)
            #expect(text.hasSuffix("\n"), "the file does not end in a newline")
        }
    }

    @Test("the file survives a reopen — a second sink appends rather than truncates")
    func aSecondSinkDoesNotTruncate() throws {
        try withTemporaryDirectory { directory in
            FileEventSink(directory: directory, timeZone: Self.warsaw)
                .append(Event(.sessionStart, at: Self.instant))
            FileEventSink(directory: directory, timeZone: Self.warsaw)
                .append(Event(.sessionEnd, at: Self.instant))
            let events = try readEvents(directory.appendingPathComponent("events.jsonl"))
            #expect(events.map(\.type) == [.sessionStart, .sessionEnd])
        }
    }

    @Test("the data directory is created if it is not there")
    func missingDirectoryIsCreated() throws {
        try withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("not/created/yet")
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            sink.append(Event(.rearmed, at: Self.instant))
            let stored = try readEvents(sink.url)
            #expect(stored.map(\.type) == [.rearmed])
        }
    }

    /// `O_APPEND` plus one `write` per line is the whole robustness claim. Concurrent
    /// writers must produce whole lines or nothing — never a line spliced into another.
    @Test("concurrent appends never interleave a partial line")
    func concurrentAppendsStayWhole() throws {
        try withTemporaryDirectory { directory in
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            let writers = 8, each = 40
            // A long payload so a torn write would be obvious rather than lucky.
            let padding = String(repeating: "x", count: 300)

            DispatchQueue.concurrentPerform(iterations: writers) { writer in
                for index in 0..<each {
                    sink.append(Event(.warned, at: Self.instant,
                                      ["writer": .number(Double(writer)),
                                       "index": .number(Double(index)),
                                       "pad": .string(padding)]))
                }
            }

            let text = try String(contentsOf: sink.url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            #expect(lines.count == writers * each)
            for line in lines {
                #expect(Event(line: String(line)) != nil, "torn line: \(line.prefix(120))")
            }
            // Every writer's every index landed exactly once.
            let seen = Set(lines.compactMap { Event(line: String($0)) }.map {
                "\($0.fields["writer"] ?? .number(-1))/\($0.fields["index"] ?? .number(-1))"
            })
            #expect(seen.count == writers * each)
        }
    }

    /// A full disk must not switch enforcement off. `append` has no throwing path at all,
    /// so the test is that the process survives and the diagnostic lands elsewhere.
    @Test("a write failure does not throw into the caller, and goes to app.log")
    func writeFailureIsSwallowedAndDiagnosed() throws {
        try withTemporaryDirectory { directory in
            // A directory where the log file should be: `open(2)` fails with EISDIR.
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            try FileManager.default.createDirectory(at: sink.url, withIntermediateDirectories: true)

            sink.append(Event(.blocked, at: Self.instant, [.reason: "expired"]))   // must not trap

            let diagnostics = try String(contentsOf: sink.diagnosticsURL, encoding: .utf8)
            #expect(diagnostics.contains("events.jsonl append failed"))
            #expect(diagnostics.contains("directory"), "\(diagnostics)")   // strerror(EISDIR)
            // The line that could not be stored is in the diagnostic, so it is not lost.
            #expect(diagnostics.contains(#""type":"blocked""#))
        }
    }

    @Test("a failure with app.log unwritable too is still not a crash")
    func doubleFailureIsSilent() throws {
        try withTemporaryDirectory { directory in
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            try FileManager.default.createDirectory(at: sink.url, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sink.diagnosticsURL, withIntermediateDirectories: true)
            sink.append(Event(.watchdogExit, at: Self.instant))       // the whole assertion
        }
    }

    @Test("the file is exactly what jq will read")
    func theFileIsReadableAsJSONL() throws {
        try withTemporaryDirectory { directory in
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            sink.append(Event(.sessionStart, at: Self.instant, [.countToday: 1]))
            sink.append(Event(.extended, at: Self.instant.addingTimeInterval(128.784),
                              [.minutes: 15, .countToday: 1]))
            sink.append(Event(.tamperGap, at: Self.instant.addingTimeInterval(2944.323),
                              [.seconds: 288]))

            let text = try String(contentsOf: sink.url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                #expect(parsed(String(line)) != nil, "not JSON: \(line)")
            }
            #expect(text.contains(#""type":"tamper_gap","seconds":288"#), "\(text)")
        }
    }

    // MARK: - MemoryEventSink

    @Test("MemoryEventSink records order faithfully")
    func memorySinkKeepsOrder() {
        let sink = MemoryEventSink()
        let order: [EventType] = [.sessionStart, .warned, .warned, .blocked, .extended, .uncovered]
        for (index, type) in order.enumerated() {
            sink.append(Event(type, at: Self.instant.addingTimeInterval(Double(index))))
        }
        #expect(sink.types == order)
        #expect(sink.events.map(\.timestamp) == sink.events.map(\.timestamp).sorted())
        #expect(sink.events(ofType: .warned).count == 2)
        sink.clear()
        #expect(sink.events.isEmpty)
    }

    @Test("MemoryEventSink loses nothing under concurrent appends")
    func memorySinkIsThreadSafe() {
        let sink = MemoryEventSink()
        DispatchQueue.concurrentPerform(iterations: 8) { writer in
            for index in 0..<50 {
                sink.append(Event(.warned, at: Self.instant,
                                  ["writer": .number(Double(writer)), "index": .number(Double(index))]))
            }
        }
        #expect(sink.events.count == 400)
    }

    @Test("NullEventSink accepts everything and keeps nothing")
    func nullSinkIsInert() {
        let sink = NullEventSink()
        for type in EventType.allCases { sink.append(Event(type, at: Self.instant)) }
    }

    // MARK: - The field vocabulary

    /// The finding this closes: nothing stopped one call site writing `used_s` and another
    /// `usedSeconds`, and the drift would only surface months later in the file that exists
    /// to be read months later. `Field` is now the only door `RSTApp` has — the string-keyed
    /// initialiser is internal, so this suite can still reach it and the app module cannot.
    @Test("a field's wire spelling is what the design says a parent will grep")
    func fieldSpellingsAreTheDocumentedOnes() {
        let documented: [Event.Field: String] = [
            .countToday: "n_today", .minutes: "minutes", .seconds: "seconds",
            .reason: "reason", .usedSeconds: "used_s", .remainingSeconds: "remaining_s",
            .threshold: "threshold", .voice: "voice", .name: "name", .forced: "forced",
            .by: "by", .until: "until", .backup: "backup", .coveredSeconds: "covered_s",
            .changed: "changed",
        ]
        // Every case is spoken for, so a field added without a spelling fails here.
        #expect(Set(documented.keys) == Set(Event.Field.allCases))
        for (field, spelling) in documented { #expect(field.rawValue == spelling) }
    }

    @Test("every field survives the round-trip under its own name", arguments: Event.Field.allCases)
    func everyFieldRoundTrips(field: Event.Field) throws {
        let event = Event(.warned, at: Self.instant, [field: "x"])
        let encoded = event.encoded(timeZone: Self.warsaw)
        #expect(encoded.contains("\"\(field.rawValue)\":\"x\""), "\(encoded)")
        let decoded = try #require(Event(line: encoded))
        #expect(decoded[field] == .string("x"))
        #expect(decoded == event)
    }

    /// The design's own two example lines, built the way `RSTApp` will have to build them.
    @Test("the documented example lines are reachable through Field alone")
    func designExamplesAreExpressible() {
        let start = Event(.sessionStart, at: Self.instant, [.countToday: 1])
        let extended = Event(.extended, at: Self.instant, [.minutes: 45, .countToday: 1])
        #expect(start.encoded(timeZone: Self.warsaw).hasSuffix(
            #""type":"session_start","n_today":1}"#))
        // 45, not 15: the parent types the amount since 2026-08-22, which is what makes
        // `minutes` worth writing down at all (DESIGN §2.5).
        #expect(extended.encoded(timeZone: Self.warsaw).hasSuffix(
            #""type":"extended","minutes":45,"n_today":1}"#))
    }

    /// Reading stays open-ended on purpose: a field a newer build invented must survive a
    /// round-trip through this one rather than being dropped from an append-only record.
    @Test("a field this build has no name for is still read back")
    func unknownFieldsSurviveReading() throws {
        let line = #"{"ts":"2026-08-21T19:42:03.118+02:00","type":"warned","invented_later":7}"#
        let event = try #require(Event(line: line))
        #expect(event.fields["invented_later"] == .number(7))
        #expect(event.encoded(timeZone: Self.warsaw) == line)
    }

    // MARK: - The write path

    /// `EINTR` with nothing written is a signal, not a failure: the file is exactly as it
    /// was, so the retry cannot interleave with another writer. Without it a stray signal
    /// silently costs an event.
    @Test("a write interrupted before any byte lands is retried, not dropped")
    func interruptedWriteIsRetried() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            let refusals = Mutex(2)
            let writer: FileEventSink.Writer = { descriptor, buffer, count in
                if refusals.take() { errno = EINTR; return -1 }
                return write(descriptor, buffer, count)
            }
            let failure = FileEventSink.appendLine("whole line\n", to: url,
                                                   creatingDirectory: directory, writer: writer)
            #expect(failure == nil, "\(failure ?? "")")
            let stored = try String(contentsOf: url, encoding: .utf8)
            #expect(stored == "whole line\n")
        }
    }

    /// The torn-line case, which needs a full disk to reach for real. A short write leaves a
    /// line with no newline; the next append would then be glued onto it, costing a second
    /// event as well as the first. Closing the line bounds the damage to the line already
    /// lost — and the remainder is deliberately not retried, because it would land after
    /// whatever another writer appended meanwhile.
    @Test("a short write closes the torn line so the next event is not glued to it")
    func shortWriteClosesTheLine() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            let truncateOnce = Mutex(1)
            let writer: FileEventSink.Writer = { descriptor, buffer, count in
                write(descriptor, buffer, truncateOnce.take() ? 10 : count)
            }
            let torn = Event(.blocked, at: Self.instant, [.reason: "expired"])
                .line(timeZone: Self.warsaw)
            let failure = FileEventSink.appendLine(torn, to: url,
                                                   creatingDirectory: directory, writer: writer)
            #expect(failure?.contains("short, 10 of") == true, "\(failure ?? "nil")")
            #expect(failure?.contains("line closed") == true, "\(failure ?? "nil")")

            // The event that follows must be readable, which is the whole point.
            let next = Event(.uncovered, at: Self.instant, [.by: "pin"])
            _ = FileEventSink.appendLine(next.line(timeZone: Self.warsaw), to: url,
                                         creatingDirectory: directory, writer: writer)
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            #expect(lines.count == 2)
            #expect(Event(line: String(lines[0])) == nil, "the torn line parsed: \(lines[0])")
            #expect(Event(line: String(lines[1])) == next)
        }
    }

    /// On a genuinely full disk the closing newline fails too. The line stays open and the
    /// message says so — the caller's diagnostic carries the whole dropped event, which is
    /// then the only copy of it.
    @Test("a short write whose closing newline also fails says the line is left open")
    func shortWriteThatCannotBeClosedSaysSo() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            let first = Mutex(1)
            let writer: FileEventSink.Writer = { descriptor, buffer, count in
                if first.take() { return write(descriptor, buffer, 10) }
                errno = ENOSPC
                return -1
            }
            let failure = FileEventSink.appendLine("a much longer line than ten bytes\n", to: url,
                                                   creatingDirectory: directory, writer: writer)
            #expect(failure?.contains("line left open") == true, "\(failure ?? "nil")")
        }
    }

    /// A failing write reaches the caller as a diagnostic and never as a throw, whatever
    /// shape the failure takes. `append` has no throwing path at all.
    @Test("a short write inside the sink is still not a failure the caller can see")
    func sinkSwallowsAShortWrite() throws {
        try withTemporaryDirectory { directory in
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            // A directory in place of the file: `open(2)` fails, so nothing is written and
            // the diagnostic is the only record. Asserted here as the sink's contract.
            try FileManager.default.createDirectory(at: sink.url, withIntermediateDirectories: true)
            sink.append(Event(.tamperGap, at: Self.instant, [.seconds: 288]))
            let diagnostics = try String(contentsOf: sink.diagnosticsURL, encoding: .utf8)
            #expect(diagnostics.contains(#""seconds":288"#), "\(diagnostics)")
        }
    }

    // MARK: - The reason this is testable at all

    /// The timestamp is the *decision's*, not the write's — DESIGN §3.5, and the rule the
    /// cover depends on, since it blocks until a PIN arrives. Nothing in `Event` can read a
    /// clock, so the only way to get this wrong is to pass the wrong `Date`.
    @Test("the sink stamps nothing — the event's own timestamp is what lands")
    func theSinkDoesNotRestampTheEvent() throws {
        try withTemporaryDirectory { directory in
            let sink = FileEventSink(directory: directory, timeZone: Self.warsaw)
            let hoursAgo = Self.instant.addingTimeInterval(-4 * 3600)
            sink.append(Event(.blocked, at: hoursAgo, [.reason: "expired"]))
            let stored = try readEvents(sink.url)
            #expect(stored.first?.timestamp == hoursAgo)
        }
    }
}

// MARK: - Helpers

private func parsed(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func readEvents(_ url: URL) throws -> [Event] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { Event(line: String($0)) }
}

/// A counter shared with a `@Sendable` write stand-in: it says "yes" a fixed number of
/// times and "no" ever after. `NSLock` rather than an actor, because ``FileEventSink/Writer``
/// is synchronous.
private final class Mutex: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    /// `true` while the budget lasts, decrementing it.
    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}

/// A scratch directory removed afterwards, whatever the body does. `RST_DATA_DIR` exists
/// precisely so nothing ever writes to the real Application Support folder from a test.
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rst-eventlog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}
