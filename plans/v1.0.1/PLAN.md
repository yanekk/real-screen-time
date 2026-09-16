# Implementation plan

7 tasks in 5 phases. Each has a file in [tasks/](tasks/) with its goal, the files it touches,
the interfaces it defines, and what "done" means.

Track state in [PROGRESS.md](PROGRESS.md). Read [DESIGN.md](DESIGN.md) first, and the
foundational [`../initial-build/DESIGN.md`](../initial-build/DESIGN.md) before it.

---

## Shape of the build

- **The riskiest unknown goes first, as a spike.** Whether this machine can tell which
  processes are making sound is the assumption the whole sound fix rides on, and no ad-hoc CLT
  build has been shown to do it here. T00 settles it before T02 is designed further.
- **Everything testable automatically is built and proven before the platform work.** The
  version comparison and the release-JSON parsing are pure and fully tested (T01, T03) before
  the download-and-install flow that consumes them (T04).
- **The dangerous, near-irreversible step is last, behind a gate.** Publishing a public repo
  cannot be undone, so it comes after everything else and only after the secrets scan (T05)
  and the user's explicit go.

```
Phase 0  ▸  T00              prove the sound-detection API      throwaway
Phase 1  ▸  T01              the version, one source            headless
Phase 2  ▸  T02              quit apps making sound             hand-verified
Phase 3  ▸  T03, T04         the update: core, then flow        core headless, flow hand-verified
Phase 4  ▸  T05, T06         scan, then publish                 outward, gated
```

---

## Phase 0 — Prove the ground

| # | Task | Depends on |
|---|---|---|
| [T00](tasks/T00-audio-detection-spike.md) | Spike: can this machine list which processes are making sound? | — |

**T00 gates T02.** If the CoreAudio process API works in an ad-hoc CLT build on macOS 26,
§2.2 is built on it. If it does not, §2.2 falls back to a fixed list of media-app bundle ids.
Throwaway code, deleted afterwards; its answer is written to `FINDINGS.md`.

## Phase 1 — The version

| # | Task | Depends on |
|---|---|---|
| [T01](tasks/T01-version-single-source.md) | Single-source version `1.0.1`, stamped into the bundle | — |

At the end: the app reports `1.0.1` in both `swift run` and the installed bundle, from one
constant, and `make test` proves the comparison helper.

## Phase 2 — The sound fix

| # | Task | Depends on |
|---|---|---|
| [T02](tasks/T02-quit-audio-apps.md) | Quit apps making sound when the cover is required | T00 |

At the end: with the cover up, a Chrome tab playing YouTube is quit and the sound stops —
verified by hand with the user.

## Phase 3 — The update mechanism

| # | Task | Depends on |
|---|---|---|
| [T03](tasks/T03-update-core.md) | Parse GitHub release JSON and compare versions (pure) | T01 |
| [T04](tasks/T04-update-settings-flow.md) | Version + Update button in Settings, and the install flow | T01, T03 |

At the end: the parent can read the version and press Update; a newer release is downloaded,
validated, installed with one admin prompt, and the app relaunches — verified by hand.

## Phase 4 — Publish

| # | Task | Depends on |
|---|---|---|
| [T05](tasks/T05-pre-publish-scan.md) | Scan for secrets and private data before going public | — |
| [T06](tasks/T06-public-repo-release.md) | Create the public repo, the release pipeline, publish 1.0.1 | T01, T02, T04, T05 |

At the end: v1.0.1 is a public GitHub release the Update button can reach.

---

## Critical path

```
T00 → T02 ┐
T01 → T03 → T04 ┤→ T06
T05 ────────────┘
```

T01 and T05 sit off the sound-fix path and can slot in whenever convenient. T06 waits for
everything, because it publishes the release that must actually contain the fixes.

## Rough sizing

| Weight | Tasks |
|---|---|
| **Heavy** | T04 (download, unzip, validate, admin swap, relaunch — mostly hand-verified) |
| **Medium** | T02 (extend eviction + audio detection), T03 (pure parsing + compare), T05 (scan + user decisions), T06 (repo + release + publish) |
| **Light** | T00 (spike), T01 (one constant + a compare) |

Where it will overrun: T04, because the admin swap and relaunch of a running enforcing app
have several ways to go wrong that only show up on the real machine, and each round trip needs
the user. T00's answer may also reshape T02 if the CoreAudio route fails.

## Decisions still open

Nothing blocks. Two things settle during the build rather than now:

- **The exact audio-detection API** is settled by T00. §2.2 names the candidate and the
  fallback; T00 picks.
- **The GitHub owner/repo name** for the public repo is settled with the user at T06, because
  it is the outward step and theirs to name.
