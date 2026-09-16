# T03 — Day window

**Phase:** 1 · **Depends on:** T02 · **Weight:** light

## Goal

Answer one question purely: *which day does this moment belong to*, so the self-service
session count knows when to refill.

**There is no curfew** — §2.1 replaced it with sessions. `ClockText` parsing is kept anyway:
it is small, tested, and a *start window* is the recorded way to close §2.1's accepted gap
if that is ever wanted.

## Interface

```swift
public struct DayWindow {
    public static func dayKey(for now: Date, resetHour: Int, calendar: Calendar) -> String
    public static func nextReset(after now: Date, resetHour: Int) -> Date
}

public enum ClockText {
    public static func parse(_ text: String) -> Int?      // minutes since midnight
    public static func format(_ minutes: Int) -> String   // canonical "HH:MM"
}
```

## The 06:00 rule

The day rolls over at `dayResetHour` (default 6), not midnight. `dayKey` for 2026-08-22
05:59 is `"2026-08-21"`; at 06:00 it becomes `"2026-08-22"`.

This gives the system exactly one morning boundary instead of two — the self-service session
count refilling and a `Disable` stand-down expiring are the same moment — and it means
someone awake at 00:30 is still inside the previous day rather than being handed two fresh
sessions at the least useful hour of the night.

## No curfew

§2.1 replaced the curfew with sessions. `isPastCurfew` is **not** implemented — do not add
it back on your own initiative.

`ClockText.parse`/`format` stay, unused for now. They are small, tested, and a *start window*
(sessions may only begin between two times) is the recorded way to close the accepted gap in
[DESIGN §2.1](../DESIGN.md) if it is ever wanted. Deleting them would mean writing lenient
time parsing again from scratch.

## Evaluated per tick, never by a timer

Both of these are computed from the wall clock on every tick. **Never schedule a timer to
fire at 06:00.** A timer set across a sleep does not fire when the machine wakes, and a
fixed delay drifts by an hour across a DST change. S.TFU learned this with its off-hours
window; it is the same trap.

## Parsing

Lenient on input, canonical on output — someone typing `8pm`, `20.00` or `8:00 PM` means
20:00 and refusing that would be perverse. Store `"20:00"`.

Reject `24:00`, `19:60` and anything non-numeric by returning `nil`; the caller keeps the
previous value rather than substituting one nobody chose.

## Tests

- `dayKey`: 05:59:59 → previous day; 06:00:00 → current day; across a month boundary;
  across a year boundary
- **DST**: a day with 23 hours and a day with 25 hours both produce sane day keys. Use a fixed `TimeZone(identifier: "Europe/Warsaw")`
  in tests so this is deterministic
- `ClockText.parse` accepts `"8pm"`, `"20:00"`, `"20.00"`, `"8:00 PM"`; rejects `"24:00"`,
  `"19:60"`, `"banana"`

## Done when

All of the above pass, including the DST cases — which are the ones that will actually
break in production, twice a year.
