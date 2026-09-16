import AppKit
import RSTCore

/// **The enforcer that really does take the screen** — the other half of T08's
/// `ObserverEnforcer`, and the reason `RST_ENFORCE=1` now means something.
///
/// It takes the same `Decision` stream the observer takes and turns it into windows: which
/// face the cover wears is ``CoverModel``'s (in `RSTCore`, where `make test` can reach it),
/// putting it on the screen is ``CoverController``'s, and closing fullscreen apps first is
/// ``FullscreenEvictor``'s. What is left here is the wiring and the three commands the
/// cover's buttons issue.
///
/// **Only ever constructed in an enforcing run.** That is the whole of the gate DESIGN
/// §2.6.2 asks for on quitting apps: a debug build makes an `ObserverEnforcer` instead, and
/// nothing in this file is reachable.
@MainActor
final class CoverEnforcer: Enforcing {

    private let clock: any Clock
    private let diagnostics: Diagnostics
    private let evictor: FullscreenEvictor

    /// Set once, immediately after the engine is built — `Engine.init` takes the enforcer,
    /// so the two cannot both be constructed knowing each other.
    ///
    /// `weak` on principle rather than necessity: both live for the whole process, and a
    /// strong reference here would be a cycle nobody would ever notice.
    weak var engine: Engine?

    /// Run a tick immediately, so a pressed button is acted on now rather than up to a
    /// second later. Set at wiring time by `main.swift`.
    var refresh: (() -> Void)?

    /// Built lazily so its `onPress` closure can capture `self` — a stored property could
    /// not, since `self` is not available until every property is initialised.
    private lazy var controller = CoverController(
        frame: frame, clock: clock, seatbelt: seatbelt, watchdog: watchdog, kiosk: kiosk,
        diagnostics: diagnostics,
        onPress: { [weak self] button in self?.press(button) },
        makePINFlow: { [weak self] scale, closed in
            self?.makePINFlow(scale: scale, closed: closed)
        })

    private let frame: CoverFrame?
    private let seatbelt: Seatbelt?
    private let watchdog: Watchdog
    private let kiosk: KioskLock
    /// The chime, the voice and the banner (T14). Built here and nowhere else, which is the
    /// whole of the gate the user asked for on 2026-08-25: an observer run makes an
    /// `ObserverEnforcer` instead, and nothing in this file — the cover, the app quitting,
    /// or a word of Polish out of the speakers — is reachable from it.
    private let warner: Warner

    init(frame: CoverFrame?,
         clock: any Clock,
         seatbelt: Seatbelt?,
         watchdog: Watchdog,
         kiosk: KioskLock,
         sink: any EventSink,
         diagnostics: Diagnostics = .discarded) {
        self.frame = frame
        self.clock = clock
        self.seatbelt = seatbelt
        self.watchdog = watchdog
        self.kiosk = kiosk
        self.diagnostics = diagnostics
        self.evictor = FullscreenEvictor(sink: sink, diagnostics: diagnostics)
        let warner = Warner(diagnostics: diagnostics, at: clock.now)
        self.warner = warner
        self.announcerVoice = warner.voiceLabel
    }

    // MARK: - Enforcing

    /// `nonisolated`, and then straight back onto the main actor.
    ///
    /// ``Enforcing`` is deliberately synchronous — `Engine` calls it inline, before
    /// dispatching, so the event is written at the time of the decision — and a
    /// main-actor-isolated method cannot satisfy a `nonisolated` requirement. `Engine` is
    /// driven from the app's main run loop and from nowhere else, so the assumption this
    /// makes is one the program already guarantees; `assumeIsolated` turns it into a
    /// checked one.
    nonisolated func apply(_ decision: Decision, at now: Date) {
        MainActor.assumeIsolated { self.applyOnMain(decision, at: now) }
    }

    private func applyOnMain(_ decision: Decision, at now: Date) {
        guard let engine else {
            // Unwired. Nothing can cover, and saying so is the only way that is ever
            // noticed — a silent no-op here looks exactly like a working observer run.
            diagnostics("cover: no engine attached — nothing will be covered", at: now)
            return
        }

        guard let model = CoverModel(decision: decision,
                                     sessionsUsedToday: engine.state.sessionsUsedToday,
                                     config: engine.config) else {
            controller.hide()
            evictor.reset()
            return
        }

        // **Before covering, and on every tick while covered** (DESIGN §2.6.2). Once is not
        // enough: some game launchers relaunch themselves, and a fullscreen app appearing
        // after the cover is up would carve a hole in it.
        evictor.evict(at: now)
        controller.show(model)

        #if DEBUG
        stallIfAsked()
        #endif
    }

