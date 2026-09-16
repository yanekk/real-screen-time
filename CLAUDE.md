# CLAUDE.md — Real Screen Time

A macOS menu-bar app that grants a child's account screen time in **sessions** — 30 minutes
a day he can start himself, and any more minutes by PIN — covering every display with a window
ordinary means cannot dismiss whenever no session is running.

**Read [plans/initial-build/DESIGN.md](plans/initial-build/DESIGN.md) before changing
behaviour.** Every rule there was decided deliberately and most of them have a rationale
attached. If you disagree with one, say so — do not quietly implement something else.

This file has two halves. **This top half is the project** — the machine, the coding rules,
the traps, and the things only a person at the keyboard can check. **The bottom half, *How
we work together*, is the shared method** — how a plan is written, read back and built one
task at a time. Read both; they do not repeat each other.

---

## What cannot be tested headless here

**`make test` is the only evidence a session may produce on its own.** If a claim can only
be established by taking the screen, pointing a camera at a face, switching users, rebooting
or launching a real game, then this session cannot establish it — and must not write it down
as though it had. Say what you built, say what it has not been shown to do, and hand me the
exact command.

Not exhaustive, but everything on it has bitten someone already:

| Cannot be tested headless | Why it needs you |
|---|---|
| The cover actually covering, on every display | No UI automation exists here; `RST_COVER_FRAME` proves layout, never that it *holds* |
| Kiosk `presentationOptions`, Cmd+Q, Cmd+Opt+Esc, Mission Control, Cmd+Tab | The system consumes some chords before the app sees them — only a person at the keyboard knows what happened |
| Evicting a fullscreen game | No level draws over one (T00). Behaviour differs per game, and Roblox is the realistic case |
| Camera presence — the face count, the permission prompt, the LED | Needs a face, a refusal, and a look at the indicator |
| Spoken warnings and the chime | `say` returns success on an unknown voice and speaks in the wrong one. Only a listener can tell |
| Login, logout, fast user switching, the LaunchAgent, the login window | Two accounts, one console |
| Reboot, sleep and wake, Safe Mode | The gap classification's inputs are a real boot clock |
| Locking the screen, and the recovery routes | If it is wrong, the way out is the reboot it was supposed to make unnecessary |

**The seatbelt is `RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30` — never a bare enforcing run**,
and the handover format looks like this:

```
Needs you — I cannot see the screen from here:

  RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30 swift run RealScreenTime

Expect: both displays covered within a second, the PIN field accepts keystrokes,
Cmd+Q does nothing, everything gone after 30s.
Tell me: whether Cmd+Q closed it, and whether the second display was fully covered.
```

**Do not run an enforcing cover to find out for yourself.** The seatbelt is what stands
between a test and a power cycle, and the T00 spike already proved a skipped code path can
take the machine (2026-08-21, findings log). Ask first, every time.

