# Progress

**Update this file whenever a task changes state.** It is the handoff between sessions —
a stale tracker costs the next session more time than keeping it current ever saves.

**What the build taught lives next door, in [FINDINGS.md](FINDINGS.md)** — read the entries
that touch the task you are picking up, and append yours there. It is where "verified by
hand with the user" is written down. **Sixty words to a Notes cell here, forty to a finding
there**; when a note wants a paragraph, the paragraph belongs in the commit message.

**Plan reviewed:** n/a — this plan was built and closed under the old `work` flow before the
`plan-implement-review` migration (2026-09-04), never through `/pir-review-plan`. Every task
is ✅, so `/pir-work` finds nothing to build here; the line exists only so the gate reads a
value. New work goes in its own plan under `plans/`, not here.

**Status:** **Phase 1 is complete** — `Clock`, `Config`, `PIN`, `DayWindow`, `SessionState`,
`Policy`, the **event log** and the **integration harness** are all done and reviewed, and every
rule in the design is proven headlessly, second by second, in 2 seconds. **Phase 2 is complete too:**
T08 built the real process — it ticks, decides, logs, and cannot cover the screen — T09
gave it the real sensor reads, and **T10 has put it in the menu bar**, so it announces
itself and shows what it thinks the state is. All three are reviewed and closed, which
makes **Phase 2 complete**. **Phase 3 has started: T11 has built the cover and it is now
reviewed and closed** — the app takes the screen, hands it back for a session the child
starts himself, takes it again when the time runs out, and locks the Mac on request, all of
it seen happening rather than inferred. Three of T11's checklist lines need a second display
or a real game and are carried to T12. **T12 is built, its L5 pass is done and it is now reviewed and closed:**
the kiosk holds against every chord on a two-display Mac, both quit defences are measured
rather than assumed, and the review found one real defect — the seatbelt target was measuring
the restored release grace without asserting it — fixed in `373f1c7`. **T13 has built the way
back in and it is now reviewed and closed** — four boxes, one digit each, no confirm button,
then the amount list, on the cover and from the menu bar alike. The review found one real
defect: a PIN salt that was present but unreadable counted as a configured PIN, so the app
covered a screen no PIN could then open — fixed in `20d5454`. Both halves have evidence,
the full-screen two-display cover included. Three of T12's checklist lines are carried
forward, named rather than waived. **T14 has built the warnings and is now reviewed and closed** — chime, spoken
line and banner, for a warning threshold, for the moment the time runs out, and for a grant
behind the PIN. **Both halves have evidence**: 290 green tests, and boxed enforcing runs on
2026-08-25 and 2026-08-26 in which the user heard every announcement, saw the banners,
and confirmed the banner leaves the keyboard alone. He **cut the consequence sentence**
after hearing it, and **DESIGN §2.6.2 was rewritten to match** — the app still quits
fullscreen games, and the case now rests on the warnings existing rather than on their wording.
**The review found three real defects**, the largest of them audible: a break and a `Wznów`
re-spoke the threshold already given, with the bucket’s number rather than the child’s. It also
found that **§2.4’s `Zapisz swoją grę.` had been specified twice and never spoken**, and the user
restored it — three words, on the second-smallest threshold. **Phase 3 is complete.**
**Phase 4 has started: T15 has built the hang watchdog and it is now reviewed and closed** —
a second detached thread beside the seatbelt, counting the silence since the last tick and
ending the process at thirty seconds of it while a cover is up. **Both halves have
evidence**: 311 green tests, a new `make watchdog` self-test that wedges a real main thread
with no windows, and a boxed enforcing run on 2026-08-26 in which the user watched a
deliberately frozen app free the screen by itself. **The review found no defects** and
answered the one question that mattered — nothing on the main thread can legitimately be
silent for thirty seconds under a cover, so the safety net is not a kill switch.
**T17 is reviewed and closed, and with it Phase 4 is complete**: every setting that exists
is reachable behind the PIN, the PIN itself can be changed against the current one, and the
uninstall entry T16 left unbuilt is there. **Both halves have evidence**: 371 green tests and
two observer-mode passes by hand on 2026-08-27 — the window drawn, two refusals, a save
taking effect on the next session, the PIN change, the uninstall, and the review's own fix.
**Two defects, both fixed**: the window was built and never appeared (`01617fd`, found by the
first hand pass), and the sessions-per-day complaint put the cursor in the session-length box
(`8c915e2`, found by the review). **T21 is reviewed and closed (2026-09-04)** — the user's overnight change request, taken before
the deploy: nothing carries across 06:00 now, his own minutes and PIN-granted ones alike, and the
child is told nothing about it.
**T20 is reviewed and closed (2026-09-04)** — the spent-session bug is shut in both charging
paths now: the review found that a gap charges one too, and a reboot eating a PIN grant hit
the same defect on the shipped default (`fbbf76c`).
**T16 is reviewed and closed, and Phase 4 now needs only T17** — four questions, a
PIN typed twice, and a `KeepAlive` LaunchAgent, which together unblock `make install` for the
first time. **The review found one real defect** (`8db4801`): walking back from step 4 killed
step 3's `Continue` outright, because the PIN is hashed and deliberately forgotten on the way
forward and the save still guarded on it. Fixed and verified by hand the same day.
**Model:** sessions, not a daily budget — see [DESIGN §2.1](DESIGN.md). Changed 2026-08-21
after the docs were first written; no code existed yet, so the cost was documentation only
**Last updated:** 2026-09-04
**Next `work` will:** **stop at [T18](tasks/T18-ship.md)** (⛔) — the queue holds nothing else. T21 is closed, so T18's block is lifted on the code side and what remains is the user's hands: the manual checklist and the deploy to `child`.
Nothing carries across 06:00 now, and the review confirmed it on both charging paths: the three
questions it was handed all came back clean — the new `Reconciliation` return type, `.discarded`
being silent everywhere (`endSession` speaks for `.expired` alone), and the redundant-but-kept T14
day-key clear in `tick`. **The code side of the project is done**; everything left is manual.

**[T18](tasks/T18-ship.md) is the only task left** (⛔), and its block is now lifted on the code
side — it was parked at the user's direction so the deploy carries the new rule rather than shipping
twice, and T21 is that rule. Everything still open in T18 needs the user's hands in any case —
the 06:00 count refill, the countdown across a fast user switch, sleep, a `kill -9`, a warning crossed
while switched away, the 30-minute media cap, Safe Mode, and the deploy to `child`. T21 adds one line
to that sheet: a night with a session left unfinished. A throwaway account `rsttest` (uid 503) exists,
with the app installed and PIN 1234; a drill sheet and two helper scripts live in `/Users/Shared/rst-drill/`.

