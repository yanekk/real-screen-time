import Foundation

/// What the app does with a ``Decision`` once it has been made.
///
/// **Defined here, in Core, next to the only thing that calls it** — DESIGN §3.2 puts
/// `Enforcer.swift` in the App target, and its implementations (`CoverEnforcer`,
/// `ObserverEnforcer`) still belong there. The *protocol* cannot: ``Engine`` drives it, and
/// `RSTCore` may not reach into `RSTApp`. Nothing in the shape is platform-flavoured — a
/// decision and a time in, no return value — so this costs the boundary nothing.
///
/// Defining it against a fake first is deliberate (T07): a protocol written before its real
/// implementation cannot grow a method the tests are unable to drive.
public protocol Enforcing: Sendable {

    /// Called on **every** tick with the current decision, unchanged or not.
    ///
    /// Not "on change": the cover has to be re-asserted while it is up (presentation options
    /// revert whenever the app is not frontmost), and T10's countdown redraws every second.
    /// Which changes are worth an event is ``Engine``'s question, not this one's.
    func apply(_ decision: Decision, at now: Date)

    /// Chime, spoken line and banner — one warning, the expiry, or a grant (DESIGN §2.4,
    /// §2.5).
    ///
    /// Separate from ``apply(_:_:)`` because these are *edges*, not states: `.warning` is
    /// returned on every tick inside a threshold, and speaking on every one of them would
    /// be unbearable. ``Engine`` fires each one once — and **never while another user is on
    /// the console**, which is §2.2's rule and is invisible to `decide`, since the decision
    /// function reads no sensors at all.
    ///
    /// The signature took a threshold and a remainder until T14, when the expiry line and
    /// the grant confirmation turned out to travel the same path; ``Announcement`` is what
    /// they have in common, and one method is one place for the off-console rule to live.
    func announce(_ announcement: Announcement, at now: Date)

    /// What will actually speak, for the `warned` event's `voice` field — or `nil` when
    /// nothing speaks at all.
    ///
    /// **`say` falls back silently on an unknown voice** (DESIGN §2.4.1), so a Mac quietly
    /// warning a Polish child in English is invisible to everyone except whoever is standing
    /// in the room. ``Engine`` writes the event and cannot ask `AVFoundation` anything, so
    /// the answer comes back up through here.
    var announcerVoice: String? { get }
}

public extension Enforcing {
    /// Nothing speaks. The default, so an enforcer that only records — or only logs — does
    /// not have to answer a question about a subsystem it has not got.
    var announcerVoice: String? { nil }
}

/// Throws every decision away. For tests that are asserting on something else.
public struct NullEnforcer: Enforcing {
    public init() {}
    public func apply(_ decision: Decision, at now: Date) {}
    public func announce(_ announcement: Announcement, at now: Date) {}
}

// MARK: - The vocabularies the log uses

/// Why the cover went up — the `reason` on a `blocked` event.
///
/// T06 left `reason` open ("not a fixed vocabulary yet — the first caller maps it from
/// `Decision`"). This is that caller, and closing it in an enum rather than at a call site
/// is the same argument `Event.Field` makes: a log whose values drift is a log `jq` cannot
/// query, and the drift only surfaces months later.
public enum CoverReason: String, Sendable {
    /// `.awaitingStart` — he has not started a session.
    case noSession = "no_session"
    /// `.awaitingResume` — time remains but nothing is running.
    case paused
    /// `.expired` — the session ran out.
    case expired

    /// Why this decision covers, or `nil` if it does not.
    ///
    /// Public because T08's `ObserverEnforcer` needs the same mapping for its `would_cover`
    /// line that ``Engine`` uses for `blocked`, and it lives on the other side of the
    /// boundary. Two copies of a switch over `Decision` is two places for the vocabulary to
    /// drift, which is the whole argument for closing it in an enum in the first place.
    ///
    /// Optional where ``Engine``'s use of it is not: an enforcer is called on every tick,
    /// including the ones that do not cover, so "no reason" is an answer it needs.
    public init?(for decision: Decision) {
        switch decision {
        case .awaitingStart: self = .noSession
        case .awaitingResume: self = .paused
        case .expired: self = .expired
        case .dormant, .allowed, .warning: return nil
        }
    }
}

