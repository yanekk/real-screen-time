import Foundation
import Testing
@testable import RSTCore

/// The menu bar's display rules (T10).
///
/// Every one of them is a rule about a string, and a rule about a string that lived in
/// `RSTApp` could only be checked by starting the app and reading the corner of the screen.
/// What the *item* looks like still needs a person; what it says does not.
@Suite("Menu bar model")
struct MenuBarModelTests {

    private static let configured: Config = {
        var config = Config()
        config.pinHash = "hash"
        config.pinSalt = "c2FsdA=="       // "salt", base64 — `pinSaltData` must decode
        return config
    }()

    private static func model(_ decision: Decision?,
                              used: Int = 0,
                              config: Config = configured) -> MenuBarModel {
        MenuBarModel(decision: decision, sessionsUsedToday: used, config: config)
    }

    // MARK: - The clock text

    @Test("all three fields, always, zero-padded")
    func threeFieldsAlways() {
        #expect(MenuBarModel.clockText(0) == "00:00:00")
        #expect(MenuBarModel.clockText(1) == "00:00:01")
        #expect(MenuBarModel.clockText(252) == "00:04:12")
        #expect(MenuBarModel.clockText(1112) == "00:18:32")
        #expect(MenuBarModel.clockText(1800) == "00:30:00")
    }

    /// The hour boundary is the whole reason for the rule: a field that appears here would
    /// shift everything to the left of the item at 59:59.
    @Test("the hour field does not appear and disappear")
    func hourBoundaryDoesNotShift() {
        #expect(MenuBarModel.clockText(3599) == "00:59:59")
        #expect(MenuBarModel.clockText(3600) == "01:00:00")
        #expect(MenuBarModel.clockText(3601) == "01:00:01")
        #expect(MenuBarModel.clockText(5025) == "01:23:45")
    }

    @Test("past ten hours the first field grows rather than truncating")
    func longSessionsDoNotWrap() {
        #expect(MenuBarModel.clockText(36000) == "10:00:00")
        #expect(MenuBarModel.clockText(360000) == "100:00:00")
    }

    /// Rounded **up**: a countdown showing `00:00:00` while the session is still running is
    /// the one number here that would be a lie.
    @Test("a fraction of a second still reads as a second")
    func fractionsRoundUp() {
        #expect(MenuBarModel.clockText(0.1) == "00:00:01")
        #expect(MenuBarModel.clockText(59.5) == "00:01:00")
        #expect(MenuBarModel.clockText(1799.4) == "00:30:00")
    }

    /// **The one input here that could kill the app.** `Int(_:)` on a `Double` past
    /// `Int.max` traps, and nothing bounds a session length: `session_minutes` in
    /// `config.json` is multiplied by 60 with no upper clamp, and `remaining_seconds` in
    /// `session.json` is decoded straight — both files the child owns. Without the ceiling
    /// the menu bar crashes the process on the tick after a session starts.
    @Test("an absurd remainder is clamped rather than crashing")
    func absurdRemaindersClamp() {
        // What `session_minutes: 9223372036854775807` actually produces.
        #expect(MenuBarModel.clockText(Double(Int.max) * 60) == "999:59:59")
        #expect(MenuBarModel.clockText(1e30) == "999:59:59")
        #expect(MenuBarModel.clockText(.infinity) == "999:59:59")
        #expect(MenuBarModel.clockText(.greatestFiniteMagnitude) == "999:59:59")
        // The ceiling itself, and the last second below it, still read exactly.
        #expect(MenuBarModel.clockText(3_599_999) == "999:59:59")
        #expect(MenuBarModel.clockText(3_599_998) == "999:59:58")
    }

    /// Not reachable through JSON, which has no `NaN` literal — but arithmetic can make one
    /// and `Int(.nan)` traps just as hard. `max` before `min` is what sends it to zero.
    @Test("a NaN reads as no time rather than trapping")
    func nanReadsAsZero() {
        #expect(MenuBarModel.clockText(.nan) == "00:00:00")
        #expect(MenuBarModel.clockText(-.infinity) == "00:00:00")
    }

    /// End to end, because the trap fires on the path the tick actually takes.
    @Test("a session of absurd length still renders a title and a menu line")
    func absurdSessionStillDisplays() {
        let model = Self.model(.allowed(remaining: Double(Int.max) * 60))
        #expect(model.title == "1000:00")
        #expect(model.remainingText == "999:59:59")
    }

