# T03 — Settings: the seven fields, and Save closing

**Phase:** 1 · **Depends on:** T01 · **Weight:** heavy

## Goal

Bring the Settings window's inputs up to the same standard as the refreshed wizard: the same
combo box and pop-up for the session numbers, a combo box for the day-start hour, token fields
for the two minute lists, detection shown in minutes, and a Save that closes the window instead of
announcing itself. After this task the only inputs in the whole app that can still raise a
validation complaint are the combo boxes — session length, day-start hour, and the two detection
fields.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.5, §2.6, §2.7, §2.8 and §3.2. Binding detail:
[CR-01-ui-refresh.md](../CR-01-ui-refresh.md) §5, §6, §7, §8. Reuses T01's `SessionsPerDayChoice`
and `ComboSuggestions` — do not build a second copy.

## Files

- `Sources/RSTApp/Settings.swift` — the session-length and hour combo boxes, the sessions pop-up,
  the two `NSTokenField`s and their delegate, the minutes labels, and `savePressed()` closing the
  window.
- `Sources/RSTCore/SettingsModel.swift` — the minute↔second conversion (§2.7); reuses the shared
  rules from T01. Check the remaining callers of `MinuteList` (see below).
- `Tests/RSTCoreTests/SettingsModelTests.swift` — the conversion, both directions and the rounding.

## Interface

```swift
// SettingsModel.swift — the display/store conversion for the two grace fields.
public enum GraceMinutes {
    /// Seconds on disk → whole minutes for the field. 600 → 10, 1800 → 30.
    public static func toMinutes(seconds: Int) -> Int
    /// Minutes from the field → seconds for disk. 10 → 600. Rounds a hand-edited non-round
    /// value to the nearest minute (DESIGN §2.7, accepted consequence).
    public static func toSeconds(minutes: Int) -> Int
}
```

- The hour combo suggests 4/5/6/7/8, accepts any hour, 23 is the cap; a stored value outside the
  suggestions is shown via `ComboSuggestions.merged`, not clamped. `SettingsDraft.problem` still
  rejects an out-of-range hour typed in.
- The two detection-grace fields become `NSComboBox`es reading and saving **minutes** (idle
  suggesting 2/5/10/15, media 15/30/45/60), any number typeable, a stored value merged not clamped
  via `ComboSuggestions` (DESIGN §2.7). Add the two grace lists to `ComboSuggestions`, reusing
  T01's `merged` rule; `GraceMinutes` converts to/from the `idle_grace_seconds`/`media_grace_seconds`
  on disk. A negative typed value is still rejected by `SettingsDraft.problem` (`.negativeGrace`).
- Grants (`extension_options`) and Warnings (`warning_minutes`) become `NSTokenField`s. **They are
  not the same shape** (DESIGN §2.6): the grant field preserves order and must refuse to delete its
  last token (empty grants is the one thing `SettingsDraft.problem` forbids); the warning field
  need not — order is irrelevant and empty is allowed. The delegate constrains tokens to whole
  numbers; tokens show the bare number, the unit stays the trailing label. Each field offers a
  short pick-list of common amounts (grants 5/10/15/20/30/45/60/90; warnings 1/2/3/5/10/15/20/30),
  any number still typeable (DESIGN §2.6).
- `savePressed()`: on success `close()` and remove `report("Saved. It is in effect now.")`; on a
  validation failure the window stays and `complain()` names the reason. **Keep**
  `report("The PIN has been changed.")` — that path stays open and the parent needs telling.
- **`MinuteList` housekeeping.** `parse` likely loses its production caller once the token fields
  land; `format` may still be used by a description string, and both are exercised by
  `SettingsModelTests`. Do not delete without checking. If `parse` genuinely has no production
  caller left, removing it and its tests is in scope; leaving it is also fine. **Say which you did**
  in the commit message and the Notes cell.

## Tests

- [ ] `GraceMinutes.toMinutes(600) == 10`, `toMinutes(1800) == 30`.
- [ ] `GraceMinutes.toSeconds(10) == 600`; a round-trip of every app-written value is stable.
- [ ] `toSeconds` rounds a non-round hand-edited value to the nearest minute (both directions of rounding).
- [ ] The hour combo's stored-value merge shows a stored `3` or a stored `23`, and `SettingsDraft.problem`
      still rejects a typed `25`.
- [ ] `ComboSuggestions.merged` on the grace lists appends a stored value not in the list (e.g. idle `7`),
      not clamped; `SettingsDraft.problem` still returns `.negativeGrace` for a negative.
- [ ] `SettingsDraft.problem` still returns `.noGrants` for an empty `extension_options` and allows
      an empty `warning_minutes` (unchanged rules, re-asserted through the new fields' path).
- [ ] Whatever you decide about `MinuteList.parse`, `make test` is green — its tests removed with it
      or still passing.

## Done when

- [ ] `make test` is green, with the conversion and rounding covered.
- [ ] The three number fields are the two combos and the pop-up; both minute lists are token fields
      offering their pick-lists; the grant field refuses to delete its last token; detection reads
      and saves in minutes through combo boxes suggesting 2/5/10/15 and 15/30/45/60.
- [ ] A successful Save closes the window with no "Saved" label; a validation failure keeps it open
      with the reason; the PIN-change confirmation still shows.
- [ ] **The task closes with a live-testing session** (see **Needs a person**): the hand pass is
      done with the product manager and its result is recorded in `FINDINGS.md` with the date.
      This task is not ✅ until then, however green `make test` is.

## Needs a person

Observer mode, no cover, no seatbelt. Settings is behind the PIN, so set one first (run the wizard,
or use a `config.json` that already has a PIN in a scratch `RST_DATA_DIR`).

```
swift run RealScreenTime
```

Expect: open Settings (menu → `Ustawienia…` → PIN). The session-length and hour fields are combo
boxes accepting a typed value and showing a hand-edited out-of-range stored value; sessions-per-day
is the `None…`-first pop-up; grants and warnings are pill/token fields that refuse letters, offer a
pick-list of common amounts, and — for grants — refuse to delete the last token. Detection reads in
minutes through combo boxes with suggestions. A valid Save closes the window; an invalid one keeps
it open with the complaint.

Tell me: whether each control behaves as above, whether the grant field truly refuses to empty
itself, whether Save closes on success and stays open on failure, and whether the minutes shown
match `idle_grace_seconds`/`media_grace_seconds` ÷ 60 in `config.json`.
