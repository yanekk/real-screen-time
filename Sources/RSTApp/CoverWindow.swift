import AppKit
import RSTCore

/// **The window ordinary means cannot dismiss.**
///
/// The overrides are the whole class, and the first one is the single most important line
/// in T11: a borderless `NSWindow` returns `false` from `canBecomeKey`, which means the PIN
/// field inside it silently refuses every keystroke — a cover nobody can unlock. Verified
/// working in the T00 spike on 2026-08-21; this is that spike's shape, reused rather than
/// rediscovered.
@MainActor
final class CoverWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Escape does nothing. Without this, `NSWindow` would route it to a cancel button —
    /// and there is no Cancel on this window by design (T11: no close button, no Escape,
    /// no Cancel).
    override func cancelOperation(_ sender: Any?) {}
}

/// What the cover draws: a headline, an optional second line, and one row of buttons.
///
/// Everything it shows comes from ``CoverModel`` in `RSTCore` — this file decides only how
/// large the type is, not which face is on the screen. Every string is from
/// ``Strings``; an English literal here is the exact mistake the bilingual split invites
/// (DESIGN §2.4.2).
///
/// Calm rather than punitive, deliberately: this screen is going to be looked at by a
/// disappointed child fairly often, and it should read as a boundary rather than a telling
/// off.
@MainActor
final class CoverContentView: NSView {

    /// Pressed. The controller turns it into an `Engine` command.
    private let onPress: (CoverModel.Button) -> Void

    /// Builds the PIN prompt for this view, at this view's type scale, and tells it what to
    /// do with the answer. **`RSTApp`'s, not the view's**: what a grant does belongs to the
    /// engine, and the closure is how `CoverEnforcer` keeps it there (T13).
    ///
    /// The `() -> Void` handed back to it is "the prompt is finished" — the view's cue to
    /// put the face back, whatever the answer was.
    private let makePINFlow: (CGFloat, @escaping () -> Void) -> PINFlow?

    private let stack = NSStackView()
    private var rendered: CoverModel?

    /// The PIN prompt, while one is up. The tick redraws nothing underneath it, because
    /// ``render(_:)`` returns early on an unchanged model — which is what lets a child take
    /// as long as he likes over four digits (T13).
    private var flow: PINFlow?

    /// The button that takes the keyboard when the cover appears — the primary action of
    /// whichever face is showing. While the PIN prompt is up the field takes it instead, and
    /// the child never has to click into it.
    private(set) weak var initialResponder: NSView?

    init(onPress: @escaping (CoverModel.Button) -> Void,
         makePINFlow: @escaping (CGFloat, @escaping () -> Void) -> PINFlow?) {
        self.onPress = onPress
        self.makePINFlow = makePINFlow
        super.init(frame: .zero)
        wantsLayer = true
        // Not pure black: an unlit rectangle reads as a broken machine, and this has to
        // read as a decision the app made.
        layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11,
                                         alpha: 1).cgColor

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib — there is no Xcode here") }

