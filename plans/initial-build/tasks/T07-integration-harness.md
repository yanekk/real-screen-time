# T07 — Integration harness

**Phase:** 1 · **Depends on:** T05, T06 · **Weight:** light
**This is the Phase 1 exit gate.**

> **Superseded in part, 2026-08-22.** Two things below are no longer what the code does, and
> `Tests/RSTCoreTests/IntegrationTests.swift` is the current statement of the scenario.
>
> 1. **The canonical timeline is ten minutes out.** It assumes the 10-minute idle grace freezes
>    the session clock; DESIGN §2.2 charges it, so the session ends at 16:35, not 16:45.
> 2. **There is one self-service session a day, and one PIN grant** (DESIGN §2.1, §2.5). So
>    18:00 is not a second `Rozpocznij` and 19:21 is not `Nowa sesja` — both are
>    `Dodaj minuty`, and every `expired` in the evening carries `selfServiceLeft: 0`.
>
> The pieces list is also out of date: `Enforcing` and the tick loop live in
> `Sources/RSTCore/Engine.swift`, and `runDay` is a `Harness` that models runs as processes.

## Goal

Drive the real `Policy`, `Ledger` and `EventLog` through scripted days with fake sensors
and a recording enforcer, and assert the exact sequence of decisions and events.

No windows. No microphone-equivalent. Runs in `make test` in milliseconds.

## Pieces

```swift
struct ScriptedSensors {                 // idle seconds and lock state, per tick
    var readings: [(offset: TimeInterval, idle: TimeInterval, locked: Bool)]
}

final class RecordingEnforcer: Enforcing {
    private(set) var calls: [(Date, Decision)] = []
    func apply(_ decision: Decision, at now: Date) { calls.append((now, decision)) }
}

func runDay(script: ScriptedSensors, config: Config, clock: FakeClock) -> [Event]
```

The `Enforcing` protocol is defined here and implemented for real in T08 and T11. Defining
it against a fake first keeps the real one honest — it cannot grow a method the tests
cannot drive.

Same technique as S.TFU's fake audio source feeding its real detector. Nothing is mocked
that matters; only the edges are.

## The canonical scenario

```
16:00  login                  → awaitingStart(2 left)
16:00  presses Rozpocznij     → allowed, 30:00, session 1 of 2
16:10  walks away             → pauses after the 10-min grace
16:25  returns                → still 20:00 left
16:35  warning(10)
16:40  warning(5)
16:44  warning(1)
16:45  session ends           → expired(1 left)
16:46  PIN ▸ Dodaj 15 minut   → allowed, 15:00
17:01  expired(1 left)
17:02  Zablokuj ekran        → screen_locked, no PIN, remaining stays 0
18:00  logs back in           → awaitingStart(1 left)
18:00  Rozpocznij             → allowed, 30:00, session 2 of 2
18:10  logs out mid-session   → clean exit, 20:00 preserved
19:00  logs back in           → awaitingResume(20:00)  ← NOT a new session
19:00  Wznów                  → allowed, 20:00
19:20  expired(0 left)        → "Na dziś koniec sesji"
19:21  PIN ▸ Nowa sesja       → allowed, 30:00, count still says 0 self-service left
06:00  next day               → awaitingStart(2 left)
```

Assert the full ordered list of decisions and the full ordered list of events.

## Also scripted

- **Killed:** heartbeat 4m48s old, `exitKind == .unknown`, boot time older than the
  heartbeat → `tamper_gap` of 288s, charged in full
- **Slept:** heartbeat 40m old, `exitKind == .expected` → nothing charged, no event
- **Rebooted:** heartbeat 2h old, boot time 5m ago → 5m charged
- **Disabled:** PIN ▸ Wyłącz at 21:40 → `.dormant` through the night, `rearmed` at 06:00,
  two self-service sessions again
- **Logout is not a gap:** clean marker written, remainder preserved, no session consumed
- **Expired then logout:** `wasRunning` survives the round trip, so logging back in offers
  `Rozpocznij` for the *next* session rather than pretending the last one never ran
- **Shared machine:** off-console for two hours → nothing charged, and no warning fires
  during it even though a threshold is crossed. The threshold fires on return
- **Film vs abandoned game:** `mediaPlaying` with 15 min idle charges; the same with 35 min
  idle does not
- **No PIN:** `hasPIN == false` → `.dormant` all day, never a cover, even with both sessions
  spent
- **DST:** the same scripted day on the two dates a year where the day is 23 and 25 hours
  long, in `Europe/Warsaw`

## Why this is the phase gate

At the end of T07 the app has no UI and every rule in the design is proven. Phase 3 then
wires a window to a decision function already known to be correct — which is the only
reason it is safe to build the cover last, on a machine where UI automation does not exist.

## Done when

All scenarios pass, and adding a rule to `Policy` without updating a test here fails
something.