The full procedure that wraps this table — when to raise it, how to wait, marking the task
unverified, and where a hand-verified answer is written down — is
[Anything the tests cannot establish](#anything-the-tests-cannot-establish-is-verified-with-me-not-asserted)
in *How we work together* below. That section governs; this one only names what this
particular machine cannot reach.

---

## Environment — read this before running anything

| | |
|---|---|
| macOS | 26.5.1 (Tahoe), Apple Silicon |
| Swift | 6.3.2 |
| Xcode | **not installed** — Command Line Tools only |
| Kid account | `child`, uid **502**, *not* an admin |
| Admin account | `admin`, uid 501 |

**There is no Xcode.** No `xcodebuild`, no `.xcodeproj`, no XCUITest, no Instruments.
The toolchain is `swift build` / `make test` plus a `Makefile` that assembles the
`.app` bundle by hand. **Tests run with `make test`, never bare `swift test`** — CLT ships
no XCTest, and Swift Testing needs search-path and rpath flags only the command line can
supply globally (T01 finding). Bare `swift test` fails to build here on purpose.
Do not propose an Xcode-based workflow, and do not add a project file — if you find
yourself wanting one, the answer is a `Makefile` target.

**No third-party dependencies.** `Package.swift` has an empty `dependencies` array and it
stays that way. Everything needed is in Foundation, CryptoKit, AppKit and SwiftUI.

---

## Rules on coding

### The Core/App boundary is the most important rule here

```
Sources/RSTCore/   Foundation + CryptoKit ONLY. No AppKit. No SwiftUI. No system calls.
Sources/RSTApp/    Everything platform-shaped.
```

`RSTCore` takes numbers and dates in and returns decisions and events out. It cannot read
a clock, open a window, or ask the system anything — the current time arrives as a
parameter, never from `Date()`.

A test enforces this by scanning `RSTCore` sources for forbidden imports. **If that test
fails, the fix is to move the code, never to relax the test.**

Why it matters: it is what makes a full day of behaviour testable in milliseconds on a
machine where UI automation does not exist. Every rule that leaks into `RSTApp` becomes a
rule that can only be checked by hand.

### Never call `Date()` outside `SystemClock`

All time goes through the `Clock` protocol. `RST_TIME_SCALE` and every test depend on it,
and a single stray `Date()` makes accelerated testing silently wrong in one place — the
worst kind of wrong, because everything else still looks right.

### Enforcement is opt-in in debug builds

`swift run` must **never** cover the screen unless `RST_ENFORCE=1` is set explicitly.
The installed release `.app` always enforces. Do not "temporarily" invert this to test
something; use `RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30` instead.

### Write the event before dispatching the action

The cover blocks until a PIN arrives, which may be hours. A log line written after the
action is misdated, and lost entirely if the process is killed while covered. Stamp it
with the time of the *decision*.

### Atomic writes for `config.json` and `ledger.json`

Temp file, then `rename`. A crash mid-write must not be able to produce an unparseable
file. This is not theoretical — the app is killed by design in the watchdog path.

### Polish for the child, English for the parent — split at the PIN

If a string can appear **without anyone typing the PIN**, it is Polish: the cover, banners,
spoken lines, the menu-bar dropdown, the PIN dialog. Everything behind the PIN is English:
Settings, the first-run wizard, the event log, the docs.

**Every Polish string lives in `Strings.swift`.** Never inline a user-facing literal in
`CoverWindow`, `Banner` or `MenuBar` — an English string leaking onto the cover is the exact
mistake a bilingual app invites, and one file makes it an audit rather than a hunt.

Full table in `plans/initial-build/DESIGN.md` §2.4.2.

### Comments explain *why*

The code says what it does. Comments are for the reason, and especially for the
non-obvious constraint — `canBecomeKey` must be overridden or the PIN field silently eats
keystrokes; presentation options revert when the app is not frontmost; invalid option
combinations raise. Match the density in `plans/initial-build/DESIGN.md`: dense where
something is surprising, absent where it is not.

### Small commits, one per task

Commit message references the task: `T04: budget ledger and gap classification`.

---

## Things that will bite you

These are known, verified or flagged, and each has cost someone a day somewhere:

- **Borderless `NSWindow` returns `false` from `canBecomeKey`.** The PIN field will accept
  no keystrokes and the cover becomes unopenable. Subclass and override.
- **`NSApp.presentationOptions` only holds while the app is frontmost.** Re-assert on
  `didResignActive` and call `NSApp.activate()`.
- **Invalid presentation-option combinations raise an exception.** `hideMenuBar` requires
  `hideDock`; `disableProcessSwitching` requires `hideDock`. T00 verifies the valid set on
  macOS 26 — do not guess from documentation.
- **Presentation options need `.regular` activation policy.** The app runs `.accessory`
  for its menu bar; switch to `.regular` while covering and back afterwards.
- **`Cmd+Q` is not blocked by presentation options.** Verified the hard way — it closed
  the T00 spike through the full kiosk set. `disableForceQuit` is `Cmd+Opt+Esc`;
  `disableSessionTermination` is Log Out. Refuse it in `applicationShouldTerminate` while
  covering, and assume any quit path you have not personally tested is open.
- **`didChangeScreenParameters` is posted by your own `hideDock`/`hideMenuBar`** — and by
  `toggleFullScreen`. **A re-entrancy boolean does not stop the loop**: the notification
  arrives asynchronously *after* the rebuild finishes, so the flag is already clear.
  Compare the actual screen layout and ignore notifications where nothing changed. This
  looped hundreds of times in 20s during T00 before it was fixed properly.
- **Arm the release before you take the screen, and never on the main run loop.**
  Cost a hard reboot on 2026-08-21: the spike's auto-release was an `NSTimer` scheduled
  at the *end* of the cover routine, and an early `return` above it skipped the timer
  while the windows were already up. A detached thread calling `exit(0)`, started before
  the first window, survives a skipped code path, a deadlocked main thread, and an
  exception `NSApplication` swallowed. `RST_MAX_COVER_SECONDS` must work this way.
- **Never `return` early from a function that has already covered the screen.** Make the
  optional part conditional, not the code path.
- **A crashed app frees the screen; a hung one does not.** This is why the watchdog exists
  and why it calls `exit(0)` rather than trying to clean up.
- **`say` and the speech APIs silently fall back on an unknown voice name.** Verified:
  `say -v "Zosia (Premium)"` with no Premium voice installed returns success and speaks in
  a different voice. Enumerate `AVSpeechSynthesisVoice.speechVoices()`, verify what you got,
  and log it. A warning spoken in the wrong language — or not at all — is invisible to
  everyone except whoever is standing in the room.
- **Timers do not fire across sleep.** Evaluate the 06:00 day rollover from the wall clock on
  every tick. Never schedule a timer for a boundary.
- **`swift run` from a terminal is not a bundled app.** Some AppKit behaviour differs
  outside a real `.app` with an `Info.plist`. Verify anything surprising against the
  assembled bundle before believing it.

---

## Commands

```bash
swift build                      # debug build
make test                        # L1 + L2, headless, no windows, always safe
                                 # (bare `swift test` cannot see Testing.framework)
make bundle                      # assemble + ad-hoc sign dist/RealScreenTime.app
make install                     # bundle, then copy to /Applications

# Manual testing — see plans/initial-build/TESTING.md. These are for me to run, not you:
# ask before any enforcing run, and always with a seatbelt.
swift run RealScreenTime                                    # observer mode, safe
RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30 swift run RealScreenTime
RST_COVER_FRAME=600x400+80+80 RST_ENFORCE=1 swift run RealScreenTime
RST_TIME_SCALE=60 RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30 swift run RealScreenTime

jq -c 'select(.type=="blocked")' ~/Library/Application\ Support/RealScreenTime/events.jsonl
```

### Environment flags

| Flag | Default (debug) | Effect |
|---|---|---|
| `RST_ENFORCE` | `0` | `1` lets the app actually cover the screen |
| `RST_MAX_COVER_SECONDS` | unset | Tear any cover down after N seconds |
| `RST_COVER_FRAME` | unset | `WxH+X+Y` — render the cover into a box, not fullscreen |
| `RST_TIME_SCALE` | `1` | 1 real second = N simulated seconds |
| `RST_DATA_DIR` | `~/Library/Application Support/RealScreenTime` | Redirect all state, for tests |

In a release build `RST_ENFORCE` defaults to `1`; the rest still work.

---

## If you are locked out

`plans/initial-build/RECOVERY.md`. Short version: **reboot and log in as `admin`.**
A LaunchAgent only exists inside a logged-in session — the login window is beyond this app's
reach, always.

---

## Scope discipline

`plans/initial-build/DESIGN.md §8` lists what this app is not, and the list is deliberate:
no per-app limits, no weekday/weekend profiles, no multi-child support, no report UI, no
notarisation. Several of them were considered and declined with reasons.

The known bypasses in §8 are also deliberate. **Do not close them on your own initiative** —
each one costs a root daemon, an XPC helper or a Keychain arms race, and the decision to
pay that was made explicitly and answered no.

---

## Background jobs and worktrees

Background jobs used to be isolated into `.claude/worktrees/` by the harness whether the
task wanted it or not; `.claude/settings.json` sets `worktree.bgIsolation: "none"` to stop
that, so work happens in the main checkout on `main`. The general rule — one checkout, one
branch, and stop if you ever find yourself on another — is in
[Where sessions run](#where-sessions-run) below.

---

## The plans

The project's plans live under `plans/`. `ls plans/` lists them.

- **`plans/initial-build/`** — the whole app, built T00–T21 and closed under the old `work`
  flow before this project moved to `plan-implement-review` (2026-09-04). Its `DESIGN.md` is
  the foundational design every later plan builds on; `PLAN.md`, `PROGRESS.md`, `FINDINGS.md`,
  `tasks/`, and the standing `RECOVERY.md` / `TESTING.md` runbooks live there too. Every task
  is ✅, so `/pir-work` finds nothing to build here.
- **`plans/cr-01-ui-refresh/`** — the next work: the wizard, Settings and menu-bar refresh,
  agreed and not yet built. It holds only the source change request so far; run `/pir-plan`
  on it to split it into tasks, then `/pir-review-plan` before the first `/pir-work`.

---

<!-- ─────────────────────────────────────────────────────────────────────────
     Below is the shared working method (plan-implement-review). Above is this
     project's own machine, rules and traps. The two halves do not repeat each
     other; where the method needs a concrete fact about this project, it points
     up into the half above.
     ───────────────────────────────────────────────────────────────────────── -->

# How we work together

Work on this project is planned once, read back once, and then executed one task at a time,
by sessions that alternate between building and reviewing. Three commands drive it:

| Command | What it does |
|---|---|
| `/pir-plan` | Brainstorm, settle the requirements, show a throwaway mock to confirm the direction when the thing has a feel to it, get the tech right, check what the code already does before planning to build it again, split the work into tasks, and write it all down under `plans/{slug}/` |
| `/pir-review-plan {slug}` | Read that plan back with fresh eyes, before a line of it is built — the gaps, the contradictions, and anything the machine does not actually support. Runs once, and `/pir-work` will not start until it has |
| `/pir-work {slug}` | Do exactly one unit of work on that plan — implement the next task, or review the last one — then stop |

**Read `plans/{slug}/DESIGN.md` before changing behaviour.** Every rule in it was decided
deliberately and most carry a rationale. If you disagree with one, say so — do not quietly
implement something else.

---

## Who you are talking to

I am the product manager. I own **what** gets built and **why**. I do not read the code and
I do not want to — that part is yours.

### Write to me in plain English

No jargon in anything you say to me. When something technical actually matters to a
decision, explain it in ordinary words: keep the reasoning, drop the vocabulary. The test
is whether a sentence would make sense to someone who has never opened this project.

"The app writes each line to the log in one go, so two copies running at once can't garble
each other's" — good. "`O_APPEND` plus a single `write(2)` gives atomicity" — same fact,
useless to me.

If I need a term to make the decision, teach me the term in one line and then use it.

**This applies to what you say, not to what you write down.** Code, comments, commit
messages and everything under `plans/` stay exactly as technical as they are — those are
written for the next session, and dumbing them down would cost the project real accuracy.
The conversation is mine; the files are yours.

### Who decides what

**You decide how.** Technical problems are yours to solve as you meet them — a bug, a bad
structure, a test that needs writing, a better way to build the thing we agreed on. Do not
ask permission to do your job well. Tell me afterwards, in one plain line, that you found
it and fixed it.

**I decide what.** The plan is mine. Come to me *before* you act when:

- the plan itself needs to change — a task split, reordered, dropped or added
- a design rule in `DESIGN.md` is wrong, or is about to be contradicted
- something is **not specified, or half-specified** — especially anything the child or the
  parent would see, hear or do
- there is a genuine choice about how it should behave, and either answer is defensible

Never invent a rule to get unblocked, and never quietly pick whichever is easier to build.
An underspecified requirement is not a gap for you to fill in silently — it is the exact
thing I am here for.

### How to ask me

One decision at a time, laid out like this:

- what you are trying to do, in a sentence
- the options, in plain words, with what each one costs the child or the parent
- **your recommendation**, because you know the machine and I do not
- what you will do if I say nothing

Do everything that does not depend on my answer while you wait. Only stop dead when
guessing wrong would waste the work or be unsafe.

### I am your hands on the real machine

Anything that needs a screen, a camera, a second account, a login, a reboot, a real game,
a real device, a paid API or a browser I will run for you — that is not a gap in the
project, it is my job in it. Give me the exact command and tell me what to look for. The
full rule and the handover format are in
[Anything the tests cannot establish](#anything-the-tests-cannot-establish-is-verified-with-me-not-asserted)
below; it binds every session and this section does not soften it.

**Stop and wait for me.** The moment the work needs my eyes, ask — and then hold there
until I answer. Do not finish the session around it, do not build anything further on top
of an assumption I have not confirmed, and do not leave the check as homework in the final
report. Everything that genuinely does not depend on my answer can be finished first, but
the session ends when the answer is in, not before.

The cost of this is real and I accept it: a session may sit paused while I am away, and
you may need me to start it going again. That is cheaper than a task built on a guess.

---

## The `pir-work` command

**When I say `pir-work`, invoke the `pir-work` skill.** It reads
`plans/{slug}/PROGRESS.md`, picks the one task the queue says is next, and dispatches to
`pir-implement` or `pir-review`:

```
read plans/{slug}/PROGRESS.md
  ├─ plan not reviewed ?   → STOP — /pir-review-plan runs first
  ├─ any task marked 🔍 ?  → REVIEW the lowest-numbered one
  ├─ else any task 🟡 ?    → FINISH it
  └─ else                  → IMPLEMENT the next ⬜ whose dependencies are ✅
```

Then update `PROGRESS.md`, commit, report, **and stop.** One unit of work per `pir-work`.

That is the whole point: the session that reviews a task is never the session that wrote
it. A reviewer holding the implementation in context is not a reviewer, and the alternation
is what buys the fresh eyes.

The skills live in `~/.claude/skills/` and hold the procedures — the dispatch, the review
gate and the blocked-task rule in `pir-work`, the step-by-step in `pir-implement` and
`pir-review`. **Do not invoke `pir-implement` or `pir-review` directly**: `pir-work` chooses
the task, and that choice is what guarantees the alternation. If you want a specific task
built or reviewed out of order, say so to me first.

The rest of this file holds the rules that bind **every** session — the ones that arrived
through `pir-work` and the ones that did not.

### A plan gets read back before it gets built

`/pir-review-plan {slug}` runs once, in a session that did not write the plan, between
`/pir-plan` and the first `/pir-work`. It reads the whole plan for four things: whether the
documents agree with each other, whether the requirements are actually complete, whether the
claims about this machine still hold, and **whether any of it is already built** — a task that
rebuilds something the code already has, instead of extending it, passes every other check
here and is still the wrong thing to build.

**Why it is a separate session, and separate from everything else here:** a mistake in a plan
is copied into every task built from it, and the build-review alternation cannot see it —
`pir-review` checks a task *against* the plan, so a wrong plan passes review task after task.
This is the only pass that questions the plan itself.

**What it may change on its own, and what it must ask about.** Anything with exactly one right
answer — a dependency pointing at a task that does not exist, the same file named two ways, a
version the machine has just contradicted — it fixes and tells me afterwards. Anything that
changes what gets built — a requirement nobody decided, two rules that contradict, a task that
should be split — it brings to me, one at a time, and waits. It reads the whole plan before it
asks me anything, so I see the size of the problem before I answer any part of it.

It marks the plan reviewed in `PROGRESS.md`, and that line is what lets `/pir-work` start. It
will not run on a plan already being built: rewriting the ground under finished work is worse
than the gap it would close, and amending a live plan is my decision.

**The account of that review lives in its commit message and nowhere else** — there is no
review report file. A session that later wonders why a rule says what it says has `git log`.

### Scope is strict

Touch only the task you picked up. Anything else you notice — a missing test in an earlier
task, a stale doc, a better way to do something — goes in the **findings log**,
`plans/{slug}/FINDINGS.md`, and is left alone.

This keeps commits matched to tasks, keeps the review boundary meaningful, and stops a
session sprawling into a rewrite. The findings log exists for exactly this.

### Anything the tests cannot establish is verified with me, not asserted

**The project's test command is the only evidence a session may produce on its own.** Here
that command is `make test`; the concrete table of what it cannot reach — the cover, the
kiosk chords, the camera, the spoken warnings, login and reboot — is
[What cannot be tested headless here](#what-cannot-be-tested-headless-here) in the project
half above. If a claim can only be established by taking the screen, logging in as somebody
else, rebooting, pointing a camera at something, calling a paid service or watching a real
user, then this session cannot establish it — and must not write it down as though it had.
Say what you built, say what it has not been shown to do, and hand me the exact command.

**How to hand it over.** Raise it the moment you need it and **wait for the answer** — see
[I am your hands on the real machine](#i-am-your-hands-on-the-real-machine); it is not
homework left at the end of a report. One block: the exact command including its flags,
what should happen, what to look at, and what to tell you back.

```
Needs you — I cannot see this from here:

  <the exact command, with its seatbelt>

Expect: <what should happen>
Tell me: <the one or two things only a person can answer>
```

**Always with a seatbelt.** Anything that can take the machine, the screen, the account or
the money gets a bound on it — a time limit, a dry-run flag, a spending cap, a scratch
account — and you never ask me to run the unbounded version to find something out. This
project's seatbelt is `RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30`; the flags are in the
project half above. **And do not run the dangerous thing yourself to save me the trouble**:
the seatbelt is what stands between a test and a power cycle.

**Mark it unverified, in `PROGRESS.md` and in the report.** A task whose automated half is
green and whose hands-on half is unchecked is not ✅ on the strength of the tests — say
which half is which, so the next session and I both know what has actually been seen. When
you get an answer back, it goes in **`FINDINGS.md`** with the date: "verified by hand" is
worth as much as any test, and only if it is written down.

Because a session waits for me, a task should rarely *end* with that half unchecked. It
stays a live state for the minutes between asking and hearing back — not a way to close a
session with the question still open.

### Say the way back before you change the live world

The test command reaches the code and nothing else. A deploy, a credential, a DNS record, a
published page, a file on a real device, a resource in a cloud account — these change state
the tests cannot see. Before an action like that, say in one plain line whether it can be
taken back and how: "reversible — the old build redeploys in one command", or "not reversible
— the old token is dead the moment the new one is written."

**The step past a point of no return is a `what`, and `what` is mine.** Stop and ask before
it, even in auto mode, even when the plan implied it: a rotated credential, a deleted
resource, a thing other people can now see, a change to a device I would have to be in the
room to undo. Naming the way back is what turns "I ran the deploy" into "the next step cannot
be undone — confirm": the decision reaching me while it is still a decision, not a report
after it.

A reversible action you own like any other `how`: take it, tell me after in one line. It is
only the irreversible edge that stops for me — a routine redeploy does not.

**When the way back mattered, it goes in `FINDINGS.md` with the date** — the rollback that
worked, or the step that turned out to have none. A reversibility written down once is one
nobody rediscovers at the worst moment.

### Commit messages

```
plan(cr-01-ui-refresh): the wizard, Settings and menu-bar refresh   ← the plan
plan-review(cr-01-ui-refresh): 6 fixes, 3 decisions                 ← the plan read back, before any build
T05: policy decision function                                       ← implementation
T05 review: fix warning threshold                                   ← a fix found while reviewing
T05 review: clean                                                   ← review found nothing; the PROGRESS update is the commit
```

The `plan-review` message is the *only* account of that session, so it is written long — every
fix by name and every decision with its reason. All the others stay short.

### Where sessions run

**Work in the main checkout, on the main branch. Always.** One checkout, one branch, commits
straight onto it — no worktrees, no branch per task, and so nothing to merge, ever. The
review boundary here is the *session*, not the branch: `pir-work` already guarantees that
whoever reviews a task did not write it, and a branch per task buys nothing on top of that
while costing a merge every time.

**If you nevertheless find yourself on a branch or in a worktree, stop and say so.** Folding
it back is a decision about history and it is mine to make — never reach for a merge, a
rebase or a reset on your own initiative.

---

## The files

Each plan is a folder under `plans/`. `ls plans/` lists them.

1. **`plans/{slug}/PROGRESS.md`** — task states and the queue. Always current.
   **Sixty words to a Notes cell**: it is the index, and the account is the commit message.
2. **`plans/{slug}/FINDINGS.md`** — what the build taught, newest first, **forty words a
   row**. **Where "verified by hand with the user" is written down**, and therefore the only
   record that anything was ever seen working for real.
3. **`plans/{slug}/PLAN.md`** — the task list, its phases and dependencies. Written once,
   at plan time; changed only by a decision of mine.
4. **`plans/{slug}/tasks/`** — one file per task: goal, files, interface, acceptance criteria.
5. **`plans/{slug}/DESIGN.md`** — why everything is the way it is, plus the environment and
   the verification contract.

A plan whose product has a feel to it also has **`plans/{slug}/prototype/`** — the throwaway
mock that confirmed the direction before it was designed, kept as a non-binding reference for
the session that later builds the real UI. It is not present in every plan.

`PROGRESS.md` is the handoff and `FINDINGS.md` is the memory. A stale one of either costs
the next session more than it saved this one.

**Both are read at the start of every session, so both are kept short on purpose.** The word
limits above are what stop them growing into a history of the project: when a note wants a
paragraph, the paragraph goes in the commit message. In the project this method came from
they were one file, and it reached 175 000 characters — three quarters of it history about
tasks long closed, re-read in full by every session before it could start.

### Keeping them short is a duty, not an aspiration

That file did not grow because anybody decided to write a history. It grew because every
session appended and no session ever removed, and a limit nobody enforces is a limit that
holds for about a week. So:

**Count the words. "About forty" is how forty becomes ninety.** A budget is per *row*, not
per column: a `FINDINGS.md` row is forty words including whatever the second column holds.

**Whoever appends, compacts.** Before adding to `FINDINGS.md` or `PROGRESS.md`, if the file
is over its ceiling — 60 rows or 15 KB for findings, 12 KB for progress — spend two minutes
shrinking it first. That is the only maintenance either file gets. Merge rows that are one
lesson twice; drop a row whose lesson is now enforced by code, a test or a rule in
`DESIGN.md`, naming where it went; cut a ✅ task's Notes cell to one line once the following
task has been reviewed.

**Two things are never dropped**, only shortened: a ✅ hand-verification row and its date,
because it is the only record that anything was seen working for real; and any term somebody
would grep for — a flag, an error string, a path.

**And fix the over-budget row you walk past.** Not the whole file, not a tidy-up — the one
row you were reading anyway. This is the single exception to the scope rule, it needs no
finding logged, and it is what keeps the ceilings from ever being reached.

### How to write in these files

**Flat prose.** These files are re-read in full by every session, so an ornamental sentence
is not written once — it is paid for on every run for the life of the project.

- One bold phrase in a row at most, and none is better than one.
- No em-dash asides, no clause that is there to sound right, no aphorism.
- Never restate what the row above already said, or what the code and its tests now say for
  themselves.
- If a row reads like it is arguing a case, it is too long. State the fact; the argument is
  in the commit message, which is written for exactly that and costs nothing to skip.

The register is contagious in both directions: a file written in flat prose keeps getting
flat prose appended to it, and one written in epigrams gets epigrams back for ever.

The RST-specific coding rules — the Core/App boundary, `Date()` only in `SystemClock`, the
atomic writes, the Polish/English split — are in the project half at the top of this file,
not repeated here.