**One question is still open for the user**, raised by T17 and unanswered: whether shortening
a session mid-flight should cut the running one short. It would be a change to T04's ledger
and wants its own task; the window currently says what will happen instead.

> ⚠️ **`make install` is no longer blocked.** T16 has built the wizard, so an installed
> build asks for a PIN on its first launch instead of standing down for want of one — and
> the wizard was completed on the installed `.app` by hand on 2026-08-26, so this is seen
> rather than inferred. Everything it wrote was removed afterwards.

> 📌 **The scratch data dirs are gone**, at the user's direction 2026-08-26 — both
> `rst-t14` and `rst-t12`. A hand run now makes its own: point `RST_DATA_DIR` somewhere
> disposable and let T16's wizard write the PIN. **T18 has one ready at `/tmp/rst-t18`** —
> PIN 1234, 3-minute sessions, warnings at 2 and 1 — in `/tmp` so a reboot clears it.

**What T09 built:** `SystemSensors` in `Sources/RSTApp/Sensors.swift` — idle seconds from
`CGEventSource`, lock state and fast user switching from the session dictionary with the
notifications behind them, and media playback from the display-sleep assertion. `StubSensors`
is gone. **All four APIs were probed on this machine before the code was written** and two
traps in the task doc's own recipe turned out to be real; see the findings.

**✅ T09 is reviewed and closed.** Both halves have evidence: the user's observer
transcript of 2026-08-23 for the platform half, 195 green tests plus a re-probe of all
three system APIs for the headless half. **The review found one real defect and fixed it**
(`b31ac00`) — the idle-break narration measured the break from the idle counter, which
stops with the ticks across sleep, so an overnight absence logged as ten minutes. All four
of T09's recorded deviations were examined and endorsed.

**Review queue: empty.** T21 was reviewed and closed 2026-09-04. **[T18](tasks/T18-ship.md) is the only task left** (⛔): everything left in T18 needs the user's hands, and the deploy must carry T21's rule. T18's §1 gained T21's line, and its ticked `Sleep 20 min` row is annotated — that night's evidence recorded the *old* rule and would now read as a charge.

**What T14 built:** `Announcement`, `PolishNumeral` and `VoiceChoice` in `RSTCore`; `Voice.swift`
(the only file that imports `AVFoundation`), `Banner.swift` and `Warner.swift` in `RSTApp`. `Engine`
now fires three announcements down one path — a warning threshold, the expiry line, and the parent's
grant — each once, and none of them while another user has the console.

**Its deviations from the task doc, and what made them:**

- **`Enforcing.announce` takes an `Announcement`**, not a threshold and a remainder. The expiry
  row of §2.4's table and §2.5's grant confirmation travel the same path, and one method is one
  place for the off-console rule to live.
- **The expiry line and the grant are `Engine`'s**, not the call sites'. Both were about to be
  fired from `RSTApp`, where no test can reach them.
- **An observer run stays silent** — the user's decision, 2026-08-25. It costs T14 its cheap
  verification route and keeps the safe run's promise absolute.
- **The consequence sentence is gone entirely** — the user's, after hearing it: it was three
  sentences a session, each longer than the fact it delivered. §2.4's table is spoken exactly as
  written, and **DESIGN §2.6.2 was rewritten the same day**, at the user's direction, to rest on
  the warnings existing rather than on their wording.
- **Numbers are spoken as digits**, except `1` and anything ending in `2`, where a Polish voice
  reads the digit in the wrong gender. The user's, over writing a Polish number-speller.
- **The three pings start 0.45 s apart**, not strictly end to end: `Ping.aiff` is 1.5 s and nearly
  all of it is decay, so back-to-back would put 4.5 s between the trigger and the first word.
- **The `warned` event's `voice` field** is filled through a new `Enforcing.announcerVoice`.
  `Engine` writes the event and cannot ask `AVFoundation` anything.
- **The expiry gets no banner** (§2.4 gives that row the cover) and says `Czas minął.` without the
  strings table's `Do zobaczenia jutro.`, which T11 had already dropped from the cover.
- **The day-rollover reset is asserted on state, not behaviour.** A remainder only ever falls, so
  nothing observable changes with the line removed; `Engine.announced` is internal for that one test.

**Two changes landed outside the queue on 2026-08-23**, both at the user's instruction and
both recorded in the findings log. The second is a **model change**: the PIN grant is now
**picked from a list** (`extension_options`, shipping 15/30/60) rather than typed, which
reverses part of 2026-08-22's free-text box. `Config` changed; **T13 built that dialog and it
is ✅**. The first:
`e7b0c04` clamps `SessionState.remainingSeconds` at every write, which kills the
crash T10's review found in `MenuBarModel` and the three siblings of it in `RSTApp` that
the same review had logged as out of scope. **No task changed state and no task was
started** — T04 and T08 stay ✅, the fix is in the findings log, and the next `work` still
picks up T11.

**What T10 built:** `MenuBarModel` in `Sources/RSTCore/MenuBarModel.swift` — the whole
display rule as a value — plus `Strings.swift` and `MenuBar.swift` in `RSTApp`, and one
line at the end of `AppController.tick`. 23 new tests, 3 more from the review, and 5 from the
out-of-queue fix that followed it — suite **226 in 1.9s**.
**Both halves have evidence:** 221 green tests, and the user's two observer runs of
2026-08-23 confirming the icon, both glyphs, the greyed 🔒 items and the Finder reveal.
**Nothing about the countdown itself can be seen until T11 or T13 lands**, and the task
doc says so in advance: nothing in the app can start a session yet.

**✅ T10 is reviewed and closed. The review found one real defect and fixed it**
(`f8d60c3`): the countdown converted the remainder to an integer with no upper bound, and
that conversion **crashes** past `Int.max` — so `session_minutes: 9223372036854775807` in
the child's own `config.json` killed the app on the first tick after a session started.
Clamped at `999:59:59`, with a NaN reading `00:00:00`; three tests, each of which takes the
test binary down against the unfixed code. All four recorded deviations were examined and
endorsed, one unrecorded one was caught and endorsed too (the SF Symbol icon), and
**DESIGN §3.2 has been corrected as the implementing session asked** — `MenuBarModel.swift`
now has a Core row and the move has the third paragraph the loop and the flags each got.
**Two carried items, both flagged in advance by the task doc, are now T11's and T12's** —
see the findings. **One out-of-scope sibling of the defect is logged and left alone:** the
same unbounded conversion is in `AppController.start`, T08's file and reviewed.

