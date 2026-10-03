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

    /// The `Wylogować?` confirmation's latch, set by its first `Wyloguj` press and cleared
    /// when a fresh confirmation is drawn. Two quick clicks land before the face comes back
    /// (that is a hop away), and without this the second would run bootout twice (§2.7).
    private var logoutConfirmed = false
    /// Whether the confirmation is what the stack holds. ``render(_:)`` must not let an
    /// unchanged model leave it standing over a face it no longer belongs to — and must
    /// replace it when the face really changes, as it replaces the PIN prompt.
    private var confirmingLogout = false

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
        confirmingLogout = false

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
        settle()
    }

    /// **Lay the new contents out now, not at the next display pass.** Between the swap and
    /// that pass an Accessibility reader can find the new buttons and read their frames before
    /// the stack has placed them; `make ui-gate` did exactly that on `Wylogować?` and clicked
    /// empty cover where `Wyloguj` was about to be (T05, 2026-10-03). A person cannot click
    /// that fast, but a frame reported is a frame that should be true.
    private func settle() {
        layoutSubtreeIfNeeded()
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
        let button = CoverButton(title: title(for: kind), role: role(for: kind),
                                 fontSize: 18 * scale, target: self,
                                 action: #selector(pressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        // The `NSUserInterfaceItemIdentifier` above is read by `pressed(_:)` to resolve the
        // kind, but AppKit does not surface it to the Accessibility system — an external
        // driver cannot see it (T00 finding). This is the same name again, set the one way a
        // cross-process `AXUIElement` reader can find (T06); T07 is the gate that uses it.
        button.setAccessibilityIdentifier(kind.rawValue)

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

    /// The colour the parent picked by (T05): blue forward, grey neutral, orange-red out.
    private func role(for kind: CoverModel.Button) -> CoverButton.Role {
        switch kind {
        case .start, .resume, .pin: return .primary
        case .lock: return .neutral
        case .logout: return .warning
        }
    }

    private func title(for kind: CoverModel.Button) -> String {
        switch kind {
        case .start: return Strings.coverStartButton
        case .resume: return Strings.coverResumeButton
        case .pin: return Strings.gated(Strings.coverPINButton)
        case .lock:
            // Always the lock now: when nothing can lock, `CoverModel` does not offer the
            // button at all (`canLock: false`, cover-buttons-logout §2.4).
            return Strings.coverLockButton
        case .logout: return Strings.coverLogOutButton
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
        // **Not forwarded either**: `Wyloguj` asks first, in this window, for the same reason
        // the PIN prompt lives here (cover-buttons-logout §2.2). Same one hop, for the same
        // sender-must-outlive-its-click reason.
        guard kind != .logout else {
            return DispatchQueue.main.async { [weak self] in self?.showLogoutConfirm() }
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
        settle()
        // The field, not a button — from the cover the child never has to click into it.
        flow.takeKeyboard()
    }

    // MARK: - The log-out confirmation (cover-buttons-logout §2.2)

    /// Swap the face for `Wylogować?`. Drawn in place, never as an `NSAlert` or panel: a
    /// separate window loses the keyboard to the tick's `NSApp.activate()` within a second.
    ///
    /// **`Anuluj` holds the keyboard and neither button answers Enter**, so a stray Return
    /// cannot log him out and lose his unsaved work. Escape already does nothing
    /// (``CoverWindow/cancelOperation(_:)``).
    private func showLogoutConfirm() {
        guard flow == nil, !confirmingLogout, rendered != nil else { return }
        confirmingLogout = true
        logoutConfirmed = false

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(headline(Strings.coverLogOutConfirmTitle))
        stack.addArrangedSubview(subline(Strings.coverLogOutConfirmLine))

        let cancel = confirmButton(Strings.pinCancelButton, id: Self.logoutCancelID,
                                   role: .neutral, action: #selector(cancelLogout(_:)))
        let confirm = confirmButton(Strings.coverLogOutConfirmButton, id: Self.logoutConfirmID,
                                    role: .warning, action: #selector(confirmLogout(_:)))
        let row = NSStackView(views: [cancel, confirm])
        row.orientation = .horizontal
        row.spacing = 16
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(40, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        initialResponder = cancel
        settle()
        window?.makeFirstResponder(cancel)
    }

    /// The Accessibility identifiers `make ui-gate` finds the confirmation's buttons by.
    static let logoutCancelID = "logout-cancel"
    static let logoutConfirmID = "logout-confirm"

    private func confirmButton(_ title: String, id: String, role: CoverButton.Role,
                               action: Selector) -> NSButton {
        let button = CoverButton(title: title, role: role, fontSize: 18 * scale,
                                 target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityIdentifier(id)
        // Deliberately no `keyEquivalent`: Enter must not log out.
        return button
    }

    @objc private func cancelLogout(_ sender: NSButton) {
        guard confirmingLogout else { return }
        // One hop: the face replaces the sender. Re-checked on arrival, so a double click
        // or a face change in between does not rebuild a face that is already there.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.confirmingLogout else { return }
            self.restoreFace()
        }
    }

    @objc private func confirmLogout(_ sender: NSButton) {
        guard confirmingLogout, !logoutConfirmed else { return }
        logoutConfirmed = true
        // The command, then the face back whatever the log-out does: a dry or failed
        // log-out must not leave him in front of a question whose button does nothing
        // (§2.2). A real one ends this process within seconds anyway.
        onPress(.logout)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.confirmingLogout else { return }
            self.restoreFace()
        }
    }

    /// Put the face back after the prompt closes, whatever the answer was.
    ///
    /// Via `rendered = nil` rather than a second draw path: ``render(_:)`` is the one place
    /// that knows how a face is built, and a prompt that returned to a hand-assembled copy
    /// of it would drift from the real one the first time a face changed.
    private func restoreFace() {
        flow = nil
        confirmingLogout = false
        guard let model = rendered else { return }
        rendered = nil
        render(model)
        if let initialResponder { window?.makeFirstResponder(initialResponder) }
    }
}
