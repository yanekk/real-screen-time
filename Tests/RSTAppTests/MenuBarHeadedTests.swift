import AppKit
import Testing
@testable import RSTApp
import RSTCore

/// **The menu bar, in memory** (DESIGN §2.1 Tier 1, §2.2 faithful-in-memory band; T04).
///
/// ``MenuBarModel`` decides *what* to show and is unit-tested over in `RSTCore`; what is under
/// test here is the AppKit wiring in `MenuBar.swift` that turns a model into a live status item
/// — the checks that have historically needed someone to glance at the corner of the screen.
/// The status button's title is the model's countdown; the warning state swaps the *symbol*
/// (never a colour — two colour attempts came back black on a dark bar, 2026-08-23); and the
/// three PIN-gated items stay disabled until a PIN exists, each carrying its ``PINAction`` and
/// its Polish label from ``Strings``.
///
/// **No seam of the cover's kind is needed.** The menu bar orders no window, so a real
/// `MenuBarController` is safe to build here; it reaches its own status button and menu items
/// through the two read-only `internal` accessors added for this task (`statusButton`,
/// `menuItems`). Creating a real `NSStatusItem` does briefly place one in the running menu bar
/// — harmless, dismissible, no lockdown — but that it does not flash objectionably during
/// `make test` is a person's glance, not something these assertions can make (Tier 2/hand).
///
/// Fully synchronous, no run-loop pump: `update(_:)` assigns on the main actor and returns, with
/// no queue hop or `Timer` to wait on. Serialized like the other headed suites because each body
/// swaps the process-global `RST_DATA_DIR` through `HeadedHarness.withApp` (T01 env-swap finding).
@Suite("Menu bar headed", .serialized)
@MainActor
struct MenuBarHeadedTests {

    // MARK: - The countdown title

    /// The status button shows the model's own countdown text, and it is the minutes form the
    /// menu bar uses (`00:MM`), not the menu's `HH:MM:SS`.
    @Test("the status button title is the model's countdown")
    func titleMatchesModelCountdown() {
        HeadedHarness.withApp { _ in
            let menu = MenuBarController(clock: FakeClock(Self.t0))
            let button = try! #require(menu.statusButton)

            let model = Self.model(.allowed(remaining: 600))   // ten minutes
            menu.update(model)

            #expect(button.title == model.title)
            #expect(button.title == MenuBarModel.shortClockText(600))   // "00:10", the minutes form
        }
    }

    // MARK: - The warning symbol

    /// The warning state changes the button's *image*, not its colour: the symbol swaps in and
    /// back out with the model, and no tint is ever applied. If the swap were dropped — the
    /// exact regression T04 must catch — the warning image would stay identical to the normal
    /// one and this fails.
    @Test("the warning state swaps the symbol, not the colour")
    func warningSwapsSymbolNotColour() {
        HeadedHarness.withApp { _ in
            let menu = MenuBarController(clock: FakeClock(Self.t0))
            let button = try! #require(menu.statusButton)

            // `configureButton` set the normal (timer) symbol at init; capture it as the
            // reference so the assertions pin the actual glyph the app ships, not a rebuild.
            let normalIcon = try! #require(button.image)

            menu.update(Self.model(.allowed(remaining: 600)))
            #expect(button.image === normalIcon)          // still the timer symbol

            menu.update(Self.model(.warning(remaining: 120, threshold: 5)))
            #expect(button.image !== normalIcon)          // the symbol swapped for the warning one

            // Back to a plain allowed state (a different model, so `update`'s change-guard lets
            // it through) and the timer symbol returns.
            menu.update(Self.model(.allowed(remaining: 300)))
            #expect(button.image === normalIcon)

            // Never a colour, in any of those states: the digits stay the menu bar's own colour.
            #expect(button.contentTintColor == nil)
        }
    }

    // MARK: - The gated items