**What T11 built:** `CoverModel` in `Sources/RSTCore/CoverModel.swift` — the four faces and
their buttons as a value — plus `Decision.offersSelfServiceStart`, and six files in `RSTApp`:
`CoverWindow` (the `canBecomeKey` override and the content view), `CoverController` (one
window per `NSScreen`, the layout-signature rebuild, the teardown redraw), `CoverEnforcer`
(the `Enforcing` half that really covers, and the three commands the buttons issue),
`Seatbelt`, `ScreenLock` and `FullscreenApps`. 26 new tests, suite **254 in 1.9s**.

**Both halves have evidence, and the platform half is unusually well covered for this
project** — see the three findings dated 2026-08-23 below. What the user watched happen, in
a 600×400 box: the cover up on launch, `Rozpocznij` taking it down and starting the session,
the session running its full 30 minutes, **the cover coming back by itself when the time ran
out**, the menu bar counting down beside it, and `SACLockScreenImmediate` resolving at
startup so the button is the real `Zablokuj ekran`. The event log for that run reads
`blocked` → `session_start` → `uncovered by started` → `warned` ×2 → `session_end expired
used_s 1800` → `blocked expired`, which is the canonical evening in seven lines.

**What is still unverified, and why** — **narrowed by the review on 2026-08-23**, which put
six more of these to the user in a box: the cover above ordinary windows, following a Space
switch, the seatbelt tearing it down, the `self_service_sessions_per_day: 0` face, `Wznów`,
and `Zablokuj ekran` actually locking are now all **seen**. What is left needs hardware or a
real game and is **T12's manual pass, not waived**: one window per display, plugging one in
while covered, evicting a fullscreen app, and the teardown redraw against T00's orphaned
frame. **The seatbelt is proven twice over**: `make seatbelt` runs the real watcher thread,
armed the real way, with no window and the process exits on time — and the user has now
watched it take a real cover down at 90 s.

Legend: ⬜ not started · 🟡 in progress · **🔍 implemented, awaiting review** · ✅ reviewed
and done · ⛔ blocked, needs a human

