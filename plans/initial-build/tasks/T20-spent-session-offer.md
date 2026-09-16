# T20 — A spent session must not block a day that still has one

**Phase:** 5 · **Depends on:** T04, T05 · **Weight:** small

> **Numbered T20, not T19.** T19 was the camera-presence task, dropped unbuilt on
> 2026-08-27 and still referenced by several rows in [FINDINGS.md](../FINDINGS.md).
> Reusing the number would make that history ambiguous.

## Goal

`decide` returns `.expired` whenever `wasRunning` is set and no time is left, and
`.expired` never offers `Rozpocznij` at any `selfServiceLeft`. That is right only while
"a session ran out" implies "the day has none left" — an invariant the 2026-08-22 finding
relied on, and one that three ordinary paths break.

## The three doors to the same defect

1. **A session straddling 06:00.** Found by hand 2026-08-30 and reproduced headlessly.
   The remainder deliberately survives the rollover, so it crosses with `wasRunning` set;
   nothing clears it when the remainder is finally spent. The child sees `Czas minął` with
   an untouched session in the ledger **until the next rollover** — so any evening he does
   not finish his minutes costs him the following day's session.
2. **`self_service_sessions_per_day: 2`.** The second was never reachable: the first
   running out left `.expired`, which offers no start.
3. **A PIN grant before he has used his own session.** The grant runs out, `wasRunning` is
   set, and his own untouched daily session becomes unofferable for the rest of the day.

## The decision

**The user chose, 2026-08-30:** clear `wasRunning` when a session is spent on a day that
still has sessions left. The rejected alternative was to let `.expired` offer a start when
`selfServiceLeft > 0`, which would have changed what the expired cover says — a design
table the user owns — for the same result.

## Interface

`SessionState.retireIfSpent(from:config:)`, called from `advance` after the charge.

```swift
private mutating func retireIfSpent(from before: TimeInterval, config: Config) {
    guard before > 0, remainingSeconds <= 0, selfServiceLeft(config) > 0 else { return }
    wasRunning = false
    isLive = false
}
```

**`before > 0` is load-bearing.** It restricts this to a session *charged down to zero on
this tick* — the same transition `Engine` uses to emit `session_end`. Reading
`remainingSeconds == 0` alone would also catch `disable(until:)`, which zeroes the
remainder and **deliberately** leaves `wasRunning` set so a stand-down lifted before 06:00
returns the expired cover rather than re-offering a session already started.

## Acceptance criteria

- [x] A session finished after a rollover leaves the new day's session offerable
- [x] The second of two daily sessions is reachable when the first runs out
- [x] The shipped default is unchanged: one session a day, spent, is still `Czas minął`
- [x] A stand-down still leaves the expired cover, even with a session left in the day
- [x] `make test` green

## Done when

Reviewed by a session that did not write it. **One behaviour change wants the reviewer's
eye**: `IntegrationTests` "minutes granted during a stand-down" now ends `.awaitingStart`
where it ended `.expired`. That follows from the rule above and is argued at the assertion,
but it is the one place a reader should stop and agree rather than skim.