/// Why a session stopped — the `reason` on a `session_end` event.
public enum EndReason: String, Sendable {
    /// Its time ran out under an ordinary tick.
    case expired
    /// A gap was charged at launch and took the rest of it (DESIGN §2.3).
    case gap
    /// A PIN-granted stand-down ended it outright (§2.5, and `SessionState.disable`).
    case disabled
    /// 06:00 discarded whatever was left on it (§2.1, T21).
    ///
    /// **Silent, and the whole point of not reusing `.expired`.** The countdown did not reach
    /// zero — the day boundary took the rest — so `Czas minął` would be Polish spoken into an
    /// empty room at six in the morning, about minutes he still had. The child is told
    /// nothing; the new day's offer on the cover is the honest statement.
    ///
    /// The word is for the parent reading the log behind the PIN, who would otherwise see a
    /// session end with no cause. `used_s` on this line is what he actually spent, not what
    /// was on the clock.
    case discarded
}

/// What lifted the cover — the `by` on an `uncovered` event.
public enum UncoverReason: String, Sendable {
    case started, resumed, extended, disabled
}

// MARK: - The engine

/// **One tick of the app, and every command the cover can issue.**
///
/// `decide` says what should be true; this says what changed and writes it down. It owns
/// the handful of rules that live between the decision function and the screen and belong
/// to neither:
///
/// - a warning is announced **once per threshold per session**, and never off-console —
///   as are the expiry line and the grant confirmation, which travel the same path (T14)
/// - `blocked` and `uncovered` are written on the **edges** of covering, not every tick
/// - a stand-down that has expired is cleared, and `rearmed` written, before anything reads it
/// - the event is written **before** the enforcer is called, stamped with the decision's time
///
/// **Why this is in Core and not in `main.swift`.** Every one of those is a rule, and
/// CLAUDE.md's boundary rule is that a rule which leaks into `RSTApp` becomes a rule that
/// can only be checked by hand — on a machine with no UI automation, that means never. DESIGN
/// §3.4 sketches this loop inside the app's timer callback; the timer stays there and calls
/// ``tick(_:)``. T07's harness drives the same object the app does, so what Phase 1 proves is
/// the shipping code rather than a second copy of it.
///
/// Not `Sendable`, and not an actor: it is driven from one place — the app's main run loop,
/// or one test — and an actor would make `tick` async for no reader.
public final class Engine {

    /// The ledger. `public private(set)` because the app persists it and the tests read it;
    /// every mutation goes through a method here so no caller can change time without an
    /// event being written beside it.
    public private(set) var state: SessionState

    /// Re-read on every tick, so T17's Settings can change it under a running app.
    public var config: Config

    /// The decision the enforcer was last given, for T10's menu bar.
    public private(set) var lastDecision: Decision?

    private let sink: any EventSink
    private let enforcer: any Enforcing
    /// Carries its own time zone, which is how `disabled`'s `until` gets a local offset
    /// without `RSTCore` asking the system anything.
    private let calendar: Calendar

    /// Is the cover up. Starts `false` on purpose: a fresh run whose first decision covers
    /// writes `blocked`, because the cover really did go up.
    private var covering = false

    /// The threshold already spoken for this session, or `nil`. Cleared exactly where the
    /// remainder can rise or restart — a new session, a grant, the 06:00 rollover — and on
    /// the end of a session, so a grant that lifts the remainder back over 10 minutes warns
    /// again on the way down.
    ///
    /// **Not on a resume, and not on a wake** (T14 review): neither hands back a second of
    /// time, so the threshold spoken before the break is still the threshold he is in. Both
    /// used to clear it, and the announcement that followed named the bucket rather than the
    /// remainder — "Zostało Ci 5 minut" to a child with 3:55 left, once per break.
    ///
    /// **Readable inside the module for one test, and only one.** The rollover reset cannot
    /// be observed through behaviour today — a remainder only ever falls, so a threshold
    /// already spoken cannot come round again without a grant, and a grant clears this
    /// anyway. It is asserted directly rather than left as a line nothing checks (T14).
    private(set) var announced: Int?

    /// Set by the command that is about to lift the cover, read by the next tick.
    private var uncoverReason: UncoverReason?

