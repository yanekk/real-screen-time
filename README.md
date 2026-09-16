# Real Screen Time

A macOS menu-bar app that grants a child's account screen time in **sessions** — 30 minutes
a day he can start himself, and any more minutes by PIN — covering every display with a window
that ordinary means cannot dismiss whenever no session is running.

**Locked out? → [plans/initial-build/RECOVERY.md](plans/initial-build/RECOVERY.md).** Short version: reboot and log in as
the admin account. That always works.

---

## Why this exists

Apple's Screen Time and the commercial parental-control apps were tried on this machine and
did not hold. They put a dismissible sheet on top of a running session, and a determined
ten-year-old gets past that.

The thing that does work — a root daemon running `launchctl bootout gui/<uid>` — is brutal:
no warning, no save, no negotiation.

This sits between them. It uses macOS's real kiosk lock (`disableProcessSwitching`,
`disableForceQuit`, `disableSessionTermination`), plus a refused `applicationShouldTerminate`
for `Cmd+Q` — which the kiosk options turn out not to cover — so `Cmd+Tab`, `Cmd+Q`,
`Cmd+Opt+Esc` and Apple ▸ Log Out do not get past it — but it warns at 10, 5 and 1 minutes first, and it takes
a PIN.

It is **deliberately visible**: a menu-bar countdown, an explanation on first run, and a log
the parent can read. A feedback device with a boundary, not a trap.

## Status

**Built and reviewed, T00 through T17 — the app is complete.** Phases 0 to 4 are closed:
the core, the event log, the menu bar, the cover, the kiosk lock, the PIN prompt, the spoken
warnings, the hang watchdog, the first-run wizard and the settings window. 371 headless tests
pass in under two seconds, and every platform behaviour that a test cannot reach has been
watched happening on this Mac and written down in
[plans/initial-build/FINDINGS.md](plans/initial-build/FINDINGS.md).

What is left is [T18](plans/initial-build/tasks/T18-ship.md): the manual checklist, the recovery drill, and
putting it on the child's account. Start at [plans/initial-build/PROGRESS.md](plans/initial-build/PROGRESS.md).

| Document | |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Environment, coding rules, and the traps — read before writing code |
| [plans/initial-build/DESIGN.md](plans/initial-build/DESIGN.md) | What it does and why, with the rationale for every decision |
| [plans/initial-build/PLAN.md](plans/initial-build/PLAN.md) | 19 tasks in six phases |
| [plans/initial-build/PROGRESS.md](plans/initial-build/PROGRESS.md) | Task state and the queue — **keep this current** |
| [plans/initial-build/FINDINGS.md](plans/initial-build/FINDINGS.md) | What the build taught, newest first — including everything verified by hand |
| [plans/initial-build/TESTING.md](plans/initial-build/TESTING.md) | How to test this without locking yourself out |
| [plans/initial-build/RECOVERY.md](plans/initial-build/RECOVERY.md) | Getting the Mac back |
| [plans/initial-build/tasks/](plans/initial-build/tasks/) | One file per task |

## Defaults

A 30-minute session, one a day he can start himself, and extra minutes behind the PIN —
15, 30 or 60, picked from a list you can change in `config.json`, as many times as you like.
The day resets at 06:00. Idle for more than 10 minutes pauses the clock — unless something
is playing, which keeps it counting for up to 30 minutes so a film does not read as an empty
chair. No camera is involved, ever. All changeable in Settings.

## Build

```bash
swift build        # requires Swift 6.3+; there is no Xcode project, by design
make test          # headless, no windows, always safe to run
make bundle        # assembles and ad-hoc signs dist/RealScreenTime.app
```

First launch shows a Gatekeeper warning — the app is ad-hoc signed because it never leaves
these machines. Right-click ▸ Open once.

## Setting it up

`make install` puts the app in `/Applications`. Log in as the child, open it once, and
answer four questions:

