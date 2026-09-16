# T04 — Session state and gap charging

**Phase:** 1 · **Depends on:** T02, T03 · **Weight:** medium

> **Superseded in part, 2026-08-22.** `grantSession(_:)` no longer exists and `extend` takes
> the amount — `extend(minutes: Int)` — because DESIGN §2.5 now has one PIN grant whose size
> the parent chooses. Everything else below is as built. See the findings log.
>
> Unaffected by the 2026-08-23 change from a typed amount to a list: `extend(minutes:)` takes
> a number and does not care where T13 got it. **What did change here is that
> `remainingSeconds` is now `private(set)` and clamped on every write** — see the findings
> log for 2026-08-23.

## Goal

Track the running session and today's self-service count, survive restarts and logouts, and
classify what happened while the app was not running.

## State

```swift
public struct SessionState: Codable, Equatable, Sendable {
    public var dayKey: String                    // from DayWindow
    public var remainingSeconds: TimeInterval    // 0 = no session running
    public var sessionsUsedToday: Int            // SELF-SERVICE starts only
    public var wasRunning: Bool                  // distinguishes .expired from .awaitingStart
    public var lastHeartbeat: Date
    public var exitKind: ExitKind                // .expected or .unknown
    public var disabledUntil: Date?
}

public enum ExitKind: String, Codable, Sendable { case expected, unknown }
```

Persisted atomically to `session.json` every 15 seconds and on every state change.

`wasRunning` carries the difference between "his session ran out" and "he has not started
one yet". Both have `remainingSeconds == 0`, and they need different covers — `Czas minął`
versus `Rozpocznij sesję`. Without it a child who lets a session expire and then logs out
would be offered a fresh start as though nothing had happened.

**`sessionsUsedToday` counts self-service starts only.** A PIN-granted session refills
`remainingSeconds` and does not touch it, because the count exists to gate what he can do
alone.

## Advancing

```swift
public mutating func advance(to now: Date, snapshot: Snapshot, config: Config)
public mutating func startSelfService(_ c: Config)   // -1 self-service, remaining = full
public mutating func grantSession(_ c: Config)       // remaining = full, count untouched
public mutating func extend(minutes: Int)            // superseded; see the banner above

public static func isActive(_ s: Snapshot, _ c: Config) -> Bool {
    guard s.sessionOnConsole, !s.screenLocked else { return false }
    if s.idleSeconds <= Double(c.idleGraceSeconds) { return true }
    guard s.mediaPlaying else { return false }
    return s.idleSeconds <= Double(c.mediaGraceSeconds)   // the cap, and the whole answer
}
```

**Decrement** `remainingSeconds` by the elapsed interval only when `isActive`. If
`dayKey(now)` differs from the stored one, reset `sessionsUsedToday` to zero first — the
running session's remaining time is *not* cleared by a day rollover, since a session that
straddles 06:00 was legitimately granted and finishing it costs nobody anything.

Four separate reasons not to charge, each for its own case
([DESIGN §2.2](../DESIGN.md)):

- **Idle beyond the grace** — he walked away from a running game
- **Screen locked** — obvious, and the cheapest signal available
- **Off-console** — another user is switched in. The Mac is shared; charging him while the
  parent works would be theft
- **Media cap** — something is playing, but more than 30 minutes since he last touched
  anything, so it is a game left running rather than a film being watched

The media clause is what stops a two-hour film costing ten minutes; the cap on it is what
stops a game left on overnight costing nothing at all. Neither is exactly right, because
nothing separates "sitting watching" from "went to bed" without a camera — and there is no
camera: T19 was dropped unbuilt on 2026-08-27, so the cap is the whole answer (DESIGN §8).

## Gap classification — the interesting part

On launch, compare `lastHeartbeat` against now.

```swift
public enum Gap: Equatable {
    case none
    case expected(TimeInterval)          // clean exit — not charged
    case rebooted(charge: TimeInterval)  // charge only the post-boot portion
    case unexplained(TimeInterval)       // killed — charged in full, logged
}

public static func classify(lastHeartbeat: Date, now: Date,
                            exitKind: ExitKind, bootTime: Date) -> Gap
```

| Condition | Result |
|---|---|
| `exitKind == .expected` | `.expected` — logged out, slept, or quit properly |
| `bootTime > lastHeartbeat` | `.rebooted(now - bootTime)` — the machine was off for the rest |
| otherwise | `.unexplained(now - lastHeartbeat)` → charged in full, `tamper_gap` logged |

**The clean-exit marker is the whole mechanism.** An orderly shutdown writes
`exitKind = .expected` before going away; `SIGKILL` cannot write anything. That asymmetry
is what distinguishes "the Mac slept" from "the app was killed" without needing to ask the
system anything.

The point is not to prevent the kill — nothing in user space can. It is to make killing
cost exactly as much session time as not killing, so there is no reason to try.

**Logging out is explicitly not a gap.** It writes the clean-exit marker, the session's
remaining seconds stay put, and logging back in offers `Wznów` rather than consuming one of
the day's two. The Mac is shared — if logging out cost him time he would stop doing it, and
the sharing would break.

`bootTime` comes from `sysctl kern.boottime`, read in `RSTApp` and **passed in** as a
parameter. `RSTCore` does not call `sysctl`.

## Known hole

`session.json` lives in the child's own home directory. He can edit it — including resetting
`sessionsUsedToday` to zero. This is recorded and accepted in
[DESIGN.md §2.3](../DESIGN.md); do not add an HMAC or a Keychain-held key on your own
initiative, as that decision was made explicitly and answered no.

## Tests

- Advance charges while active, does not while idle past the grace, does not while locked
- Boundary: 599s idle charges, 601s idle does not
- `mediaPlaying` with 900s idle **charges**; with 1801s idle does **not**, at any duration
- *(**Amended 2026-08-27**: three `presence` tests stood here — `.present` charging past the
  cap, `.absent` stopping the clock once past the idle grace, and presence being ignored on
  recent input. T19 was dropped unbuilt and `Presence` came out of `RSTCore` with it, so the
  media cap is the whole of the media clause. The surviving rule from the third of them is
  kept below in its own right.)*
- Recent input charges whether or not anything is playing — the idle clause settles the tick
  on its own. Nothing downstream may *reduce*
  time that plain input already justified
- `mediaPlaying` is irrelevant once off-console or locked — those beat it
- **Off-console charges nothing, with no grace at all** — not even one tick
- Every combination of the four inputs, since this predicate decides whether a child's
  evening is billed correctly and it is four booleans wide
- Day rollover zeroes `sessionsUsedToday` but **preserves** a running session's remainder
- `startSelfService` decrements the count; `grantSession` does not
- `wasRunning` distinguishes `.expired` from `.awaitingStart` across a restart
- A logout mid-session preserves the remainder and consumes no session
- Each of the four `classify` branches
- `.expected` after a simulated clean shutdown; `.unexplained` after a simulated kill
- A gap spanning a reboot charges only the post-boot part
- A gap spanning a day boundary does not charge yesterday's time to today
- A gap longer than the session's remaining time floors it at zero, never negative
- Round-trip through JSON; corrupt ledger is treated as `.unexplained` for the whole period

## Done when

All branches are covered, especially the day-boundary-inside-a-gap case — it is the one
that silently produces a child with no screen time on a Tuesday morning.
