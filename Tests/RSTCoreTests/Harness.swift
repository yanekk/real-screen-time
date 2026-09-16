import Foundation
import Testing
@testable import RSTCore

// MARK: - The recording enforcer

/// The fake half of ``Enforcing`` — T07's, and the reason the protocol was written before
/// either real implementation existed.
///
/// `@unchecked Sendable` behind an `NSLock`, matching `MemoryEventSink` and `FakeClock`:
/// both protocol methods are synchronous because the decision path calls them inline, and an
/// actor would make every call site async for the benefit of test-only reads.
final class RecordingEnforcer: Enforcing, @unchecked Sendable {
    private let lock = NSLock()
    private var applied: [(now: Date, decision: Decision)] = []
    private var announcements: [(now: Date, announcement: Announcement)] = []

    /// Set by a test that wants ``Enforcing/announcerVoice`` to answer something — the
    /// `warned` event carries it, and an enforcer with no voice omits the field.
    let voice: String?

    init(voice: String? = nil) { self.voice = voice }

    /// Every tick, in order — the task doc's `calls`.
    var calls: [(now: Date, decision: Decision)] { lock.withLock { applied } }

    /// Everything actually announced, in order: warnings, the expiry line and grants (T14).
    var announced: [(now: Date, announcement: Announcement)] { lock.withLock { announcements } }

    /// Every warning actually spoken. Distinct from the `warned` events only in that a
    /// suppressed warning appears in neither, which is the point of asserting both.
    var warnings: [(now: Date, threshold: Int)] {
        announced.compactMap { entry in
            guard case .warning(let minutes, _) = entry.announcement else { return nil }
            return (entry.now, minutes)
        }
    }

    var announcerVoice: String? { voice }

    func apply(_ decision: Decision, at now: Date) {
        lock.withLock { applied.append((now, decision)) }
    }

    func announce(_ announcement: Announcement, at now: Date) {
        lock.withLock { announcements.append((now, announcement)) }
    }
}

// MARK: - What the assertions are written against

/// A decision with its per-second detail dropped.
///
/// `.allowed(remaining:)` is a different value every tick, so a raw decision list for an
/// evening is fourteen thousand entries and says nothing. What a scenario actually asserts
/// is the *shape* — and, for the two that carry a count or a threshold, the number that
/// distinguishes one offer from another.
///
/// ``Beat/launched`` is not a decision. It marks a run boundary so that two runs which open
/// and close on the same shape do not collapse into one another; the log's `blocked` line
/// proves the same thing, and the timeline is far easier to read with it.
enum Beat: Equatable {
    case launched
    case dormant
    case awaitingStart(Int)
    case awaitingResume
    case allowed
    case warning(Int)
    case expired(Int)

    init(_ decision: Decision) {
        switch decision {
        case .dormant: self = .dormant
        case .awaitingStart(let left): self = .awaitingStart(left)
        case .awaitingResume: self = .awaitingResume
        case .allowed: self = .allowed
        case .warning(_, let threshold): self = .warning(threshold)
        case .expired(let left): self = .expired(left)
        }
    }
}

// MARK: - Scripted sensors

/// The sensor half of a ``Snapshot``, as something a script can nudge.
///
/// **A deliberate departure from the task doc's `readings: [(offset, idle, locked)]`.** Idle
/// seconds are not scripted, they are *derived*: the script says when he last touched the
/// machine and idle grows from there, exactly as `CGEventSource` reports it. Writing "he
/// walked away at 16:10" as an idle value per tick means recomputing a table by hand every
/// time a scenario moves, and a table computed by hand is a table that quietly disagrees with
/// the grace it is meant to be testing. The other two sensors the doc omits — console and
/// media — are needed by several of its own scenarios.
struct ScriptedSensors {
    /// The last HID event. `idleSeconds` is `now` minus this.
    var lastInput: Date
    /// While true, every tick refreshes ``lastInput``: he is at the keyboard using it.
    var typing = true
    var screenLocked = false
    /// `false` while another user is switched in (DESIGN §2.2).
    var sessionOnConsole = true
    var mediaPlaying = false

    func snapshot(at now: Date) -> Snapshot {
        Snapshot(now: now,
                 idleSeconds: max(0, now.timeIntervalSince(lastInput)),
                 screenLocked: screenLocked,
                 sessionOnConsole: sessionOnConsole,
                 mediaPlaying: mediaPlaying)
    }
}

// MARK: - The harness

/// Drives the real ``Engine``, ``decide``, ``SessionState`` and ``Event`` through a scripted
/// day. No windows, no sensors, no clock — and nothing mocked that matters: the only fakes
/// are at the two edges, the sensor readings going in and the enforcer coming out.
///
/// **A run is a process.** ``quit()`` writes the clean-exit marker and ``kill()`` writes
/// nothing; both then put the ledger through `JSONEncoder`/`JSONDecoder` exactly as
/// `SessionStore` does, so every scenario that spans a logout is also asserting that the
/// round trip through `session.json` preserved what it needed to — which is the whole of the
/// "a session survives a logout" rule.
@MainActor
final class Harness {
    let calendar: Calendar
    let clock: FakeClock
    let sink = MemoryEventSink()
    let enforcer: RecordingEnforcer

