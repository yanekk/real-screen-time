import Foundation
import RSTCore

/// **The one place in the app a cover can drop from a network event** (DESIGN §2.6, §3.4), and
/// therefore the most carefully fail-closed. It rides ``AppController``'s existing one-second
/// tick — no second timer — and on each tick, if the cadence's interval has elapsed, launches a
/// single non-blocking fetch. When grants come back it runs each through ``decideRemoteGrant``
/// and, on `.apply`, hands it to ``Engine/applyRemoteGrant(id:minutes:at:announce:)``, ticks to
/// drop the cover, and consumes the grant on the server so it is not re-served.
///
/// **Every failure keeps the cover up.** Offline, a 5xx, a timeout, a body that will not parse —
/// all are ``RemoteClient``'s `.failure`, and every one of them applies nothing (§2.7). A 401 is
/// the single failure that does more than nothing: it raises the token-rejected flag so Settings
/// can say "re-pair" (§2.4). The cover still stays up.
///
/// `@MainActor` because it touches the ``Engine`` — which is single-threaded by design — and the
/// tick. The fetch itself is the only thing that must not run on the main actor: it is `await`ed
/// off a non-isolated ``RemoteClient`` method, so the socket wait never stalls the tick or the
/// watchdog (§3.4), and the result is applied back on the main actor exactly as `PINVerifier`
/// returns its answer to main.
@MainActor
final class RemotePoller {

    private let client: RemoteClient
    private let engine: Engine
    private let clock: any Clock
    /// The day-boundary check in ``decideRemoteGrant`` needs a calendar, and `RSTCore` may not
    /// read `Calendar.current` — so the App layer supplies it, the same `.current` the engine
    /// was built with. Not in the T04 task-doc interface sketch; added because the decision is
    /// the poller's to make (DESIGN §3.4) and it cannot make it without one.
    private let calendar: Calendar
    /// Run a tick right now, so an applied grant drops the cover this instant rather than within
    /// the second. In production this is `AppController.tick`.
    private let onApplied: () -> Void
    /// Raise ``AppController/remoteTokenRejected`` on a 401. Not in the task-doc sketch (which
    /// named only `onApplied`), but DESIGN §3.4 requires the poller to signal a rejected token,
    /// and the flag lives on the controller — which survives the poller and is read by Settings
    /// — so the poller reaches it through a closure, the same shape as `onApplied`.
    private let onTokenRejected: () -> Void

    /// When the last fetch was **launched**, or `nil` if none has been. The cadence interval is
    /// measured from here, so a poll is spaced from the previous request rather than from its
    /// reply — a slow reply does not compress the next interval.
    private var lastPollAt: Date?
    /// A fetch is in flight. A second one launched over it would race the same grants and, worse,
    /// could apply a grant twice in the window before its consume lands — the applied-set dedupe
    /// makes that safe, but not launching is cheaper and clearer.
    private var polling = false

    #if DEBUG
    /// The in-flight fetch-apply-consume task, so a test can `await` the whole async cycle
    /// deterministically instead of sleeping. Set the instant a fetch is launched and cleared
    /// when it finishes; `nil` between polls. Never read by production code.
    private(set) var currentPoll: Task<Void, Never>?
    #endif

    init(client: RemoteClient,
         engine: Engine,
         clock: any Clock,
         calendar: Calendar,
         onApplied: @escaping () -> Void,
         onTokenRejected: @escaping () -> Void) {
        self.client = client
        self.engine = engine
        self.clock = clock
        self.calendar = calendar
        self.onApplied = onApplied
        self.onTokenRejected = onTokenRejected
    }

    /// Called every ``AppController`` tick. Launches an async fetch **only** if the interval for
    /// this cadence has elapsed since the last poll, and returns immediately either way — it
    /// never `await`s the fetch, so the tick and the watchdog are never held (DESIGN §3.4).
    func maybePoll(now: Date, cadence: PollCadence, onConsole: Bool, config: Config) {
        let interval: TimeInterval
        switch cadence {
        // Not paired, or nobody is waiting — do not poll at all (DESIGN §2.5).
        case .idle: return
        case .slow: interval = config.remotePollSlowInterval
        case .fast: interval = config.remotePollFastInterval
        }

        // One fetch at a time.
        guard !polling else { return }

        // Spaced by the interval. `now >= last` keeps a clock stepped backwards from suspending
        // the poll for the length of the correction — the same guard `AppController.persist` makes.
        if let last = lastPollAt, now >= last, now.timeIntervalSince(last) < interval { return }

        // No token, nothing to authenticate with. `cadence != .idle` already implies paired, so
        // this is belt-and-braces against a config whose endpoint and token disagree (both are
        // hand-editable, and nothing validates `config.json`).
        let token = config.remoteDeviceToken
        guard !token.isEmpty else { return }

        lastPollAt = now
        polling = true
        let task = Task { [weak self] in
            // `fetchGrants` is a non-isolated async call, so this `await` hops off the main actor
            // for the socket wait and resumes back on it — the tick ran and returned long ago.
            let result = await self?.client.fetchGrants(token: token)
            await self?.finishPoll(result, onConsole: onConsole, config: config, token: token)
        }
        #if DEBUG
        currentPoll = task
        #endif
    }

    /// Back on the main actor with the fetch's outcome. Applies what is fresh, raises the
    /// token-rejected flag on a 401, and does nothing at all on every other failure.
    private func finishPoll(_ result: Result<[RemoteGrant], RemoteClientError>?,
                            onConsole: Bool, config: Config, token: String) async {
        defer {
            polling = false
            #if DEBUG
            currentPoll = nil
            #endif
        }
        switch result {
        case .success(let grants):
            await apply(grants, onConsole: onConsole, config: config, token: token)
        case .failure(.unauthorized):
            // The token was rejected or revoked (§2.4, §2.7). Settings shows "re-pair"; the
            // cover stays up because nothing was applied.
            onTokenRejected()
        case .failure, .none:
            // Offline, timeout, 5xx, malformed — fail closed, apply nothing, keep the cover up.
            // `.none` is `self` gone before the fetch returned, which is the same do-nothing.
            break
        }
    }

    /// Decide and apply each fetched grant (DESIGN §2.6). Reads the applied set and the clock
    /// afresh for every grant, so a grant that went stale during a slow fetch is caught by the
    /// current time rather than the time the poll was launched.
    private func apply(_ grants: [RemoteGrant], onConsole: Bool, config: Config, token: String) async {
        let ttl = config.remoteGrantTTLInterval
        for grant in grants {
            let now = clock.now
            let applied = Set(engine.state.appliedRemoteGrants.keys)
            let decision = decideRemoteGrant(grant,
                                             applied: applied,
                                             now: now,
                                             ttl: ttl,
                                             dayResetHour: config.dayResetHour,
                                             calendar: calendar)
            guard case .apply(let minutes) = decision else { continue }

            // Records the id and writes `extended` with `source:"remote"`; the poller never
            // touches the `private(set)` ledger itself. `announce: onConsole` is what suppresses
            // the chime when the parent is switched in (§2.6).
            engine.applyRemoteGrant(id: grant.id, minutes: minutes, at: now, announce: onConsole)
            // Drop the cover now.
            onApplied()
            // Tell the server it is applied so it is not re-served. A failed consume is logged and
            // ignored — the persisted applied set skips a re-delivery as a duplicate, so
            // at-least-once delivery plus local dedupe is effectively once (§2.7).
            _ = await client.consumeGrant(id: grant.id, token: token)
        }
    }
}
