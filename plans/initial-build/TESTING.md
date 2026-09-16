# Testing

The app's job is to make a Mac unusable. Testing it must not make *this* Mac unusable.

The strategy is to push every rule into `RSTCore`, where it can be tested headlessly, and
to make the remaining platform behaviour observable in ways that do not take the screen.

**Two self-tests run the real detached threads without ever taking the screen**, and both
are safe to run as often as you like: `make seatbelt` proves the cover's auto-release fires
on time, and `make watchdog` proves the hang detector outlives a main thread that has
stopped answering — it parks a real one and requires the process to end itself, having
written `watchdog_exit` first.

**Before trusting any manual test, verify the release path.** The cover's auto-release is
the thing that must never regress: arm it before the first window, on a detached thread,
and keep a self-test mode that fires it with no windows so it can be checked after every
edit. The T00 spike shipped a version where an early `return` skipped a trailing
`NSTimer`, and the machine had to be power-cycled.

**The safety default: debug builds observe, release builds enforce.** `swift run` and
`make test` cannot cover the screen. Enforcement requires `RST_ENFORCE=1`, typed
deliberately. You cannot lock yourself out by running the wrong command.

---

## L1 — Unit tests on `RSTCore`

**Runs:** `make test` · **Risk:** none · **Covers:** roughly 85% of the behaviour

Everything that decides whether to block is pure. `Policy.decide(snapshot, config)` takes
a struct and returns a `Decision`; a test constructs the struct directly.

What must be covered:

- Budget exhaustion at exactly the boundary, one second either side
- Idle grace: 9:59 idle still counts, 10:01 does not
- Off-console charges nothing, with no grace at all — not even one tick
- `mediaPlaying` charges up to the 30-minute cap and not one second beyond, at any duration
- Recent input charges whether or not anything is playing — the idle clause settles the tick
  on its own, before the media clause gets a say
- **The activity predicate across all its inputs.** It is four booleans plus a number wide and
  it decides whether a child's evening is billed correctly — it deserves the exhaustive test
- The 06:00 day rollover — 05:59 is yesterday, 06:00 is today
- A `disabledUntil` in the past re-arms; in the future stays dormant
- Extensions stack: three grants of 15 is 45 minutes, not 15
- Granted minutes on an expired session return `.allowed`, then fall back to `.expired`
- Granted minutes never decrement the self-service count, however many there are
- `.awaitingResume` after a logout mid-session; `.awaitingStart` after one that ran out
- Gap classification: clean marker → not charged; boot inside gap → partial; nothing → full
- Warning thresholds fire once each, at 10, 5 and 1 minutes, and not again
- No PIN hash → `.dormant`, never `.blocked` (DESIGN.md §2.5)
- Config round-trip, defaulting, and corrupt-file recovery
- PBKDF2 hash and verify, including a wrong PIN and an empty PIN
- **The import boundary test** — scan `Sources/RSTCore/**.swift`, fail on `import AppKit`,
  `import SwiftUI`, `import Cocoa`. If this fails, move the code; never relax the test.

Time is injected via `FakeClock`. A test that needs eight hours to pass advances a
variable.

## L2 — Integration, still headless

**Runs:** `make test` · **Risk:** none

The real `Policy`, the real `Ledger`, the real `EventLog`, with `FakeClock`, scripted
sensor readings, and `RecordingEnforcer` in place of the cover. Assert the exact sequence
of decisions and events across a scripted day.

The canonical scenario:

**Implemented in `Tests/RSTCoreTests/IntegrationTests.swift`; the times below are what it
asserts.** Two things differ from the sketch this replaced: the 10-minute idle grace is
*charged*, per DESIGN §2.2, so the session ends at 16:35 rather than 16:45; and there is one
self-service session a day, per §2.1 as revised 2026-08-22, so everything after it is minutes
the parent typed.

```
16:00  login                 → awaitingStart(1 left)
16:00  Rozpocznij            → allowed, 30:00
16:10  walks away            → the grace charges on; pauses at 16:20 with 10:00 left
16:20  warning(10) · 16:30 warning(5) · 16:34 warning(1)
16:25  returns               → 10:00 left, counting again
16:35  session ends          → expired(0 left)
16:46  PIN ▸ Dodaj minuty: 15 → allowed, 15:00
17:01  expired(0 left)
17:02  Zablokuj ekran        → screen_locked, no PIN
17:03  logs out
18:00  logs in               → expired(0 left), "Na dziś koniec sesji"
18:00  PIN ▸ Dodaj minuty: 30 → allowed, 30:00
18:10  logs out mid-session  → 20:00 preserved, no session consumed
19:00  logs back in          → awaitingResume(20:00), Wznów
19:20  expired(0 left)
19:21  PIN ▸ Dodaj minuty: 30 → allowed, 30:00
19:51  expired(0 left)
06:00  next day              → awaitingStart(1 left)
```

The same evening is replayed on 2026-03-29 and 2026-10-25 — the mornings that are 23 and 25
hours from their midnight — and must produce an identical list.

Also scripted: the kill-and-relaunch path (heartbeat with no clean marker → `tamper_gap`
charged in full), and the clean-shutdown path (marker present → nothing charged).

