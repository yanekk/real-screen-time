# T00 — Kiosk spike

**Phase:** 0 · **Depends on:** — · **Weight:** medium · **Throwaway**

## Goal

Verify, on this Mac and this macOS, that the cover mechanism the whole design rests on
actually works. Delete the code afterwards; keep the findings.

## Why this is first

If `disableProcessSwitching` does not hold on macOS 26, or a `.screenSaver` window will not
draw over a fullscreen game, then the cover approach is wrong and every task after this one
is wasted. An afternoon here is cheap insurance.

## Part 1 — Presentation options ✅ DONE

```bash
cd spike/kiosk-probe && ./probe-options.sh
```

**Result, 2026-08-21, macOS 26.5.1 — all seven valid together:**

```
hideDock, hideMenuBar, disableProcessSwitching, disableForceQuit,
disableSessionTermination, disableHideApplication, disableAppleMenu
```

Each of `hideMenuBar`, `disableProcessSwitching`, `disableForceQuit` and
`disableSessionTermination` **raises** without `hideDock`. Set the whole set at once.

And the finding that matters beyond this task: **a raise is not a crash.** `NSApplication`
catches exceptions thrown in `applicationDidFinishLaunching`, logs them, and keeps its run
loop going. An invalid set looks like a hang. Set, read back, compare.

## Part 2 — Does the cover hold? ⬜ NEEDS A HUMAN

```bash
cd spike/kiosk-probe && swift run KioskProbe cover 60
```

Takes over every display for 60 seconds, then releases itself and exits. Nothing is
installed, no LaunchAgent is written, no state persists. **Not something to launch
unattended** — run it yourself, and start with `cover 20` if you want to get your bearings.

Record each result in [PROGRESS.md](../PROGRESS.md):

- [x] `Cmd+Tab` — **blocked** ✅ pressed, nothing happened, never reached the app
- [x] `Cmd+Q` — **blocked** ✅ but only by the event monitor; `applicationShouldTerminate` still unexercised
- [x] `Cmd+Opt+Esc` — **blocked** ✅ pressed, no panel, never reached the app
- [x] Apple menu ▸ Log Out — **unavailable** ✅ `hideMenuBar` leaves nothing to click
- [x] **`Ctrl+Cmd+Q` — blocked** ✅ reached the app instead of locking;
      `screenIsLocked` never fired. **RECOVERY.md Route 4 is therefore dead** — use Route 3
- [x] Mission Control (F3) — **suppressed** ✅ F3 arrived as an ordinary keystroke
- [x] Typing into the text field produces characters → `canBecomeKey` override works ✅
- [x] `Cmd+Q` — blocked, but by the event monitor; `applicationShouldTerminate` still unexercised ✅
- [x] Every attached display is covered ✅ two screens enumerated and covered
- [x] No `RESIGNED ACTIVE` across three runs ✅ nothing ever took focus back

## Part 3 — Over a fullscreen game ⬜ NEEDS A HUMAN

Start a real game or fullscreen video first, then launch the spike from a terminal on
another Space.

- [x] Cover draws over a fullscreen app in its own Space — ❌ **NO**, and no level fixes it
- [x] **Quitting the fullscreen app first — ✅ WORKS.** `terminate()` accepted, game exited
      gracefully with no dialog, cover then took both displays fully. This is the design
      (DESIGN §2.6.2)

Original finding, kept for the record:

Tested against Sneaky Sasquatch, confirmed frontmost at cover time. The game held its own
display and the cover appeared only on the other screen. Two `RESIGNED ACTIVE` events
fired with no keystrokes at all, so the game also reclaims focus by itself.

Experiments run, all recorded:

- [x] `PROBE_LEVEL=shielding` — ❌ `CGShieldingWindowLevel()` (raw 2147483628) did nothing
- [x] `PROBE_LEVEL=max` — ❌ `maximumWindow` (raw 2147483631) did nothing either
- [x] `PROBE_HIDE=hide` — ❌ `NSRunningApplication.hide()` returns **false**; macOS refuses
      to hide a fullscreen app, so S.TFU's minimise-first trade cannot be ported
- [x] `PROBE_EVICT=fullscreen` — claiming our own fullscreen Space caused an unbounded
      rebuild loop; abandoned once quitting proved simpler
- [x] `PROBE_EVICT=quit` — ✅ **works**, and is now the design

This is the question a VM answers wrongly — its compositor is not the one under test. It
needs real hardware.

If this fails, the fallback is S.TFU's accepted trade-off: leave the game first
(`NSRunningApplication.hide()` on the frontmost app) and then cover. Record which one is
needed; T11 depends on the answer.

## Part 4 — Safe Mode ⬜ NEEDS A HUMAN

Shut down, hold the power button, pick the startup disk with **Shift** held, log in, then:

```bash
launchctl list | grep -i realscreentime
```

- [ ] Do user LaunchAgents load in Safe Mode?

If not, that is a genuine bypass — Safe Mode needs no admin password. It belongs in
[DESIGN.md §8](../DESIGN.md#8-explicitly-out-of-scope) next to the SSH gap, and it would be
an argument for revisiting the root-daemon decision.

## Done when

✅ **Done, 2026-08-22.** Every question this task existed to answer has an answer, including
the ones that came back "no", and all of them are in [PROGRESS.md](../PROGRESS.md).

Two items were deliberately **not** left blocking, because neither gates any code:

- **Safe Mode** — tracked as an open question in PROGRESS and on [T18](T18-ship.md)'s
  checklist. It decides a [DESIGN §8](../DESIGN.md) entry, not an implementation
- **`applicationShouldTerminate`** — the event monitor caught every `Cmd+Q` before the
  delegate was reached, so that layer is still unexercised. [T12](T12-kiosk-lockdown.md)
  implements and tests both layers rather than inferring one from the other

`spike/` stays until T18 — its `windows`, `seatbelt` and `lock` modes are still useful
while T11 and T12 are being built. Delete it then.
