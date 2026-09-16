# Progress

**Update this whenever a task changes state.** It is the handoff between sessions; a stale
tracker costs the next session more than keeping it current ever saves.

**What the build taught lives next door in [FINDINGS.md](FINDINGS.md)** — read the rows
touching the task you pick up, and append yours there.

**Sixty words to a Notes cell, counted.** The account is the commit message; this cell is the
index. Whoever writes a cell also fixes the over-budget cell they walk past.

**Plan reviewed:** 2026-09-05 — 3 fixes, 3 decided with the user (grace combos, token pick-lists,
final-screen session length). Code claims verified against the source; nothing rebuilds what exists.

**Status:** T01–T04 all done ✅ (all hand-passed, FINDINGS). Plan cr-01-ui-refresh complete.
**Last updated:** 2026-09-05
**Next `pir-work` will:** nothing — every task is ✅.

## Tasks

Legend: ⬜ not started · 🟡 in progress · 🔍 implemented, awaiting review · ✅ reviewed and
done · ⛔ blocked, needs a human.

| # | Task | Depends on | State | Notes |
|---|---|---|---|---|
| T01 | Wizard: button row, step-3 controls, step-4 buttons + arming delay; shared Core rules | — | ✅ | §2.1–§2.3 + Core `SessionsPerDayChoice`/`ComboSuggestions` (+16 tests). Review clean; hand pass ✅ (FINDINGS). |
| T02 | Wizard: the final "You're done" screen | T01 | ✅ | §2.4: `.done` 5th step, optional `position`, Core `EnglishPlural`+`FinalScreenSummary` (+9 tests). Reopen-showed-default fix (thread `savedLimits`). Hand pass ✅ (FINDINGS). |
| T03 | Settings: seven fields and Save closes | T01 | ✅ | §2.5–§2.8: two combos, sessions pop-up, 2 grace combos, grant/warning token fields, Save closes (670-wide fixed window; not runModal — engine tick is on `.common`). Core `GraceMinutes` + hour/grace `ComboSuggestions` (+14 tests). Review clean, no code fix; probed uncommitted token text, pop-up resolved against captured value, Core boundary. Hand pass ✅ (FINDINGS). Kept `MinuteList.parse` (allowed). |
| T04 | Menu bar: remove three items | — | ✅ | §2.9 removals. Review clean, no fix commit; probed dangling refs (none; surviving `eventsURL` is `SettingsWindow.Host`), the five-line `buildMenu`, the untouched auto-open, and the deliberately-dropped setup-recovery route (DESIGN §7). Hand pass ✅ — five lines, unconfigured launch opens wizard (FINDINGS). |

**Review queue:** empty — plan complete.

## Blocked on the user

Nothing. T03–T04 not started.
