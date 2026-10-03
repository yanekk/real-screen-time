import AppKit
import RSTCore

/// **Four boxes, one digit each, and no button** — the PIN entry (T13).
///
/// Changed by the user on 2026-08-25, from a single `NSSecureTextField` that verified on
/// every keystroke. The shape it replaces was S.TFU's answer to "an already-correct PIN
/// should not need an Enter after it"; four boxes answer the same complaint more plainly —
/// the fourth digit *is* the confirmation, so there is nothing left to press.
///
/// It also settles a question the field could not. With one field, "a wrong attempt" had to
/// mean either every keystroke — which would have put a growing delay between a parent's own
/// four digits — or only a submitted one, which needed a rule nobody could see. Here there
/// is exactly one attempt per four digits, and ``PINGate`` counts them without ambiguity.
///
/// **Nothing on screen ever shows the PIN** (DESIGN §2.5, and the user's choice again on
/// 2026-08-25): a box holds a dot the instant it is filled. The person it is being kept from
/// is usually standing next to the person typing it.
@MainActor
final class PINBoxes: NSView {

    /// **Four, and this is now the PIN's length.** DESIGN §2.5 has said "four digits"
    /// throughout, and until now nothing enforced it — the hash reveals no length, so a
    /// hand-set six-digit PIN would have worked in the old field. It cannot be entered here,
    /// which makes this the rule T16's wizard has to hold the parent to.
    static let length = pinDigits

    /// The digits so far. Never longer than ``length``.
    private(set) var digits = ""

    /// Fired the instant the fourth digit lands. There is no other way to submit.
    var onComplete: ((String) -> Void)?

    /// False while a check is in flight or the rate limit is holding one back. Typing is
    /// ignored and the boxes dim, so a held-down key cannot queue guesses behind the wait.
    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    private let scale: CGFloat

    /// The identifier the real-click gate targets when the boxes hold the keyboard. Stable and
    /// custom-drawn: this is not an `NSTextField`, so it is the fallback T07 confirms an
    /// external `AXUIElement` reader can actually see by identifier on a plain `NSView`.
    static let accessibilityID = "pin-boxes"

