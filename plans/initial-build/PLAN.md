# Implementation plan

20 tasks in six phases. Each has a file in [tasks/](tasks/) with its goal, the files it
touches, the interfaces it defines, and what "done" means.

Track state in [PROGRESS.md](PROGRESS.md). Read [DESIGN.md](DESIGN.md) first.

---

## Shape of the build

The ordering follows one principle: **everything that can be tested headlessly is built
and tested before anything draws a pixel.** By the end of Phase 1 the app has no UI at all
but every rule in the design is implemented and verified — sessions, the self-service count,
idle, presence, gaps, extensions, the 06:00 rollover. Phase 3 then wires a window to a decision function that is
already known to be correct.

The second principle: **the cover is built in a 600×400 box before it is built
fullscreen.** Nearly every bug in that window — the key-window trap, z-order, Spaces,
multi-display — is findable without taking the screen. Only kiosk lockdown genuinely
requires the full thing, and that is one task, done last, in a scratch account.

```
Phase 0  ▸  T00                      prove the ground          throwaway
Phase 1  ▸  T01 … T07                pure core, headless       no UI exists
Phase 2  ▸  T08 … T10                real app, harmless        observer mode
Phase 3  ▸  T11 … T14                the cover                 windowed, then kiosk
Phase 4  ▸  T15 … T17                resilience and setup      installable
Phase 5  ▸  T18                      ship
```

---

## Phase 0 — Prove the ground

Nothing is designed on top of an assumption about AppKit that has not been checked on this
machine, on this macOS version.

| # | Task | Depends on |
|---|---|---|
| [T00](tasks/T00-kiosk-spike.md) | Kiosk spike — verify presentation options, window level, Spaces, Safe Mode | — |

**T00 gates the whole design.** If `disableProcessSwitching` does not hold on macOS 26, or
if a `.screenSaver`-level window will not draw over a fullscreen game, the cover approach
is wrong and we would rather find out in an afternoon than in week three. It is throwaway
code and it is deleted afterwards.

## Phase 1 — Foundation

Pure `RSTCore`. No AppKit, no windows, no system calls. All of it runs under `make test`.

| # | Task | Depends on |
|---|---|---|
| [T01](tasks/T01-package-skeleton.md) | SwiftPM package, two targets, bundle assembly, import-boundary test | T00 |
| [T02](tasks/T02-clock-config-pin.md) | `Clock` protocol, `Config`, atomic JSON, PBKDF2 PIN | T01 |
| [T03](tasks/T03-day-window.md) | 06:00 day boundary and rollover | T02 |
| [T04](tasks/T04-session-state.md) | Session state, self-service count, heartbeat, gap classification | T02, T03 |
| [T05](tasks/T05-policy.md) | `decide(snapshot, config) -> Decision` — **the heart of the app** | T03, T04 |
| [T06](tasks/T06-event-log.md) | Append-only JSONL event log | T02 |
| [T07](tasks/T07-integration-harness.md) | L2 harness: fake sensors, recording enforcer, scripted days | T05, T06 |

At the end of Phase 1, `make test` proves the app's entire behaviour. Nothing has been
displayed.

## Phase 2 — A real app that cannot hurt you

The process runs, senses, decides and logs — and refuses to cover anything, because debug
builds observe by default.

| # | Task | Depends on |
|---|---|---|
| [T08](tasks/T08-app-shell.md) | `main.swift`, env flags, activation policy, single instance, `ObserverEnforcer` | T07 |
| [T09](tasks/T09-sensors.md) | Idle seconds, lock/unlock, sleep/wake | T08 |
| [T10](tasks/T10-menu-bar.md) | `NSStatusItem`, live countdown, menu | T08 |

Run it for a day on your own account. The log should describe your day accurately, with
`would_cover` where the cover would have appeared.

## Phase 3 — The cover

| # | Task | Depends on |
|---|---|---|
| [T11](tasks/T11-cover-window.md) | The window: level, Spaces, multi-display, `canBecomeKey` — **built windowed** | T10 |
| [T12](tasks/T12-kiosk-lockdown.md) | `presentationOptions`, fullscreen, re-assert on resign — **verified in the scratch account** | T11, T00 |
| [T13](tasks/T13-pin-dialog.md) | PIN entry; add-minutes (the parent types the amount), disable; and the no-PIN screen lock | T11 |
| [T14](tasks/T14-warning-banners.md) | 15 / 5 / 1-minute warnings that do not steal focus | T10 |

T11 is the largest single task and the one with the most ways to go subtly wrong. It is
built and debugged entirely inside `RST_COVER_FRAME=600x400+80+80`.

## Phase 4 — Resilience and setup

| # | Task | Depends on |
|---|---|---|
| [T15](tasks/T15-watchdog.md) | Hang detector; `exit(0)` after a 30s stall while covered | T12 |
| [T16](tasks/T16-first-run.md) | Wizard, PIN creation, LaunchAgent self-install | T13 |
| [T17](tasks/T17-settings.md) | SwiftUI settings window, PIN change, uninstall | T16 |

**T15 before T16** deliberately: do not put a KeepAlive agent on a machine before the
thing it keeps alive can recover from hanging.

## Phase 5 — Ship

| # | Task | Depends on |
|---|---|---|
| [T18](tasks/T18-ship.md) | Manual checklist, scratch-account run, README, deploy to `child` | all |

---

## Phase 6 — Found in the field

| Task | What | Depends on |
|---|---|---|
| [T20](tasks/T20-spent-session-offer.md) | A spent session must not block a day that still has one | T04, T05 |
| [T21](tasks/T21-rollover-discards-remainder.md) | 06:00 discards whatever is left on the session | T04, T05, T06, T20 |

**T21 was added 2026-09-04, by the product manager, and is built before the deploy to
`child`** — so the machine he gets carries the rule from its first day rather than learning
the old one and having it changed underneath him. **T18 is parked behind it** for that
reason, not because anything in T18 is unfinished by the app's side.

Added 2026-08-30, out of T18's hand-testing rather than out of the plan. **T19 is not
reused** — it was the camera task, dropped unbuilt on 2026-08-27 and still named in the
findings log.

## Critical path

```
T00 → T01 → T02 → T04 → T05 → T07 → T08 → T10 → T11 → T12 → T15 → T16 → T18
```

T03 and T06 can be done alongside T04. T09, T13, T14 and T17 are off the critical path
and can slot in wherever convenient.

**T19 (camera presence detection) was dropped on 2026-08-27, unbuilt**, and its scaffolding
came out of `RSTCore` with it. The 30-minute media cap in DESIGN §2.2 is now the app's whole
answer to "watching a film or gone to bed with a game running" — see §8 for the reasoning.
The task list ends at T18; there is no T19.

## Rough sizing

Not estimates in hours — a relative sense of where the weight is.

| Weight | Tasks |
|---|---|
| **Heavy** | T11 (cover window), T05 (policy), T16 (wizard + agent) |
| **Medium** | T00, T04, T12, T13, T14, T17, T18 |
| **Light** | T01, T02, T03, T06, T07, T08, T09, T10, T15 |

The two places this will overrun are **T11**, because AppKit window behaviour is discovered
rather than read, and **T12**, because it can only be tested by locking a session.

## Decisions still open

Nothing blocking. Two things T00 will settle:

- Whether `Ctrl+Cmd+Q` survives kiosk mode — decides whether Route 4 in
  [RECOVERY.md](RECOVERY.md) is real
- Whether Safe Mode loads user LaunchAgents — decides whether a documented bypass exists in
  [DESIGN.md §8](DESIGN.md#8-explicitly-out-of-scope)

Both change documentation, not architecture.