    /// Whether the child had the console at the last tick.
    ///
    /// §2.2's silence rule reaches two announcements that do not happen inside a decision:
    /// the expiry line, written while the ledger is being closed, and the grant
    /// confirmation, which arrives from a button and carries no sensors at all. Both are
    /// spoken out loud into whatever room the Mac is in, so both need the same answer the
    /// warnings need. Optimistic to start: a run that has not ticked yet has nobody
    /// switched in either.
    private var onConsole = true

    /// Seconds charged since the app last saw this session start or resume.
    ///
    /// **Not the same as "seconds this session has been used"** where a logout intervened:
    /// liveness is not persisted (T04) and neither is the original grant, so a resumed
    /// session's earlier minutes are not knowable from `session.json`. `used_s` therefore
    /// means "charged in this run", which is a number the log can actually stand behind.
    private var charged: TimeInterval = 0

    public init(state: SessionState,
                config: Config,
                sink: any EventSink,
                enforcer: any Enforcing,
                calendar: Calendar) {
        self.state = state
        self.config = config
        self.sink = sink
        self.enforcer = enforcer
        self.calendar = calendar
    }

    // MARK: - Lifecycle

    /// Close the books on however long the app was away, then carry on (DESIGN §2.3).
    ///
    /// Call once per run, before the first ``tick(_:)`` — at launch, and again on wake from
    /// sleep, which is a gap that happens without a launch (T04 finding, 2026-08-22).
    ///
    /// `bootTime` comes from `sysctl kern.boottime`, read in `RSTApp`: `RSTCore` no more
    /// calls `sysctl` than it reads a clock.
    @discardableResult
    public func launch(at now: Date, bootTime: Date) -> Gap {
        let before = state.remainingSeconds
        let outcome = state.reconcile(at: now, bootTime: bootTime, config: config,
                                      calendar: calendar)

        // A new run knows nothing about what the last one spent, and what the gap just took
        // off the session is the one number it does know.
        //
        // **The charge, not the gap.** `chargedSeconds` is what the gap was *worth*; a gap
        // longer than the session is floored by `SessionState.charge`, so the two part
        // company exactly when the gap ends the session — and that is the case that writes a
        // `session_end`. Reporting the gap there would put a `used_s` on the record larger
        // than the session ever held. Same expression `tick` uses, for the same reason.
        //
        // **Minus the discard** (T21): 06:00 taking the remainder looks byte-for-byte like a
        // charge from here, and it means the opposite — time handed back rather than time
        // spent. Left in, a night slept through with 30 minutes on the clock would put
        // `used_s: 1800` against a session he played 15 of, and a parent reading the log to
        // find out why the evening was short would find the wrong answer.
        charged = max(0, before - state.remainingSeconds - outcome.discardedSeconds)

        if case .unexplained(let seconds) = outcome.gap {
            sink.append(Event(.tamperGap, at: now, [.seconds: .number(seconds.rounded())]))
        }
        // **This is the path the reported scenario takes.** Sleeping writes the clean-exit
        // marker and waking reconciles against it, so the morning after a session left
        // unfinished arrives here and never reaches `tick` with anything on the clock. A fix
        // that only handled the tick would fix nothing for the case that prompted T21.
        //
        // The discard wins where both could apply, and the two cannot really collide: the gap
        // is charged before the rollover, so a gap that reached zero on its own leaves
        // nothing to discard.
        if before > 0, state.remainingSeconds <= 0 {
            endSession(outcome.discardedSeconds > 0 ? .discarded : .gap, at: now)
        }
        return outcome.gap
    }

    /// Write the clean-exit marker on the way out — quit, logout, sleep (DESIGN §2.3).
    ///
    /// This is the one write whose absence punishes an innocent shutdown, so it is a method
    /// of its own rather than a flag on something else.
    public func expectedExit(at now: Date) {
        state.markExpectedExit(at: now)
    }

    // MARK: - The tick