    /// Draw this face, or leave the view exactly as it is if it is already showing it.
    ///
    /// The guard is not an optimisation. Rebuilding the stack replaces the buttons, and
    /// replacing the button the child is about to press — sixty times a minute, since the
    /// tick calls this every second — would make the cover unusable.
    func render(_ model: CoverModel) {
        guard model != rendered else { return }
        rendered = model

        // A face that has genuinely changed underneath the prompt takes the screen back:
        // the day rolled over, or a grant landed from the menu bar. Rare, and the honest
        // answer — what the prompt was standing in front of is no longer what is there.
        flow?.dismissed()
        flow = nil

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        initialResponder = nil

        switch model.face {
        case .start(let minutes, let index, let limit):
            stack.addArrangedSubview(headline(Strings.coverStart(minutes: minutes)))
            stack.addArrangedSubview(subline(Strings.coverSessionCount(index: index, of: limit)))
        case .resume(let minutesLeft):
            stack.addArrangedSubview(headline(Strings.coverResume(minutes: minutesLeft)))
        case .expired:
            stack.addArrangedSubview(headline(Strings.coverExpired))
        case .exhausted:
            stack.addArrangedSubview(headline(Strings.coverExhausted))
        }

        let row = NSStackView(views: model.buttons.map(button))
        row.orientation = .horizontal
        row.spacing = 16
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(40, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    // MARK: - Pieces

    /// Type scaled to the window, so the same code reads correctly fullscreen and inside
    /// `RST_COVER_FRAME=600x400+80+80` — which is where the whole of this task is built.
    private var scale: CGFloat { max(0.45, min(1, bounds.height / 900)) }

    private func headline(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 46 * scale, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2
        return label
    }

    private func subline(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22 * scale, weight: .regular)
        label.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        label.alignment = .center
        return label
    }

    private func button(_ kind: CoverModel.Button) -> NSButton {
        let button = NSButton(title: title(for: kind), target: self, action: #selector(pressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        // The `NSUserInterfaceItemIdentifier` above is read by `pressed(_:)` to resolve the
        // kind, but AppKit does not surface it to the Accessibility system — an external
        // driver cannot see it (T00 finding). This is the same name again, set the one way a
        // cross-process `AXUIElement` reader can find (T06); T07 is the gate that uses it.
        button.setAccessibilityIdentifier(kind.rawValue)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 18 * scale, weight: .medium)

        // The padlock stays now that the field exists (T13): it is honest, and it is how
        // the child can see which door needs a parent before pressing it.
        // The primary action answers Enter as well as the mouse, and takes the keyboard
        // when the cover appears. `Rozpocznij` and `Wznów` are the only two that qualify —
        // an Enter that locked the screen would be a nasty surprise.
        if kind == .start || kind == .resume {
            button.keyEquivalent = "\r"
            initialResponder = button
        }
        return button
    }

    private func title(for kind: CoverModel.Button) -> String {
        switch kind {
        case .start: return Strings.coverStartButton
        case .resume: return Strings.coverResumeButton
        case .pin: return Strings.gated(Strings.coverPINButton)
        case .lock:
            // The label follows the mechanism that was actually resolved at startup, so
            // there is never a button that lies about what it will do.
            return ScreenLock.mechanism == .lockImmediately
                ? Strings.coverLockButton : Strings.coverLogOutButton
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let kind = CoverModel.Button(rawValue: raw) else { return }
        // **The PIN prompt is handled here rather than forwarded.** It is a view inside this
        // window, not a command — DESIGN §2.6's cover is borderless and only holds the
        // keyboard because it is the key window, so a panel floating over it would lose
        // first responder to the next tick's `NSApp.activate()` (T12) within the second.
        // One hop, exactly as `CoverEnforcer.press(_:)` takes one: opening the prompt
        // replaces every view in the stack, including the button whose action is still on
        // the stack — the sender must outlive its own click.
        guard kind != .pin else {
            return DispatchQueue.main.async { [weak self] in self?.showPIN() }
        }
        onPress(kind)
    }

    // MARK: - The PIN prompt (T13)

    /// Swap the face for the prompt. The cover stays exactly where it is: this is the way
    /// back *in*, and nothing about it lifts anything.
    private func showPIN() {
        guard flow == nil,
              let flow = makePINFlow(scale, { [weak self] in self?.restoreFace() })
        else { return }
        self.flow = flow

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(flow.view)
        initialResponder = flow.keyboardTarget
        // The field, not a button — from the cover the child never has to click into it.
        flow.takeKeyboard()
    }

    /// Put the face back after the prompt closes, whatever the answer was.
    ///
    /// Via `rendered = nil` rather than a second draw path: ``render(_:)`` is the one place
    /// that knows how a face is built, and a prompt that returned to a hand-assembled copy
    /// of it would drift from the real one the first time a face changed.
    private func restoreFace() {
        flow = nil
        guard let model = rendered else { return }
        rendered = nil
        render(model)
        if let initialResponder { window?.makeFirstResponder(initialResponder) }
    }
}