This is the same technique S.TFU uses to test its detector against a fake audio source.
No microphone there, no window here.

## L4 — Windowed cover

**Runs:** `RST_COVER_FRAME=600x400+80+80 RST_ENFORCE=1 swift run RealScreenTime`
**Risk:** none — the cover is a box you can drag your other windows around

`presentationOptions` is app-global and therefore *not* exercised here, but everything
window-shaped is:

- [ ] The PIN field accepts keystrokes → proves `canBecomeKey` is overridden
- [ ] Window sits above normal windows → `.screenSaver` level
- [ ] Window follows a Space switch → `.canJoinAllSpaces`
- [ ] Window persists over an app entering fullscreen → `.fullScreenAuxiliary`
- [ ] One window appears per attached display
- [ ] Plugging and unplugging a display adds and removes one
- [ ] Correct PIN dismisses it; wrong PIN clears the field and does not
- [ ] **The watchdog frees a wedged app.** Add `RST_STALL_SECONDS=60`: two seconds after
      the cover appears the main thread parks, and the process must end itself thirty
      seconds later, taking the box with it. `RST_MAX_COVER_SECONDS` goes *behind* the
      watchdog — 90, not 30 — so what fires is the watchdog and the seatbelt is only there
      if it does not. `events.jsonl` should end with `watchdog_exit`

This is where the fiddly AppKit work gets done. Nearly every cover bug is findable in a
600×400 box, and finding it there costs a keystroke instead of a reboot.

## L5 — Scratch account, full kiosk

**Risk:** none to your own session

The one thing L4 cannot reach. `presentationOptions` locks the whole app, so real Cmd+Tab
blocking only exists when it is really on.

```bash
# once, from the admin account
sudo sysadminctl -addUser rst-test -password test -fullName "RST Test"

# fast-user-switch into rst-test, install the bundle, let it lock down,
# switch back out, then assert from your own account:
sudo cat /Users/rst-test/Library/Application\ Support/RealScreenTime/events.jsonl | jq -c .
```

Assertions are read from the log file afterwards, from outside — the log is just a file,
and being locked out of a session does not mean being locked out of its filesystem.

Always deploy there with `RST_MAX_COVER_SECONDS=30` in the plist's `EnvironmentVariables`
until the behaviour is trusted.

Checklist:

- [ ] Cmd+Tab does nothing
- [ ] Cmd+Q does nothing
- [ ] Cmd+Opt+Esc does not open Force Quit
- [ ] Apple ▸ Log Out / Shut Down are unavailable
- [ ] Ctrl+Cmd+Q — **record the result**, it is a recovery path if it works (see T00)
- [ ] Mission Control gesture and F3 do not reveal anything
- [ ] Killing the process from the admin account: cover vanishes, launchd relaunches, cover returns
- [ ] `tamper_gap` appears in the log with roughly the right duration

## Manual checklist — before it goes on `child`'s account

Not automatable. Run with `RST_MAX_COVER_SECONDS=30` set.

- [ ] Cover draws over a **fullscreen game** (real GPU; a VM will not tell you the truth)
- [ ] Cover draws over fullscreen video and over Mission Control
- [ ] Covers the second display, and the notch area on the built-in one
- [ ] **Safe Mode**: does the LaunchAgent still load? If not, that is a real bypass — record it in DESIGN.md §8
- [ ] Reboot → the app is running again at login, budget intact
- [ ] Sleep for 20 minutes → nothing charged
- [ ] Log out for 20 minutes → nothing charged
- [ ] `kill -9` → gap charged, `tamper_gap` logged
- [ ] Warnings appear without stealing focus from a game
- [ ] Menu-bar countdown matches the log
- [ ] PIN ▸ Disable stands down, and re-arms by itself the next morning
- [ ] **Recovery drill** — do this one before you need it: reboot, log in as the admin
      account, remove the plist, confirm you have the Mac back

---

## Accelerated time

`RST_TIME_SCALE=60` makes one real second pass as one simulated minute, so a 90-minute
budget plays out in 90 seconds.

```bash
RST_TIME_SCALE=60 RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30 \
  RST_COVER_FRAME=600x400+80+80 swift run RealScreenTime
```

That command shows warnings, cover, PIN entry, extension and re-block in about two
minutes, in a box, on your own account, with a seatbelt. It is the fastest honest feedback
loop this project has.

It works only because all time flows through the `Clock` protocol. A single stray `Date()`
in the app makes one part of the system run at real speed while the rest runs at 60× —
which looks like a logic bug and is not one. If accelerated runs behave strangely, grep
for `Date()` first.

---

## What is not tested, and why

**XCUITest is unavailable.** This machine has Command Line Tools, not Xcode, and
`xcodebuild test` needs Xcode. There is no scripted UI automation and none is planned.
L4 and L5 are driven by environment variables and asserted against the event log.

The response to that constraint is the Core/App boundary: push behaviour into `RSTCore`
until what remains in `RSTApp` is thin enough to check by eye. A rule that can only be
verified by clicking is a rule in the wrong module.

**VMs are not used for cover testing.** A macOS VM would be a perfect place to get locked
out safely, but its compositor and GPU path are not the ones under test — "does this draw
over a fullscreen game" is exactly the question a VM answers wrongly.
