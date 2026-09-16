# T01 — Wizard: button row, step-3 controls, step-4 buttons and the arming delay

**Phase:** 1 · **Depends on:** — · **Weight:** heavy

## Goal

Make the first-run wizard's chrome and step-3 inputs right, and give step 4 the three-button
row it needs without reopening the stray-click failure that row once caused. This is the wizard
half of the refresh that a person sees first, and it also builds the two shared Core rules —
the sessions-per-day pop-up and the combo suggestion/merge rule — that Settings (T03) reuses, so
they are built once and tested here.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.1, §2.2, §2.3, and §3.2. The binding detail is
[CR-01-ui-refresh.md](../CR-01-ui-refresh.md) §1, §2, §3 — read §3's boxed warning in full.

## Files

- `Sources/RSTApp/FirstRun.swift` — `buildChrome()` (button row, §2.1), `showSessions()` and the
  step-3 controls (§2.2), `showLogin()` and `updateNextButton()` (§2.3), and the arming delay.
- `Sources/RSTCore/FirstRunModel.swift` — the sessions-per-day pop-up items and mapping, and the
  combo suggestion lists plus the merge rule. Shared with T03.
- `Tests/RSTCoreTests/FirstRunModelTests.swift` — tests for the new Core rules.

## Interface

```swift
// FirstRunModel.swift — the sessions-per-day pop-up as a rule, not a view.
public enum SessionsPerDayChoice {
    /// The items the pop-up shows, in order, for a given stored value. Item 0 is always the
    /// "None — every session needs your PIN" case (value 0). Items 1...4 are 1...4 sessions.
    /// A storedValue outside 0...4 is appended as an extra trailing item — never clamped.
    public static func items(storedValue: Int) -> [SessionsItem]
    /// The value a chosen item index maps to.
    public static func value(atIndex index: Int, storedValue: Int) -> Int
    /// The index to pre-select for a stored value (the appended item when out of range).
    public static func selectedIndex(storedValue: Int) -> Int
}

public struct SessionsItem: Equatable, Sendable {
    public let value: Int          // 0 = None
    public let isNoneCase: Bool     // drives the "…needs your PIN" label in RSTApp
}

// A stored combo value shown against a suggestion list: the list to display, with the stored
// value appended if it is not already one of the suggestions. Shared by session-length here
// and by day-start hour in T03.
public enum ComboSuggestions {
    public static let sessionLength = [15, 20, 30, 45, 60]
    public static func merged(_ suggestions: [Int], storedValue: Int) -> [Int]
}
```

- The pop-up's *labels* are English (the wizard is behind the parent's side, DESIGN §2.4.2's
  exception), assembled in `RSTApp` from the item's `value`/`isNoneCase`; only the values and
  ordering are the rule and live in Core.
- The arming delay disables the step-4 primary button for ~500 ms after step 4 first appears.
  `isKeyRepeat` is already guarding held keys and is not sufficient on its own — a second
  physical click is what installed a login item nobody had read (CR §3). The delay is `RSTApp`'s
  and cannot be unit-tested; it is verified by hand.

## Tests

- [ ] `SessionsPerDayChoice.items` for stored 0–4: five items, item 0 is the None case (value 0).
- [ ] `items(storedValue: 7)`: the five plus a trailing item of value 7; `selectedIndex` points at it.
- [ ] `value(atIndex:)` maps each index to the right `sessionsPerDay`, including 0 for the None case.
- [ ] `ComboSuggestions.merged` leaves the list unchanged when the stored value is already in it.
- [ ] `merged` appends a stored value not in the list, and does not duplicate or reorder.
- [ ] `SessionLimits.problem` still governs a combo value (0 minutes still rejected); the pop-up
      cannot produce a negative `sessionsPerDay`.

## Done when

- [ ] `make test` is green, with the new Core rules covered above.
- [ ] Every wizard step shows the primary rightmost, the step counter at the leading edge, and
      `Back` immediately left of the primary (§2.1); `nextButton.keyEquivalent` and the
      `backButton.isHidden` PIN-step rule are unchanged.
- [ ] Step 3 shows an `NSComboBox` (session length, suggesting 15/20/30/45/60, any number typeable)
      and an `NSPopUpButton` (sessions per day, `None…` first); picking `None` yields
      `sessionsPerDay == 0`; a hand-edited out-of-range stored value is shown, not clamped.
- [ ] Step 4 shows `[Back] [Finish without it] [Install login item]`, install primary and
      rightmost, with the ~500 ms arming delay in place.
- [ ] **The task closes with a live-testing session** (see **Needs a person**): the hand pass is
      done with the product manager and its result is recorded in `FINDINGS.md` with the date.
      This task is not ✅ until then, however green `make test` is.

## Needs a person

The wizard runs in observer mode and does not cover the screen, so no cover seatbelt is needed.
The arming delay must be attacked deliberately — this is the one hand test in the plan that
reopens a real past failure.

```
swift run RealScreenTime
```

Expect: the wizard opens (delete `config.json` first, or run with `RST_DATA_DIR` at a scratch
dir, so it is unconfigured). On every step the primary button is rightmost with the step counter
at the leading edge. On step 3 the two controls are a combo box and a pop-up whose first item is
`None — every session needs your PIN`. Leaving step 3, then **double-clicking Continue fast**, must
not install the login item during the ~½-second pause.

Tell me: whether the primary is rightmost on every step; whether the step-3 controls behave; and —
the important one — whether a fast double-click after step 3 ever installs the login item. Check
`app.log` for `launchctl bootstrap` within 500 ms of leaving step 3; there should be none.
