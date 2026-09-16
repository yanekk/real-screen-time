import Foundation

/// **What the status item shows this tick**, as a value — the whole of T10's display rule.
///
/// Every choice the menu bar makes is a rule: minutes in the bar and seconds in the menu,
/// both zero-padded and rounded up, which glyph stands in for a countdown when there is
/// nothing to count, and when the digits are tinted. DESIGN §3.2 gives `MenuBar.swift` to the App target and it keeps the
/// `NSStatusItem`; the rules moved here on exactly the argument that moved `Flags.swift`
/// and the tick before them — a rule in `RSTApp` is a rule that can only be checked by
/// starting the app and looking at the corner of the screen, on a machine with no UI
/// automation.
///
/// **No Polish crosses the boundary.** ``title`` is digits and two symbols, and the menu's
/// own lines are assembled in `Strings.swift` from ``remainingText`` and the two session
/// numbers. §2.4.2's one-file rule still holds, and there is nothing in this file to
/// translate.
///
/// `Equatable` is load-bearing rather than decorative: the App holds the last model it
/// displayed and assigns nothing unless this one differs, which is T10's "only touch the
/// title when the string actually changed" for the whole item at once.
public struct MenuBarModel: Equatable, Sendable {

    /// No session is counting down — nothing started, nothing running, or stood down until
    /// 06:00. Deliberately the same glyph for all of them: DESIGN §2.2 refuses a "paused"
    /// badge, and distinguishing the reasons here would be that badge under another name.
    public static let pausedGlyph = "⏸"

    /// No PIN, so the wizard (T16) has not been run and the app cannot enforce anything.
    /// A different thing from having no time left, and worth a different character: an
    /// `⏸` here would say "waiting" about an app that is not armed at all.
    public static let noPINGlyph = "–"

    /// What sits next to the icon: `00:18`, ``pausedGlyph`` or ``noPINGlyph``.
    ///
    /// **Minutes, not seconds** — changed by the user 2026-08-23, after the first session
    /// anyone had ever watched run. A digit that changes once a second is movement in the
    /// corner of the eye all evening, and the seconds were never the number being paced
    /// against. The precise figure is one click away in ``remainingText``, which keeps all
    /// three fields.
    public let title: String

    /// This tick is inside a warning threshold.
    ///
    /// Named for what it used to do — draw the digits orange — and kept under that name
    /// because it is the *rule* that matters and the rule has not changed. What `RSTApp`
    /// does with it did: two attempts to colour a status item's digits both came back black
    /// on a dark menu bar, so the warning now changes the symbol beside them instead. See
    /// `MenuBar.swift`, 2026-08-23.
    public let tinted: Bool

    /// `HH:MM:SS` for the menu's first line — `00:00:00` where no session has time left.
    /// Always present, unlike ``title``: the menu has room for the number even when the
    /// menu bar is showing a glyph instead.
    public let remainingText: String

    /// Self-service sessions started today, and the day's limit, for the menu's second line.
    public let sessionsUsed: Int
    public let sessionLimit: Int

    /// Whether a PIN exists at all (DESIGN §6).
    ///
    /// Published for T13: the menu's two gated items open a PIN prompt, and with no PIN
    /// stored there is nothing that prompt could accept — so they stay disabled, exactly as
    /// they were before the dialog existed. The glyph below already knew this; the menu
    /// needed to be told.
    public let isConfigured: Bool

    /// Build the display from the tick that just ran.
    ///
    /// `decision` is ``Engine/lastDecision`` and may be `nil` for the instant between the
    /// status item appearing and the first tick — treated as "nothing running", which it is.
    public init(decision: Decision?, sessionsUsedToday: Int, config: Config) {
        sessionsUsed = max(0, sessionsUsedToday)
        sessionLimit = config.selfServiceLimit
        remainingText = Self.clockText(decision?.remainingSeconds ?? 0)
        isConfigured = config.isConfigured

        // The no-PIN check comes first and beats the decision, exactly as `decide`'s own
        // first rule does. It is also the only way to tell the two `.dormant`s apart —
        // "stood down until 06:00" and "never set up" arrive as the same case.
        if !config.isConfigured {
            title = Self.noPINGlyph
            tinted = false
        } else {
            switch decision {
            case .some(.allowed(let remaining)):
                title = Self.shortClockText(remaining)
                tinted = false
            case .some(.warning(let remaining, _)):
                title = Self.shortClockText(remaining)
                tinted = true
            case .some(.dormant), .some(.awaitingStart), .some(.awaitingResume),
                 .some(.expired), .none:
                // `.awaitingResume` has minutes on it and still shows the glyph: the
                // question the menu bar answers is "is it counting down", and it is not.
                // The minutes are a menu line away in `remainingText`.
                title = Self.pausedGlyph
                tinted = false
            }
        }
    }

    /// Seconds as `HH:MM`, two fields, zero-padded, **rounded up**.
    ///
    /// The menu bar's own text since 2026-08-23. Rounding up is what keeps the promise the
    /// digits make: while any time at all remains this reads `00:01`, never `00:00`, and a
    /// countdown that sits on zero with the session still running is the one number here
    /// that would be a lie. It also means a fresh 30-minute session opens on `00:30` rather
    /// than dropping to `00:29` a second later.
    ///
    /// Same clamp as ``clockText(_:)`` and for the same reason: the `Int` conversion traps
    /// past `Int.max`, and this takes whatever a `Decision` carries.
    public static func shortClockText(_ seconds: TimeInterval) -> String {
        let bounded = min(max(0, seconds), ceiling)
        let minutes = Int((bounded / 60).rounded(.up))
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// The largest countdown this will render: `999:59:59`, about 41 days.
    ///
    /// **A width, and a second belt.** ``SessionState/secondsCeiling`` is what actually
    /// keeps the app alive — since 2026-08-23 the ledger clamps its remainder at every
    /// write, so nothing the app itself holds can trap the `Int` conversion below. This
    /// ceiling is nine digits lower and does a different job: `clockText` is `public` and
    /// takes any `TimeInterval` anyone hands it, and a menu-bar item is a fixed strip of
    /// screen. A number too wide to read is a bad display; a number wide enough to crash is
    /// a dead app, and neither is worth allowing because the other is already handled.
    static let ceiling: TimeInterval = 3_599_999

    /// Seconds as `HH:MM:SS`, always three fields, always zero-padded.
    ///
    /// A field that appears at the hour boundary shifts everything to its left, and at a
    /// glance `4:12` reads as four hours rather than four minutes. Past 99 hours the first
    /// field simply grows, up to ``ceiling`` — neither case this app can reach.
    ///
    /// **Rounded up**, so the last fractional second reads `00:00:01` rather than
    /// `00:00:00`. A countdown that sits on zero while the session is still running is the
    /// one number here that would be a lie; ticks land on whole seconds anyway, so this
    /// only decides the fractions a `RST_TIME_SCALE` run produces.
    public static func clockText(_ seconds: TimeInterval) -> String {
        // `max` before `min`, and that order is what makes a NaN read `00:00:00`: every
        // comparison against NaN is false, so `max(0, .nan)` returns the 0 it was given.
        let bounded = min(max(0, seconds), ceiling)
        let total = Int(bounded.rounded(.up))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
