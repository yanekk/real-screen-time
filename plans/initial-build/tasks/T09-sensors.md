# T09 — Sensors

**Phase:** 2 · **Depends on:** T08 · **Weight:** light

## Goal

Read idle time, lock state and sleep transitions. The only part of the app that asks the
system how the world is.

## Interface

```swift
public protocol Sensing: Sendable {
    func read() -> SensorReading
}

public struct SensorReading: Equatable, Sendable {
    public let idleSeconds: TimeInterval
    public let screenLocked: Bool
    public let sessionOnConsole: Bool
    public let mediaPlaying: Bool
}
```

Lives in `RSTApp`; `RSTCore` receives the numbers as parameters.

## Idle

```swift
CGEventSource.secondsSinceLastEventType(
    .hidSystemState,
    eventType: CGEventType(rawValue: ~0)!   // "any event"
)
```

`~0` is the documented sentinel for any event type. No permission prompt, no Accessibility
grant, no TCC dialog — which is why this approach was chosen over anything that watches
input directly.

## Lock and unlock

`DistributedNotificationCenter`, names `com.apple.screenIsLocked` and
`com.apple.screenIsUnlocked`. These are undocumented but long-stable. Treat absence as
unlocked rather than crashing, and note in a comment that they are unofficial — if a future
macOS drops them, idle time still covers the case approximately.

## Fast user switching — `sessionOnConsole`

`NSWorkspace.shared.notificationCenter`, names `NSWorkspaceSessionDidResignActiveNotification`
and `NSWorkspaceSessionDidBecomeActiveNotification`. **Confirmed present in the macOS 26.5
SDK** (`NSWorkspace.h:329-330`); they exist for exactly this.

The Mac is shared and the two accounts are switched back and forth all evening. His session
stays live in the background the whole time, so without this every switch charges him up to
the full idle grace. Pause the instant the session leaves the console — no grace period,
not one tick.

Start-up state matters too: the app can launch while already off-console, so read the
current state rather than assuming on-console until told otherwise.

## Media playback — `mediaPlaying`

`IOPMCopyAssertionsStatus`, checking `kIOPMAssertionTypePreventUserIdleDisplaySleep` — held
by video players to stop the display sleeping mid-film. Confirmed present in
`IOPMLib.h:1011`. No permission needed.

Check the **display** assertion, not the system one: `pmset -g assertions` on this Mac shows
`powerd` and `caffeinate` holding `PreventUserIdleSystemSleep` at idle, which is a different
thing and would read as "always playing".

Games hold the same display assertion, which is why [DESIGN §2.2](../DESIGN.md) caps its
effect at 30 minutes since the last real input rather than trusting it outright.

Never let the app's own process hold that assertion, or it will read as media forever.

## Sleep and wake

`NSWorkspace.shared.notificationCenter`: `willSleepNotification` and `didWakeNotification`.
On `willSleep`, write the clean-exit marker (T08) — a sleeping Mac must not be charged, and
this is the only notice the app gets.

## Boot time

For T04's gap classification:

```swift
var tv = timeval(); var size = MemoryLayout<timeval>.size
sysctlbyname("kern.boottime", &tv, &size, nil, 0)
```

Read here, passed into `RSTCore` as a `Date`.

## Concurrency

Swift 6 strict concurrency: notification observers arrive `@Sendable`. Make the sensor an
`@MainActor` type and use `MainActor.assumeIsolated` inside observers, exactly as the T00
spike does. Do not reach for `.swiftLanguageMode(.v5)`.

## Tests

Mostly not unit-testable — these are system reads, which is precisely why they are isolated
in one small file behind a protocol. `RSTCoreTests` uses `ScriptedSensors` and never touches
this.

What can be checked by hand, against `RST_ENFORCE=0`:

- [ ] Idle seconds climb when you stop typing and reset when you resume
- [ ] Lock the screen → `screenLocked` true; unlock → false
- [ ] Sleep 20 minutes → the log shows nothing charged
- [ ] Boot time matches `sysctl -n kern.boottime`

## Done when

A day of observer-mode running produces a log that matches what you actually did with the
Mac — including the lunch break.
