# T06 — Event log

**Phase:** 1 · **Depends on:** T02 · **Weight:** light

## Goal

An append-only JSONL record of what the app did. This is the report — there is no report
UI, by design.

## Interface

```swift
public enum EventType: String, Codable, Sendable {
    case sessionStart = "session_start"
    case sessionEnd   = "session_end"
    case warned, blocked, uncovered, extended, disabled, rearmed
    case tamperGap     = "tamper_gap"
    case configReset   = "config_reset"
    case watchdogExit  = "watchdog_exit"
    case wouldCover    = "would_cover"      // observer mode
}

public protocol EventSink: Sendable {
    func append(_ event: Event)
}

public struct FileEventSink: EventSink { /* appends to events.jsonl */ }
public final class MemoryEventSink: EventSink { /* tests */ }
```

One JSON object per line, with an ISO-8601 timestamp carrying the UTC offset:

```json
{"ts":"2026-08-21T19:42:03.118+02:00","type":"blocked","reason":"budget","used_s":5400}
{"ts":"2026-08-21T19:44:11.902+02:00","type":"extended","minutes":15,"n_today":1}
{"ts":"2026-08-21T20:31:07.441+02:00","type":"tamper_gap","seconds":288}
```

Keep the offset. A log of evening screen time read six months later, across a DST change,
is materially harder to interpret without it.

## Write before dispatching

An event is written **before** the action it describes, stamped with the time of the
decision rather than the time of the write.

The cover blocks until a PIN arrives, which could be hours. A line written after the action
completes is misdated by that entire interval — and lost completely if the process is
killed while covered, which is exactly the case the log exists to record. S.TFU's rule, same
reasoning.

## Robustness

- Append with `O_APPEND` and a single `write` per line, so concurrent writers cannot
  interleave partial lines.
- A failed write must never propagate into the decision path. Log to `app.log` and carry
  on: a full disk should not switch enforcement off.
- No rotation. This is a few hundred bytes a day.

## Reading it

There is no UI. The documented interface is `jq`, and it belongs in the README:

```bash
jq -c 'select(.type=="tamper_gap")' events.jsonl
jq -c 'select(.type=="extended")'   events.jsonl
jq -s 'group_by(.ts[0:10]) | map({day: .[0].ts[0:10], blocks: length})' events.jsonl
```

Charting was considered and declined — it is the longest tail in the build and answers the
same questions these three lines already answer.

## Tests

- Round-trip every event type
- Timestamp format parses back to the same instant, offset intact
- Appending never rewrites earlier lines
- A write failure does not throw into the caller
- `MemoryEventSink` records order faithfully, for T07

## Done when

`make test` passes and a hand-written scenario produces a log a human can read without the
schema in front of them.
