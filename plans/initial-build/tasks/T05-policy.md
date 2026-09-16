# T05 — The policy decision function

**Phase:** 1 · **Depends on:** T03, T04 · **Weight:** heavy

> **Superseded in part, 2026-08-22.** The shipped `selfServiceSessionsPerDay` is 1, so the
> ordinary evening is `awaitingStart(1)` → `expired(0)`; and "a granted session sets
> `sessionRemaining` to a full session" is gone with `grantSession` — granted minutes *add*.
> `decide` itself is unchanged. See DESIGN §2.1 and §2.5.

## Goal

One pure function that decides everything. This is the heart of the app.

```swift
public struct Snapshot: Equatable, Sendable {
    public let now: Date
    public let idleSeconds: TimeInterval
    public let screenLocked: Bool
    public let sessionOnConsole: Bool      // false while another user is switched in
    public let mediaPlaying: Bool          // something holds the display awake
                                           // (`presence` stood here until T19 was dropped, 2026-08-27)
    public let sessionRemaining: TimeInterval   // 0 = no session running
    public let sessionsUsedToday: Int           // self-service starts today
    public let disabledUntil: Date?
    public let hasPIN: Bool
}

public enum Decision: Equatable, Sendable {
    case dormant                                          // disabled, or no PIN set
    case awaitingStart(selfServiceLeft: Int)              // cover: Rozpocznij
    case awaitingResume(remaining: TimeInterval)          // cover: Wznów
    case allowed(remaining: TimeInterval)
    case warning(remaining: TimeInterval, threshold: Int) // 10, 5 or 1
    case expired(selfServiceLeft: Int)                    // cover: PIN grants, or lock screen
}

public func decide(_ s: Snapshot, _ c: Config) -> Decision
```

No side effects, no I/O, no `Date()`. Everything it needs arrives in `Snapshot`.

## Order of evaluation

The order is load-bearing — get it wrong and the app locks someone out with no way back.

1. **`!s.hasPIN` → `.dormant`.** First, and non-negotiable. An app with no PIN must never
   cover the screen, because nothing could then uncover it. This is not a general
   fail-open policy; it is the one case where blocking is a trap with no key.
2. **`disabledUntil > now` → `.dormant`.** A stand-down beats every other rule.
3. **`sessionRemaining > 0`** → the session is live:
   - within a warning threshold → `.warning`
   - otherwise → `.allowed`
4. **`sessionRemaining == 0`, and a session was running when it hit zero** → `.expired`.
5. **`sessionRemaining == 0`, nothing was running** → `.awaitingStart(selfServiceLeft:)`.
6. A **paused** session — remaining > 0 but the app was not running, or the user logged out
   and back in — surfaces as `.awaitingResume(remaining:)` rather than `.allowed`, so the
   child presses a button to take back the screen rather than the cover vanishing under him.

`selfServiceLeft = max(0, selfServiceSessionsPerDay - sessionsUsedToday)`. When it is zero,
the cover still shows — the difference is only which text and which buttons.

## The PIN beats every limit

`decide` does not know about the PIN beyond `hasPIN`. Grants are applied by the caller —
`+15` adds to `sessionRemaining`; a granted session sets `sessionRemaining` to a full
`sessionMinutes` **without** incrementing `sessionsUsedToday`, since the daily count gates
self-service only.

That keeps one rule with no special cases: the app limits how many sessions he can start
*alone*, and nothing else.

Unlimited, deliberately. The cap belongs in the parent's judgement, not the app's
arithmetic. Every grant is logged so the pattern is visible later without ever being
refused in the moment.

## Warnings

`warningMinutes = [10, 5, 1]`, measured against the running session's remaining time. There
is nothing else to warn about — no curfew, no daily pool. 15 is dropped because on a
30-minute session it lands at the halfway mark.

Each threshold fires **once per day per limit**. The caller tracks which have fired;
`decide` reports which threshold the current remaining time falls into, and returns the
same `.warning` on the next tick. De-duplication belongs in the enforcer, not here, so this
function stays a pure function of its inputs.

## Tests

This function gets the most tests in the repo. It is cheap — every case is a struct literal
and an assertion.

- Each of the seven evaluation steps, in isolation and in the orders where they compete
- `hasPIN == false` beats everything, including both sessions spent
- `disabledUntil` in the past does not suppress; in the future does
- Exactly at the session boundary; one second either side
- `.expired` with an extension live becomes `.allowed`, and returns to `.expired` when spent
- Three stacked extensions give 45 minutes, not 15
- Warning thresholds at exactly 15:00, 14:59, 5:00, 1:00, 0:59 remaining
- `.awaitingResume` when remaining > 0 but no session was running this launch
- `.expired(0)` when the self-service count is spent — same state, different cover text

## Done when

Every branch is covered and you would be comfortable shipping this function without ever
seeing it run in a UI — because you will, for another two tasks.
