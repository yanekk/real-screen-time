# T13 — PIN entry and the two grants

**Phase:** 3 · **Depends on:** T11 · **Weight:** medium

## Goal

The way back in. Used from the cover and from the menu bar.

## Behaviour

**Verify on every keystroke, and close the instant it matches.** No Enter, no OK required.
This comes straight from S.TFU, where requiring Enter after an already-correct PIN was
filed as a bug — the fix is small and the difference in feel is not.

Enter and an OK button still work, for a wrong PIN or for anyone who prefers to
type-and-confirm. A wrong PIN clears the field and shows a hint; it never closes as if it
had succeeded.

## What each button does

| Action | PIN? | Effect |
|---|---|---|
| **Rozpocznij** / **Wznów** | no | Starts or resumes a session — the ordinary path |
| **Zablokuj ekran** | no | Locks the screen. Ending your own turn is the intended exit, not a bypass — and nothing is killed, so nothing is lost |
| **Dodaj minuty…** | yes | `Engine.extend(minutes:at:)` — the parent picks an amount from `config.extensionChoices`; `remainingSeconds += minutes*60`, **without** touching `sessionsUsedToday` |
| **Wyłącz do jutra** | yes | `Engine.disable(at:)` — `disabledUntil = next 06:00`; the app goes `.dormant` |

> **Changed 2026-08-22.** There used to be two PIN grants, `Dodaj 15 minut` and `Nowa sesja`.
> DESIGN §2.5 now has one, with the amount in the parent's hands. `SessionState.grantSession`
> and `Engine.grantSession` were deleted with it.
>
> **Changed again 2026-08-23, and this is the shape to build.** The amount is **picked from a
> list**, not typed. `config.extensionMinutes` is gone; `config.extensionOptions` is the list
> and ships as `[15, 30, 60]`.

**Read the list through `config.extensionChoices`, never `extensionOptions` directly.** It
drops non-positive values and duplicates, keeps the parent's order, and falls back to the
shipped three if a hand-edited `config.json` leaves nothing usable — a grant dialog with no
amounts on it is a PIN prompt that can grant nothing.

```
after the PIN:
  ┌──────────────────────────┐
  │  Dodaj minuty            │
  │   (•) 15    ( ) 30       │      ← the first entry in the list is pre-selected
  │   ( ) 60                 │
  │        [Anuluj] [Dodaj]  │
  └──────────────────────────┘
```

**The first entry is pre-selected**, so `Dodaj minuty…` ▸ PIN ▸ Enter grants 15 with no
further choice — and a parent who wants a different default reorders the list. Draw the
amounts in the order `extensionChoices` returns them; do not sort.

What the dialog must not do is argue about an amount. There is nothing to reject any more —
every value it can offer came out of the config — and **it must not grow a cap of its own**:
§2.5's rule is that the judgement is the parent's, now made in advance rather than in the
moment. A list of one is a valid list, and so is `[240]`.

Granted minutes leave the self-service count alone deliberately: that count gates what he can
do *alone*, and minutes you granted were never self-service.

Both are logged (`extended`, `disabled`) before they take effect.

A successful grant is confirmed out loud — `Ping` ×3 then "Dodano piętnaście minut" (T14 declines the number the parent typed) — via
`Voice.swift` (T14). The countdown updating alone is too easy to miss, and the spoken
confirmation doubles as proof the PIN registered.

Extensions are **unlimited** — deliberately. The cap belongs in the parent's judgement, and
an app that refuses its owner is an app that gets uninstalled. The log makes the pattern
visible later without ever arguing in the moment.

`Disable` **re-arms by itself at 06:00**. The realistic failure of a stand-down feature is
forgetting to undo it, at which point a disabled app and a broken app are indistinguishable
a week later. So the app remembers instead of the parent.

## No PIN grace, ever

Every grant costs a PIN entry. No "remember for 60 seconds", no unlocked-menu window.

The convenience is real and the cost is worse: a grace window means an unattended Mac hands
out time, and the child only has to watch you type once to know the window is there. Two
PIN entries for `+30` is a small price for never having to think about it.

## Rate limiting

A short delay after each wrong attempt — 1s, growing to 5s — so the field cannot be brute
forced by holding a key down. Not a security measure; four digits and a patient child is a
real scenario, and this makes it boring.

Never lock out after N failures. A locked-out PIN field on a covered screen is precisely
the trap [DESIGN.md §2.5](../DESIGN.md) exists to avoid.

## Implementation notes

- One dialog used in two contexts: as a view inside the cover window, and as a sheet from
  the menu bar. Same view, two hosts.
- From the cover, the field is already first responder — the child never has to click.
- Do not echo the PIN. `NSSecureTextField`.
- Constant-time comparison (T02).

## Tests

Core-side (`RSTCoreTests`):

- Verify accepts the right PIN, rejects wrong and empty
- Grants stack: three of 15 give 45 minutes on the session
- A grant does **not** decrement the self-service count, whatever its size
- `Rozpocznij` decrements it; at zero it is unavailable and only the PIN path remains
- A grant on an expired session returns `.allowed`, and falls back to `.expired` when spent
- A negative or absurd typed value is clamped, not trapped — `extend(minutes:)` is total
- `Disable` sets `disabledUntil` to the next 06:00 — including when invoked at 05:30, where
  "tomorrow" is half an hour away, not a day
- Re-arm at 06:00 restores a full budget

That 05:30 case is the one that will be wrong on the first attempt.

## Done when

The cover opens with the PIN in a box (L4), both grants work, and the 05:30 edge case has a
test.