    /// Advance the ledger, decide, write what changed, dispatch.
    ///
    /// `sensors` is a ``Snapshot`` with only the sensor half filled in — `RSTApp` reads idle
    /// seconds, the lock, the console and the media assertion, and ``Snapshot/applying(_:_:)``
    /// fills the rest from the ledger. Its `now` is the tick's time and the stamp on every
    /// event this tick writes.
    @discardableResult
    public func tick(_ sensors: Snapshot) -> Decision {
        let now = sensors.now

        // Before anything reads `disabledUntil`, including `decide` below.
        rearmIfDue(at: now)

        onConsole = sensors.sessionOnConsole

        let before = state.remainingSeconds
        let dayBefore = state.dayKey
        // `sensors` rather than the applied snapshot: `SessionState.isActive` reads only the
        // sensor half, and the state half is about to change under it anyway.
        let discarded = state.advance(to: now, snapshot: sensors, config: config,
                                      calendar: calendar)
        // Minus the discard, for the reason `launch` spells out: 06:00 taking the remainder
        // is not time he spent, and `used_s` is the number a parent reads (T21).
        charged += max(0, before - state.remainingSeconds - discarded)

        // **The 06:00 rollover re-arms the warnings** (T14).
        //
        // **Belt and braces since T21, and kept deliberately.** A threshold is only ever
        // spoken-for while a session has time on it, and the boundary now ends any session
        // that has — through `endSession`, which clears the set itself. So the two clears
        // coincide, and this one can no longer be the load-bearing half. It stays because the
        // argument that it is redundant is a chain of three separate invariants, none of them
        // local to this file, and the failure if one of them moves is the morning warning
        // going silent — which is invisible until somebody is standing in the room.
        if state.dayKey != dayBefore { announced = nil }

        // `.discarded` rather than `.expired` when the boundary is what emptied the clock:
        // `.expired` is the one reason that is spoken (§2.4's 0 row), and the user asked for
        // silence at 06:00. The two cannot collide — `advance` rolls the day over before it
        // charges, so a tick that discarded has nothing left to run out.
        if before > 0, state.remainingSeconds <= 0 {
            endSession(discarded > 0 ? .discarded : .expired, at: now)
        }

        let decision = decide(sensors.applying(state, config), config)
        lastDecision = decision

        announceIfDue(decision, onConsole: sensors.sessionOnConsole, at: now)
        reconcileCover(decision, at: now)

        // Last, and after the events: the cover blocks until a PIN arrives, which may be
        // hours, so a line written afterwards is misdated by that whole interval and lost
        // outright if the process is killed meanwhile.
        enforcer.apply(decision, at: now)
        return decision
    }

    // MARK: - Commands from the cover

    /// `Rozpocznij` — one of the day's own sessions.
    ///
    /// Ungated, as ``SessionState/startSelfService(_:)`` is ungated: whether the button is
    /// offered is the cover's question (T11), and a second gate here would be a second place
    /// for the rule to live and disagree.
    public func startSelfService(at now: Date) {
        state.startSelfService(config)
        beginSession(by: .started, at: now)
    }

    /// `Wznów` — take back time already granted. Consumes no session (§2.1).
    /// **`announced` is deliberately not cleared** (T14 review). `Wznów` hands back the
    /// same remainder it paused on — it is the one command that changes nothing about the
    /// time — so a threshold already spoken has not come round again. Clearing it re-fired
    /// the threshold he is standing in with the *bucket's* number rather than his own:
    /// resume at 3:55 and the Mac said "Zostało Ci 5 minut", once for every break he took.
    /// The thresholds below him are still owed and still fire, because each is a different
    /// number from the one recorded here.
    public func resume(at now: Date) {
        state.resume()
        charged = 0
        uncoverReason = .resumed
        sink.append(Event(.sessionResume, at: now,
                          [.remainingSeconds: .number(state.remainingSeconds.rounded())]))
    }