    @Test("a negative remainder cannot produce a negative clock")
    func negativesFloorAtZero() {
        #expect(MenuBarModel.clockText(-1) == "00:00:00")
        #expect(MenuBarModel.clockText(-100000) == "00:00:00")
    }

    // MARK: - The title

    /// **Minutes in the bar, seconds in the menu** (changed by the user 2026-08-23). The
    /// two are deliberately different resolutions of the same number.
    @Test("a running session counts down in minutes, and the menu keeps the seconds")
    func runningShowsTheClock() {
        let model = Self.model(.allowed(remaining: 1112))
        #expect(model.title == "00:19")
        #expect(model.remainingText == "00:18:32")
    }

    @Test("a warning counts down too, and is tinted")
    func warningIsTinted() {
        let warned = Self.model(.warning(remaining: 252, threshold: 5))
        #expect(warned.title == "00:05")
        #expect(warned.tinted)
    }

    /// The one property the rounding exists for: the bar never says `00:00` while the
    /// session is still running, and it opens on the whole number it was granted.
    @Test("HH:MM rounds up, so a live session never reads zero")
    func shortClockRoundsUp() {
        #expect(MenuBarModel.shortClockText(1800) == "00:30")
        #expect(MenuBarModel.shortClockText(1799) == "00:30")
        #expect(MenuBarModel.shortClockText(61) == "00:02")
        #expect(MenuBarModel.shortClockText(60) == "00:01")
        #expect(MenuBarModel.shortClockText(1) == "00:01")
        #expect(MenuBarModel.shortClockText(0) == "00:00")
    }

    @Test("the hour field grows rather than wrapping, and nothing absurd traps")
    func shortClockBounds() {
        #expect(MenuBarModel.shortClockText(3600) == "01:00")
        #expect(MenuBarModel.shortClockText(36000) == "10:00")
        #expect(MenuBarModel.shortClockText(360000) == "100:00")
        #expect(MenuBarModel.shortClockText(.infinity) == "1000:00")
        #expect(MenuBarModel.shortClockText(.nan) == "00:00")
        #expect(MenuBarModel.shortClockText(-1) == "00:00")
    }

    @Test("nothing else is tinted")
    func onlyWarningsAreTinted() {
        #expect(Self.model(.allowed(remaining: 1112)).tinted == false)
        #expect(Self.model(.awaitingResume(remaining: 1112)).tinted == false)
        #expect(Self.model(.expired(selfServiceLeft: 0)).tinted == false)
        #expect(Self.model(.dormant).tinted == false)
        #expect(Self.model(nil).tinted == false)
    }

    /// One glyph for every not-counting state, and deliberately so: DESIGN §2.2 refuses a
    /// "paused" badge, and a different character per reason would be that badge.
    @Test("every state that is not counting down shows the same glyph",
          arguments: [Decision.dormant,
                      .awaitingStart(selfServiceLeft: 1),
                      .awaitingStart(selfServiceLeft: 0),
                      .awaitingResume(remaining: 900),
                      .expired(selfServiceLeft: 0)])
    func notCountingShowsPause(_ decision: Decision) {
        #expect(Self.model(decision).title == MenuBarModel.pausedGlyph)
    }

    @Test("before the first tick there is nothing to count either")
    func noDecisionShowsPause() {
        #expect(Self.model(nil).title == MenuBarModel.pausedGlyph)
    }

    /// The two `.dormant`s — "stood down until 06:00" and "never set up" — arrive as the
    /// same case, and only the config tells them apart.
    @Test("no PIN shows the dash, not the pause")
    func unconfiguredShowsDash() {
        #expect(Self.model(.dormant, config: Config()).title == MenuBarModel.noPINGlyph)
        #expect(Self.model(nil, config: Config()).title == MenuBarModel.noPINGlyph)
    }

    /// A hash with no salt is not a PIN — `Config.isConfigured` is stricter than a non-empty
    /// string, and the menu bar must agree with it or it advertises a lock that cannot open.
    @Test("a half-written PIN is no PIN")
    func halfConfiguredShowsDash() {
        var half = Config()
        half.pinHash = "hash"
        #expect(Self.model(.dormant, config: half).title == MenuBarModel.noPINGlyph)
    }