    init(scale: CGFloat) {
        self.scale = scale
        super.init(frame: .zero)
        focusRingType = .none        // drawn below, on the box that is actually next
        setAccessibilityIdentifier(Self.accessibilityID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib — there is no Xcode here") }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    /// **Redrawn on focus in both directions.** The only thing telling the child which box
    /// he is in is the ring this view draws, so a view that keeps drawing it after losing
    /// the keyboard is a box that lies about being ready.
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    /// Digits fill boxes, delete empties the last one, everything else is ignored.
    ///
    /// Handled here rather than through `NSTextField`s and their delegates: four fields
    /// passing first responder between themselves is four times the focus juggling, and
    /// every rule below — digits only, no paste, no Enter, backspace steps back — would have
    /// had to be enforced against a control that wants to do something else.
    override func keyDown(with event: NSEvent) {
        // **Silently, with no beep.** A rejected key during the rate-limit wait is expected,
        // and the message underneath already says what is happening; a Mac barking once per
        // keystroke at a child on a covered screen is not a boundary, it is a telling off.
        guard isEnabled else { return }

        for character in event.charactersIgnoringModifiers ?? "" {
            switch character {
            case "\u{7F}", "\u{8}":                     // delete, backspace
                if !digits.isEmpty { digits.removeLast() }
            case "0"..."9":
                guard digits.count < Self.length else { continue }
                digits.append(character)
            default:
                // Letters, symbols, Enter, the arrows. A four-digit PIN has no use for any
                // of them, and a stray keypress must not eat one of the four slots.
                continue
            }
            needsDisplay = true

            if digits.count == Self.length {
                // Straight away, and before any further characters in this event: holding a
                // key down delivers repeats, and the fourth is the whole attempt.
                let entered = digits
                isEnabled = false
                onComplete?(entered)
                return
            }
        }
    }

    /// Empty the boxes — after a wrong PIN, or on the way out.
    func clear() {
        digits = ""
        needsDisplay = true
    }

    // MARK: - Drawing

    private var side: CGFloat { 54 * scale }
    private var gap: CGFloat { 12 * scale }

    override var intrinsicContentSize: NSSize {
        NSSize(width: side * CGFloat(Self.length) + gap * CGFloat(Self.length - 1),
               height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        for index in 0..<Self.length {
            let filled = index < digits.count
            // The next box to be typed into, and only while this view has the keyboard.
            let active = focused && isEnabled && index == digits.count

            let box = NSBezierPath(roundedRect: rect(at: index),
                                   xRadius: 10 * scale, yRadius: 10 * scale)
            NSColor.labelColor.withAlphaComponent(isEnabled ? 0.10 : 0.05).setFill()
            box.fill()

            let border: NSColor = active
                ? .controlAccentColor
                : .labelColor.withAlphaComponent(isEnabled ? 0.35 : 0.18)
            border.setStroke()
            box.lineWidth = active ? 3 * scale : 1.5 * scale
            box.stroke()

            if filled {
                let radius = 7 * scale
                let centre = rect(at: index).center
                let dot = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                                      width: radius * 2, height: radius * 2))
                NSColor.labelColor.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
                dot.fill()
            }
        }
    }

    private func rect(at index: Int) -> NSRect {
        // Centred in whatever width the stack gave us, so the row stays put when the type
        // around it changes size.
        let total = intrinsicContentSize.width
        let originX = bounds.midX - total / 2 + CGFloat(index) * (side + gap)
        return NSRect(x: originX, y: bounds.midY - side / 2, width: side, height: side)
            .insetBy(dx: 1.5 * scale, dy: 1.5 * scale)
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

/// **The way back in** — one prompt, two hosts (T13).
///
/// The same object is embedded in the cover's own window while the screen is covered, and
/// dropped into a floating panel when it is opened from the menu bar. It has to be one
/// object: everything interesting about a PIN prompt is in the *behaviour* — four boxes that
/// submit themselves, a check that never runs on the main thread, a wait after a wrong one —
/// and two copies of that is two places for it to drift.
///
/// **It knows nothing about the ledger.** It produces an ``Outcome``; `GrantCommand` turns
/// that into `Engine.extend` or `Engine.disable`. That is what lets the cover and the menu
/// bar share it without either of them owning the other's engine.
@MainActor
final class PINFlow: NSObject {

    /// What the prompt came to. `.cancelled` is a first-class answer — backing out of a PIN
    /// box is the ordinary case, not a failure.
    enum Outcome: Equatable {
        case cancelled
        case extend(minutes: Int)
        case disable
        /// **The PIN was right and that is the whole answer** — T17's `Ustawienia…`.
        ///
        /// Nothing for the engine to do: what happens next is a window the caller opens.
        /// Kept distinct from `.cancelled` because the two differ by exactly the thing this
        /// prompt exists to establish, and from `.disable` because a settings window that
        /// stood the app down would be a very expensive typo.
        case unlocked
    }

    /// What a host puts on the screen. Its contents are swapped in place when the PIN is
    /// accepted and the amount picker takes over, so the host never has to know there are
    /// two stages.
    let view = NSStackView()

    private let action: PINAction
    private let config: () -> Config
    private let clock: any Clock
    private let scale: CGFloat
    private let diagnostics: Diagnostics
    private let finish: (Outcome) -> Void

    /// The rate limit. One wrong four-digit entry, one wait — see ``PINGate``.
    private var gate = PINGate()
    /// Injected (T03): the shipping ``PINVerifier``, or a scripted double in a headed test.
    private let verifier: any PINVerifying

    private lazy var boxes = PINBoxes(scale: scale)
    private let hint = NSTextField(labelWithString: "")

    /// Ticks the `Spróbuj ponownie za…` line down and re-opens the boxes when it reaches
    /// zero. Injected (T03): the shipping ``TimerCountdown``, or a hand-driven double.
    private let countdown: any Countdown
    /// One outcome per flow. A second `finish` would grant twice.
    private var finished = false

    init(action: PINAction,
         config: @escaping () -> Config,
         clock: any Clock,
         scale: CGFloat = 1,
         diagnostics: Diagnostics = .discarded,
         // Defaulted to the shipping pieces, so every production call site is unchanged; a
         // headed test passes doubles for both to run without a hash and without a run loop.
         verifier: any PINVerifying = PINVerifier(),
         countdown: any Countdown = TimerCountdown(),
         finish: @escaping (Outcome) -> Void) {
        self.action = action
        self.config = config
        self.clock = clock
        self.scale = scale
        self.diagnostics = diagnostics
        self.verifier = verifier
        self.countdown = countdown
        self.finish = finish
        super.init()

        view.orientation = .vertical
        view.alignment = .centerX
        view.spacing = 16 * scale
        verifier.onResult = { [weak self] text, ok in self?.verified(text, ok: ok) }
        buildEntry()
    }

    /// What should hold the keyboard while this prompt is up.
    var keyboardTarget: NSView { boxes }

    /// Put the keyboard in the boxes. **From the cover the child never has to click** — and
    /// on a borderless window this only works at all because `CoverWindow` overrides
    /// `canBecomeKey` (DESIGN §2.6).
    func takeKeyboard() {
        view.window?.makeFirstResponder(boxes)
    }

    /// The host went away — the panel was closed, or the cover rebuilt underneath.
    func dismissed() { complete(.cancelled) }

    // MARK: - Stage one: the boxes

    private func buildEntry() {
        replaceContents(with: [
            label(Strings.pinTitle, size: 30, weight: .semibold, colour: .labelColor),
            label(Strings.pinFor(action), size: 17, weight: .regular,
                  colour: .secondaryLabelColor),
            boxes,
            hint,
            // **`Anuluj` and nothing else.** There is no OK — the fourth digit submits — but
            // the way out has to stay: without it, a child who pressed `Wprowadź PIN` by
            // mistake is left staring at a box he cannot fill and cannot leave.
            row([button(Strings.pinCancelButton, #selector(cancelPressed))]),
        ])

        boxes.onComplete = { [weak self] entered in self?.attempt(entered) }

        hint.font = .systemFont(ofSize: 15 * scale, weight: .regular)
        // Amber rather than red. A wrong PIN is a mistake, not an alarm, and this box is
        // read by a child as often as by a parent.
        hint.textColor = NSColor(calibratedRed: 0.95, green: 0.6, blue: 0.35, alpha: 1)
        hint.alignment = .center
        hint.stringValue = " "
    }

    @objc private func cancelPressed() { complete(.cancelled) }

    /// Four digits have landed. ``PINBoxes`` has already stopped taking input.
    private func attempt(_ entered: String) {
        let now = clock.now
        // Belt and braces: the boxes go inert the moment the gate closes, so this should be
        // unreachable. It is one line, and the thing on the other side of it is a covered
        // screen being guessed at.
        guard gate.isOpen(at: now) else { return holdBack(at: now) }

        let settings = config()
        guard let salt = settings.pinSaltData, !settings.pinHash.isEmpty else {
            // §2.5's derived rule the other way round: with no usable PIN nothing can be
            // unlocked — and nothing is covering the screen either, so there is nobody
            // trapped behind it. Said out loud rather than rejected silently for ever.
            diagnostics("pin: no PIN configured — the prompt cannot accept anything", at: now)
            return reject(at: now)
        }
        verifier.offer(text: entered, hash: settings.pinHash, salt: salt)
    }

    /// The verifier's answer, back on the main thread.
    private func verified(_ text: String, ok: Bool) {
        let now = clock.now
        guard ok else { return reject(at: now) }

        gate.succeeded()
        stopCountdown()
        boxes.clear()
        diagnostics("pin: accepted for \(action.rawValue)", at: now)

        switch action {
        case .extend: buildAmounts()
        case .disable: complete(.disable)
        case .settings: complete(.unlocked)
        }
    }

    private func reject(at now: Date) {
        gate.failed(at: now)
        diagnostics("pin: rejected, \(gate.failures) in a row, "
                    + "next attempt in \(Int(gate.wait(at: now).rounded())) s", at: now)
        holdBack(at: now)
    }

    /// Shut the boxes for however long the gate says, and put the reason on the screen.
    ///
    /// **Emptied first, always.** A held-back entry that kept its four digits would come
    /// back from the wait already full: the next keystroke would be ignored, no fourth digit
    /// would ever land, and the prompt would sit there looking dead.
    private func holdBack(at now: Date) {
        boxes.clear()
        let wait = gate.wait(at: now)
        guard wait > 0 else { return reopen() }
        boxes.isEnabled = false
        hint.stringValue = Strings.pinWait(seconds: max(1, Int(wait.rounded(.up))))
        startCountdown()
    }

    /// Ready for another four digits. The hint stays until it is typed over, so the child
    /// can still read why the last one failed.
    private func reopen() {
        stopCountdown()
        boxes.isEnabled = true
        hint.stringValue = Strings.pinWrong
        takeKeyboard()
    }

    // MARK: - The rate limit, on the screen

    /// **A box that has stopped answering says why.** The alternative is a PIN prompt that
    /// looks broken for five seconds, which is the same thing as being broken.
    private func startCountdown() {
        // **The tick closure holds the flow strongly, on purpose.** The countdown owns the
        // timer, so a `weak self` here would leave it firing for the life of the process if a
        // host dropped the prompt mid-wait. This countdown stops itself the moment the gate
        // opens — five seconds at the very most — so the cycle is bounded by the thing it is
        // counting rather than by anyone remembering to break it, and `complete` breaks it in
        // every other case.
        countdown.start { self.countdownTicked() }
    }

    private func countdownTicked() {
        let wait = gate.wait(at: clock.now)
        guard wait == 0 else {
            hint.stringValue = Strings.pinWait(seconds: max(1, Int(wait.rounded(.up))))
            return
        }
        reopen()
    }

    private func stopCountdown() {
        countdown.stop()
    }

    // MARK: - Stage two: the amount

    /// `Dodaj minuty` — one button per entry of `config.extensionChoices`, in the parent's
    /// own order (DESIGN §2.5). ``GrantModel`` owns the list and its fallback.
    ///
    /// **One press grants** (cover-buttons-logout DESIGN §2.1), replacing radios plus a
    /// `Dodaj` confirm. No confirmation: the parent has just typed the PIN, so the mis-tap a
    /// confirm would guard against has already been guarded against.
    private func buildAmounts() {
        let model = GrantModel(config: config())
        var amounts: [NSButton] = []
        for (index, amount) in model.amounts.enumerated() {
            let amountButton = button(Strings.grantAmountButton(amount),
                                      #selector(amountPressed(_:)),
                                      // Enter grants the first amount, as it granted the
                                      // pre-selected radio before. `make ui-gate`'s
                                      // `right-pin` scenario presses Return and relies on it.
                                      primary: index == model.preselected)
            amountButton.tag = amount
            amountButton.setAccessibilityIdentifier("amount-\(amount)")
            amounts.append(amountButton)
        }

        // Stacked vertically once there are more than three, so a long list does not run off
        // the side of a 600×400 boxed cover.
        let grid = NSStackView(views: amounts)
        grid.orientation = amounts.count > 3 ? .vertical : .horizontal
        grid.alignment = amounts.count > 3 ? .centerX : .centerY
        grid.spacing = 14 * scale

        replaceContents(with: [
            label(Strings.grantTitle, size: 30, weight: .semibold, colour: .labelColor),
            grid,
            row([button(Strings.pinCancelButton, #selector(cancelPressed))]),
        ])
    }

    /// The amount is the button's tag. ``complete(_:)`` latches, so a double click grants once.
    @objc private func amountPressed(_ sender: NSButton) {
        complete(.extend(minutes: sender.tag))
    }

    // MARK: - Finishing

    private func complete(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        stopCountdown()
        finish(outcome)
    }

    // MARK: - Pieces

    private func replaceContents(with views: [NSView]) {
        view.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(view.addArrangedSubview)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       colour: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size * scale, weight: weight)
        label.textColor = colour
        label.alignment = .center
        return label
    }

    private func row(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 16 * scale
        return row
    }

    private func button(_ title: String, _ selector: Selector,
                        primary: Bool = false) -> NSButton {
        // The cover's style, here too: the parent chose the menu-bar panel to follow the
        // cover (T05, 2026-10-03), so there is one look and one code path for this step.
        let button = CoverButton(title: title, role: primary ? .primary : .neutral,
                                 fontSize: 16 * scale, target: self, action: selector)
        if primary { button.keyEquivalent = "\r" }
        return button
    }
}

// MARK: - Off the main thread

/// **What checks a PIN for ``PINFlow``** — the injection point T00 settled for T03.
///
/// The shipping implementation is ``PINVerifier``, which runs 200 000 rounds of HMAC on a
/// background queue and answers a run-loop hop later. A headed test cannot afford either: the
/// hash is half a second each, and no run loop drains the hop in the test process (FINDINGS
/// 2026-09-16). A test conforms a double that answers a scripted `ok` synchronously, so the
/// wrong-PIN and each accepted-PIN path can be driven without a hash and without a pump. The
/// flow only ever calls `offer` and reads `onResult`, so the double sees the real wiring.
@MainActor
protocol PINVerifying: AnyObject {
    /// `(text, ok)`, on the main thread. Set by the flow in its init.
    var onResult: ((String, Bool) -> Void)? { get set }
    /// Check `text` against `hash`/`salt` and deliver the answer through ``onResult``.
    func offer(text: String, hash: String, salt: Data)
}

/// **Runs `verifyPIN` off the main thread.**
///
/// A derivation is 200 000 rounds of HMAC — measured at about half a second optimised and a
/// second in a debug build (`PIN.swift`). On the main thread that would freeze the cover for
/// that long every time the fourth digit landed, on the one screen the child cannot get away
/// from.
///
/// Serial, and the latest candidate wins. ``PINBoxes`` stops taking input the moment it has
/// four digits, so in practice there is never a second one waiting — this is what makes that
/// true rather than something the caller has to remember, and it is why a stuck derivation
/// cannot pile up behind itself.
@MainActor
final class PINVerifier: PINVerifying {

    /// `(text, ok)`, on the main thread.
    var onResult: ((String, Bool) -> Void)?

    private struct Job: Sendable {
        let text: String
        let hash: String
        let salt: Data
    }

    /// Serial and `.userInitiated`: a person is waiting for it, and nothing about it is
    /// parallelisable.
    private let queue = DispatchQueue(label: "com.realscreentime.pin", qos: .userInitiated)
    private var running = false
    private var next: Job?

    func offer(text: String, hash: String, salt: Data) {
        next = Job(text: text, hash: hash, salt: salt)
        startIfIdle()
    }

    private func startIfIdle() {
        guard !running, let job = next else { return }
        next = nil
        running = true
        queue.async { [weak self] in
            let ok = verifyPIN(job.text, hash: job.hash, salt: job.salt)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.running = false
                    self.onResult?(job.text, ok)
                    self.startIfIdle()
                }
            }
        }
    }
}

// MARK: - The rate-limit countdown

/// **Ticks ``PINFlow``'s "try again in…" line down** — the second injection point T00 settled
/// for T03.
///
/// The shipping implementation is ``TimerCountdown``, a repeating `Timer` on the main run
/// loop. That timer never fires in the test process — no run loop services it (FINDINGS
/// 2026-09-16) — so the wrong-PIN wait would hold the boxes shut for ever under test. A
/// headed test injects a double that stores the flow's `tick` and calls it by hand after
/// advancing the injected `clock` past the gate's wait, so the same re-enable path runs
/// without a run loop. The flow calls only `start`/`stop`, so the double drives the real code.
@MainActor
protocol Countdown {
    /// Begin calling `tick` repeatedly. A second `start` while already running does nothing —
    /// the flow re-arms by `stop` then `start`, never by starting twice.
    func start(_ tick: @escaping () -> Void)
    /// Stop; no `tick` fires after this returns. Called on every finish and re-open.
    func stop()
}

/// The shipping countdown: a quarter-second repeating `Timer`, in `.common` mode so an open
/// menu does not park it (the menu-bar path opens the prompt from inside a menu tracking
/// loop). It holds `tick` — and therefore the flow — strongly, on purpose: see
/// ``PINFlow/startCountdown()``.
@MainActor
final class TimerCountdown: Countdown {
    private var timer: Timer?
    // Held here rather than captured into the timer's closure: the closure is `@Sendable`,
    // so it reaches the tick through `self` (a main-actor object) exactly as the flow's old
    // inline timer reached `countdownTicked` through its own `self`.
    private var tick: (() -> Void)?

    func start(_ tick: @escaping () -> Void) {
        guard timer == nil else { return }
        self.tick = tick
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tick = nil
    }
}

// MARK: - What an outcome does

/// **Turns a ``PINFlow/Outcome`` into an `Engine` command**, in one place for both hosts.
///
/// Everything the two grants do is `Engine`'s — the event is written before the ledger
/// moves, and `extend` is what lifts a stand-down (DESIGN §2.5). What is left here is the
/// dispatch and the line in `app.log`.
@MainActor
struct GrantCommand {
    let engine: Engine
    let clock: any Clock
    let diagnostics: Diagnostics
    /// Run a tick straight away, so the cover comes down now rather than within the second.
    let refresh: () -> Void

    func apply(_ outcome: PINFlow.Outcome) {
        let now = clock.now
        switch outcome {
        case .cancelled:
            diagnostics("pin: cancelled", at: now)
            return
        case .extend(let minutes):
            diagnostics("pin: granted \(minutes) min", at: now)
            // The chime and the spoken `Dodano 15 minut` §2.5 asks for are `Engine`'s to
            // fire, not this call site's (T14) — it is the one place that knows the grant
            // was real, that another user does not have the console, and that the event has
            // already been written.
            engine.extend(minutes: minutes, at: now)
        case .disable:
            let until = engine.disable(at: now)
            diagnostics("pin: stood down until \(until)", at: now)
        case .unlocked:
            // T17's `Ustawienia…`. Not a grant and not this type's business — the window is
            // opened by whoever asked for the prompt. Said out loud rather than fallen
            // through, so a future outcome added to the enum cannot land here silently.
            diagnostics("pin: accepted, nothing to grant", at: now)
            return
        }
        refresh()
    }
}

// MARK: - The menu-bar host

/// **The prompt when there is no cover to put it in** — `Dodaj minuty…` and
/// `Wyłącz do jutra` from the menu bar (T13).
///
/// A panel of its own rather than the sheet the task doc names: an `NSStatusItem` has no
/// window, and `beginSheet` needs one to hang from. This is the nearest honest thing —
/// floating, centred, closable, and it takes the keyboard.
///
/// It is never on screen at the same time as the cover. The menu bar is hidden while the
/// cover is up (T12's presentation options), so the only way to this path is free time —
/// which is also why it can be a window of its own at all: over a cover it would lose first
/// responder to the next tick's `NSApp.activate()` within the second.
@MainActor
final class PINPanel: NSObject, NSWindowDelegate {

    /// The one on screen, if any. Static because the menu can be opened again while a
    /// prompt is already up, and two PIN boxes competing for the keyboard is worse than
    /// either of them. It is also what keeps this object alive: nothing else holds it.
    private static var showing: PINPanel?

    private let panel: NSPanel
    /// Assigned straight after `super.init()`, because its callback needs `self`.
    private var flow: PINFlow!
    private let finish: (PINFlow.Outcome) -> Void
    private var finished = false

    /// Put the prompt on the screen. A second call while one is up brings the first forward
    /// rather than opening another.
    static func present(action: PINAction,
                        config: @escaping () -> Config,
                        clock: any Clock,
                        diagnostics: Diagnostics,
                        finish: @escaping (PINFlow.Outcome) -> Void) {
        if let showing {
            showing.panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        showing = PINPanel(action: action, config: config, clock: clock,
                           diagnostics: diagnostics, finish: finish)
    }

    private init(action: PINAction,
                 config: @escaping () -> Config,
                 clock: any Clock,
                 diagnostics: Diagnostics,
                 finish: @escaping (PINFlow.Outcome) -> Void) {
        self.finish = finish
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()

        flow = PINFlow(action: action, config: config, clock: clock,
                       diagnostics: diagnostics) { [weak self] outcome in
            // One hop, as on the cover: the panel closes inside a button's own action, and
            // a grant can take a cover down underneath it.
            DispatchQueue.main.async { self?.close(with: outcome) }
        }

        panel.title = Strings.pinFor(action)
        panel.isFloatingPanel = true
        panel.level = .floating
        // Stays put when the parent clicks away to look something up. It is a question
        // waiting for an answer, not a HUD.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // The same dark box wherever the prompt appears, and the reason the flow can use
        // `.labelColor`: every control inside it is drawn for a dark background, here and
        // on the cover alike.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        panel.contentView = Self.host(flow.view)

        panel.center()
        // The app runs `.accessory` — no Dock icon — so it is not frontmost when a menu item
        // is chosen, and a panel that is not frontmost takes no keystrokes.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        flow.takeKeyboard()
    }

    /// The panel's content size. A constant rather than a literal in `init` so the headed
    /// drill (cover-buttons-logout T04) lays the flow out at exactly this size.
    static let contentSize = NSSize(width: 400, height: 300)

    /// The panel's content view around a flow: centred, 24 pt clear of either side. Split out
    /// of `init` so a headed test can lay the flow out as the panel does without opening the
    /// panel, which would order a window on screen.
    static func host(_ flowView: NSView) -> NSView {
        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))
        flowView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(flowView)
        NSLayoutConstraint.activate([
            flowView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            flowView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            flowView.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor,
                                              constant: 24),
            flowView.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                               constant: -24),
            // **Required, so the panel grows rather than clips.** The amount step is a column
            // above three amounts, and the parent's list has no upper bound: six at scale 1
            // ran 16 pt off both edges of 300 pt (T04 drill). These make the window taller
            // when the content needs it and leave it at `contentSize` when it does not.
            flowView.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 20),
            flowView.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor,
                                             constant: -20),
        ])
        return content
    }

    /// The red button, `Cmd+W`, or anything else AppKit calls closing. Same as `Anuluj`.
    func windowWillClose(_ notification: Notification) {
        close(with: .cancelled)
    }

    private func close(with outcome: PINFlow.Outcome) {
        guard !finished else { return }
        finished = true
        // Before the callback: a grant runs a tick, and a tick can put the cover up.
        panel.delegate = nil
        panel.orderOut(nil)
        Self.showing = nil
        finish(outcome)
    }
}
