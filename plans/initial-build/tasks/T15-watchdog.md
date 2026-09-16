# T15 — Hang watchdog

**Phase:** 4 · **Depends on:** T12 · **Weight:** light
**Do this before T16.** Do not install a KeepAlive agent on a machine before the thing it
keeps alive can recover from hanging.

## Goal

Make a hung app a 30-second blink instead of a dead Mac.

## The reasoning

**A crashed app cannot leave the screen covered.** Windows belong to processes; when a
process dies the window server destroys its windows and releases the kiosk presentation
options in the same instant. A crash frees the screen. That is the *good* failure.

The failure that can strand someone is a **hang** — main thread deadlocked, cover still
drawn, PIN field not responding to a keystroke. That is what this task addresses, and it is
the only automatic safety net in the app.

## Implementation

```swift
final class Watchdog {
    private let counter = ManagedAtomic<Int>(0)   // or an os_unfair_lock'd Int

    func start() {
        // Background thread — must not be the one that can deadlock.
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                if counter.wrappingIncrementThenLoad(ordering: .relaxed) > 30,
                   coverIsUp.load(ordering: .relaxed) {
                    logWatchdogExit()
                    exit(0)
                }
            }
        }
    }

    @MainActor func pet() { counter.store(0, ordering: .relaxed) }   // called each tick
}
```

- The main tick (T08) calls `pet()`. If the main thread stops running, nothing resets the
  counter.
- **The thread is the point.** A run-loop timer cannot rescue a wedged run loop. The T00
  spike proved this the expensive way — its `NSTimer`-based release was skipped by an
  early `return` and the machine had to be power-cycled.
- **Only fires while a cover is up.** A hang with no cover is a bug to investigate, not a
  reason to kill a process that is harming nobody.
- `exit(0)`, not a graceful shutdown. The main thread is wedged; anything that needs it will
  wedge too. Write the log line from the watchdog thread first, then leave.
- Write `exitKind = .unknown` — this *is* an unexplained gap and should be charged, so that
  a hang is not a way to farm free time.

## Why nothing else is automatic

A `DISABLED` sentinel file, fail-open on a corrupt config, and a 6-hour cover ceiling were
all considered and declined. Each is another way for enforcement to switch itself off for
reasons nobody chose, and [RECOVERY.md](../RECOVERY.md) Route 3 — reboot to the login
window — already guarantees a way back in without the app's cooperation.

The one narrow exception, which is a logical necessity rather than a policy: **no PIN hash
means never cover** (T05, step 1), because nothing could then uncover it.

## Tests

The mechanism is testable headlessly by injecting the exit function:

- Counter reaching 30 with a cover up → exit called, `watchdog_exit` logged first
- Counter reaching 30 with no cover → exit **not** called
- `pet()` resets the counter
- The watchdog thread survives a main-thread stall (verify by actually blocking the main
  thread in a test with the exit function stubbed)

Then by hand: add a debug-only menu item that sleeps the main thread for 60s while covered,
confirm the process dies at 30 and the screen frees. Delete the menu item before shipping,
or gate it behind `#if DEBUG`.

## Done when

The tests pass and the manual hang test frees the screen in 30 seconds.
