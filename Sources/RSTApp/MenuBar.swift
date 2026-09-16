import AppKit
import RSTCore

/// **The visible face of the app** — DESIGN §3.2, T10.
///
/// An `NSStatusItem` with a countdown and a dropdown, and nothing else: what to display is
/// ``MenuBarModel``'s, over in `RSTCore` where `make test` can reach it, and this is the
/// AppKit that puts it on the screen.
///
/// Being visible is a design decision, not an oversight (DESIGN §8). A hidden watchdog
/// starts an arms race and takes away the parent's own "is it running?" indicator; a
/// countdown turns the block from an ambush into a deadline the child can pace against.
@MainActor
final class MenuBarController {

    /// **Held strongly or it silently disappears.** An `NSStatusItem` is owned by whoever
    /// asked for it, and a status bar with no owner left is an empty menu bar with no error
    /// anywhere — this property is the whole of the fix.
    private let statusItem: NSStatusItem

    private let diagnostics: Diagnostics
    private let clock: any Clock

    private let remainingItem = NSMenuItem()
    private let sessionsItem = NSMenuItem()
    /// The three items behind the PIN prompt — T13's two grants and T17's settings — kept so
    /// ``update(_:)`` can enable them only while there is a PIN to check against.
    private var pinItems: [NSMenuItem] = []

    /// Opens the PIN prompt for one of those three. Set by `main.swift`, which owns the
    /// engine and the windows the answer goes to — this class knows about the menu and
    /// nothing else.
    var onPINAction: ((PINAction) -> Void)?

    /// The last model actually rendered. T10: assign the title only when the string really
    /// changed — a status item redrawn every second is a visible flicker and a wake-up on
    /// battery for nothing.
    private var displayed: MenuBarModel?

    /// The appearance the status item last rendered in.
    ///
    /// **Watched, not used.** On 2026-08-23 the countdown was seen turning black on a dark
    /// menu bar — legible, but the wrong colour and nothing in this file had asked for it.
    /// The two candidates are the tint being applied or lifted, and the item's effective
    /// appearance flipping under us; both are recorded so the log can say which, without
    /// anyone having to catch it happening.
    private var appearance: NSAppearance.Name?

    init(clock: any Clock, diagnostics: Diagnostics = .discarded) {
        self.clock = clock
        self.diagnostics = diagnostics
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        statusItem.menu = buildMenu()
    }

    // MARK: - The item

    /// **Monospaced digits, and this is the whole reason it is spelled once here.** With
    /// proportional figures the item changes width as the numbers change, and everything to
    /// its left in the menu bar jitters — maddening in a way that is hard to place until it
    /// is named. Named as a constant because the attributed title above has to repeat it:
    /// an attributed string carries its own font and would otherwise silently drop back to
    /// proportional figures for exactly the minutes that matter most.
    /// The ordinary face: a stopwatch. Template, so the menu bar inverts it with the
    /// system appearance — an emoji would stay the same colour on a dark bar.
    private static let normalIcon = icon("timer")
    /// Inside a warning threshold. Template too, for the same reason.
    private static let warningIcon = icon("exclamationmark.circle")

    private static func icon(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Real Screen Time")
        image?.isTemplate = true
        return image
    }

    private static let titleFont =
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.normalIcon
        button.imagePosition = .imageLeading
        button.font = Self.titleFont
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Off, deliberately. With auto-enabling on, AppKit disables every item that has no
        // target and no action — which would grey out the two information lines for the
        // right reason and the gated items for the wrong one, leaving `isEnabled` here
        // saying nothing. Every item below states its own answer instead.
        menu.autoenablesItems = false

        for item in [remainingItem, sessionsItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // The padlock stays on these three now that they work. It has always meant "needs a
        // parent", which is exactly what they still need (T13, T17). `Konfiguracja…`,
        // `Raport użycia…` and `Zakończ` were removed in CR-01 §2.9 — the wizard now opens
        // only by the unconfigured auto-open in `main.swift`, the log has two other doors,
        // and the `Zakończ` item never did anything.
        pinItems = [pinItem(Strings.menuSettings, .settings),
                    pinItem(Strings.menuExtend, .extend),
                    pinItem(Strings.menuDisable, .disable)]
        pinItems.forEach(menu.addItem)
        return menu
    }

    /// A gated item that actually opens the prompt. Enabled from ``update(_:)`` — with no
    /// PIN stored there is nothing the prompt could accept, and offering it would be a box
    /// that can only ever say no.
    private func pinItem(_ label: String, _ action: PINAction) -> NSMenuItem {
        let item = NSMenuItem(title: Strings.gated(label),
                              action: #selector(pinItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.isEnabled = false
        return item
    }

    // MARK: - Every tick

    /// Called at the end of each tick (DESIGN §3.4). Cheap when nothing changed, which is
    /// most seconds once the countdown is not running.
    func update(_ model: MenuBarModel) {
        // Before the guard: the appearance can change without the model changing at all,
        // and that is precisely the case being hunted.
        noteAppearanceChange()

        guard model != displayed else { return }
        if model.tinted != displayed?.tinted {
            diagnostics("menu: digits \(model.tinted ? "orange (warning)" : "default colour")",
                        at: clock.now)
        }
        displayed = model

        if let button = statusItem.button {
            // **The warning changes the symbol, not the colour** (2026-08-23).
            //
            // Two attempts to colour these digits orange both came back black on a dark
            // menu bar — first `contentTintColor`, then an explicit `.foregroundColor` in an
            // attributed title. A status item draws in a *vibrant* appearance, which blends
            // what it is given against the bar rather than painting it literally, and the
            // app's only visible surface is not somewhere to keep guessing at that.
            //
            // A shape carries the same meaning and cannot be blended away. It is also
            // better than the colour was: it survives a colour-blind reader, a light bar and
            // a dark one. The digits stay in the menu bar's own colour, which is the one
            // thing guaranteed to be legible.
            button.title = model.title
            button.image = model.tinted ? Self.warningIcon : Self.normalIcon
        }
        for item in pinItems { item.isEnabled = model.isConfigured }
        remainingItem.title = Strings.menuRemaining(model.remainingText)
        sessionsItem.title = Strings.menuSessionCount(used: model.sessionsUsed,
                                                      of: model.sessionLimit)
    }

    private func noteAppearanceChange() {
        guard let name = statusItem.button?.effectiveAppearance.name, name != appearance else {
            return
        }
        diagnostics("menu: status item appearance \(appearance?.rawValue ?? "(first)") → \(name.rawValue)",
                    at: clock.now)
        appearance = name
    }

    // MARK: - Actions

    @objc private func pinItemChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = PINAction(rawValue: raw) else { return }
        diagnostics("menu: \(action.rawValue) — PIN prompt", at: clock.now)
        onPINAction?(action)
    }
}