**🔍 is the handoff state.** A session that implements a task marks it 🔍 and stops. The
next `work` reviews it — see [CLAUDE.md](../CLAUDE.md#the-work-command). A task is never
implemented and reviewed by the same session.

---

## Phase 0 — Prove the ground

| | Task | Notes |
|---|---|---|
| ✅ | [T00](tasks/T00-kiosk-spike.md) Kiosk spike | **Done — it answered what it existed to answer.** Kiosk options verified; cover holds against Cmd+Tab, Cmd+Q, Cmd+Opt+Esc, Ctrl+Cmd+Q and Mission Control; `canBecomeKey` works; quitting a fullscreen app then covering works on two games; `SACLockScreenImmediate` locks instantly. Two loose ends deliberately **not** left blocking: Safe Mode (open question below, and on T18's checklist) and exercising `applicationShouldTerminate` (T12 implements and tests both layers). Neither gates any code. Delete `spike/` at T18 |

## Phase 1 — Foundation (headless)

| | Task | Notes |
|---|---|---|
| ✅ | [T01](tasks/T01-package-skeleton.md) Package skeleton | Implemented and reviewed 2026-08-22. Every "Done when" verified by hand: `swift build`, `make test`, `make bundle`, the bundle launches through `open`, and the boundary test fails on a planted import. **Review changed the boundary test from a denylist to an allowlist** and fixed two latent traps in bundle assembly — see the three findings dated 2026-08-22 below |
| ✅ | [T02](tasks/T02-clock-config-pin.md) Clock, config, PIN | Implemented and reviewed 2026-08-22. `Clock`/`SystemClock`/`FakeClock`/`ScaledClock`, `Config` + `ConfigStore` (atomic, corrupt-file quarantine, unknown-key preservation), PBKDF2-HMAC-SHA256 PIN. 31 tests, 2.1s. **Two deviations from the task doc, both deliberate:** `ScaledClock` takes an injected wall clock rather than calling the `Date` initialiser itself (the doc's snippet would have been the second such call in `RSTCore`), and `ConfigStore.load()` *returns* a `.reset` outcome instead of logging `config_reset` — Core has no event log and no clock, so **T08 must log the event when it sees that outcome**. `hashPIN`/`verifyPIN` gained a defaulted `rounds:` parameter so the tests are not 0.5s each. **Review found one real defect** — `verifyPIN` derived as many bytes as the stored hash decoded to, see the finding below — plus a false claim about the KDF's reference vectors. Both fixed in `a2c620c`; 34 tests, 2.1s. Everything else held: all five "Done when"/test-list items verified, `grep -rn 'Date()' Sources/` returns exactly the one hit in `SystemClock`, the unknown-key preservation cannot lose a key (it copies only keys outside `Config.jsonKeys`, and known keys always win — tested), and `hashPIN("") == ""` is right per DESIGN §6/§2.5 |
| ✅ | [T03](tasks/T03-day-window.md) Day window | Implemented 2026-08-22. `DayWindow.dayKey`/`nextReset` and `ClockText.parse`/`format`. 19 tests, suite now 53 in 2.0s. No curfew, as §2.1 says; `ClockText` is unused and kept for the start window. **Three deviations from the task doc's interface snippet, all deliberate:** `nextReset` takes a `calendar:` parameter the snippet omits (without one it would read `Calendar.current` — an ambient system query `RSTCore` does not make, and the reason the DST cases are testable at all); `DayWindow` is an `enum` rather than a `struct`, matching `ClockText` and leaving nothing to instantiate; and `day_reset_hour` is **clamped at the point of use** to 0...23, which is the open config-validation question being answered for this task only — see the finding below. Callers are unaffected in all three cases. **Reviewed 2026-08-22 — clean, no fix commit.** Every "Done when" item and every test the doc lists is present and passing (53 tests, 2.0s); the DST cases are real ones — 2026-03-29 and 2026-10-25 in a fixed `Europe/Warsaw` calendar, asserting the reset-to-reset intervals really are 23h and 25h — the boundary test is green and `grep -rn 'Date()' Sources/` still returns only `SystemClock`. Probed well past the doc: `nextReset` and `dayKey` agree at **all 24 reset hours** on both Warsaw transition days; over a year in seven zones (including the 30- and 45-minute-offset ones) `nextReset` is always strictly after `now`, never more than 26h away, and lands on exactly the instant the key changes; a ~18 000-case parser fuzz produced no out-of-range minute and no round-trip failure. The three interface deviations are all sound. One genuine property surfaced that Warsaw cannot reach — the **day-key regression** finding below, which is T04's to handle, not T03's |
| ✅ | [T04](tasks/T04-session-state.md) Session state and gap charging | Implemented 2026-08-22. `Ledger.swift`: `SessionState`, `Snapshot`, `ExitKind`, `Gap`, `SessionStore` (`Presence` too, until T19 was dropped 2026-08-27). Self-service counts are **keyed by day string** per T03's finding, not a counter reset on change. **Reviewed 2026-08-22 — one real defect, fixed in `1013ec5`; suite now 102 in 2.1s.** The defect: `rollOverIfNeeded` cleared `wasRunning` on a spent session at 06:00 but left `isLive` set, and `remaining == 0 && isLive` is the *expired* quadrant — so a session that ran out overnight on a machine left logged in read as `Czas minął` on the morning its allowance came back, the two halves of T05's reading disagreeing. Every "Done when" item and every line of the doc's test list is present and passing, and the day-boundary-inside-a-gap case the "Done when" singles out is real (a 7200s unexplained gap across 06:00 floors the session and opens today at a full allowance). The four recorded departures all hold up: the **`.absent`-at-60s line was the doc's error, not the code's** — the since-deleted DESIGN §2.2.1 sampled the camera *only* while `idle > idleGrace && mediaPlaying`, so the state was unreachable — and both that line and TESTING.md's copy are corrected rather than left to be rediscovered; `isLive`, the `calendar` parameter and the day-keyed map are all sound. Probed past the doc: the truth-table test's oracle is an independent expression, so guard *order* is pinned and not just the outcomes; `pruneHistory`'s `keep.insert(key)` was **exercised by nothing** and a test now pins it (without it, a clock that spent a fortnight in the future drops today's count and hands out a fresh allowance); a backwards clock charges nothing and does not sit out the difference; negative `session_minutes`, `idle_grace_seconds` and `media_grace_seconds` off a hand-edited file all clamp. Two behaviours differ from the doc's prose and are recorded below rather than changed: a **corrupt ledger classifies `.rebooted`, not `.unexplained`**, so T06 must log the tamper from the load outcome; and `startSelfService` trusts the stored `dayKey`, so T05 must reconcile first. Headless only — nothing in T04 touches the screen, so there is no platform half to leave unverified |
| ✅ | [T05](tasks/T05-policy.md) Policy decision function | Implemented 2026-08-22, **reviewed 2026-08-22 — one fix, comments only.** Every "Done when" item verified: all six `Decision` cases reached, both `dormant` routes, the four quadrants swept exhaustively, the warning ladder at 15:00 / 14:59 / 10:00 / 5:01 / 5:00 / 1:00 / 0:59, `.expired` extended back to `.allowed` and spent again, three stacked extensions at 45 minutes, resume across a real JSON round-trip, and the 06:00 rollover — 122 tests green, `swift build` clean. Read for vacuous tests too: none found, and `LedgerTests`' 46 rewritten call sites are a mechanical rename to a `sensors(...)` factory that weakens no assertion. **The four recorded deviations all hold up** — the two extra `Snapshot` fields are load-bearing (without them two of the six decisions cannot be expressed), the required `now` is right, the three additions are each small and used, and the clamp-at-point-of-use answer is argued rather than assumed. **The fix:** `SessionState.isLive`'s quadrant table keyed its bottom row on `isLive`, where `decide` reads `wasRunning` — see the findings log. **One unrecorded deviation, harmless:** `Snapshot`'s fields are `var` where the task doc and DESIGN §3.2 both show `let`, which `applying(_:_:)` and the sensor-mutating tests need; it is a value type, so nothing escapes. **Probed past the doc:** a clock stepped backwards (no calendar in `decide` at all — `disabledUntil` is the only date and it is compared against the `now` it was handed, so DST cannot reach it); a negative `sessionRemaining` (lands on the cover, asserted); a hand-edited `warning_minutes: [1000]` (warns on every session, but the enforcer de-duplicates per threshold per day and the clamp philosophy is deliberately to leave a typed value visible for T17 — not a defect); and a negative self-service count in `session.json`, which hands out extra sessions and is DESIGN §8's accepted "child owns his home directory" bypass, not a new one. Two forward findings logged for T08 and T11. **Headless is the whole of this task** — `decide` is a pure function and nothing in it needs the screen |
| ✅ | [T06](tasks/T06-event-log.md) Event log | Implemented 2026-08-22, **reviewed 2026-08-22 — one fix, documentation only.** `EventType` (15 cases, `CaseIterable`), `EventValue`, `Event` with `encoded(timeZone:)`/`line(timeZone:)`/`init?(line:)`, `EventSink`, `FileEventSink` (`O_APPEND` + one `write` per line), `MemoryEventSink`, `NullEventSink` — all in `Sources/RSTCore/EventLog.swift`. **26 tests, suite 150 in 2.2s, green.** Both halves of "Done when" are headless and the review re-did both independently: `make test`, and a fresh 17-event two-day scenario compiled straight against `EventLog.swift` and played through `FileEventSink` — the file reads without a schema and all four README `jq` recipes run against it. **All four recorded deviations hold**: the type list is DESIGN §3.5 ∪ `would_cover` (checked against both documents — DESIGN is the authority and the union loses nothing); the injected `timeZone` with no default is the Core boundary doing its job; the missing integer case is what makes the round-trip exact rather than nearly exact (verified: `5400` is written, and comes back `.number(5400)`); and the absent factory functions are a real cost, logged below for T07/T08. **Probed past the doc** and everything held: `nan`/`inf`/`1e20`/`-0.0`, an empty key, a Polish key, `9007199254740993`, pre-1970 and 2100 timestamps — all still valid JSON, all round-trip except the non-finites, which degrade to strings deliberately; `app.log` gets exactly one line per failure, ending in one newline; a second `FileEventSink` on the same directory appends rather than truncates. **The one fix is to the README's daily-count recipe** — it groups by midnight where the app's day rolls at 06:00 — plus two findings left as findings — **both since fixed at the user's instruction**, in `Event.Field` and in `appendLine`; see their rows below. Suite 158 after that work |
| ✅ | [T07](tasks/T07-integration-harness.md) Integration harness | Implemented 2026-08-22, **reviewed 2026-08-22 — one real defect, fixed.** **Phase 1 exit gate, and it holds.** `Sources/RSTCore/Engine.swift`: `Enforcing`, `NullEnforcer`, `CoverReason`/`EndReason`/`UncoverReason`, and `Engine` — `launch`/`expectedExit`, `tick`, and the six commands. `Tests/RSTCoreTests/Harness.swift` models runs as processes; `IntegrationTests.swift` holds the scenarios. **Suite 175 → 178 in 2.0s.** **The gate was re-verified independently, with three planted rules the implementing session did not use** — the warning boundary turned exclusive, `.expired` collapsed into `.awaitingStart`, and a sensor rule (`screenLocked → .dormant`) added to `decide`. All three fail the integration suite, not merely `PolicyTests`; the canonical evening and both DST days name the offending line with a timestamp. Every item on the doc's "Also scripted" list is present and real (killed / slept / rebooted / disabled / logout / expired-then-logout / shared machine / film vs game / no PIN / DST), and the tests were read for vacuity — none found. **The defect: `launch` reported the gap where `tick` reports the decrement.** A gap longer than the session wrote `session_end used_s=1800` for a session that only ever held 1200 — a number larger than the session existed to hold, in the log that exists as evidence. Fixed in `Engine.launch` (`max(0, before - remainingSeconds)`, the expression `tick` already used) plus a clamped/exact-fit test pair; the clamped one is verified to fail against the unfixed code. **All four recorded deviations hold up.** The tick loop in Core is right and DESIGN §3.2's module table has been corrected to match rather than left as a finding — `Engine.swift` now has a row, `Enforcer.swift` keeps only the implementations, and §3.2 carries a paragraph on why. The ten-minutes-earlier timeline is DESIGN §2.2 read correctly (the predicate *and* the prose both charge the grace, so the doc's arithmetic was wrong, not the code's); 18:00 is `.expired(0)` because `wasRunning` survives the logout; and `ScriptedSensors` deriving idle from a last-input time is better than the doc's per-tick table. **Traps all clean:** `grep -rn 'Date()' Sources/` returns only `SystemClock`, `RSTCore` imports Foundation and CryptoKit only, no user-facing string is in Core, and every event is appended *before* the enforcer is called. **Probed well past the doc:** a clock stepped backwards mid-run (charges nothing for the step and resumes from the new now — no free time); a negative grant (clamped, and the `extended` line records the clamped `0` rather than what was typed); a relaunch *inside* a stand-down (dormant, `disabledUntil` survives the JSON round trip, `rearmed` still fires at 06:00); a gap exactly the size of the remainder. **Two findings**, both below. The first turned into a second fix the same day: minutes granted while the app was stood down drained behind a free screen — raised with the user, who ruled that a grant switches the app back on, and `Engine.extend` now does (DESIGN §2.5 states the rule; suite 178). The second is left as a finding: a grant that stays inside the same warning threshold announces it twice. **Headless is the whole of this task** — nothing in T07 touches the screen, a camera or a second account, so there is no unverified platform half |
## Phase 2 — Real app, observer mode

| | Task | Notes |
|---|---|---|
| ✅ | [T08](tasks/T08-app-shell.md) App shell and flags | **Reviewed 2026-08-22 — one defect found and fixed, three judgements endorsed, one unrecorded deviation caught.** The defect: `RST_MAX_COVER_SECONDS` checked `> 0` but not `isFinite`, so `inf`, `infinity` and `1e400` all parsed as `Double.infinity` and were accepted as a seatbelt that can never fire — a run that believes it is protected, takes the screen and is never torn down, which is the one failure mode that flag exists to prevent. `RST_TIME_SCALE` beside it already guarded `isFinite`; this was the missing half of the pair. Five values added to the parameterised test, three of which fail against the unfixed parser (checked by stashing the fix and re-running). Suite still **195 in 1.8 s**. **Unrecorded deviation:** §3.2's T07 paragraph said in as many words that "the timer really does stay in `main.swift`", and T08 moved it to a new `AppController`. Sound — `main.swift` keeps the assembly, and the timer, the notifications and the signals get one owner — so **DESIGN §3.2 now says so**, and gained rows for `Flags.swift`, `AppController.swift`, `SingleInstance.swift` and `Diagnostics.swift`. **Probed beyond the doc, all clean:** the clean-exit marker's delivery path (see the finding — measured, not assumed); `exitKind` re-armed to `.unknown` by `reconcile`, so a kill after a wake is still charged; `charged`, `savedState` and the heartbeat floor across a backwards clock step; `CoverFrame` against unicode digits, `++`, overflow and trailing whitespace, all of which fail safe with a warning; the `SIGTERM`/`SIGINT` sources against a mid-tick arrival (both on the main queue, so serialised); and the Core boundary and the single-`Date()` rule, both still exact. Original implementation note follows. — Implemented 2026-08-22. **Headless half green; the platform half was verified by hand with the user the same day** — see the finding. What remains unverified is only what T08 cannot reach: sleep/wake, `SIGTERM`, and a logout. `RSTApp` is now six files: `main.swift` (flags, data directory, single instance, assembly — all of it *before* `NSApplication.run()`, because T00 showed a throw inside `applicationDidFinishLaunching` hangs instead of crashing), `AppController` (the 1s timer, the tick, `session.json` persistence, sleep/wake, signals), `Enforcer` (`ObserverEnforcer`), `Sensors` (T09's protocol with an always-active stub, plus `kern.boottime`), `SingleInstance` (`flock`) and `Diagnostics` (`app.log`). **Flag parsing is in `RSTCore`** — see the finding, and item 1 above. **17 new tests, suite 178 → 195 in 1.9s**, all of them on `Flags`: the safety default both ways, every near-miss of `RST_ENFORCE=1`, the values that would trap `ScaledClock`, and 12 malformed `RST_COVER_FRAME` strings. **Deviations from the task doc, each with a finding below:** no `session_start` on launch (the doc predates the session model); `SIGTERM`/`SIGINT` also write the clean-exit marker, and sleep stops the timer, which the doc does not ask for and DESIGN §2.3 needs; `tamper_gap` for a corrupt ledger carries `seconds: 0`, the charge rather than the unknowable length; an unreadable `kern.boottime` charges gaps in full. **Three small additions to reviewed Core files**, each because T08 is the first caller: `CoverReason(for:)` made public (the enforcer needs the engine's mapping), `FileEventSink.note` for `app.log`, and `Event.Field.backup` widened to cover a quarantined `session.json`. **`RST_MAX_COVER_SECONDS` and `RST_COVER_FRAME` are parsed and logged but nothing consumes them yet** — there is no cover until T11, and the watchdog thread that arms the seatbelt is T11/T15's to start before the first window. **`RST_ENFORCE=1` currently observes** and says so on stderr and in `app.log`. **Verified by hand 2026-08-22** (user at the keyboard): the process starts, nothing appears on screen, the three files are written, the two cover events land at launch, a concurrent second launch exits on the `flock`, and Ctrl-C leaves `"exit_kind": "expected"`. The one blemish it found — a raw Swift value printed into `app.log` — is fixed in the same commit |
| ✅ | [T09](tasks/T09-sensors.md) Sensors | Implemented 2026-08-22, **platform half verified by hand with the user 2026-08-23 — all four sensors correct, plus the idle break and a fullscreen game** (transcript in the findings log). **Headless half green: 195 tests, 1.9 s — unchanged, and that is the honest number: T09 adds no testable rule, only system reads.** `SystemSensors` replaces `StubSensors`: idle from `CGEventSource.secondsSinceLastEventType(.hidSystemState, ~0)`, lock and fast user switching from `CGSessionCopyCurrentDictionary`, media from `IOPMCopyAssertionsStatus`. **Every failed read defaults towards charging**, so a broken sensor is not a bypass — `onConsole` defaults true, `locked` false, and `mediaPlaying` false, which shortens the grace from 30 min to 10 rather than lengthening it. **Deviations from the task doc, each deliberate:** (a) **the session dictionary is polled every tick and is the source of truth for both `screenLocked` and `sessionOnConsole`; the doc's `DistributedNotificationCenter` and `NSWorkspace` notifications are still wired but only as the fallback for a dictionary that will not read** — a poll cannot miss an edge and is right at launch without having had to witness the transition, which is exactly what the doc asks for under *Start-up state matters too*, and a missed unlock notification would otherwise strand the app believing the screen is locked and hand out an evening of free time; (b) `Sensing` is now **`@MainActor`**, which T08's note said would not change — a `@MainActor` conformer cannot satisfy a non-isolated requirement, and the doc itself says to make the sensor an `@MainActor` type, so the alternative was `MainActor.assumeIsolated` at every call site; (c) **sleep/wake and `kern.boottime` are not touched** — T08 already built both, and DESIGN §3.2's `Sensors.swift` row has been corrected to say so rather than left stale; (d) **two logging additions the doc does not ask for**, without which T09's own acceptance criterion cannot be checked by anybody: `SystemSensors` writes one `app.log` line per change of a boolean sensor plus the full reading at launch, and `AppController.narrateIdle` writes two lines per idle break against the configured grace. A lunch break is otherwise invisible in every file the app writes. **No new tests, and no test target was added for `RSTApp`** — the doc says these are system reads and not unit-testable, and a test asserting that a dictionary lookup returns what was put in it would be theatre **Reviewed 2026-08-23 — one defect found and fixed (`b31ac00`), four deviations endorsed.** *The defect:* `AppController.narrateIdle` reported the resume line from the previous tick's idle counter, and ticks stop across sleep (`willSleep` invalidates the timer), so the first tick after an overnight logged **“input resumed after 10 min idle” for an eight-hour absence** — the line a parent is most likely to read the next morning, and a direct contradiction of T09's own acceptance criterion. Now measured from the wall clock via `idleBreakBegan`, back-dated to the last input so the whole break is reported rather than only its part past the grace; the grace is also clamped with `max(0,)` so it compares against the same boundary `Ledger.isActive` does. *Endorsed:* (a) poll-as-truth is **better** than the doc's notification-only design, not merely acceptable — `> grace` in the narration is the exact complement of `isActive`'s `<= grace`, and the fallbacks are near-dead code by design; (b) forced by the type system; (c) correct, and DESIGN §3.2's row now says so; (d) justified — without those lines the acceptance criterion is uncheckable. *Probed beyond the doc:* **all three system APIs re-run headlessly on this machine during the review** — `CGEventType(rawValue: ~0)` is non-nil so the force-unwrap cannot trap, `kCGSessionOnConsoleKey` really expands to `kCGSSessionOnConsoleKey`, `CGSSessionScreenIsLocked` really is absent when unlocked, and `PreventUserIdleDisplaySleep` read 0 with nothing playing while `PreventUserIdleSystemSleep` read 1 — both of the task doc's traps confirmed a second time. **`systemBootTime()` verified against `sysctl -n kern.boottime` and matches to the second**, which closes the doc's fourth checklist item headlessly. Also confirmed `make test` really does compile `RSTApp` (it does), that `sensors.read()` has exactly one call site, that no `Date()` escaped `SystemClock`, and that the new strings are all English `app.log` lines and so on the correct side of the PIN split. **Still unverified, and not T09's:** “sleep 20 min → nothing charged” — T09 contains no sleep code (it is T08's, reviewed) and the item is already on T18's checklist |
| ✅ | [T10](tasks/T10-menu-bar.md) Menu bar countdown | **Reviewed 2026-08-23 — one real defect found and fixed (`f8d60c3`), five deviations endorsed, DESIGN §3.2 corrected.** *The defect:* `MenuBarModel.clockText` converted the remainder to an `Int` with no upper bound, and that conversion **traps** past `Int.max`. Nothing bounds a session length — `Ledger.fullSession` is `Double(max(0, sessionMinutes)) * 60` with no upper clamp and `session.json`'s `remaining_seconds` is decoded straight, both files the child owns (§8) — so `session_minutes: 9223372036854775807` in `config.json` makes a 5.5 × 10²⁰-second session and the **first tick after `Rozpocznij` kills the process**, taking the parent's own status indicator with it. Not a new bypass (he can already type a large honest number) but a far worse failure than the absurd number it now shows: clamped into `0...999:59:59`, `max` before `min` so a NaN reads `00:00:00` rather than trapping too. Three tests, **each verified to take the whole test binary down against the unfixed code** (signal 5, with the trap's own message). Suite **221 in 1.9 s**. *Endorsed:* the model living in Core is the same move `Flags.swift` and `Engine.swift` made and it bought 26 tests that could not otherwise exist; the tint following `decide`'s own `.warning` case gives the default the doc's exact 10 minutes while keeping the orange and the spoken warning one number rather than two that can drift; the 🔒 items shipping visible-and-disabled is right, and `Zakończ` wired to nothing would be a one-click bypass; the padlock on the end of the label is what `NSMenu` allows. *One unrecorded deviation, caught and endorsed:* the icon is the **`timer` SF Symbol as a template image**, not the doc's literal `⏱` — an emoji would stay coloured on a dark menu bar instead of inverting with it, and `contentTintColor` then turns the glyph orange with the digits in one line. *Probed beyond the doc:* the whole trap class the fix came from (`1e30`, `.infinity`, `.greatestFiniteMagnitude`, `Double(Int.max) * 60`, `.nan`, `-.infinity`, and the same values through a `Decision`); the tests read for vacuity — none found, the equality cases in particular pin the tint and the menu lines separately, so a model that compared only the title would fail; the first-tick gap (`AppController.start` ticks once immediately, so the item is populated before the run loop starts, and `displayed == nil` is never displayed); the timer's `.common` run-loop mode, which is what stops the countdown and the ledger freezing whenever the menu is open (already there from T08, and the comment already credits T10); the Polish audit — `grep` for Polish characters across `Sources/` returns **only comments** outside `Strings.swift`, and all seven menu strings are in it; `grep -rn 'Date()' Sources/` still returns exactly `SystemClock`; `RSTCore` still imports only Foundation and CryptoKit; and `swift build` is warning-clean. *Both halves have evidence:* 221 tests, and the user's two observer runs of 2026-08-23. **Two "Done when" items remain unreachable and are carried, not waived** — the countdown tracking the ledger for an hour needs something that can start a session (T11 or T13), and the activation-policy round trip needs the switch T12 adds; the task doc predicted both |

## Phase 3 — The cover

| | Task | Notes |
|---|---|---|
| ✅ | [T11](tasks/T11-cover-window.md) Cover window | **Reviewed 2026-08-23 — one latent crash found and fixed (`977bd91`), two misplaced comments moved, all nine deviations endorsed, six more checklist lines verified by hand with the user.** *The defect:* `PolishPlural.form` took `abs(count)` and `abs(Int.min)` **traps** — the same class of thing T10's review found in the countdown a day earlier, and the existing test stepped around it with `Int.min + 1`. Unreachable today (both callers clamp first) but a `public` Core function fed by a hand-edited `config.json`, so it is closed rather than argued about: `count.magnitude`, plus the test that takes the binary down against the old line (SIGTRAP, verified). *Also fixed:* `bundle`'s doc block in the `Makefile` ended up above the new `seatbelt` target and documented the wrong recipe, and `FlagsTests` grew an empty `MARK` in the wrong section. *All nine recorded deviations endorsed*, and no unrecorded ones beyond those two comment slips — the padlocked PIN button matches T10's precedent, `CoverModel` in Core is the same move `MenuBarModel` made and buys 26 tests that could not otherwise exist, `PolishPlural` is a rule a child reads daily, the forward-counting `Sesja 1 z 1` is literally what DESIGN §2.6 draws, the one-box `RST_COVER_FRAME` follows from T08's absolute coordinates, the launch-armed seatbelt deletes the ordering the 2026-08-21 power-cycle depended on, and the main-queue hop stops a button releasing the view whose method is on the stack. *Probed beyond the doc:* `grep -rn 'Date()' Sources/` still returns exactly `SystemClock`; `RSTCore` still imports only Foundation and CryptoKit; `swift build` is warning-clean; the tests read for vacuity — none found, `spentAllowanceOffersNoStart` and `zeroSelfServiceSessionsNeverOffersStart` each fail against a cover that ignores `offersSelfServiceStart`; the seatbelt's `coverBegan()` is re-entrant so a display re-plug does **not** restart the countdown, and `coverEnded()` really does stop it; the layout signature is compared, never a flag; `FullscreenEvictor` converts `NSScreen` frames into CoreGraphics coordinates before matching, which is the bug that would pass on one display and fail silently on two; `Seatbelt`'s cross-thread closure is `Sendable` and every `Clock` is immutable or locked; and `make seatbelt` passes (exits after 4 s on a 3 s limit). *Both halves have evidence.* Headless: 254 tests in 1.9 s. Platform: the implementing session's three runs plus **six further checklist lines verified with the user during this review** — over an ordinary window, following a Space switch, the seatbelt tearing it down, `Na dziś koniec sesji` with no `Rozpocznij` from the first tick under `self_service_sessions_per_day: 0`, `Zablokuj ekran` locking immediately with the cover still up after the unlock, and `Wznów` after a Ctrl-C mid-session. **Three checklist lines remain unverified and are carried to T12, not waived:** one window per display, plugging a display in while covered, and evicting a fullscreen app. `RST_COVER_FRAME` cannot reach the first two by construction, and the third needs a real game |
| ✅ | [T12](tasks/T12-kiosk-lockdown.md) Kiosk lockdown | **Reviewed 2026-08-24 — one real defect fixed (`373f1c7`), six deviations endorsed.** `make seatbelt` measured the restored release grace without requiring it; proved by gutting the grace and watching it still pass. Surrender latch, release ordering and arm-before-cover probed clean. Verdict in `5724e42`. **Platform half verified with the user; three lines open — a display plugged in while covered, a real fullscreen game, the launchd relaunch (T16).** |
| ✅ | [T13](tasks/T13-pin-dialog.md) PIN dialog | **Reviewed 2026-08-25 — one real defect fixed (`20d5454`), four deviations endorsed.** `Config.isConfigured` measured the salt instead of decoding it, so a mangled salt covered a screen no PIN could open — DESIGN §2.5's own "missing **or unreadable**". *Probed:* two implementations gutted, tests caught both; build warning-clean. **Both halves verified — full-screen, two displays, wrong PIN then right, grant lifted it.** |
| ✅ | [T14](tasks/T14-warning-banners.md) Warning banners | **Reviewed 2026-08-26 — three defects, all fixed.** `Wznów` re-spoke the threshold already given, naming the bucket rather than the remainder — “5 minut” at 3:55, once per break; a banner shown inside the previous fade-out was ordered straight back off; and **`Zapisz swoją grę.` was in DESIGN §2.4 twice and had never been spoken**, restored on the second-smallest threshold at the user’s direction. Probed the reset set, the numerals, the voice tie-break and the off-console gates. **290 green, and heard by the user 2026-08-26** |

## Phase 4 — Resilience and setup

| | Task | Notes |
|---|---|---|
| ✅ | [T15](tasks/T15-watchdog.md) Hang watchdog | **Reviewed 2026-08-26 — no defects; one comment added (`4f6f73e`), nine deviations endorsed.** Probed past the doc: every covered-tick call is non-blocking, so the net cannot fire on a healthy app — except through `stopTicking()` on sleep, left armed on purpose and now documented. Release build, `make watchdog` and 311 tests re-run green |
| ✅ | [T16](tasks/T16-first-run.md) First-run wizard and agent | **Reviewed 2026-08-27 — one real defect fixed (`8db4801`), all deviations endorsed.** `Back` from step 4 left step 3's `Continue` doing nothing: the PIN is hashed and forgotten on the way to step 4, and the save guarded on it. Fixed and **verified by hand with the user.** Probed the close paths, the deferred config write, the re-entrant wizard and `launchctl` handling; two stale doc lines corrected. **Both halves have evidence** — 339 tests and the end-to-end hand run of 2026-08-26. Unseen: a real logout/login starting the app, on T18. |
| ✅ | [T17](tasks/T17-settings.md) Settings window | **Reviewed 2026-08-27 — one real defect fixed (`8c915e2`), all five deviations endorsed.** `SettingsProblem.field` sent the sessions-per-day complaint to the session-length box: right message, wrong box to fix. Fixed and **verified by hand with the user.** Probed past the doc — all seven settings are read fresh each tick, grant order survives to the dialog, a large grant cannot overflow, no PIN can reach the log. DESIGN §3.1, §3.2 and §3.5 corrected as T17 asked. **Both halves have evidence**: 371 tests, two hand passes. Built as `SettingsModel.swift` + `Settings.swift` behind `Ustawienia… 🔒`; `01617fd` fixed a window that never appeared |
| ❌ | ~~T19 Presence detection~~ | **Dropped unbuilt 2026-08-27**, by the product manager. Camera declined outright; the 30-min media cap in DESIGN §2.2 is now the whole answer, not a fallback. Scaffolding removed from `RSTCore` |

## Phase 5 — Ship

| | Task | Notes |
|---|---|---|
| ⛔ | [T18](tasks/T18-ship.md) Manual checklist and deploy | **Parked behind T21, 2026-09-04, at the user's direction** — the deploy must carry the new rollover rule. Everything still open here needs the user's hands anyway: the 06:00 refill, sleep, Safe Mode, the deploy. §1 is 5 ticked, 4 half. Verified by hand: a real fullscreen Roblox quit gracefully, both spoken warnings heard over it, a stand-down re-armed on a real clock. The recovery drill found and fixed a defect in RECOVERY.md. **T21 adds one line to §1**: a night with a session left unfinished |
| ✅ | [T20](tasks/T20-spent-session-offer.md) A spent session must not block a day that still has one | **Reviewed 2026-09-04 — one real defect found and fixed (`fbbf76c`).** T20 fixed `advance`; there are two charging paths, and `reconcile` charges a gap the same way. A reboot that eats a PIN grant on the shipped default left his own untouched session unofferable until 06:00 — the fourth door. All five criteria walk clean; the flagged integration expectation is right. Probed: every reader of `wasRunning` and `isLive`, the stand-down through the gap path, a backwards clock, `sessions_per_day: 0` and `-1`. 376 green |
| ✅ | [T21](tasks/T21-rollover-discards-remainder.md) 06:00 discards whatever is left on the session | **Reviewed and closed 2026-09-04 — clean, no fix commit.** All four deviations examined and endorsed. **382 tests, 1.8 s** (was 376). `rollOverIfNeeded` zeroes the remainder, clears `wasRunning`/`isLive` unconditionally, and returns the seconds discarded; both `advance` and `reconcile` pass that up, so all three traps close on the wake path as well as the tick. New `EndReason.discarded` — silent, because only `.expired` speaks. **Deviations:** (a) `reconcile` now returns a **`Reconciliation`** struct rather than a bare `Gap`, the doc having specified only `rollOverIfNeeded`'s signature — `Engine` cannot tell a discard from a charge without it, and a stored flag would be a hidden channel; 5 test call sites take `.gap`. (b) `advance` returns the discard too, `@discardableResult`. (c) The T14 day-key clear of `announced` in `tick` is now **redundant** — `endSession` clears it — and was **kept**, with the comment saying so. (d) T18's §1 gained T21's line and its `Sleep 20 min` row an annotation: that ✅ recorded the old rule and would now read as a charge. **Headless half is the whole of what this task can prove** (Core arithmetic); the platform half is that one T18 line — a real night, **unseen**. **The review probed past the doc**: a mutation that discards but reports 0 reproduces all three traps and 9 assertions catch it; `pruneHistory` still keeps a future day key, so a backwards clock costs the remainder but hands out no free session; no `EndReason` reader exists outside `Engine` |

---

## Findings log — moved to [FINDINGS.md](FINDINGS.md)

**Moved on 2026-08-24**, because it was 127 000 of this file's 175 000 characters and every
session read all of it before it could pick up a task. Nothing was deleted — the whole log
is in [FINDINGS.md](FINDINGS.md), newest first.

**The split does not soften the rule.** Append your findings there, and read it before
touching a task: it is where "verified by hand with the user" lives, and this project counts
that as evidence equal to a test.

---

## Open questions

| Question | Settled by | Answer |
|---|---|---|
| Should the kid-facing UI be Polish too, or only the spoken lines? | you | ✅ **Kid-facing Polish, parent-facing English**, split on the PIN. Strings and the rule in DESIGN §2.4.2 |
| Which `presentationOptions` combination is valid on macOS 26? | T00 | ✅ **All seven**, listed in [FINDINGS.md](FINDINGS.md) |
| Does `Ctrl+Cmd+Q` survive kiosk mode? | T00 | ✅ **No — blocked.** RECOVERY.md Route 4 is unavailable; Route 3 is the fast path |
| Does a `.screenSaver` window draw over a fullscreen game? | T00 | ❌ **No — and neither does any other level.** Resolved by decision: fullscreen apps are **quit** rather than covered (DESIGN 2.6.2) |
| Does Safe Mode load user LaunchAgents? | T00 | Decides a DESIGN.md §8 entry |
| Which log-out mechanism works — Apple Event or `launchctl bootout`? | T11 | ✅ **Neither — it locks the screen instead.** `SACLockScreenImmediate` verified on macOS 26.5, returns 0, locks immediately |
