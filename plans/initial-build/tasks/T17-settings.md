# T17 — Settings window

**Phase:** 4 · **Depends on:** T16 · **Weight:** medium

## Goal

Change the rules without editing JSON. A SwiftUI window behind the PIN.

## Contents

Every setting that exists, in one window, grouped:

**Sessions** — session length (minutes), self-service sessions per day, day reset hour
**Grants** — the amounts `Dodaj minuty…` offers (`extension_options`, ships 15 / 30 / 60)
**Detection** — idle grace before the clock pauses
**Warnings** — which thresholds fire (default 10 / 5 / 1)
**Security** — change PIN (requires the current one)
**Maintenance** — reveal `events.jsonl`, reveal the data folder, uninstall

Expose all of them. A hidden setting is one someone eventually edits in the JSON by hand,
and hand-edited JSON is how a config becomes corrupt.

## English, deliberately

Settings sits behind the PIN, so by [DESIGN §2.4.2](../DESIGN.md) it is English. So is the
first-run wizard, and so is the event log.

The split is at the PIN: if a string can appear without anyone typing it, it is Polish.

## Behaviour

- PIN-gated on open (T13).
- There are no time fields left; the curfew went with §2.1's move to sessions.
- **Validate before saving, and never save a value nobody chose.** A session length of 0, or
  a negative session count, keeps the previous value and shows why.
- **The grant list is an editable list of amounts, and it must never be saved empty**
  (DESIGN §2.5, 2026-08-23) — a `Dodaj minuty…` dialog with nothing on it is a PIN prompt
  that can grant nothing. `Config.extensionChoices` already falls back to the shipped three
  for a hand-edited file; this window should refuse the empty list outright rather than
  saving something it will then silently ignore. **Keep the order the parent puts them in:**
  the first entry is what T13's dialog pre-selects, so ordering *is* a setting. No upper
  bound on the values — §2.5's rule is that the app never argues with an amount its owner
  chose, and this window is where that judgement is now made.
- Changes apply on the next tick — no restart, and no "apply" button pretending otherwise.
- Log a `config_reset`-style event on any change, so the log explains a sudden change in
  behaviour six weeks later.

## Changing session length mid-session

Shortening it below what a running session has already consumed means the cover appears
immediately. That is correct — but say so before saving, because the alternative is a parent
who typed `15` meaning "from now" and got an instant lockout with a confused child in front
of it.

## Not here

- Weekday/weekend or per-day profiles — one profile, PIN for exceptions
  ([DESIGN.md §8](../DESIGN.md#8-explicitly-out-of-scope))
- A usage chart — the log is the report
- Anything that turns enforcement off other than `Disable` and `Uninstall`

## Tests

Validation is Core-side and testable:

- Session length below 1 minute rejected
- Sessions per day below 0 rejected; 0 is legal and means every session needs the PIN
- An empty grant list is rejected; a list of one is legal, and so is a large amount
- The grant list's order survives a save — the first entry is T13's pre-selection
- PIN change requires the current PIN and rewrites the salt
- A config saved by this window round-trips through `Config` unchanged

## Done when

Every setting is reachable, invalid input cannot be saved, and a changed budget takes effect
on the next tick without a restart.