    var config: Config
    var sensors: ScriptedSensors
    private(set) var engine: Engine
    private(set) var timeline: [(now: Date, beat: Beat)] = []
    /// Ticks so far — asserted against `enforcer.calls.count`, so a scenario cannot silently
    /// stop ticking and still pass.
    private(set) var ticks = 0

    var now: Date { clock.now }
    var remaining: TimeInterval { engine.state.remainingSeconds }
    /// The events in order, which is what the scenarios compare against a literal list.
    var events: [Event] { sink.events }
    /// The decision timeline with consecutive repeats of the same shape collapsed.
    var beats: [Beat] { timeline.map(\.beat) }

    /// `voice` is what ``Enforcing/announcerVoice`` answers — `nil` for an enforcer that
    /// does not speak, which is every scenario except T14's own (2026-08-25).
    init(start: Date,
         config: Config = Config.forTesting(),
         calendar: Calendar = .warsaw,
         state: SessionState = SessionState(),
         voice: String? = nil) {
        self.calendar = calendar
        self.config = config
        self.clock = FakeClock(start)
        self.sensors = ScriptedSensors(lastInput: start)
        let enforcer = RecordingEnforcer(voice: voice)
        self.enforcer = enforcer
        self.engine = Engine(state: state, config: config, sink: sink,
                             enforcer: enforcer, calendar: calendar)
    }

    // MARK: Process lifecycle

    /// Launch (or wake): reconcile the gap, then start ticking.
    @discardableResult
    func launch(bootTime: Date) -> Gap {
        timeline.append((now, .launched))
        return engine.launch(at: now, bootTime: bootTime)
    }

    /// An orderly shutdown — quit, logout, sleep. Writes the clean-exit marker.
    func quit() {
        engine.expectedExit(at: now)
        respawn()
    }

    /// `SIGKILL`. Nothing is written, which is the whole of §2.3's discriminator.
    func kill() {
        respawn()
    }

    /// A fresh process against the ledger as it would be read back off disk.
    private func respawn() {
        let encoded = try! JSONEncoder().encode(engine.state)
        let reloaded = try! JSONDecoder().decode(SessionState.self, from: encoded)
        engine = Engine(state: reloaded, config: config, sink: sink,
                        enforcer: enforcer, calendar: calendar)
    }

    // MARK: Time

    /// Tick once a second up to and including `until`.
    ///
    /// - Parameter step: seconds between ticks. The app's is one; a scenario passes a coarser
    ///   one only for a stretch where nothing is being charged, because `advance` charges the
    ///   whole interval between two ticks and a coarse step would resolve a grace boundary to
    ///   the nearest step.
    func run(until: Date, step: TimeInterval = 1) {
        while clock.now < until {
            clock.advance(min(step, until.timeIntervalSince(clock.now)))
            tick()
        }
    }

    /// Move the clock without ticking: the process is not running, or the Mac is asleep.
    func skip(to date: Date) { clock.now = date }

    /// Tick at the current instant, without moving the clock. Used to open a run.
    func tick() {
        if sensors.typing { sensors.lastInput = clock.now }
        let decision = engine.tick(sensors.snapshot(at: clock.now))
        ticks += 1
        let beat = Beat(decision)
        if timeline.last?.beat != beat { timeline.append((clock.now, beat)) }
    }

    // MARK: Sensors

    /// He stops touching the machine at this instant; idle grows from here.
    func walksAway() {
        sensors.typing = false
        sensors.lastInput = clock.now
    }

    /// He is back at the keyboard.
    func returns() {
        sensors.typing = true
        sensors.lastInput = clock.now
    }

    // MARK: Assertions

    /// The `(time, beat)` timeline as wall-clock text, for a failure that can be read.
    var timelineDescription: String {
        timeline.map { "\(hhmmss($0.now)) \($0.beat)" }.joined(separator: "\n")
    }

    var eventDescription: String {
        events.map { event in
            let payload = event.fields.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(hhmmss(event.timestamp)) \(event.type.rawValue) \(payload)"
        }.joined(separator: "\n")
    }

    func hhmmss(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0,
                      parts.second ?? 0)
    }
}

// MARK: - Shorthand

extension Calendar {
    /// The one time zone every scenario runs in. Injected everywhere — `RSTCore` may not read
    /// `Calendar.current`, which is also the only reason the DST days below are testable.
    static let warsaw = calendar(in: "Europe/Warsaw")

    static func calendar(in identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// A date from wall-clock components in this calendar's time zone.
    func wall(_ year: Int, _ month: Int, _ day: Int,
            _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let parts = DateComponents(year: year, month: month, day: day,
                                   hour: hour, minute: minute, second: second)
        guard let date = date(from: parts) else {
            fatalError("no such local time: \(year)-\(month)-\(day) \(hour):\(minute):\(second)")
        }
        return date
    }
}

extension Config {
    /// Shipped defaults with a PIN, which is what almost every scenario wants: without one
    /// §2.5 stands the whole app down and there is nothing to test.
    static func forTesting() -> Config {
        var config = Config()
        config.pinHash = String(repeating: "a", count: 64)
        config.pinSalt = Data(repeating: 7, count: 16).base64EncodedString()
        return config
    }
}
