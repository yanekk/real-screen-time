# T08 — App shell and safety flags

**Phase:** 2 · **Depends on:** T07 · **Weight:** light

## Goal

A real process that ticks, decides, logs — and cannot cover the screen.

## The safety default

```swift
#if DEBUG
let enforcementDefault = false
#else
let enforcementDefault = true
#endif
let enforcing = ProcessInfo.processInfo.environment["RST_ENFORCE"]
    .map { $0 == "1" } ?? enforcementDefault
```

**`swift run` never covers the screen.** The installed release `.app` always does.
Enforcement requires typing `RST_ENFORCE=1` on purpose.

Do not "temporarily" invert this while working on something. Use
`RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30` instead — that is what those flags are for.

## Flags

| Flag | Default (debug) | Effect |
|---|---|---|
| `RST_ENFORCE` | `0` | `1` allows real covering |
| `RST_MAX_COVER_SECONDS` | unset | Tear any cover down after N seconds |
| `RST_COVER_FRAME` | unset | `WxH+X+Y` — render into a box instead of fullscreen |
| `RST_TIME_SCALE` | `1` | 1 real second = N simulated seconds |
| `RST_DATA_DIR` | `~/Library/Application Support/RealScreenTime` | Redirect all state |

`RST_DATA_DIR` is what lets tests and the scratch account run without touching real state.

## Wiring

```
Timer 1s (tolerance 0.2)
  → Sensors.read()                  (T09; stubbed to "active" for now)
  → ledger.advance(...)
  → Policy.decide(snapshot, config)
  → enforcer.apply(decision)        ObserverEnforcer for now
  → eventLog.append(...) on change
```

`ObserverEnforcer` logs `would_cover` where `CoverEnforcer` will cover. That single line is
what makes it safe to run this on your own account for a full day, which is the fastest way
to find out whether the sensors and the tick are telling the truth.

## Lifecycle

- **Activation policy `.accessory`** at launch — menu-bar app, no Dock icon. It switches to
  `.regular` only while covering, because presentation options require it (T12).
- **Single instance.** A named lock file with `flock`, or a `CFMessagePort`. A second
  launch exits immediately; two instances would double-charge the ledger.
- **Clean-exit marker.** On `NSApplicationWillTerminate`, `NSWorkspace.willSleepNotification`
  and `NSWorkspace.willPowerOffNotification`, write `exitKind = .expected` before going
  away. T04's whole gap classification depends on this being reliable — it is the one
  place where a missed write silently punishes an innocent shutdown.
- **`session_start`** on launch, after gap classification.
- Unhandled errors go to `app.log` and the app keeps running.

## Gotcha

**An exception thrown during startup will hang, not crash.** T00 established that
`NSApplication` catches exceptions raised in `applicationDidFinishLaunching`, logs them,
and keeps its run loop going. Do not assume a startup failure will be loud — wrap startup
in explicit error handling and log the outcome.

## Done when

`swift run RealScreenTime` starts on your own account, **nothing is ever displayed**, a
second launch exits on the lock, and the three files say what the run actually did: the
launch, the classified gap and the exit in `app.log`; `blocked` and `would_cover` in
`events.jsonl` where a cover would have gone up; `exit_kind: "expected"` in `session.json`
after an orderly stop.

> **The hour moved to [T10](T10-menu-bar.md) — user's decision, 2026-08-22.** This task
> originally asked for an hour of observer running "whose log describes that hour
> accurately". It cannot: at T08 there is no menu, no cover and no PIN dialog, so nothing
> in the app can *start* a session and the decision never leaves `awaitingStart` /
> `expired` / `dormant`. An hour would be two lines and a heartbeat. T10 is where the
> countdown gives the hour something to be right about.
