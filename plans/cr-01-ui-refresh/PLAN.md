# Implementation plan

Four tasks in one phase. Each has a file in [tasks/](tasks/) with its goal, the files it
touches, the interfaces it defines, and what "done" means.

Track state in [PROGRESS.md](PROGRESS.md). Read [DESIGN.md](DESIGN.md) first, and the binding
specification it points at, [CR-01-ui-refresh.md](CR-01-ui-refresh.md).

---

## Shape of the build

There is no headless phase before a UI phase here, because this plan *is* the UI phase of a
finished app — the rules the engine enforces were built and proven in the initial build. What
the ordering does instead:

- **Every rule a change carries is built in `RSTCore` with a test, in the same task as its
  AppKit.** Each task touches both targets: the Core rule first, tested, then the view wired to
  it. This keeps the boundary intact and means no task ships a control whose rule was never
  tested — the same guarantee a separate headless phase would buy, at the grain of one task.
- **The shared rules are built once and reused.** The sessions-per-day pop-up and the combo
  suggestion/merge rule are used by both the wizard and Settings, so T01 builds them and T03
  depends on T01 rather than copying them.
- **The riskiest change carries a mandatory hand test.** T01 includes §2.3's arming delay, which
  reverses a fix made after a real failure and can only be proved by deliberately double-clicking.
- **The menu-bar removals are independent** and can slot in anywhere.
- **Every task finishes with a live-testing session** with the product manager — none of these
  surfaces can be proved by `make test`, so a task is not ✅ until its hand pass is done and
  recorded in `FINDINGS.md`. Each task doc carries the exact command under **Needs a person**.

```
Phase 1  ▸  T01  wizard: button row, step-3 controls, step-4 buttons + arming delay
         ▸  T02  wizard: the final screen                         depends on T01
         ▸  T03  settings: all seven fields, and Save closing      depends on T01
         ▸  T04  menu bar: remove three items                      independent
```

---

## Phase 1 — The refresh

| # | Task | Depends on |
|---|---|---|
| [T01](tasks/T01-wizard-controls.md) | Wizard: button row (§2.1), step-3 combo + pop-up (§2.2), step-4 three buttons and the ~500 ms arming delay (§2.3); the shared sessions-per-day and combo-suggestion rules in Core | — |
| [T02](tasks/T02-wizard-final-screen.md) | Wizard: the terminal "You're done" screen (§2.4); `EnglishPlural` and optional `FirstRunStep.position` in Core | T01 |
| [T03](tasks/T03-settings-fields.md) | Settings: session/hour combos, sessions pop-up, grant/warning token fields, minutes display, Save closes (§2.5–§2.8); reuses T01's shared rules; adds the minute/second conversion in Core | T01 |
| [T04](tasks/T04-menu-bar.md) | Menu bar: remove `Raport użycia…`, `Konfiguracja…`, `Zakończ` and their plumbing (§2.9) | — |

At the end of the phase the three parent-facing surfaces are refreshed, every rule they carry is
tested in `RSTCore`, and each surface has had its hand pass with the product manager.

---

## Critical path

```
T01 → T03
T01 → T02
```

T01 is the only task on the shared path — both T02 and T03 build on it. T02 and T03 do not
depend on each other and may be built in either order once T01 is reviewed. T04 is off the path
entirely and can be picked up whenever convenient.

## Rough sizing

| Weight | Tasks |
|---|---|
| **Heavy** | T01 (three wizard changes plus the shared Core rules and the arming delay), T03 (three combos, a pop-up, two token fields, the minute/second conversion, and Save-closes) |
| **Medium** | T02 (one new screen, the plural, the optional position) |
| **Light** | T04 (three removals and their plumbing) |

Where this overruns: T01's arming delay and T03's grant-list "refuse to delete the last token"
are both fiddly AppKit that the tests cannot reach, so their cost is in the hand pass and any
back-and-forth it produces, not in the code.

## Sequencing against the other plan

The CR notes this refresh should land **before T18**, the ship checklist in the initial-build
plan, which hand-verifies the wizard and Settings on the real machine. Shipping first means
walking that checklist twice. This is a cross-plan ordering note, not a dependency this plan can
enforce; it is the product manager's to hold.

## Decisions still open

None. The two the CR left open — `Konfiguracja…` on a configured Mac, and `Zakończ` — were
settled with the product manager on 2026-09-05 and are recorded in [DESIGN.md](DESIGN.md) §7. The
one consequence they opened, where the login-item reinstall lives, was settled in the same
conversation. Nothing blocks the build once the plan is reviewed.