    /// `PIN ▸ Dodaj minuty` — the parent's amount, on a running or a just-expired session.
    ///
    /// **The only PIN grant there is** (DESIGN §2.5, changed 2026-08-22). A whole new session
    /// is `minutes: 30`, which is why `grantSession` no longer exists: the app has no opinion
    /// about the size of a grant, only about recording it.
    ///
    /// **A grant lifts a stand-down** (§2.5, decided by the user 2026-08-22). Without that it
    /// would drain in silence: `decide` goes on returning `.dormant` while `disabledUntil` is
    /// in the future, so the screen stays free — but ``SessionState/advance(to:snapshot:config:calendar:)``
    /// charges whenever the session is live and he is at the machine, and it reads neither the
    /// stand-down nor the decision. `disable` made that safe by *ending* the session, leaving
    /// nothing to charge; a grant puts a live session back and re-opens it. Lifting is the
    /// rule §2.5 already states — the PIN beats everything — and a parent typing minutes into
    /// the dialog means *now*, not "tomorrow, if I remember to switch it back on".
    public func extend(minutes: Int, at now: Date) {
        // Clamped once, here, and used for the state, the log and the test below: a negative
        // off a hand-edited caller must not hand back time, and must not switch the app on.
        let granted = max(0, minutes)

        // Only a real grant lifts it. `minutes: 0` changes nothing, and a no-op that quietly
        // ends the night's stand-down is the surprise this guard exists to avoid.
        if granted > 0 { liftStandDown(at: now) }

        state.extend(minutes: granted)
        // The remainder has just gone back over the thresholds, so the way down warns again.
        announced = nil
        uncoverReason = .extended
        sink.append(Event(.extended, at: now,
                          [.minutes: .number(Double(granted)),
                           .countToday: .number(Double(state.sessionsUsedToday))]))

        // **After the event, and only for a real grant** (§2.5, T14). `minutes: 0` changes
        // nothing, and a Mac announcing that nothing was added is worse than silence. The
        // countdown moving was the only acknowledgement until T14, and on the menu-bar path
        // — where there is no cover to come down — it was very nearly no acknowledgement at
        // all.
        if granted > 0 { announce(.granted(minutes: granted), at: now) }
    }

    /// `PIN ▸ Wyłącz` — stand the app down until the next 06:00 (§2.5).
    ///
    /// The re-arm instant is computed here rather than taken from the caller: "until 06:00
    /// tomorrow" is a rule, and a caller free to pass any date is a caller that can stand the
    /// app down for a week by mistake.
    @discardableResult
    public func disable(at now: Date) -> Date {
        let until = DayWindow.nextReset(after: now, resetHour: config.dayResetHour,
                                        calendar: calendar)
        // Before the state change, because `disable` is what zeroes the remainder.
        if state.remainingSeconds > 0 { endSession(.disabled, at: now) }
        state.disable(until: until)
        uncoverReason = .disabled
        sink.append(Event(.disabled, at: now,
                          [.until: .string(Event.timestampText(until, calendar.timeZone))]))
        return until
    }

    /// `Zablokuj ekran` — his own way to end a turn, and deliberately not behind the PIN
    /// (§2.6). Changes nothing in the ledger: the remainder is whatever it was.
    ///
    /// The lock itself is `RSTApp`'s (`SACLockScreenImmediate`); this writes the record.
    public func lockScreen(at now: Date) {
        sink.append(Event(.screenLocked, at: now))
    }

    // MARK: - Internals

    private func beginSession(by: UncoverReason, at now: Date) {
        charged = 0
        announced = nil
        uncoverReason = by
        // No `kind`: DESIGN §3.5 had one because a session could also be granted behind the
        // PIN, and since 2026-08-22 it cannot — every `session_start` is self-service, and a
        // field with one possible value is noise in a file read by eye.
        sink.append(Event(.sessionStart, at: now,
                          [.countToday: .number(Double(state.sessionsUsedToday))]))
    }

    /// Close the books on a session, and say `Czas minął` if it simply ran out.
    ///
    /// **Only `.expired` is spoken** — §2.4's table gives the 0 row a chime and a line, and
    /// that row is the countdown reaching zero under an ordinary tick. `.gap` is a session
    /// the app was not running for, so the sentence would arrive minutes or hours after the
    /// fact; `.disabled` is the parent standing the app down, where the screen is left free
    /// and "your time is up" is not what happened; `.discarded` is 06:00 taking the rest of a
    /// session he still had, at an hour he is not up to hear it (T21).
    private func endSession(_ reason: EndReason, at now: Date) {
        sink.append(Event(.sessionEnd, at: now,
                          [.reason: .string(reason.rawValue),
                           .usedSeconds: .number(charged.rounded())]))
        announced = nil
        if reason == .expired { announce(.expired, at: now) }
    }

