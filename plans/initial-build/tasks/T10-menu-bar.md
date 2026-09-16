# T10 — Menu bar

**Phase:** 2 · **Depends on:** T08 · **Weight:** light

## Goal

The visible face of the app: an `NSStatusItem` showing minutes remaining, and a menu.

## Why it is visible

Taken from S.TFU and load-bearing here for the same reason. The app announces itself, shows
a countdown, and is meant to be noticed by the person it limits. A hidden watchdog starts an
arms race and removes the parent's own status indicator — with the icon there, "is it
running?" is answered at a glance by both of you.

The countdown also lets `child` pace himself, which turns the block from an ambush into a
deadline. That is the whole difference between this and the sheet Screen Time puts up.

## Appearance

```
⏱ 00:18:32     session running — HH:MM:SS, always all three fields
⏱ 00:04:12     under 10 minutes — tint it
⏱ ⏸            no session running, or dormant
⏱ –            no PIN set; the wizard has not been completed
```

**Use `NSFont.monospacedDigitSystemFont`.** With proportional digits the item changes width
as the numbers change and everything to its left jitters once a second, which is maddening
in a way that is hard to place until you see it named.

Always render all three fields zero-padded — `00:04:12`, not `4:12`. A field that appears
and disappears shifts the layout at the hour boundary, and at a glance `4:12` reads as four
hours.

**Update once a second, and only assign the title when the string actually changed.**

**One consequence worth being deliberate about:** with seconds visible, a frozen counter
makes the idle pause obvious — walk away, watch the seconds stop. This spec previously
argued against advertising that. Showing seconds reverses it, and that is a fair trade: the
countdown is honest about what it is counting, and "stepping away stops the clock" is the
correct behaviour anyway, not a loophole. It is only a loophole if he sits still for five
minutes at a time to farm it, which costs him more than it gains.

Menu — **Polish**, per [DESIGN §2.4.2](../DESIGN.md); the dropdown is visible without a PIN:

```
Pozostały czas: 00:18:32
Sesja 1 z 1
─────────────────────────
Raport użycia…             opens events.jsonl in Finder
Ustawienia…             🔒
Dodaj minuty…           🔒   ← repeatable; PIN each time; pick the amount from a list
Wyłącz do jutra         🔒
─────────────────────────
Zakończ                 🔒
```

The windows these open are English — Settings is parent-facing. The split is at the PIN,
not at the menu item.

All of these strings come from `Strings.swift`. None are literals here.

🔒 items ask for the PIN (T13). "Usage report" does not — seeing your own usage should not
need a gate.

There is no *report window*: the menu item reveals `events.jsonl`. Charting was declined in
the design, and this is the honest one-line version of it.

## Extending without a block ever happening

This is the everyday path and it must be quick: three minutes left in a session, menu ▸
**Dodaj minuty…** ▸ PIN ▸ pick an amount ▸ done. No cover appears, the countdown jumps from
`00:03:00` to `00:18:00`, and per [T14](T14-warning-banners.md) the already-fired warnings
re-arm so the new last five minutes get warned again.

- **One grant, repeatable, and the amount comes off a list** — `config.extension_options`,
  shipping 15/30/60, with the first entry pre-selected (changed 2026-08-22 and again
  2026-08-23 with DESIGN §2.5). Two taps at arm's length, rather than typing a number with a
  child watching. 90 minutes is two grants, and the log then shows two deliberate grants
  rather than one large one
- **The PIN is retyped for every grant.** No grace window, no "remember for 60 seconds".
  A timer leaves the machine handing out time unattended, and he only has to watch you type
  once to learn the window exists
- **Confirm out loud**: `Ping` ×3 then "Dodano piętnaście minut." — the amount that was
  actually granted, declined by T14, not always fifteen. Same channel as the
  warnings, so good news and bad news arrive the same way. It also tells *you* the PIN
  registered, from across the room, without squinting at the menu bar

## Updating

Refresh on every tick, but only touch the button's title when the displayed string actually
changes — a status item redrawn every second for no reason is a visible flicker and a
pointless wakeup on battery.

**Do not show a "paused" badge when the idle clock is paused.** It would teach that walking
away is a way to game the counter, which it is, and which is fine — but advertising it turns
an honest allowance into a puzzle.

## Gotchas

- `NSStatusItem` must be held in a strong property or it silently disappears.
- Menu-bar width matters on a notched display. Keep the title short; `42m`, not
  `42 minutes remaining`.
- The app is `.accessory` here. T12 switches it to `.regular` while covering and back —
  make sure the status item survives that round trip, because it is exactly the kind of
  thing that quietly does not.

## Done when

The countdown tracks the ledger for an hour in observer mode, the menu opens, PIN-gated
items are gated, and switching activation policy back and forth leaves the icon intact.

**The hour is [T08](T08-app-shell.md)'s, moved here by the user on 2026-08-22.** It is the
one that was written as "the log describes that hour accurately, `would_cover` appears
where a cover would have, and nothing is ever displayed" — T08 could not run it, because
nothing in the app could start a session. So this task owns both halves: the countdown
agreeing with the ledger second by second, *and* the log of that hour agreeing with what
you actually did with the Mac.

> **Check before planning the hour: can anything start a session yet?** The menu does not
> start one — `Rozpocznij` is on the cover ([T11](T11-cover-window.md)) — and every menu
> item that changes the ledger is behind the PIN dialog ([T13](T13-pin-dialog.md)). If T10
> lands before either of those, the hour can only exercise the dormant and idle displays,
> and the rest of it waits for whichever arrives first. Say so in `PROGRESS.md` rather than
> quietly marking it done.
