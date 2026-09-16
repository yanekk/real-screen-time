# T11 — The cover window

**Phase:** 3 · **Depends on:** T10 · **Weight:** heavy — the largest single task

## Goal

An opaque window on every display that ordinary means cannot dismiss, holding the PIN
field.

**Build it entirely in `RST_COVER_FRAME=600x400+80+80`.** Nearly every bug in this window is
findable in a box, and finding it there costs a keystroke instead of a reboot. Fullscreen and
kiosk lockdown are T12.

## The window

```swift
final class CoverWindow: NSWindow {
    // Borderless windows return false here. A cover with a PIN field that
    // accepts no keystrokes is a cover nobody can open — this override is the
    // single most important line in the task.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

```swift
window.level = .screenSaver
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
window.isOpaque = true
window.hasShadow = false
window.backgroundColor = …
```

- `.screenSaver` puts it above ordinary windows and above the Dock.
- `.canJoinAllSpaces` makes it follow a Space switch instead of being left behind.
- `.fullScreenAuxiliary` is what allows drawing over an app in its own fullscreen Space —
  the T00 Part 3 question.
- `.stationary` keeps it still during a Mission Control transition.

The T00 spike already proved this combination builds and runs; reuse its shape rather than
rediscovering it.

## Multiple displays

One window per `NSScreen.screens`. Observe
`NSApplication.didChangeScreenParametersNotification` and rebuild — plugging a monitor in
while covered must not open an uncovered display, and that is exactly what someone would
try.

**Debounce it by comparing the actual layout, not with a boolean.** The app's own
`hideDock`/`hideMenuBar` post this notification, and so does anything that changes screen
configuration. A re-entrancy flag does not help, because the notification arrives
asynchronously after the rebuild has finished and cleared it. Build a signature from
`NSScreen.screens` frames and ignore any notification where the signature is unchanged.
T00 hit an unbounded rebuild loop this way.

Cover the full `screen.frame`, including the menu-bar and notch area. `visibleFrame` leaves
a strip.

## Content

**Polish** — the cover is the most kid-facing surface there is ([DESIGN §2.4.2](../DESIGN.md)),
and with sessions it is the app's entire interface for him. **Three faces, four rows** —
`.awaitingStart` splits on `n`, which is where [DESIGN §2.6](../DESIGN.md)'s three states
already put the split ("no session, *self-service left*" against "session over, *or none
left*"). The condition was lost translating that table into `Decision` cases; restored
2026-08-22.

| Decision | Shown | Buttons |
|---|---|---|
| `.awaitingStart(n)`, `n > 0` | `Rozpocznij sesję — 30 minut` · `Sesja 1 z 1` | `Rozpocznij` — **no PIN** |
| `.awaitingStart(0)` | `Na dziś koniec sesji` | **No `Rozpocznij` at all** — `Wprowadź PIN` ▸ `Dodaj minuty…`, plus `Zablokuj ekran` |
| `.awaitingResume(t)` | `Wznów sesję — pozostało 20 minut` | `Wznów` — **no PIN** |
| `.expired(n)` | `Czas minął`, or `Na dziś koniec sesji` when `n == 0` | `Wprowadź PIN` ▸ `Dodaj minuty…`, plus `Zablokuj ekran` |

- `Zablokuj ekran` needs **no PIN** and is always present on the expired cover
- A wrong PIN shows `Niepoprawny PIN`
- No close button, no Escape, no Cancel

**`.awaitingStart(0)` is the row that carries the daily cap, and it is the only thing that
does.** `SessionState.startSelfService` is ungated on purpose, and `decide` does not refuse
either — it reports `.awaitingStart(selfServiceLeft: 0)` like any other state, because
whether the button is offered is a question about the cover. So a `Rozpocznij` wired without
looking at `n` deletes the one limit the app enforces for itself, and **no test below this
layer would fail**. Found reviewing T05, 2026-08-22.

It is reachable, and not only through a spent allowance: `self_service_sessions_per_day: 0`
is a supported setting meaning *every* session needs the PIN, and it produces
`.awaitingStart(0)` from the very first tick. There is already a test pinning that.

Same dead end as `.expired(0)`, so it wears the same face — the difference is only that no
session ran first, which is why `Czas minął` would be a lie here. `Zablokuj ekran` is on it
for the same reason it is on the expired cover: with nothing self-service left, handing the
machine back is the only move he has that does not need a parent.

**Gate it on a tested pure property, not on re-deriving the count here** — a
`Decision.offersSelfServiceStart` in `RSTCore` alongside the existing `coversScreen`, true
only for `.awaitingStart(n)` where `n > 0`. That keeps the rule in the one layer this
project can test headless, and leaves the cover only able to get it wrong by ignoring the
property outright.

`.awaitingStart` and `.awaitingResume` are separate states, not one with a variable label:
one consumes a session and the other returns time already granted, and collapsing them makes
the resume-after-logout rule inexpressible.

Both start and resume are **PIN-free**. The cover is not a punishment in those states — it
is the front door, and it exists so a session does not silently drain while he is away from
the desk.

Every string from `Strings.swift`. An English literal here is the specific mistake the
bilingual split invites.

Keep it calm and readable. This screen is going to be looked at by a disappointed child
fairly often; it should read as a boundary, not a punishment.

## The seatbelt

`RST_MAX_COVER_SECONDS` tears the cover down after N seconds regardless of state. Wire it
here, not in T12 — every manual test from this point on depends on it.

**Arm it before the first window is shown, on a detached thread calling `exit(0)`.** Not
an `NSTimer`, not at the end of the function. The T00 spike did it the obvious way and
took the machine down with it: an early `return` above a trailing `NSTimer` left the
screen covered with nothing to release it. A detached thread started before `buildCover()`
survives a skipped branch, a wedged main thread, and a swallowed exception.

Add a self-test mode that arms the release with no windows and asserts the process exits,
so this can be verified after every edit without taking the screen.

## Fullscreen apps must be quit before covering

Per [DESIGN.md §2.6.2](../DESIGN.md). No window level reaches into another app's fullscreen
Space and `hide()` is refused, so a fullscreen app is closed rather than covered.

- Detect apps owning a fullscreen Space. `CGWindowListCopyWindowInfo` with a window whose
  bounds exactly match an `NSScreen` frame, owned by a regular app, is a workable detector
  and needs no Accessibility grant
- `terminate()`, then `forceTerminate()` after 10 seconds — a modal "save changes?" sheet
  must not be able to hold the cover off indefinitely
- Log `app_quit` with the name and whether it was forced
- **Gate it behind the same enforcement check as covering.** A debug build must never quit
  a real app; this is destructive in a way the cover is not
- Only when a cover is actually required, and only for fullscreen apps — ordinary windowed
  apps are covered fine and quitting them would be gratuitous
- **Re-check on each tick while covered, not once.** Some game launchers relaunch
  themselves, and a fullscreen app appearing after the cover is up would carve a hole in
  it. The check is cheap; doing it once is the kind of assumption this project has already
  been caught by
- Verified against two different games (Sneaky Sasquatch and Roblox): `terminate()`
  accepted, clean exit, both displays covered afterwards

## Locking the screen — resolved, with a fallback

**`SACLockScreenImmediate()` in `login.framework` works on macOS 26.5 and returns 0.**
Measured 2026-08-22. It locks *immediately* — no dim-and-wait, no Automation prompt, no
Accessibility grant.

```swift
let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY)
let fn = dlsym(h, "SACLockScreenImmediate")   // resolve at startup, not at click time
```

Private API. Acceptable here — ad-hoc signed, never distributed — but it must degrade
rather than crash. **Resolve the symbol at startup and label the button accordingly**, so
there is never a button that lies:

| | Button reads | Does |
|---|---|---|
| Symbol present | `Zablokuj ekran` | Locks immediately |
| Symbol absent | `Wyloguj` | `launchctl bootout gui/$UID` — hard logout, last resort |

**Setup requirement, independent of the above.** This Mac reports
`sysadminctl -screenLock status` → **300 seconds**: no password is asked until five minutes
after sleep or the screensaver. That grace undermines the whole app every time the Mac
sleeps. Set **System Settings ▸ Lock Screen ▸ Require password → immediately** on the
child's account, and check it in T18.

## Teardown must not leave the screen wrong

Measured in T00: quitting a fullscreen app while covered orphaned its fullscreen Space and
left a stale frame on that display, with **no process owning it**. Killing things did not
help and neither did sleeping the display; it had to be closed by hand in Mission Control.

A child's Mac stuck showing a frozen frame after the cover lifts looks exactly like the app
broke the machine — and it would be the app's fault.

- Force a redraw of every screen on teardown, not just `orderOut`
- `spike/kiosk-probe` has a `windows` mode listing every on-screen window with its owner
  and layer. A **WindowServer-owned window at layer 0 with no app behind it** is the
  signature of an orphaned Space. Keep that diagnostic
- If the hide-the-frontmost-app fallback is adopted, this failure cannot occur — nothing is
  in fullscreen to orphan

## Checklist (L4, in a box)

- [x] Typing into the PIN field produces characters → `canBecomeKey` works
      **(verified in T00, 2026-08-21 — the override is correct, reuse the spike's shape)**
- [x] The window sits above normal windows **(verified with the user 2026-08-23, in a box, over a Finder window)**
- [x] It follows a Space switch **(verified with the user 2026-08-23)**
- [ ] It survives another app entering fullscreen **— T12's manual pass: needs a real fullscreen app**
- [ ] One window per attached display **— T12's manual pass: `RST_COVER_FRAME` is one box by construction**
- [ ] Plugging and unplugging a display adds and removes one **— T12's manual pass: needs a second display**
- [ ] Correct PIN dismisses it; a wrong PIN clears the field and does not **— T13 owns the field; the button ships padlocked and disabled**
- [x] `Rozpocznij` and `Wznów` work without any PIN **(both verified with the user 2026-08-23 — `Wznów` after a Ctrl-C mid-session)**
- [x] With `self_service_sessions_per_day: 0`, the cover shows `Na dziś koniec sesji` and
      offers **no** `Rozpocznij` — only the PIN path. This is the daily cap, and this
      checklist line is the only thing that tests it
      **(verified with the user 2026-08-23, from the very first tick)**
- [x] `Zablokuj ekran` locks immediately without a PIN, and the cover is still there on unlock **(verified with the user 2026-08-23)**
- [x] `RST_MAX_COVER_SECONDS=10` releases it after ten seconds **(verified twice: `make seatbelt` headless, and the user watching a real cover go at 90 s, 2026-08-23)**

## Gotchas

- Set `contentView` **before** `makeKeyAndOrderFront`, then `makeFirstResponder` on the
  field — in that order, or focus lands nowhere.
- Only the primary window should take key. Secondary displays use `orderFrontRegardless()`.
- Swift 6: `@MainActor` throughout, `MainActor.assumeIsolated` inside notification
  observers.

## Done when

Every box above is ticked, in a 600×400 box, without the screen ever having been taken.