1. **Welcome** — what the app does, and that none of it is hidden
2. **PIN** — four digits, typed twice. No default, and no way to skip: with no PIN the app
   refuses to cover anything, because nothing would be able to uncover it again
3. **Sessions** — how long a session is, and how many he may start himself each day
4. **Start at login** — installs `~/Library/LaunchAgents/com.krolikowski.realscreentime.agent.plist`,
   which starts the app at login and starts it again if it is killed

No terminal, no `sudo`, no installer script. The answers are written when the setup window
closes — not a step earlier, because writing the PIN is what lets the app cover the screen,
and it would have covered the window step 4 lives in. So once step 3 is answered, closing
the window either way leaves an app that works; only the login item may be missing, and
`Konfiguracja…` in the menu bar reopens the wizard at step 4 to finish it.

The app re-runs the wizard whenever `config.json` is absent or has no PIN in it. A
half-finished setup is not a usable state, and a half-finished setup that enforced would be
a trap.

## Running it safely during development

**Debug builds cannot cover the screen.** Enforcement needs `RST_ENFORCE=1`, typed on
purpose.

```bash
swift run RealScreenTime                                       # observer mode
RST_COVER_FRAME=600x400+80+80 RST_ENFORCE=1 swift run RealScreenTime
RST_TIME_SCALE=60 RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30 swift run RealScreenTime
```

The last one plays a whole day — warnings, cover, PIN, extension, re-block — in about two
minutes, in a box, with a seatbelt.

| Flag | Default | What it does |
|---|---|---|
| `RST_ENFORCE` | `0` in a debug build, `1` in a release one | `1` lets the app actually cover the screen. Anything that is neither `1` nor `0` is read as `0` and warned about, so a typo can never enforce |
| `RST_MAX_COVER_SECONDS` | unset | The seatbelt. Tears any cover down after N seconds, from a detached thread armed **before** the first window — so it survives a skipped code path, a deadlocked main thread, and an exception. **Never take the screen without it** |
| `RST_COVER_FRAME` | unset | `WxH+X+Y` — draw the cover into a box instead of over the display. The safe way to look at it |
| `RST_TIME_SCALE` | `1` | One real second counts as N. `60` plays a 30-minute session in 30 seconds |
| `RST_DATA_DIR` | `~/Library/Application Support/RealScreenTime` | Where config, ledger and log live. Point it at a throwaway directory and a test run cannot touch the real one — **a run without it reads the real data, finds no PIN, and stands down**, which has wasted a run twice |

Four more exist — `RST_SEATBELT_SELFTEST`, `RST_WATCHDOG_SELFTEST`, `RST_WATCHDOG_SECONDS`
and `RST_STALL_SECONDS` — and they belong to `make seatbelt` and `make watchdog` rather than
to a person. Both targets prove a detached safety thread fires on time without ever taking
the screen, and both are safe to run as often as you like.

## Where the data lives

Four files, all in `~/Library/Application Support/RealScreenTime` on the account being
limited — so `/Users/child/Library/Application Support/RealScreenTime`, readable with `sudo`
from the admin account. `RST_DATA_DIR` moves all four at once.

| File | |
|---|---|
| `config.json` | The PIN hash and salt, session length, sessions a day, the grant list, warning thresholds, the reset hour. Edit it here or in Settings; the app rereads it |
| `session.json` | The ledger — what is running, what is left, how many self-service sessions today, and the clean-exit marker that tells a relaunch whether the gap it just slept through was a logout or a kill |
| `events.jsonl` | One JSON object per line, appended and never rewritten. This is the record |
| `app.log` | Diagnostics — what it decided each tick and why. Noisier, and the first place to look when something did not happen |

`config.json` and `session.json` are written to a temp file and renamed, so a crash halfway
through a write cannot leave an unparseable file behind. That matters here because the app is
killed by design: the watchdog ends the process rather than trying to clean up after itself.

