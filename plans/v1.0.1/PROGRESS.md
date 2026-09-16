# Progress

**Update this whenever a task changes state.** It is the handoff between sessions; a stale
tracker costs the next session more than keeping it current ever saves.

**What the build taught lives next door in [FINDINGS.md](FINDINGS.md)** — read the rows
touching the task you pick up, and append yours there.

**Sixty words to a Notes cell, counted.** Flat prose, no bold-per-clause. The cell is an index
for the next session; the account is the commit message. **Whoever writes a cell also fixes
the over-budget cell they walk past.**

**Plan reviewed:** 2026-09-15 — 1 fixed, 3 decided with the user.

**Status:** T06 in progress, paused on the user at the irreversible gate. Local half built and
committed: `make release` zips the bundle to `RealScreenTime.app.zip` (ditto --keepParent, with a
round-trip codesign verify), the asset is produced (bundle at archive root, ~410 KB), and
RELEASING.md documents cutting future releases. 416 green. What remains needs the user: the repo
owner/name, whole-history vs a fresh initial commit (T05 says fresh — history carries the child's
name/admin username/`/Users/admin`), and an explicit go before any public push. Then wire
Updater.swift's `repoOwner`/`repoName` and publish v1.0.1.
**Last updated:** 2026-09-16
**Next `pir-work` will:** FINISH T06 — the publish half, once the user gives the repo name, the
history choice, and the explicit go (see "Blocked on the user").

## Tasks

Legend: ⬜ not started · 🟡 in progress · 🔍 implemented, awaiting review · ✅ reviewed and
done · ⛔ blocked, needs a human.

| # | Task | Depends on | State | Notes |
|---|---|---|---|---|
| T00 | Spike: can this machine list which processes are making sound? | — | ✅ | Hand-verified CoreAudio route; see FINDINGS. Spike deleted. |
| T01 | Single-source version `1.0.1`, stamped into bundle | — | ✅ | Reviewed clean. `AppVersion.current`/`compare` in RSTCore; `make bundle` stamps plist. 5 tests, boundary held. |
| T02 | Quit apps making sound when cover is required | T00 | ✅ | Reviewed clean + hand pass ✅ (user 2026-09-15). Audio-emitting eviction (CoreAudio, fullscreen∪audio by pid, own pid excluded) stops sound on the real machine. |
| T03 | Parse GitHub release JSON + version compare (pure) | T01 | ✅ | Reviewed clean. Pure release-JSON parse + version compare; `.app.zip` by suffix, every bad body → `.malformed`. 416 green. |
| T04 | Version + Update button in Settings, install flow | T01, T03 | ✅ | Code review clean; 1 fix. Traps held. 2 📌 T06 findings in FINDINGS. HAND-UNVERIFIED: round-trip deferred to T06. |
| T05 | Pre-publish secrets & private-data scan | — | ✅ | Review clean, no fix to the scan. Re-ran the sweep: no secrets/state in tree or history, tree redaction verified complete. Record-accuracy fix: history still carries child name/admin username/`/Users/admin` (tree-only redaction), so T06 must use a fresh initial commit or they publish. Probed history diffs+messages, secret-shaped tokens, state files. |
| T06 | Public repo + release pipeline + publish 1.0.1 | T01, T02, T04, T05 | 🟡 | Local half built: `make release` zips bundle→`RealScreenTime.app.zip` (ditto --keepParent, round-trip codesign verify passes); asset produced, bundle-at-root; RELEASING.md written; 416 green. PAUSED on user: repo owner/name, whole-history vs fresh-initial-commit (T05 recommends fresh), explicit go. Then wire Updater.swift constants + publish. |

**Review queue:** empty.

## Blocked on the user

**T06 (later):** needs the user's explicit go and the repo name before anything is published.
Raised by the implementing session when reached.
