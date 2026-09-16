# Real Screen Time — Design

**Date:** 2026-08-21
**Status:** Approved design, ready for implementation
**Target:** macOS 26 (Tahoe), Apple Silicon, a single shared family Mac
**Inspiration:** [omricn/stfu](https://github.com/omricn/stfu) — its Core/Platform split, PIN gate, JSONL event log and "deliberately visible, not hidden" stance are adopted wholesale. Nothing else is.

---

## 1. Purpose

A menu-bar app that grants a child's macOS account screen time in **sessions** — 30
minutes a day he can start himself, and any more minutes by PIN — and covers every display
with an opaque window that ordinary means cannot dismiss whenever no session is running.

The problem it solves is specific and already has failed solutions. Apple's Screen Time
and third-party parental-control apps were tried on this machine and did not hold: they
put a *dismissible sheet* on top of a *running session*, and a determined ten-year-old
gets past that. The one thing that reliably works — `launchctl bootout gui/<uid>`, a root
daemon killing the whole GUI session — is brutal: no warning, no save, no negotiation.

This app sits between those. It is as unbypassable as user space allows, but it warns
first, it lets you save your work, and it takes a PIN.

### Success criteria

1. When a session ends, every display is opaque and stays that way.
2. `Cmd+Tab`, `Cmd+Q`, `Cmd+Opt+Esc` and Apple ▸ Log Out do not get past it.
3. Killing the app gains no screen time — the gap is charged.
4. The parent can always get the machine back, without the app's cooperation.
5. Nobody loses unsaved work to a surprise.

### Stance

Taken directly from S.TFU, and load-bearing here for the same reason: **the app is
visible.** A menu-bar icon shows the minutes remaining. It announces itself on first
run. It is a feedback device with a boundary, not a trap. A hidden watchdog invites
the arms race; a visible countdown invites pacing.

---

## 2. Behaviour specification

### 2.1 Sessions

Time is granted in **sessions**, not as a daily pool. A session is **30 minutes of active
use** (§2.2 defines "active"), and the machine is covered whenever no session is running.

| | Default |
|---|---|
| Session length | 30 minutes |
| Self-service sessions per day | **1** |
| Extension, with the PIN | **any number of minutes, unlimited, the parent chooses** |
| Day rolls over at | 06:00 |

**One session a day is self-service.** He logs in, the cover says `Rozpocznij sesję — 30
minut`, he presses the button and the clock starts. No PIN, no adult needed. That is the
ordinary rhythm — a block of time he can take on his own — and it does not require anyone
to be found.

**Everything past that is one PIN decision: how many more minutes.** When the session is
over the cover offers `Dodaj minuty` behind the PIN, and the parent types an amount. There
is no separate "grant a whole new session" — with an arbitrary amount available, a fresh
half hour is thirty typed into the same box, and two buttons for one act would only teach
that one of them is worth more.

> **Changed 2026-08-22**, from two self-service sessions and a fixed `+15`. The old shape
> had a contradiction in it that only surfaced when T07 scripted a whole evening: §2.1
> promised two sessions with no adult, while §2.6's cover offered no `Rozpocznij` once the
> first had run out. One session a day removes the state where the question could be asked
> at all, and the amount moving into the parent's hands is the same principle §2.5 already
> stated — **the cap belongs in the parent's judgement, not in the app's arithmetic**.

The count is still a setting (`self_service_sessions_per_day`), and still gates only what
he can do unaided. A household that wants the old rhythm sets it to 2 and nothing else
changes; setting it to 0 means every minute of the day is a PIN decision.

**A session survives a logout.** Logging out ten minutes in leaves twenty minutes on that
session, and logging back in offers `Wznów sesję — pozostało 20 minut` rather than
consuming the day's one. The machine is shared: he must never learn that logging out to
free it costs him time, because then he will stop doing it.

**But nothing survives 06:00.** Whatever is left on the clock at the day boundary is
discarded — his own minutes and PIN-granted ones alike — and the new day starts with a
fresh allowance and an empty session. A session left unfinished at bedtime is gone in the
morning: the cover offers `Rozpocznij sesję — 30 minut`, not `Wznów`.

> **Changed 2026-09-04**, from a remainder that crossed the boundary intact. The old rule
> was written for a session granted at 05:50 and finished at 06:10, where carrying it costs
> nobody anything; the case it did not anticipate is the ordinary one, where an evening left
> half-used hands him 45 minutes the next morning instead of 30. **The 06:00 line does the
> discarding, always** — asleep or awake, playing or paused — because the alternative, losing
> minutes only to an interruption, leaves a Mac left awake all night carrying them anyway.
> Nobody is left short: the allowance refills on the same instant. **Nothing is said to the
> child**; the new day's offer is the honest statement, and 06:00 is before he is up.
> Implemented by [T21](tasks/T21-rollover-discards-remainder.md).

**There is no curfew.** Sessions control how much; nothing controls how late.

> **Accepted gap.** With a self-service session and no wall-clock rule, it can be started at
> any hour — 06:05 before school, or 22:30 if the day's one is unused. The app will not
> stop it. Closing this needs a *start window* (sessions may only begin between
> two times), which is a smaller rule than the curfew that was removed and can be added
> without disturbing anything else.

### 2.2 What consumes a session

Time counts only while the session is **actively in use**:

One predicate decides it, and everything it needs is passed in:

```
active =  sessionOnConsole
       && !screenLocked
       && (  idleSeconds <= idleGrace                              // 10 min
          || (mediaPlaying && idleSeconds <= mediaGrace)  )        // 30 min
```

| Condition | Counting? |
|---|---|
| Input within the last **10 minutes** | **yes** |
| No input, but something is holding the display awake, within **30 minutes** of last input | **yes** — he is watching something |
| No input for more than 10 minutes, nothing playing | no — paused |
| No input for more than 30 minutes, whatever is playing | no — paused |
| Screen locked | no |
| **Another user is on the console** (fast user switching) | no |
| System asleep | no |
| Session logged out | no |
| App not running, gap unexplained | **yes** — see §2.3 |

Idle comes from `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)` — no
permission prompt, no Accessibility grant.

**Why the media clause exists.** Input-only idle has an inverse hole: a two-hour film looks
exactly like an empty room, so passive watching would cost about ten minutes of a session.
`kIOPMAssertionTypePreventUserIdleDisplaySleep` — held by video players — distinguishes
*something is playing* from *nothing is happening*.

**Why it is capped.** A game holds the same assertion, so the signal alone cannot tell "he
is watching a film" from "he left a game running and went to bed". The 30-minute cap bounds
the damage in both directions: a film keeps counting for half an hour past the last touch,
and a game left running overnight stops after half an hour rather than eating tomorrow's
the next session too.

**The cap is the answer, not a stopgap** (2026-08-27). A camera presence check was specified
to separate the two directly and was dropped before it was built — see §8. So this one number
is the whole of the app's answer, and both errors it can make are small and bounded by it:
thirty minutes over-counted on a forgotten game, thirty minutes past his last touch granted to
a film he really is watching. It errs towards the child in the second case on purpose.

**Be precise about what is indistinguishable, because the paragraph above used to overstate
it** (corrected 2026-08-27). Two different questions were bundled together:

| Question | Answerable? |
|---|---|
| Is this a *game* or a *film*? | **Yes, and cheaply.** `IOPMCopyAssertionsByProcess` names the owning process and the assertion's own description string — no permission prompt, no entitlement. The app does not read it; it reads `IOPMCopyAssertionsStatus`, which is an aggregate *count* per type and therefore identical for both. That is a choice, not a limit |
| Is he *in the chair*? | **No.** A game parked on its title screen in an empty room holds exactly the same assertion as one being played, and so does a film nobody is watching. No process name changes that |

**Only the second question is the one the cap exists for**, and it is genuinely unanswerable
from this signal — which is why the cap survives the correction with its reasoning intact.
Knowing the owner would let the app treat a film differently from a game; it would never tell
it whether the room is empty. The camera was the only thing that would have, and it is
declined (§8). See the findings log, 2026-08-27.

**Fast user switching is not a logout.** The machine is shared and the accounts are switched
back and forth, so his session stays live in the background while the parent works. Without
handling it, every switch would quietly charge him up to the full idle grace.
`NSWorkspaceSessionDidResignActiveNotification` and `…DidBecomeActiveNotification` — which
exist for exactly this — pause and resume with no grace period at all.

The same rule suppresses **warnings** while off-console. A background session speaking
Polish into whoever is actually using the Mac is the sort of thing that gets an app
uninstalled.

The 10-minute grace exists so that a machine left on during dinner does not burn the
session, while a pause to read something does not stop the clock and make the countdown
feel dishonest.

**A paused clock is still visible.** The menu bar shows the same remaining minutes; it
simply stops decreasing. There is no "paused" badge — it would teach that stepping away
is a way to game the counter, which it is, and which is fine.

### 2.3 Gaps, and why they are charged

The app writes a heartbeat every 15 seconds: the current time, today's used seconds, and
the day it belongs to. On launch it compares the last heartbeat against now.

The discriminator is a **clean-exit marker**. On an orderly shutdown — the user logs out,
the machine sleeps, the app is quit through its own menu — the app writes `expected` into
the heartbeat before going away. A `SIGKILL` cannot write anything.

| Gap has… | Interpretation | Charged? |
|---|---|---|
| Clean-exit marker | Logged out, slept, or quit properly | no |
| Boot time inside the gap | Machine was rebooted or off | only the portion after boot |
| Nothing | Process was killed | **yes, in full**, logged as `tamper_gap` |

The incentive this creates is the entire point: killing the app costs exactly as much
screen time as not killing it, so there is no reason to try. The `tamper_gap` event in
the log is the parent's evidence that someone did.

**Known hole, accepted.** `session.json` lives in `~/Library/Application Support/` — the
child's own home directory, which he owns and can edit. He can set `usedSecondsToday`
to zero with a text editor, and he can run `launchctl bootout gui/502/<label>` on his own
LaunchAgent without admin rights. Neither has a fix in pure user space; both are closed
only by a root LaunchDaemon owning the file, which was considered and declined for its
blast radius. Signing it with an HMAC keyed from the Keychain was also considered
and declined as an arms race not worth entering. **If the file is ever found edited,
the answer is a conversation, not a bigger lock.** Should that change, §8 records the
upgrade path.

### 2.4 Warnings, then the cover

Each warning is **a chime, then a spoken line, and a banner**.

| Remaining | Sound | Spoken (Polish) | Banner |
|---|---|---|---|
| 10 min | `Ping` ×3 | "Zostało Ci dziesięć minut." | yes |
| 5 min | `Ping` ×3 | "Zostało Ci pięć minut. Zapisz swoją grę." | yes |
| 1 min | `Ping` ×3 | "Ostatnia minuta." | yes |
| 0 | `Ping` ×3 | "Czas minął." | **the cover** |

**Thresholds are 10/5/1, not 15/5/1.** A 15-minute warning on a 30-minute session lands at
the halfway mark, which is a progress report rather than a warning. `warningMinutes` is a
config array — revert it to `[15, 5, 1]` if a longer session length makes that right again.

**`Zapisz swoją grę.` rides the second-smallest threshold, not the number 5.** It is the
only thing the app ever tells him to *do*, and it belongs where there is still time to do
it: the last warning is too late to start saving, and every warning above it would be
nagging. Keyed to position so a retuned array keeps it — `[20, 10, 2]` puts it on the ten
— where hard-coding 5 would silently drop it. A single-entry array carries it on its one
threshold. Restored 2026-08-25 in the T14 review: this table had specified it since the
section was written and the app had never said it.

**It is not the consequence sentence, which is gone.** *"Zapisz grę — gra na pełnym ekranie
zostanie zamknięta"* named §2.6.2's outcome as well as the instruction, and was cut on
2026-08-25 after being heard: eight words, three times a session. §2.6.2 now rests on the
warnings existing rather than on their wording, and what is spoken is the three words above.

The three `Ping`s play **back to back with no gap**, then the speech. The chime exists
because without it the first two words are missed — the ear needs a moment to arrive
before the sentence starts.

**Audio is the primary channel and the banner is the backup**, which is the opposite of
what it looks like. The failure mode this design has to survive is a child inside a
fullscreen game: §2.6.1 established that nothing can be drawn over that, so a banner is
literally invisible at the one moment it matters most. Sound reaches him through
headphones regardless of what is on screen.

The banner then covers what audio cannot: a muted Mac, headphones round his neck, volume
at zero. Neither channel is sufficient alone; together they are hard to miss.

**No attempt is made to raise the volume.** It is intrusive, and on this very Mac the
output device does not report volume to the API at all — a check that fails silently on
the target hardware is worse than not having it.

Banners are non-blocking, appear on the main display, and auto-dismiss after a few
seconds. They do not steal focus — a warning that interrupts a saved game to tell you to
save your game is self-defeating.

Warnings fire against the running session's remaining time. There is nothing else to warn
about — no curfew, and no daily pool draining in the background.

**The cover** is an opaque window on every attached display showing why it appeared, the
time, and a PIN field. There is no close button, no Escape, no menu.

#### 2.4.1 Choosing a voice

Speech is `AVSpeechSynthesizer` in `RSTApp`; `RSTCore` decides *that* a warning is due and
never knows it is spoken.

Polish voices ship in three tiers — compact, Enhanced, Premium — and only compact is
present on a stock Mac. The difference is large: compact is audibly concatenative,
Enhanced is close to natural. Enhanced is installed on this machine via System Settings ▸
Dostępność ▸ Treść mówiona ▸ Zarządzaj głosami.

**Resolve the voice by identifier and verify it, never by name.** Measured 2026-08-21:
`say -v "Zosia (Premium)"` with no Premium voice installed **returns success and speaks in
a different voice**. It does not error. `AVSpeechSynthesisVoice(language:)` has the same
shape of behaviour, so the app must enumerate `AVSpeechSynthesisVoice.speechVoices()`,
pick the best available, and log which one it got.

Fallback chain, best first: **Premium `pl_PL` → Enhanced `pl_PL` → compact Zosia → any
`pl_PL` voice → system default**. A Mac missing every Polish voice must still say
something; a warning that silently does not happen is the one failure this feature cannot
have, because apps get quit on the strength of it.

Rate needs tuning by ear — `say -r 160` is words-per-minute, while `AVSpeechUtterance.rate`
is a 0–1 scale around `AVSpeechUtteranceDefaultSpeechRate`. The two do not map directly and
the CLI value cannot be copied across.

#### 2.4.2 Language: Polish for the child, English for the parent

The machine's locale is `pl_PL` and so is the child. The parent reads the settings and the
log. So the app is bilingual, split on one rule:

> **Everything visible during normal running is Polish. Everything behind the PIN, plus the
> record, is English.**

| Surface | Language |
|---|---|
| The cover | **Polish** |
| Warning banners and spoken lines | **Polish** |
| Menu-bar countdown and its dropdown | **Polish** |
| PIN dialog | **Polish** |
| Settings window | English |
| First-run wizard | English |
| `events.jsonl`, `app.log` | English |
| All documentation | English |

The rule is chosen because it is checkable without judgement: if a string can appear without
anyone typing the PIN, it is Polish. No case-by-case argument, no drift.

The event log stays English because it is structured data a parent greps, not prose anyone
reads under pressure — and because `jq` filters written in one language should not stop
working in another.

**Every Polish string lives in one file, `Strings.swift`.** Not scattered through
`CoverWindow`, `Banner` and `MenuBar`. A hardcoded English literal in the cover is the exact
mistake this split invites, and one file makes it a five-second audit instead of a hunt.

The strings themselves:

| Where | Polish |
|---|---|
| Menu: remaining | `Pozostały czas: 01:23:45` |
| Menu: session count | `Sesja 1 z 1` |
| Menu: report | `Raport użycia…` |
| Menu: settings 🔒 | `Ustawienia…` |
| Menu: extend 🔒 | `Dodaj minuty…` |
| Menu: stand down 🔒 | `Wyłącz do jutra` |
| Menu: quit 🔒 | `Zakończ` |
| Cover, no session | `Rozpocznij sesję — 30 minut` |
| Cover, resumable | `Wznów sesję — pozostało 20 minut` |
| Cover, session over | `Czas minął` |
| Cover, none left today | `Na dziś koniec sesji` |
| Button: start | `Rozpocznij` |
| Button: resume | `Wznów` |
| Field: how many minutes 🔒 | `Ile minut?` |
| Button: lock screen | `Zablokuj ekran` |
| PIN prompt | `Wprowadź PIN` |
| PIN wrong | `Niepoprawny PIN` |
| Warning, 15 min | `Zostało Ci piętnaście minut.` |
| Warning, 5 min | `Zostało Ci pięć minut. Zapisz swoją grę.` |
| Warning, 1 min | `Ostatnia minuta.` |
| Blocked | `Czas minął. Do zobaczenia jutro.` |
| Granted | `Dodano piętnaście minut.` — the number is spoken, so T14 declines it by the amount |

### 2.5 The PIN

One PIN. It:

- **adds however many minutes the parent types**, to a running or a just-expired session,
  without limit and as often as they like, and
- **can stand the app down entirely** until 06:00 the next morning.

It is never needed to *start* the day's self-service session, and never needed to **log
out** — see §2.6.

Unlimited extension is deliberate: there is no limit on how many grants a day can hold, and
none on what they add up to. The cap belongs in the parent's judgement, not in the app's
arithmetic, and an app that refuses its own owner is an app that gets uninstalled. Every
grant is written to the event log **with its size**, so the pattern is visible later even
though it is never blocked in the moment.

**The amount is chosen from a list, not typed** (changed 2026-08-23, from the free-text box
that replaced the fixed `+15` the day before). The dialog offers `extension_options` — which
ships as **15, 30 and 60 minutes** — and the parent picks one. The grant is made standing
over a Mac with a child at it, often mid-argument, and two taps at arm's length beats typing
a number and checking it. Grants stay repeatable, so 90 minutes is 60 then 30, and the log
shows both, which reads better than one large number anyway.

> **This is a list, not a cap, and the distinction is the whole reason it is a setting.** A
> parent who needs 90 in one press puts 90 in `extension_options`; the app has no opinion
> about what belongs there and no upper bound on the values. §2.5's rule has not moved — it
> has changed *when* it applies, from the moment of the grant to the shape of the menu. What
> the app must never do is stand between a parent and their own decision, and asking that
> decision to be made in advance, once, is not that.
>
> The order in the list is the parent's too: **the first entry is what the dialog
> pre-selects**, so reordering it is how the one-keystroke default changes. An
> `extension_options` hand-edited to `[]` or to nothing positive falls back to what ships —
> a grant dialog that can grant nothing is the one shape it must never take.

The **session count** is the only thing the app itself limits, and even that only gates
self-service: minutes granted behind the PIN never touch it, however many there are. One
consistent rule — **the PIN beats everything**.

`Disable` re-arms automatically at 06:00. A manual-only disable is indistinguishable, a
week later, from an app that quietly stopped working — the realistic failure mode of that
feature is forgetting, so the app remembers instead.

**Granting minutes during a stand-down ends it** (decided 2026-08-22). A parent who stands
the app down and then adds minutes means *now*, and "the PIN beats everything" already says
which of the two wins. The alternative — refusing until they undo the stand-down first —
makes them take two steps at the moment they are doing someone a favour, and the third
option, holding the minutes until morning, is the one thing nobody means.

This is not only a convenience. `decide` returns `.dormant` for the whole stand-down, so
the screen stays free and no countdown appears — while the ledger charges any live session
regardless, because it reads neither the stand-down nor the decision (§3.4 runs the
accounting *before* the decision, and nothing carries the answer back). `Disable` keeps
that safe by **ending** the running session rather than suspending it, so there is nothing
left to charge; a grant puts a live session back, and without the lift those minutes would
drain in silence behind a free screen. The `rearmed` line is written at the moment of the
grant, with the `extended` line beside it saying what caused it.

A grant of **zero** minutes lifts nothing: it is not a grant, and a no-op that quietly ends
the night's stand-down is a surprise nobody asked for. The child's own `Rozpocznij` does not
lift one either — that would be his button beating his parent's decision, which is the
opposite of this section — and it cannot be reached during a stand-down anyway, since
`.dormant` puts no cover on the screen.

Stored as PBKDF2-HMAC-SHA256 with a random per-install salt, via CryptoKit.

**The PIN is a speed bump, not a security boundary**, in exactly S.TFU's sense. Anyone
with admin rights on this Mac can end this app in one command, and that is correct: see §5.

**One derived rule.** If the PIN hash is missing or unreadable, the app **must not cover
the screen**, because nothing could then uncover it. This is not a general fail-open
policy — a corrupt config is otherwise repaired from shipped defaults and enforcement
continues — it is the narrow case where blocking would be a trap with no key.

### 2.6 What the cover actually is

Two mechanisms together. Neither is sufficient alone.

The cover has **three states**, and they are the app's whole user interface for the child:

| State | Shown | Buttons |
|---|---|---|
| No session, self-service left | `Rozpocznij sesję — 30 minut` · `Sesja 1 z 1` | `Rozpocznij` |
| Session paused mid-way | `Wznów sesję — pozostało 20 minut` | `Wznów` |
| Session over, or none left | `Czas minął` / `Na dziś koniec sesji` | `PIN` ▸ `Dodaj minuty…` — plus `Zablokuj ekran` |

**The third row has one PIN button, not two**, since 2026-08-22. Whether `Czas minął` or
`Na dziś koniec sesji` is shown still follows `selfServiceLeft`, and on the shipped default
of one session a day the second is what he will see — but the distinction stays, because the
setting still allows more and `awaitingStart(0)` is reachable through it (§2.1).

**`Zablokuj ekran` needs no PIN.** Ending your own turn is the intended exit, not a bypass.
It gives him a dignified way to finish rather than sitting in front of a wall until an adult
appears, and it hands the Mac over without anyone hunting for a password.

**A screen lock, not a logout.** Verified working on macOS 26.5:

```swift
// login.framework, private. dlopen + dlsym; returns 0 on success.
SACLockScreenImmediate()
```

Locking beats logging out on every axis that matters here: nothing is killed, no unsaved
work is lost, it is instant, and it needs no Automation permission. Fast user switching is
enabled on this Mac, so the lock screen is also where the parent switches to their own
account — the shared-machine case is served without him logging out at all.

If he unlocks and comes back, **the cover is still there**, because the session is still
over. Locking is not an escape; it is a polite exit.

Fallback chain, since `SACLockScreenImmediate` is private and could vanish:

1. `SACLockScreenImmediate()` — immediate, verified
2. Display sleep — locks immediately **only if** "require password" is set to *immediately*
3. `launchctl bootout gui/$UID` — hard logout, last resort, loses unsaved work

**Setup requirement.** This Mac reports `screenLock delay is 300 seconds` — five minutes
after sleep before a password is asked. That grace undermines the whole app every time the
Mac sleeps, quite apart from the fallback above. Set **System Settings ▸ Lock Screen ▸
Require password → immediately** on the child's account.

**Windows** — one `NSWindow` per `NSScreen`, at `.screenSaver` level, opaque, with
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
`canJoinAllSpaces` is what makes it follow a Space switch. `fullScreenAuxiliary` is
*supposed* to let it draw over an app in its own fullscreen Space — **and does not**,
measured 2026-08-21 against a real game, which kept its display entirely while the cover
appeared only on the other screen. See §2.6.1. `NSApplication.didChangeScreenParametersNotification`
adds and removes windows as displays are plugged in — and **needs a re-entrancy guard**,
because applying `hideDock`/`hideMenuBar` changes `visibleFrame` and posts that very
notification. Measured: it fires once, immediately after the options are set.

Borderless windows return `false` from `canBecomeKey`, which means the PIN field silently
refuses keystrokes. The window class must override it. This is the single most likely
way to ship a cover nobody can unlock.

**Presentation options** — the app-global kiosk lock:

```swift
NSApp.presentationOptions = [
    .hideDock, .hideMenuBar,
    .disableProcessSwitching,     // Cmd+Tab
    .disableForceQuit,            // Cmd+Opt+Esc
    .disableSessionTermination,   // Apple ▸ Log Out / Shut Down
    .disableHideApplication,      // Cmd+H
    .disableAppleMenu,            // the  menu itself
]
```

**This exact set is verified valid on macOS 26.5.1** — measured, not inferred, by
`spike/kiosk-probe/probe-options.sh`. Four things about it shape the implementation:

1. **Invalid combinations raise, and a raise is not a crash.** `hideMenuBar`,
   `disableProcessSwitching`, `disableForceQuit` and `disableSessionTermination` each
   raise when set *without* `hideDock`. More importantly: `NSApplication` catches an
   exception thrown inside `applicationDidFinishLaunching`, logs it, and keeps its run
   loop going — so a bad combination presents as a **hang**, not a crash, and cannot be
   detected by exit status. Set the options early, read them back, and treat a mismatch
   as a failure.
2. **They only hold while the app is frontmost.** The app must `NSApp.activate()` and
   re-assert on `didResignActive`.
3. **They need `.regular` activation policy.** The app normally runs as `.accessory`
   (menu-bar only, no Dock icon); it switches to `.regular` while covering and back
   afterwards.
4. **They do not block `Cmd+Q`.** Measured, 2026-08-21: `Cmd+Q` closed the spike straight
   through the full option set. No presentation option covers it — `disableForceQuit` is
   the `Cmd+Opt+Esc` panel, `disableSessionTermination` is Log Out / Restart / Shut Down,
   and an app terminating *itself* is neither. `NSApp.terminate(_:)` asks the delegate
   first, so the app must refuse:

   ```swift
   func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
       covering ? .terminateCancel : .terminateNow
   }
   ```

   The watchdog's `exit(0)` does not consult this method, deliberately — the escape hatch
   must not be blockable by the thing it is escaping.

**`Ctrl+Cmd+Q` does not lock the screen** under this option set — measured 2026-08-21 on
the T00 spike, confirmed 2026-08-24 on the shipping app (T12).
The chord reaches the app as an ordinary keystroke instead of being consumed by the
WindowServer. That is one less hole for the child and one less route for the parent:
[RECOVERY.md](RECOVERY.md) Route 4 is unavailable, and Route 3 — reboot to the login
window — is the fast path.

`Cmd+Tab`, `Cmd+Opt+Esc` and Mission Control (F3) are likewise suppressed, all measured
rather than inferred. `Cmd+Q` is the one exception, and it needs its own defence — see
point 4 above.

#### 2.6.1 Fullscreen apps defeat the cover — and the fallback fixes two problems

Measured against Sneaky Sasquatch, confirmed frontmost at cover time:

| Observed | Consequence |
|---|---|
| The game held its display; the cover appeared only on the *other* screen | `.screenSaver` + `.fullScreenAuxiliary` is not sufficient |
| Two `RESIGNED ACTIVE` events with **no keystrokes** | A fullscreen game reclaims focus unprompted, so presentation options lapse with no user action. Re-asserting is continuous, not exceptional |
| Quitting the game while covered left a **stale frame on that display** | The game's fullscreen Space was orphaned. Nothing owned it, so no process could be killed to clear it; it needed closing by hand in Mission Control |

Escalation ladder, in order:

1. `CGShieldingWindowLevel()` — what the system's own screen shields use, above `.screenSaver`
2. `CGWindowLevelForKey(.maximumWindow)` — brute force
3. **Hide the frontmost app before covering** (`NSRunningApplication.hide()`), S.TFU's
   accepted trade-off: leave the game running, force it out of fullscreen first

**Option 3 is not just a fallback, it is a fix for the third row of that table.** A game
forced out of fullscreen before the cover appears has no fullscreen Space to orphan, so
the stale-frame failure cannot happen. If 1 and 2 fail, the fallback is strictly better
than a cover that half-works.

One more lead worth testing before concluding: **macOS Game Mode** (`GamePolicyAgent` was
running) gives a fullscreen game priority over other processes. It may be the actual cause
of both the coverage failure and the unprompted focus loss. Re-test with it disabled.

#### 2.6.2 Fullscreen apps are quit, not covered

A fullscreen app cannot be covered — §2.6.1 establishes that no window level reaches into
another app's Space, and `hide()` is refused outright. Three options remained: accept the
gap, buy an Accessibility grant, or close the app. **The app is closed.**

The decision rests on the warnings. By the time anything is quit, the child has had a
chime, a spoken line and a banner at ten minutes, at five and at one. A game closed after
three warnings is a consequence; the forced logout rejected in §7 was rejected because it
closed *everything* with *no* warning, and that objection does not carry over.

> **Changed 2026-08-25, and this is the amended version.** The warnings used to say the
> consequence in so many words — *"Zapisz grę — gra na pełnym ekranie zostanie zamknięta"* —
> and the case for quitting rested on those words. The user heard them in a real run and cut
> them: three sentences a session, each longer than the fact it delivered. **The case now
> rests on the warnings existing rather than on their exact wording.** He is told three times
> that his time is ending; what he is no longer told is the mechanism. That is the same deal
> a parent makes by saying "turn it off now" twenty minutes before they mean it, and §2.4's
> table is what is spoken.

**Rules:**

| Rule | Why |
|---|---|
| Only apps owning a **fullscreen Space** are quit | Ordinary windowed apps are covered perfectly well. Quitting them would be gratuitous |
| Only when a cover is actually required | Never on a warning, never during normal use |
| `terminate()` first, `forceTerminate()` after **10 seconds** | Let the app save. But a modal "save changes?" sheet must not hold the cover off indefinitely — that would be a trivial bypass |
| Every quit is logged as `app_quit`, with the name and whether it was forced | The parent needs to know what was closed, and the child needs to be believed when they say something was lost |
| **There must be warnings, and they must be heard** | Replaces "the warnings must name the consequence" (2026-08-25). What makes quitting fair is that the end was announced three times, out loud, in a channel a fullscreen game cannot hide — §2.4's audio-first design is load-bearing *here*, not only there. Take the warnings away and this feature stops being defensible; change their wording and it does not |
| Gated behind the same enforcement check as covering | Debug builds must never quit a real app. This is destructive in a way the cover is not |

**Accepted cost:** a child mid-game loses that game's unsaved progress if they ignore three
warnings, and since 2026-08-25 he is not told in words that this is what will happen. That is the intended lesson, and it is the same trade a parent makes by saying
"turn it off now". It is not silent, not a surprise, and it is in the log.

### 2.7 Staying alive

A `KeepAlive` LaunchAgent in `~/Library/LaunchAgents/`. Killed, the app is back in a few
seconds — and the gap it was away is charged. Together those mean killing it is pointless
rather than merely difficult.

No root LaunchDaemon. No forced logout. No `pwpolicy` account disabling. The account is
always able to log in, which is what keeps §5 simple.

### 2.8 The hang watchdog

**A crashed app cannot leave the screen covered.** Windows belong to processes; when the
process dies the window server destroys its windows and releases the presentation
options in the same instant. A crash frees the screen.

The failure that *can* strand someone is a **hang** — main thread deadlocked, cover still
drawn, PIN field not responding to a single keystroke.

**This is not hypothetical.** On 2026-08-21 the T00 spike's own auto-release was an
`NSTimer` scheduled after the windows were built, and an early `return` above it skipped
the timer. The screen was covered with nothing left to release it and the machine had to
be power-cycled. Two rules came out of it, and they bind the real app:

1. **Arm the release before taking the screen**, never after.
2. **The release must not depend on the main run loop** — that is precisely the thing that
   wedges. A detached thread survives a deadlock, a skipped branch, and an exception
   `NSApplication` swallowed.

So: a background thread increments a counter every second and the main thread's run loop
resets it. If it reaches 30 while a cover is up, the watchdog calls `exit(0)`. The
process dies, the cover vanishes, launchd relaunches within seconds, and the fresh
instance re-evaluates and re-covers if it should. A hang becomes a blink instead of a
dead Mac.

This is the only automatic safety net in the app. A `DISABLED` sentinel file, a
fail-open-on-corrupt-config rule and a 6-hour cover ceiling were all considered and
declined: each is another way for enforcement to switch itself off for reasons nobody
chose, and §5 already guarantees a way back in.

---

## 3. Architecture

One Swift package, two targets, one hand-assembled `.app`. No third-party dependencies.

### 3.1 The boundary

```
Sources/
  RSTCore/       pure Swift — Foundation only, NO AppKit, NO SwiftUI
  RSTApp/        AppKit — every platform call lives here
Tests/
  RSTCoreTests/  everything below runs headless
```

`RSTCore` imports nothing but `Foundation` and `CryptoKit`. It takes numbers and dates in
and emits decisions and events out. It cannot open a window, read a clock, or ask the
system anything.

This is copied from S.TFU, where `detector.py` and `strikes.py` hold the correctness and
the tests concentrate there. **A test asserts the boundary** — it scans `RSTCore` sources
for forbidden imports and fails the build if one appears. S.TFU enforces the same rule
with an AST test; a `grep`-grade check is enough here and costs nothing.

### 3.2 Modules

| Module | Target | Responsibility |
|---|---|---|
| `Clock.swift` | Core | `Clock` protocol; `SystemClock`; `FakeClock`; `ScaledClock` for `RST_TIME_SCALE` |
| `Config.swift` | Core | `Config` struct, JSON load/save, defaulting, corrupt-file recovery |
| `PIN.swift` | Core | PBKDF2 hash and verify |
| `DayWindow.swift` | Core | 06:00 day boundary and rollover. No curfew — see §2.1 |
| `Ledger.swift` | Core | Used seconds today, heartbeat, gap classification and charging |
| `Policy.swift` | Core | **The decision function.** State in → `Decision` out |
| `EventLog.swift` | Core | Append-only JSONL; `FileEventSink.note` for `app.log` |
| `Flags.swift` | Core | The `RST_*` grammar, defaults and clamps. The *reading* of the environment stays in `main.swift` — see below |
| `WatchdogModel.swift` | Core | **When a hang has happened**, as arithmetic: the count since the last tick, whether a cover is up, the thirty-second threshold — §2.8 |
| `MenuBarModel.swift` | Core | **What the status item shows**, as a value: the `HH:MM` bar text and the `HH:MM:SS` menu line, the `⏸`/`–` glyphs, the tint flag and the two session numbers — see below |
| `Engine.swift` | Core | **One tick, and the six commands the cover can issue.** The `Enforcing` protocol; the `blocked`/`uncovered` edges; warning de-duplication and its off-console suppression; the 06:00 re-arm |
| `Sensors.swift` | App | Idle seconds, lock state, fast user switching, the media assertion, `kern.boottime`. **Sleep and wake are `AppController`'s** (T08) — they are lifecycle, not a reading |
| `Enforcer.swift` | App | `CoverEnforcer` and `ObserverEnforcer` — the two implementations of Core's `Enforcing`. `RecordingEnforcer` (tests) |
| `CoverWindow.swift` | App | The windows, the kiosk options, the PIN field |
| `Banner.swift` | App | The visual half of a warning |
| `Voice.swift` | App | Chime, voice resolution, speech. `AVFoundation` lives here and nowhere else |
| `Strings.swift` | App | **Every** Polish string. One file, so the bilingual split is auditable |
| `MenuBar.swift` | App | `NSStatusItem`, the dropdown, the fonts and the colours, and the reveal-in-Finder action. **What to display is `MenuBarModel`'s** (T10) |
| `PinDialog.swift` | App | PIN entry; `Dodaj minuty…` / `Wyłącz` |
| `SettingsModel.swift` | Core | **What the settings window is not allowed to save**: the draft, its ordered validation, the two comma-separated minute lists, the log line naming what moved, and the three-stage PIN change — T17 |
| `Settings.swift` | App | The settings window itself, the PIN-change sheet and the uninstall. English, per §2.4.2's one stated exception. **What the rules are is `SettingsModel`'s** (T17) |
| `FirstRunModel.swift` | Core | **What the wizard is not allowed to get wrong**: the four steps, the PIN pair, the two limits, and the plist's contents and program path — §6, T16 |
| `FirstRun.swift` | App | The wizard window itself. English, per §2.4.2's one stated exception |
| `LaunchAgent.swift` | App | Writes `~/Library/LaunchAgents/…plist` and runs `launchctl`. **What it says is `FirstRunModel`'s** (T16) |
| `Watchdog.swift` | App | The hang detector: the detached thread, the `watchdog_exit` line and the `exit(0)`. **When to fire is `WatchdogModel`'s** (T15) |
| `AppController.swift` | App | The 1 s timer, the tick, `session.json` persistence, sleep/wake and the termination signals |
| `SingleInstance.swift` | App | `flock` on `instance.lock`; a second launch exits |
| `Diagnostics.swift` | App | The `app.log` writer, kept out of the event vocabulary by the type system |
| `main.swift` | App | Wiring, single instance, env-var flags |

**The loop between them is Core's, not App's** (T07, reviewed 2026-08-22). §3.4 sketches
the tick inside the app's timer callback, and the timer really does stay App-side — in
`AppController` rather than in `main.swift` itself (T08, reviewed 2026-08-22), which leaves
`main.swift` the assembly and gives the timer, the notifications and the signals one owner —
but what it calls is `Engine.tick`. The four rules the loop carries are rules, and a rule in
`RSTApp` is a rule that can only be checked by hand on a machine with no UI automation. The
`Enforcing` protocol went with it for the plain reason that `Engine` drives it and Core
cannot reach into App; nothing platform-shaped crossed, since the protocol is a `Decision`
and a `Date` in with no return value.

**The env-var *grammar* crossed the same way** (T08, reviewed 2026-08-22). The table gives
"env-var flags" to `main.swift`, and the *reading* of the environment stays there — asking
`ProcessInfo` anything is a system query, and Core makes none. What moved into `Flags.swift`
is the parsing, the defaults and the clamps, on the same argument as the loop: "`swift run`
never covers the screen unless `RST_ENFORCE=1`" is a rule about a string, and a rule in
`RSTApp` is a rule that can only be checked by starting the app — the one way this
particular rule must never be checked. `Flags.parse` takes a dictionary and returns a
struct, so nothing platform-shaped crossed here either.

**And the menu bar's display rules crossed for the third time** (T10, reviewed 2026-08-23).
The table gives the whole of the menu bar to the App target, and `MenuBar.swift` keeps
everything that is AppKit — the `NSStatusItem` held strongly so it does not silently vanish,
the monospaced-digit font, the tint colour, the menu and its items. What moved into
`MenuBarModel.swift` is every part of it that is a *rule*: the fields, zero-padded and
rounded up, which glyph stands in for a countdown there is none of, and when the digits turn
orange. Same argument as the loop and the flags — "the hour field does not appear and
disappear at 59:59" is a rule about a string, and a rule in `RSTApp` can only be checked by
starting the app and reading the corner of the screen.

**The bar counts in minutes, the menu in seconds** — changed by the user 2026-08-23, on the
first session anyone had watched run (T11). `MenuBarModel.title` is `HH:MM` and
`remainingText` keeps `HH:MM:SS`: a digit changing once a second is movement in the corner
of the eye all evening, and the seconds were never the number being paced against. Both
still round up, so neither can read zero while a session is still running. Nothing platform-shaped
crossed: the model takes a `Decision` and a `Config` and returns a struct of numbers and
strings, and **no Polish crossed either** — its `title` is digits and two symbols, and the
menu's own Polish lines are assembled in `Strings.swift` from its fields, so §2.4.2's
one-file rule is untouched.

### 3.3 The decision function

The heart of the app is one pure function with no side effects:

```swift
struct Snapshot {
    let now: Date
    let idleSeconds: TimeInterval
    let screenLocked: Bool
    let sessionOnConsole: Bool
    let mediaPlaying: Bool
    let sessionRemaining: TimeInterval   // 0 = no session running
    let sessionsUsedToday: Int           // self-service sessions started
    let disabledUntil: Date?
    let hasPIN: Bool
}

enum Decision: Equatable {
    case dormant                                             // disabled, or no PIN set
    case awaitingStart(selfServiceLeft: Int)                 // cover: Rozpocznij
    case awaitingResume(remaining: TimeInterval)             // cover: Wznów
    case allowed(remaining: TimeInterval)
    case warning(remaining: TimeInterval, threshold: Int)    // 10, 5 or 1
    case expired(selfServiceLeft: Int)                       // cover: PIN, or Zablokuj ekran
}

func decide(_ s: Snapshot, _ c: Config) -> Decision
```

`awaitingStart` and `awaitingResume` are distinct because they are different offers: one
consumes a session, the other returns time already granted. Collapsing them would make the
resume-after-logout rule impossible to express.

Every rule in §2 is expressible against this signature, and every one of them is
therefore testable in microseconds without a window, a clock, or a Mac.

### 3.4 Data flow

```
timer tick (1s)
  → Sensors: idle seconds, locked?
  → Ledger: advance used seconds if active; heartbeat every 15s
  → Policy.decide(snapshot, config)
  → Enforcer:  allowed → nothing
               warning → Banner
               blocked → CoverWindow  (or ObserverEnforcer, which only logs)
  → EventLog: append on every state change
  → MenuBar: update countdown
```

### 3.5 Storage

`~/Library/Application Support/RealScreenTime/`

| File | Contents |
|---|---|
| `config.json` | Session length, sessions per day, idle grace, PIN hash + salt |
| `session.json` | Current session's remaining seconds, self-service sessions used today, heartbeat, clean-exit marker |
| `events.jsonl` | Append-only event log |
| `app.log` | Diagnostics |

Both JSON files are written **atomically** — temp file plus rename — so a crash mid-write
cannot leave an unparseable file. A `config.json` that fails to parse anyway is moved to
`config.json.bad`, replaced with shipped defaults, and logged. A `session.json` that fails
to parse ends any running session and returns to `awaitingStart`.

**Event record:**

```json
{"ts":"2026-08-21T16:00:02.118+02:00","type":"session_start","n_today":1}
{"ts":"2026-08-21T19:44:11.902+02:00","type":"extended","minutes":45,"n_today":1}
{"ts":"2026-08-21T20:31:07.441+02:00","type":"tamper_gap","seconds":288}
```

`type` is one of `session_start`,
`session_resume`, `session_end`, `warned`, `blocked`, `uncovered`, `extended`,
`screen_locked`, `disabled`, `rearmed`, `tamper_gap`, `config_reset`, `config_changed`,
`watchdog_exit`, `app_quit`.

`config_reset` and `config_changed` are deliberately two types and not one. The first means
the file was unparseable and the app threw it away; the second means a parent changed a
setting on purpose, in the window behind the PIN, and carries `changed` —
`session_minutes 30→45, warning_minutes [10, 5, 1]→[5]`. One type for both would make
either of them unreadable as evidence six weeks later. A PIN change is recorded as
`pin_hash changed`, and the value is never written in either direction (T17).

**No report UI.** The log is a file; `jq` reads it. Charting is long-tail UI work whose
value here is answered by four lines of shell.

An event is written **before** the action it describes is dispatched, stamped with the
time of the decision rather than the time of the write — the cover blocks until a PIN
arrives, which could be hours, and a record written afterwards would be misdated and lost
entirely if the process were killed meanwhile. S.TFU's rule, same reasoning.

---

## 4. Testing

Full detail in [TESTING.md](TESTING.md). The shape:

| Level | What | Risk to the dev machine |
|---|---|---|
| **L1** unit | Every rule in `RSTCore`, injected clock | none, headless |
| **L2** integration | Scripted full days through the real Policy with fake sensors and a recording enforcer | none, headless |
| **L4** windowed cover | Real cover window rendered into a 600×400 box | none |
| **L5** scratch account | Real kiosk lockdown in a throwaway `rst-test` user, asserted from the log | none to your session |
| **Manual** | Fullscreen game, Safe Mode, reboot, multi-display | seatbelted |

**The safety default: debug builds observe, release builds enforce.** `swift run` never
covers the screen unless `RST_ENFORCE=1` is passed deliberately. The installed `.app`
always enforces. The dangerous behaviour requires an explicit act; the safe one is free.

`RST_MAX_COVER_SECONDS=30` tears any cover down after 30 seconds regardless of state, and
`RST_TIME_SCALE=60` runs a 30-minute session out in 30 seconds — together they let start,
warnings, expiry, extension and logout be watched in about two minutes.

**No XCUITest.** This machine has Command Line Tools, not Xcode, so `xcodebuild test` is
unavailable and there is no scripted UI automation. L4 and L5 are driven by environment
variables and asserted against the event log, not by a UI robot. This is a constraint to
design around, not a gap to apologise for: it pushes behaviour into `RSTCore` where it can
be tested properly, which is where it belongs anyway.

---

## 5. Recovery

Full runbook in [RECOVERY.md](RECOVERY.md). The guarantee, in one line:

**Reboot, and log in as the admin account instead.** A LaunchAgent exists only inside a
logged-in user's session; the login window is a context this app can never touch. That
path needs no network, no terminal skill, no prior setup and no cooperation from the app,
and it is why the automatic safety nets in §2.8 could be kept to one.

Ordinary route, app healthy: type the PIN, or use PIN ▸ Disable.
Hung: the watchdog exits within 30 seconds by itself.
Everything else: reboot to the login window. Recovery Mode as the last resort.

Remote Login is deliberately **not** part of setup. It only helps if enabled before it is
needed, and the reboot path already always works.

---

## 6. Install

Drag `RealScreenTime.app` to `/Applications`, launch it once while logged in as the
child, and answer the first-run wizard:

1. **Welcome** — what it does, and that it is not hidden
2. **PIN** — chosen twice; there is no default and no way to skip
3. **Limits** — session length and sessions per day, pre-filled with 30 minutes and **1**
4. **Start at login** — writes `~/Library/LaunchAgents/com.krolikowski.realscreentime.agent.plist`
   and bootstraps it

No terminal, no `sudo`, no installer script. The app is **ad-hoc signed** (`codesign -s -`) —
it never leaves these machines, so a Developer ID and notarisation would buy nothing.

The app counts as configured when `config.json` exists and `pin_hash` is non-empty.
Anything else re-runs the wizard: a half-finished setup is not a usable state, and
per §2.5 an app with no PIN must not cover anything.

---

## 7. Decisions and rationale

| Decision | Rationale |
|---|---|
| Swift + SwiftUI over Python + PyObjC | No runtime to bundle, no PyInstaller fragility, direct access to the AppKit calls that *are* the product. The S.TFU patterns port; the Python does not need to |
| SwiftPM, no `.xcodeproj` | Only Command Line Tools are installed. `swift build` plus a bundle-assembly script is the whole toolchain |
| Sessions rather than a daily budget | Matches how the machine is actually used — a block of time, started deliberately, rather than a pool draining in the background. It also makes "how much is left" a question about *now* instead of arithmetic over the whole day |
| One self-service session, then the PIN | The ordinary rhythm needs no adult present. Only the exceptions do, which is where a parent's judgement is actually worth something. Two was the original number; one was chosen 2026-08-22 because the second was the session the cover could not offer without contradicting §2.6, and because a parent who can type any amount does not need the app to ration the second block for them |
| A session survives a logout | The Mac is shared. If logging out cost him time he would stop doing it, and the sharing would break |
| The PIN grants minutes, and the parent picks how many | A fixed `+15` made the app arbitrate an amount it knows nothing about; a "whole new session" button was the same act with a different number pre-filled. Every grant is in the log with its size. §2.5's rule that the cap belongs in the parent's judgement, applied to the amount as well as to the count (2026-08-22) |
| …from a list, not a text field | The grant happens standing over the Mac with a child watching, and two taps beat typing a number and checking it. The amounts are a **setting** (`extension_options`, shipping 15/30/60), so the app still refuses nothing — the judgement is made once, in advance, instead of every time (2026-08-23) |
| Lock the screen rather than log out | Nothing killed, no unsaved work lost, instant, no Automation prompt — and fast user switching means the lock screen is where the parent switches in. `SACLockScreenImmediate` verified on macOS 26.5 |
| Locking needs no PIN | Ending your own turn is the intended exit, not a bypass. Requiring a PIN would keep the Mac covered while he stands there wanting to hand it over |
| No curfew | Sessions control how much. How late is left to the household, at the cost of a gap recorded in §2.1 |
| Warnings at 10/5/1, not 15/5/1 | On a 30-minute session, a 15-minute warning is the halfway mark — a progress report, not a warning |
| Cover window over forced logout | A logout with no warning destroys unsaved work and cannot be negotiated. The cover warns, waits, and takes a PIN |
| Kiosk presentation options | The specific thing Screen Time and its commercial imitators do not do, and the specific reason they were bypassed on this machine |
| LaunchAgent KeepAlive, no root daemon | Closes the casual kill; a root daemon's blast radius is not worth the remaining edge |
| Charge unexplained gaps | Removes the incentive rather than blocking the method. The method has no user-space block |
| Plain JSON session state, no HMAC | The remaining hole needs a conversation, not a Keychain-keyed signature. Escalation invites escalation |
| Idle pauses the clock | A Mac left on during dinner should not cost the evening |
| Media assertion counts as activity, capped at 30 min | Without it a two-hour film costs ten minutes. With no cap, a game left running overnight would count. The cap bounds both, and since the camera was dropped (§8) it is the only thing that does — a game and a film hold the identical assertion |
| No camera at all | Considered, adopted, then dropped unbuilt (2026-08-27). The 30-minute cap already bounds both directions of the one question a camera would have answered, and the cost of being wrong inside that half hour is minutes, not trust |
| Fast user switching pauses immediately | The Mac is shared and switched back and forth all evening. Charging him while the parent works would be theft, and the notification for it already exists |
| Warnings suppressed off-console | A background session speaking Polish over whoever is using the Mac is how an app gets uninstalled |
| 06:00 day reset | One morning boundary, not two. It is when the self-service session count refills and a stand-down expires |
| Unlimited PIN extensions | The cap belongs in the parent's judgement. An app that refuses its owner gets uninstalled. Unchanged by the 2026-08-23 list: there is still no limit on how many grants, or on what they total, and any amount a parent means can be put on the list |
| PIN beats every limit the app has | One rule instead of several. It grants minutes past the half hour and sessions past the daily count, in exactly the same way |
| Disable re-arms at 06:00 | The realistic failure of a stand-down feature is forgetting to undo it |
| Visible menu bar with countdown | Pacing beats surprise. Hiding it starts an arms race and removes the parent's own status indicator |
| Warnings before the cover | Something will be unsaved at the moment the limit hits, and it should not be |
| Spoken warnings, not just banners | A banner cannot be drawn over a fullscreen game (§2.6.1), which is exactly where the child is. Sound is the only channel that reaches him there |
| Polish, in a real voice | The machine's locale is `pl_PL` and so is the child. A warning he has to translate is a warning that arrives late |
| Polish for the child, English for the parent, split on the PIN | A rule that can be checked without judgement: if it can appear without typing the PIN, it is Polish. Case-by-case decisions drift; this one does not |
| Every Polish string in one `Strings.swift` | A hardcoded English literal in the cover is the mistake a bilingual split invites. One file makes it an audit, not a hunt |
| No volume forcing | Intrusive, and the target Mac's output device does not report volume to the API — a check that fails silently on the actual hardware is worse than none |
| Quit fullscreen apps rather than cover them | Measured: no window level reaches another app's fullscreen Space, and `hide()` is refused. Quitting after three warnings is a consequence, not an ambush — which is exactly why the no-warning forced logout was rejected |
| Hang watchdog, and nothing else automatic | A crash already frees the screen; a hang is the only stranding failure. Every other automatic release is enforcement switching itself off uninvited |
| No report UI | The JSONL log plus `jq` answers the same questions. Charting is the longest tail in the build |
| Debug observes, release enforces | Locking yourself out of your own dev machine should require a deliberate act |
| Ad-hoc signing | Two machines, both yours. Notarisation solves a distribution problem that does not exist |

---

## 8. Explicitly out of scope

- Per-app or per-website limits — this is time, not content
- Weekday/weekend or per-day profiles — one profile, PIN for exceptions
- Multiple children or multiple Macs — one account on one machine
- Remote control, network reporting, cloud sync, or a companion phone app
- A report or charting UI — the JSONL log is the report
- MDM enrolment or a Screen Time configuration payload
- Notarisation and public distribution
- **Camera presence detection of any kind** — declined 2026-08-21, adopted the same day as
  T19, and **dropped unbuilt on 2026-08-27**. It would have sampled the camera anonymously
  in the ambiguous window (`idle > grace && media playing`) to tell "watching a film" from
  "went to bed with a game running". The 30-minute media cap (§2.2) already bounds both
  directions of that question, and half an hour of over- or under-counting is a small price
  against a camera on a child's machine. Face **recognition** was never on the table:
  it would mean enrolment and a biometric template at rest, for a distinction that barely
  matters on his own account behind his own login
- Bluetooth or phone-proximity presence detection — tracks a second device and is defeated
  by leaving the phone on the desk

**Known gaps, accepted and named:**

| Gap | Why it is open | What would close it |
|---|---|---|
| SSH into the account from another device | No user-space defence | Root daemon |
| Editing `session.json` by hand | Child owns his home directory | Root-owned state file, or HMAC keyed from the Keychain |
| `launchctl bootout` on his own agent | The GUI domain is his | Root LaunchDaemon in `/Library/LaunchDaemons` |
| Safe Mode possibly skipping LaunchAgents | Unverified — [T00](tasks/T00-kiosk-spike.md) checks it | Root daemon, if it turns out to be real |

Every one of these is closed by the same thing: the root LaunchDaemon from the original
`kid-logout.sh` sketch. It remains the documented upgrade path if the cover alone stops
being enough.