If `config.json` ever *is* unreadable, the app moves it aside to `config.json.bad`, writes a
`config_reset` line naming that backup, and starts again from the shipped defaults. Those have
no PIN in them, so it stands down rather than covering anything and reopens the setup window —
the same path as a first launch. Your old file is still there to read.

## Reading the log

There is no report UI, by design. The log is a file.

```bash
LOG=~/Library/Application\ Support/RealScreenTime/events.jsonl

jq -c 'select(.type=="tamper_gap")'    "$LOG"   # was it killed?
jq -c 'select(.type=="extended")'      "$LOG"   # how often was the PIN used?
jq -c 'select(.type=="watchdog_exit")' "$LOG"   # has it been hanging?

# Blocks per calendar day. `.ts[0:10]` is the local date because every line carries its
# UTC offset — which is also why an evening read back across a DST change still reads
# right. Note this groups by midnight, not by the app's 06:00 day: a block after midnight
# lands on the new date here while `n_today` still counts it against the night before.
jq -s 'group_by(.ts[0:10])
       | map({day: .[0].ts[0:10], blocks: [.[] | select(.type=="blocked")] | length})' "$LOG"
```

Every line is `{"ts": …, "type": …}` followed by that event's own fields, so `type` is the
only thing you need to know to grep it. The types are `session_start`,
`session_resume`, `session_end`, `warned`, `blocked`,
`uncovered`, `extended`, `screen_locked`, `disabled`, `rearmed`, `tamper_gap`,
`config_reset`, `config_changed`, `watchdog_exit`, `app_quit`, and `would_cover` — the last
meaning a debug run decided to cover and deliberately did not.

`config_reset` and `config_changed` are deliberately two different words: the first means the
file was unreadable and was replaced, the second means somebody opened Settings and edited it.
Reading the log a year from now, you want to be able to tell your own edit from a corruption.

The fields after `type` come from a closed list, so what you grep for today is what the log
still says next year. `Event.Field` in `Sources/RSTCore/EventLog.swift` is that list, and
adding to it is a deliberate edit there rather than a string typed at a call site:

| Field | Where it appears | What it is |
|---|---|---|
| `n_today` | `session_start`, `extended` | Self-service sessions so far today, counted on the 06:00 day |
| `minutes` | `extended` | The size of the grant — whatever you typed |
| `seconds` | `tamper_gap` | The unexplained gap, charged in full |
| `reason` | `blocked`, `would_cover`, `session_end` | Why it happened |
| `used_s` | `blocked`, `would_cover`, `session_end` | Seconds of the session spent |
| `remaining_s` | `warned`, `session_resume` | Seconds of the session left |
| `threshold` | `warned` | Which warning fired — 10, 5 or 1 |
| `voice` | `warned` | The voice actually used, so a Mac quietly speaking English shows up |
| `name`, `forced` | `app_quit` | What was quit, and whether it had to be forced |
| `by` | `uncovered` | What lifted the cover |
| `until` | `disabled` | When the stand-down re-arms — the next 06:00 |
| `backup` | `config_reset` | Where the unreadable config was moved to |
| `covered_s` | `watchdog_exit` | How long the cover had been up when it gave up |
| `changed` | `config_changed` | What was edited, old value to new — e.g. `session_minutes 30→45`. A PIN change reads `pin_hash changed`, and the PIN itself is never written in either direction |

A line whose fields you do not recognise was written by a newer version and is still valid
JSON — nothing here ever rewrites or removes a line once it is on disk.

## Credit

The architecture — a pure core with a test enforcing the boundary, the PIN gate, the JSONL
event log, and the "deliberately visible, not hidden" stance — is taken from
[omricn/stfu](https://github.com/omricn/stfu), which solves a different problem in the same
house.

## Known gaps

Named and accepted in [DESIGN.md §8](plans/initial-build/DESIGN.md#8-explicitly-out-of-scope): SSH into the
account, hand-editing the ledger, and `launchctl bootout` on his own agent. Every one is
closed by the same thing — a root LaunchDaemon — which is the documented upgrade path if the
cover alone stops being enough.