    /// The one case where the two disagree on purpose: the dash beats the countdown, so a
    /// build that somehow ran a session without a PIN says so rather than looking normal.
    @Test("no PIN beats a running session")
    func unconfiguredBeatsTheClock() {
        let model = Self.model(.allowed(remaining: 1112), config: Config())
        #expect(model.title == MenuBarModel.noPINGlyph)
        #expect(model.tinted == false)
    }

    // MARK: - The menu's own lines

    @Test("the menu shows the remainder even where the item shows a glyph")
    func pausedSessionStillReportsItsMinutes() {
        let model = Self.model(.awaitingResume(remaining: 1200))
        #expect(model.title == MenuBarModel.pausedGlyph)
        #expect(model.remainingText == "00:20:00")
    }

    @Test("a state with no session left reads zero")
    func noSessionReadsZero() {
        #expect(Self.model(.expired(selfServiceLeft: 0)).remainingText == "00:00:00")
        #expect(Self.model(.awaitingStart(selfServiceLeft: 1)).remainingText == "00:00:00")
        #expect(Self.model(.dormant).remainingText == "00:00:00")
        #expect(Self.model(nil).remainingText == "00:00:00")
    }

    @Test("the remainder is reported without a PIN too — the menu is not gated")
    func unconfiguredStillReportsTheRemainder() {
        #expect(Self.model(.allowed(remaining: 60), config: Config()).remainingText == "00:01:00")
    }

    @Test("sessions used and the day's limit come straight through")
    func sessionCounts() {
        let model = Self.model(.allowed(remaining: 600), used: 1)
        #expect(model.sessionsUsed == 1)
        #expect(model.sessionLimit == 1)
    }

    /// A parent may set the allowance to zero — every session then needs the PIN — and may
    /// hand-edit it negative. `Config.selfServiceLimit` floors it, and the menu must show
    /// the floored number rather than `z -2`.
    @Test("a negative allowance is shown as none")
    func negativeLimitFloors() {
        var config = Self.configured
        config.selfServiceSessionsPerDay = -2
        #expect(Self.model(.dormant, config: config).sessionLimit == 0)
    }

    @Test("the allowance is reported as set, even once it is used up")
    func usedUpAllowanceStillShowsTheLimit() {
        var config = Self.configured
        config.selfServiceSessionsPerDay = 2
        let model = Self.model(.expired(selfServiceLeft: 0), used: 2, config: config)
        #expect(model.sessionsUsed == 2)
        #expect(model.sessionLimit == 2)
    }

    // MARK: - Only redraw when something changed

    /// The App holds the last model and assigns nothing unless this one differs, so equality
    /// is what implements T10's "only touch the title when the string actually changed".
    @Test("two ticks of the same second are the same model")
    func equalWithinASecond() {
        #expect(Self.model(.allowed(remaining: 600)) == Self.model(.allowed(remaining: 600)))
        // Rounding up is what makes these two the same tick: a timer that fires 400 ms late
        // must not drop a whole second off the display and count 30:00, 29:58, 29:57.
        #expect(Self.model(.allowed(remaining: 599.6)) == Self.model(.allowed(remaining: 600)))
    }

    @Test("a second later it is not")
    func differentAcrossASecond() {
        #expect(Self.model(.allowed(remaining: 600)) != Self.model(.allowed(remaining: 599)))
    }

    /// The countdown is identical either side of the threshold; only the tint moves, and if
    /// equality missed that the item would never change colour.
    @Test("crossing a warning threshold is a change even at the same second")
    func tintAloneIsAChange() {
        #expect(Self.model(.allowed(remaining: 600)) != Self.model(.warning(remaining: 600, threshold: 10)))
    }

    /// Same glyph, different menu contents. If this were equal the dropdown would freeze at
    /// whatever it said when the session ended.
    @Test("the menu lines change even while the glyph does not")
    func menuLinesAreCompared() {
        #expect(Self.model(.awaitingResume(remaining: 600)) != Self.model(.awaitingResume(remaining: 599)))
        #expect(Self.model(.dormant, used: 0) != Self.model(.dormant, used: 1))
    }
}