    /// One gate in front of the enforcer, so §2.2's silence has exactly one implementation.
    ///
    /// **The event has already been written by the time anything reaches here**, for the two
    /// announcements that go through this path — `session_end` and `extended`. Only the
    /// noise is suppressed, which is the right way round: what happened is a fact about the
    /// evening, and who was in front of the Mac is a fact about the room.
    ///
    /// The warning is the one exception and does it the other way: see ``announceIfDue(_:onConsole:at:)``.
    private func announce(_ announcement: Announcement, at now: Date) {
        // §2.2: another user has the console, so the Mac is theirs. A background session
        // speaking Polish into whoever is actually using it is what gets an app uninstalled.
        guard onConsole else { return }
        enforcer.announce(announcement, at: now)
    }

    /// A stand-down that has run out is cleared here, not by `decide` — `decide` is pure and
    /// cannot write the `rearmed` line that is the parent's evidence it happened.
    ///
    /// `<=`, matching `decide`'s strict `>`: at the instant it expires the app is armed
    /// again, which is what makes the 06:00 re-arm exact.
    private func rearmIfDue(at now: Date) {
        guard let until = state.disabledUntil, until <= now else { return }
        state.disable(until: nil)
        sink.append(Event(.rearmed, at: now))
    }

    /// The same lift, taken early and on purpose rather than because the clock reached it.
    ///
    /// One `rearmed` line serves both: what the parent needs from the log is that the app came
    /// back on and when, and the `extended` line written beside it at the same instant already
    /// says what did it. A second vocabulary for the cause would be a field with two possible
    /// values, which §3.5 is elsewhere careful not to add.
    ///
    /// **Not called from ``startSelfService(at:)``, deliberately.** That is the child's own
    /// button, and a child's button beating the parent's stand-down is the opposite of §2.5.
    /// It is unreachable during one anyway — `.dormant` puts no cover on the screen, so there
    /// is nothing to press.
    private func liftStandDown(at now: Date) {
        guard state.disabledUntil != nil else { return }
        state.disable(until: nil)
        sink.append(Event(.rearmed, at: now))
    }

    /// DESIGN §2.4 gives one warning per threshold; `decide` returns `.warning` on every tick
    /// inside it and says de-duplication belongs here.
    private func announceIfDue(_ decision: Decision, onConsole: Bool, at now: Date) {
        guard case .warning(let remaining, let threshold) = decision else { return }

        // §2.2 again, and here it is checked *before* both the event and `announced`, which
        // is what T07 settled and T14 leaves alone: a threshold crossed while another user
        // has the Mac has not really been reached — the ledger charges nothing off-console,
        // so the remainder is frozen where it was — and it is still owed when he comes back.
        // The other two announcements have nothing to come back to, which is why they are
        // gated inside ``announce(_:at:)`` after their event and this one is gated here.
        guard onConsole else { return }
        guard threshold != announced else { return }
        announced = threshold

        var fields: [Event.Field: EventValue] = [
            .threshold: .number(Double(threshold)),
            .remainingSeconds: .number(remaining.rounded())
        ]
        // Omitted rather than guessed when nothing speaks — an observer run and a test both
        // warn without a voice, and `voice: "none"` in an evidence log is a claim about a
        // subsystem that was never asked.
        if let voice = enforcer.announcerVoice { fields[.voice] = .string(voice) }
        sink.append(Event(.warned, at: now, fields))

        announce(.warning(minutes: threshold,
                          suggestsSaving: config.warningSuggestsSaving(threshold)),
                 at: now)
    }

    /// `blocked` and `uncovered` are edges. Written every tick they would be a few hundred
    /// thousand lines a day and would say nothing.
    private func reconcileCover(_ decision: Decision, at now: Date) {
        let covers = decision.coversScreen
        guard covers != covering else { return }
        covering = covers

        if covers {
            sink.append(Event(.blocked, at: now,
                              [.reason: .string(Self.coverReason(decision).rawValue)]))
        } else {
            // `by` is omitted rather than guessed when nothing set it — the cover can also
            // lift because a stand-down arrived, and an invented value in an evidence log is
            // worse than a missing one.
            sink.append(Event(.uncovered, at: now,
                              uncoverReason.map { [.by: .string($0.rawValue)] } ?? [:]))
        }
        uncoverReason = nil
    }

    private static func coverReason(_ decision: Decision) -> CoverReason {
        // The `??` is unreachable: this is only called where `Decision.coversScreen` is
        // true, and that is the single place saying which three those are. Defaulted rather
        // than trapped — a log line is not worth a crash.
        CoverReason(for: decision) ?? .noSession
    }
}
