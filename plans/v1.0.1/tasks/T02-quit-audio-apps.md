# T02 — Quit apps making sound when the cover is required

**Phase:** 2 · **Depends on:** T00 · **Weight:** medium

> Do not start until T00 has settled which detection route to use, and read its `FINDINGS.md`
> row first. If T00 chose the bundle-id fallback, the detection helper below returns pids for
> known media apps found running instead of querying CoreAudio; everything else is the same.

## Goal

Stop the sound when the turn ends. Today only fullscreen apps are quit; an ordinary window
like a Chrome tab is merely covered, so its audio plays on and locking the screen does not
help because the app is still alive. Extend the eviction that already runs when a cover is
required so its target set is the fullscreen apps *plus* the apps currently making sound,
reusing the existing terminate-then-force, grace, per-tick re-check and `app_quit` logging
unchanged.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.2, on top of foundational §2.6.2. The fairness argument (three
warnings first), the 10-second grace, the per-tick re-check, the `app_quit` event and the
enforcement gate are all inherited from §2.6.2 and must not change.

## Files

- `Sources/RSTApp/FullscreenApps.swift` (changed) — generalise so `evict(at:)` acts on the
  union of fullscreen apps and audio-emitting apps, deduplicated by pid. Add the
  emitting-audio detection helper here or in a sibling `AudioApps.swift`.
- `Sources/RSTApp/CoverEnforcer.swift` — only if wiring needs it; the evictor is already
  constructed and called here on every covered tick, so ideally no change.

## Interface

```swift
// New detection helper (route decided by T00). Excludes our own pid.
static func audioEmittingApps() -> [App]     // App is the existing {pid, name} struct

// The evictor's target becomes the union; the existing App.pid dedup applies.
func evict(at now: Date)   // unchanged signature; now also quits audio-emitting apps
```

Why the union and not a second evictor: the grace bookkeeping (`asked[pid]`), the
force-after-10s and the reset-on-relaunch all key on pid and must be shared, or an app that is
both fullscreen and loud would be handled twice or get two graces.

**Exclude our own process by pid** in `audioEmittingApps()` — the app plays its own warnings
and cover sound, and quitting itself would drop the cover.

## Tests

**The evictor lives in `RSTApp` (AppKit) and there is no `RSTApp` test target** — the app has
always kept logic in `RSTCore` for `make test` to reach and hand-verified the platform side, and
this task does not change that (decided with the user, 2026-09-15). There are no existing
evictor tests to extend. So `make test` reaches exactly one thing here:

- [ ] The Core boundary test still passes — no AppKit/CoreAudio import crept into `RSTCore`.

Everything else has no automated coverage and is verified by hand with the user (below): the
union deduplicating (an app that is both fullscreen and emitting asked to quit once, one grace,
one `app_quit`), our own pid never in the evict set, the grace and force-after-10s, the
detection, and the sound actually stopping. **Reuse the existing terminate/grace/`app_quit`
machinery unchanged** — that path is the already-verified §2.6.2 behaviour, so extending its
target set is the only new thing, not the timing it inherits.

## Done when

- [ ] With a cover required, the evict set includes apps currently making sound, deduplicated
      with the fullscreen set, our own process excluded.
- [ ] `make test` is green and the Core import scan still passes.
- [ ] The behaviour is verified by hand with the user (below); until then the task is 🔍 with
      its hand-verification half explicitly unchecked.

## Needs a person

Sound stopping cannot be tested headless. Run inside the seatbelt, never a bare enforcing run.

```
# with a YouTube video playing in a Chrome window:
RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30 RST_TIME_SCALE=60 swift run RealScreenTime
# (RST_TIME_SCALE fast-forwards to the cover; adjust per TESTING.md)
```

Expect: when the cover appears, Chrome is asked to quit and the YouTube sound stops within a
few seconds; the cover tears down after 30s.
Tell me: whether the sound actually stopped, whether Chrome was closed, and whether the app's
own spoken warning still played (it must — we exclude ourselves).
