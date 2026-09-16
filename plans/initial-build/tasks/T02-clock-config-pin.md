# T02 — Clock, config and PIN

**Phase:** 1 · **Depends on:** T01 · **Weight:** light

> **Superseded in part, 2026-08-22 and again 2026-08-23.** `selfServiceSessionsPerDay` ships
> as **1**, not 2. `extensionMinutes` no longer exists: T13's dialog offers a **list** of
> amounts rather than a field, so the key is `extension_options: [15, 30, 60]` and callers
> read it through `Config.extensionChoices`, which drops junk and never returns an empty list
> — DESIGN §2.1 and §2.5. The `Config` shape below is otherwise as built.

## Goal

The three foundations everything else sits on: injectable time, persisted settings, and a
PIN that can be checked.

## The Clock protocol

```swift
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock { public var now: Date { Date() } }

public final class FakeClock: Clock {          // tests
    public var now: Date
    public func advance(_ interval: TimeInterval) { now += interval }
}

public struct ScaledClock: Clock {             // RST_TIME_SCALE
    let origin: Date, wallOrigin: Date, scale: Double
    public var now: Date { origin + Date().timeIntervalSince(wallOrigin) * scale }
}
```

**`Date()` appears exactly once in `RSTCore`, inside `SystemClock`, and nowhere in
`RSTApp`.** A single stray call makes accelerated testing silently wrong in one place while
everything around it still looks right — the worst kind of wrong. If an accelerated run
behaves oddly, grep for `Date()` first.

## Config

```swift
public struct Config: Codable, Equatable, Sendable {
    public var sessionMinutes: Int = 30
    public var selfServiceSessionsPerDay: Int = 2
    public var dayResetHour: Int = 6
    public var idleGraceSeconds: Int = 600      // 10 min — no input at all
    public var mediaGraceSeconds: Int = 1800    // 30 min — something is playing
    // presence_enabled / _interval_seconds / _misses_before_pause stood here until
    // 2026-08-27, when T19 was dropped unbuilt and they came out of Config with it.
    // An older config.json carrying them still loads: unknown keys are preserved, not rejected.
    public var warningMinutes: [Int] = [10, 5, 1]   // 15 would be halfway through 30 min
    public var extensionOptions: [Int] = [15, 30, 60]   // superseded 2026-08-23; see below
    public var pinHash: String = ""
    public var pinSalt: String = ""
}
```

- **Atomic writes.** Temp file then `rename`. The watchdog kills this process by design, so
  a torn write is a real scenario, not a theoretical one.
- **Corrupt file** → move to `config.json.bad`, write shipped defaults, log `config_reset`,
  carry on enforcing. There is no general fail-open rule here.
- **Unknown keys are preserved** where practical, so a config written by a newer build is
  not silently truncated by an older one.
- There are no wall-clock times left in the config — the curfew was removed with §2.1's
  move to sessions. `ClockText` (T03) stays, because a *start window* is the recorded way to
  close §2.1's accepted gap should it ever be wanted.

## PIN

PBKDF2-HMAC-SHA256 via CryptoKit, 200_000 rounds, 32-byte random per-install salt.

```swift
public func hashPIN(_ pin: String, salt: Data) -> String
public func verifyPIN(_ pin: String, hash: String, salt: Data) -> Bool
```

Compare in constant time. It is one line with `Data`'s equality being wrong for this, and
free to get right.

The PIN is a speed bump, not a security boundary — anyone with admin rights ends this app
in one command. That is understood and acceptable; the hashing is there so the PIN is not
sitting in a file in plain text next to a curious ten-year-old.

## Tests

- Config round-trip; missing file yields defaults; corrupt file yields defaults plus a
  `.bad` backup
- Atomic write leaves no partial file when interrupted
- Hash and verify; wrong PIN rejected; empty PIN rejected; two installs with the same PIN
  produce different hashes (proves the salt is used)
- `FakeClock.advance` moves `now` and nothing else
- `ScaledClock` at scale 60 advances 60 seconds per real second (test with an injected
  wall-clock source, not by sleeping)

## Done when

`make test` covers all of the above and `grep -rn 'Date()' Sources/` returns exactly one
hit, in `SystemClock`.
