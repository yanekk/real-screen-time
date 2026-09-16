import Foundation
import RSTCore

/// **The enforcer that cannot cover anything.** DESIGN §3.2, and the reason it is safe to
/// run this build on your own account for a whole day.
///
/// It takes exactly the same `Decision` stream `CoverEnforcer` will take at T11 and writes
/// down what the cover *would* have done. What comes out is a log that can be compared
/// against an afternoon you actually remember — which is the only way to find out whether
/// the sensors and the tick are telling the truth before anything is allowed to take the
/// screen.
///
/// `@unchecked Sendable` behind an `NSLock`, matching `MemoryEventSink` and T07's
/// `RecordingEnforcer`: both protocol methods are synchronous because the decision path
/// calls them inline, before dispatching, and an actor would make `Engine.tick` async for
/// the benefit of one boolean.
final class ObserverEnforcer: Enforcing, @unchecked Sendable {
    private let sink: any EventSink
    private let diagnostics: Diagnostics
    private let lock = NSLock()

    /// Its own copy of the covering edge, deliberately not `Engine`'s.
    ///
    /// `Engine` writes `blocked` on the same edge, and the two are different claims: the
    /// engine's is "the app decided to cover", this one's is "and nothing appeared". Reading
    /// the engine's private state to avoid one boolean would couple the enforcer to the
    /// order in which the engine does its work.
    private var covering = false

    init(sink: any EventSink, diagnostics: Diagnostics = .discarded) {
        self.sink = sink
        self.diagnostics = diagnostics
    }

    /// Writes `would_cover` on the rising edge only.
    ///
    /// Once per cover, not once per tick: `apply` is called every second, and a line a
    /// second is three hundred thousand a day that say nothing between them. The falling
    /// edge is already `Engine`'s `uncovered`.
    ///
    /// **Both `blocked` and `would_cover` appear** in an observer run, at the same instant —
    /// `blocked` from the engine, this one immediately after. That is the honest record:
    /// the decision really was made and really was not acted on, and the pair says so in a
    /// way neither line does alone. A reader who wants only real covers wants
    /// `select(.type=="blocked")` on a release run; a `would_cover` beside it is the marker
    /// saying this one was a development run. Left as a finding for T11 to revisit, when
    /// there is a second enforcer to compare against.
    func apply(_ decision: Decision, at now: Date) {
        let reason = CoverReason(for: decision)
        let covers = decision.coversScreen

        lock.lock()
        let changed = covers != covering
        covering = covers
        lock.unlock()

        guard changed, covers else { return }
        sink.append(Event(.wouldCover, at: now,
                          reason.map { [.reason: .string($0.rawValue)] } ?? [:]))
    }

    /// The warning, the expiry line or the grant that would have been chimed, spoken and
    /// shown (T14).
    ///
    /// **An observer run makes no noise at all** — the user's decision, 2026-08-25. Its
    /// promise is that it changes nothing about the Mac, and a Polish sentence out of the
    /// speakers is a change. What it writes instead is the sentence in `app.log` that lets
    /// you check, after the fact, that the announcement was due at the moment you expected.
    ///
    /// A diagnostic rather than an event: `Engine` has already written the `warned` line,
    /// and a second record of the same threshold in `events.jsonl` would double-count every
    /// warning in a query.
    func announce(_ announcement: Announcement, at now: Date) {
        diagnostics("observer: would announce \(announcement.logDescription)", at: now)
    }
}