    /// The three PIN items are disabled while no PIN exists and enabled once one does — with no
    /// PIN there is nothing a prompt could accept, so offering them would be a box that can only
    /// say no.
    @Test("the gated items follow isConfigured: off unconfigured, on configured")
    func gatedItemsFollowConfigured() {
        HeadedHarness.withApp { _ in
            let menu = MenuBarController(clock: FakeClock(Self.t0))

            menu.update(Self.model(.dormant, config: Config()))          // no PIN
            #expect(Self.gatedItems(menu).allSatisfy { !$0.isEnabled })

            menu.update(Self.model(.allowed(remaining: 600)))            // configuredPIN
            #expect(Self.gatedItems(menu).allSatisfy { $0.isEnabled })
        }
    }

    /// The gating is explicit, not inferred: `autoenablesItems` is off, or AppKit would grey the
    /// two information lines for having no action and leave `isEnabled` saying nothing.
    @Test("the menu does not auto-enable its items")
    func menuDoesNotAutoEnable() {
        HeadedHarness.withApp { _ in
            let menu = MenuBarController(clock: FakeClock(Self.t0))
            let owningMenu = try! #require(menu.menuItems.first?.menu)
            #expect(owningMenu.autoenablesItems == false)
        }
    }

    /// Each gated item carries its own ``PINAction`` in `representedObject`, in the order
    /// settings, extend, disable — that raw value is how ``pinItemChosen`` knows which prompt
    /// to open.
    @Test("each gated item carries its PINAction in representedObject")
    func gatedItemsCarryTheirAction() {
        HeadedHarness.withApp { _ in
            let menu = MenuBarController(clock: FakeClock(Self.t0))
            let actions = Self.gatedItems(menu).compactMap { $0.representedObject as? String }
            #expect(actions == [PINAction.settings.rawValue,
                                PINAction.extend.rawValue,
                                PINAction.disable.rawValue])
        }
    }

    // MARK: - No inline literals

    /// Every visible word in the menu resolves through ``Strings`` — the gated items' padlocked
    /// labels and, after a tick, the two information lines. An inline English literal on a line
    /// the child can read is the exact mistake the bilingual split forbids (DESIGN §2.4.2).
    @Test("every menu string resolves through Strings")
    func everyStringComesFromStrings() {
        HeadedHarness.withApp { _ in
            let menu = MenuBarController(clock: FakeClock(Self.t0))

            // The gated labels are set at build time, before any tick.
            let gatedTitles = Self.gatedItems(menu).map(\.title)
            #expect(gatedTitles == [Strings.gated(Strings.menuSettings),
                                    Strings.gated(Strings.menuExtend),
                                    Strings.gated(Strings.menuDisable)])

            // The two information lines are filled by `update(_:)`.
            let model = Self.model(.allowed(remaining: 600))
            menu.update(model)
            let infoTitles = Self.infoItems(menu).map(\.title)
            #expect(infoTitles == [Strings.menuRemaining(model.remainingText),
                                   Strings.menuSessionCount(used: model.sessionsUsed,
                                                            of: model.sessionLimit)])
        }
    }

    // MARK: - Fixtures

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A config carrying a usable PIN, so a model built from it reads as configured. The salt and
    /// hash are placeholders — nothing here verifies a PIN — but must be well-formed for
    /// `isConfigured` to hold (matches `PINFlowHeadedTests.configuredPIN`).
    static func configuredPIN() -> Config {
        var config = Config()
        config.pinSalt = Data([1, 2, 3, 4]).base64EncodedString()
        config.pinHash = "placeholder — no PIN is verified in these tests"
        return config
    }

    static func model(_ decision: Decision, config: Config = configuredPIN()) -> MenuBarModel {
        MenuBarModel(decision: decision, sessionsUsedToday: 1, config: config)
    }

    // MARK: - Reading the menu

    /// The gated items, in menu order: the three that open a PIN prompt carry a
    /// `representedObject`; the information lines and the separator do not.
    static func gatedItems(_ menu: MenuBarController) -> [NSMenuItem] {
        menu.menuItems.filter { $0.representedObject != nil }
    }

    /// The two information lines, in menu order: the enabled-nothing items before the separator.
    static func infoItems(_ menu: MenuBarController) -> [NSMenuItem] {
        menu.menuItems.prefix { !$0.isSeparatorItem && $0.representedObject == nil }
            .map { $0 }
    }
}