    #if DEBUG
    /// **Break the app on purpose, so the watchdog can be watched fixing it** —
    /// `RST_STALL_SECONDS`, T15's manual test.
    ///
    /// The task doc asked for a debug-only *menu item* that parks the main thread while
    /// covered. There is no menu to click by then: the kiosk hides the menu bar as the cover
    /// goes up (T12), and a hang with no cover is not the case worth testing. A flag reaches
    /// the state a menu item cannot, and leaves nothing behind to remember to delete —
    /// `#if DEBUG` here, and `main.swift` says so out loud if a release build is handed one.
    ///
    /// **Two seconds late, deliberately.** `show(_:)` orders the windows in; the run loop is
    /// what paints them. Parking the thread in the same breath would wedge the app before
    /// anything was drawn, and the test is whether a cover the user can *see* goes away.
    private func stallIfAsked() {
        guard let seconds = stallSeconds, !stalling else { return }
        stalling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [diagnostics, clock] in
            diagnostics("stall: parking the main thread for \(Int(seconds)) s — "
                        + "the watchdog should end the process before it wakes up", at: clock.now)
            Thread.sleep(forTimeInterval: seconds)
            // Only reached if the watchdog did not fire, which is the failure this run is
            // looking for. Said out loud, because a run that simply carries on looks like a
            // run where nothing was ever asked.
            diagnostics("stall: the main thread woke up — the watchdog did NOT end the process",
                        at: clock.now)
        }
    }

    /// `RST_STALL_SECONDS`, set by `main.swift` at wiring time. Debug builds only.
    var stallSeconds: TimeInterval?
    /// One park per run. The stall happens inside a tick, and every tick after it would ask
    /// for another.
    private var stalling = false
    #endif

    // MARK: - The PIN prompt (T13)

    /// Build the prompt the cover embeds, and say what its answer does.
    ///
    /// **`.extend` and nothing else.** DESIGN §2.6's third row is `PIN` ▸ `Dodaj minuty…`
    /// plus `Zablokuj ekran`; standing the app down is a menu-bar item, and the menu bar is
    /// hidden while the cover is up anyway.
    ///
    /// `config` is read through the engine on every attempt rather than captured once, so a
    /// PIN changed in Settings (T17) is the PIN this prompt checks against.
    private func makePINFlow(scale: CGFloat,
                             closed: @escaping () -> Void) -> PINFlow? {
        guard engine != nil else { return nil }
        return PINFlow(action: .extend,
                config: { [weak self] in self?.engine?.config ?? Config() },
                clock: clock,
                scale: scale,
                diagnostics: diagnostics) { [weak self] outcome in
            // **One hop, for the same reason `press(_:)` takes one.** A grant takes the
            // cover down, and taking the window down releases the view whose button action
            // is still on the stack — including the one that closed the prompt.
            DispatchQueue.main.async {
                closed()
                guard let self, let engine = self.engine else { return }
                GrantCommand(engine: engine, clock: self.clock,
                             diagnostics: self.diagnostics,
                             refresh: { self.refresh?() }).apply(outcome)
            }
        }
    }

    /// Chime, spoken line, banner (T14). `Engine` has already decided that this one is due
    /// and written the event; ``Warner`` only makes the noise.
    ///
    /// `nonisolated` and straight back onto the main actor, for the same reason
    /// ``apply(_:at:)`` is.
    nonisolated func announce(_ announcement: Announcement, at now: Date) {
        MainActor.assumeIsolated { self.warner.announce(announcement, at: now) }
    }

    /// The voice `Engine` puts on the `warned` event. A stored `let` rather than a reach
    /// into ``Warner``, because a `@MainActor` property cannot answer a `nonisolated`
    /// protocol requirement — and it is resolved once at launch and never changes.
    nonisolated let announcerVoice: String?

    // MARK: - The cover's buttons

    /// Every command the cover can issue. All of them go through `Engine`, which writes the
    /// event and moves the ledger; none of them touches `SessionState` directly.
    private func press(_ button: CoverModel.Button) {
        // **Never act inside the button's own action.** `Rozpocznij` takes the cover down,
        // and taking a window down releases the content view whose method is still on the
        // stack. One hop through the main queue puts the command after the click has
        // finished, and costs nothing a person can perceive.
        DispatchQueue.main.async { [weak self] in self?.perform(button) }
    }

    private func perform(_ button: CoverModel.Button) {
        guard let engine else { return }
        let now = clock.now

        switch button {
        case .start:
            // **No PIN**, and no second gate here either: whether this button was drawn at
            // all is `Decision.offersSelfServiceStart`'s answer, made in `RSTCore` where it
            // is tested. A gate here as well would be a second place for the rule to live
            // and disagree.
            diagnostics("cover: Rozpocznij", at: now)
            engine.startSelfService(at: now)
        case .resume:
            diagnostics("cover: Wznów", at: now)
            engine.resume(at: now)
        case .pin:
            // Unreachable: `CoverContentView` opens the prompt itself and does not forward
            // this, because the prompt has to live inside the cover's own window (T13).
            // Cheaper to say than to assume.
            diagnostics("cover: PIN pressed but not handled in the view", at: now)
            return
        case .lock:
            // The event first, then the action: the cover stays up either way, because the
            // session is still over. Locking is a polite exit, not an escape (§2.6).
            engine.lockScreen(at: now)
            ScreenLock.engage(diagnostics, at: now)
            return
        }

        // Start and resume change the decision, so the cover should come down now rather
        // than within the second. The tick is the only thing allowed to make that call.
        refresh?()
    }
}
