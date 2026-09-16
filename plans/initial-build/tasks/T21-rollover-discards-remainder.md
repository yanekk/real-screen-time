# T21 — 06:00 discards whatever is left on the session

**Phase:** 6 · **Depends on:** T04, T05, T06, T20 · **Weight:** small

## Goal

**Nothing carries across 06:00.** Whatever minutes remain on a session at the day boundary
— his own, or granted behind the PIN — are discarded, and the new day begins with a fresh
allowance and an empty clock.

## What changes, in the shape it was reported

```
1. Start a session, do not finish it
2. Sleep. Wake in the morning, log in

Now:      the cover offers `Wznów sesję — pozostało 15 minut`, he finishes those,
          and only then is the new day's session offered — 45 minutes that morning
Wanted:   the cover offers `Rozpocznij sesję — 30 minut` straight away
```

`SessionState.rollOverIfNeeded` deliberately carries `remainingSeconds` across the
boundary today, on the grounds that a session granted at 05:50 was legitimately granted.
DESIGN §2.1's **"a session survives a logout"** is what makes the overnight case work the
way it does: the remainder outlives the logout, and nothing then bounded it by the day.

## The decision

**The user chose, 2026-09-04**, all four:

1. **The 06:00 line is what discards, always** — asleep or awake, playing or paused. The
   rejected alternative made the loss conditional on an interruption, which leaves the
   hole of a Mac left awake all night with a paused session: the reported scenario,
   surviving the fix.
2. **PIN-granted minutes go with the rest.** One pot, no distinction; the parent grants
   again if they want to. Keeping a grant alive across the night means tracking two kinds
   of minute through every path that spends one.
3. **The child is told nothing.** The cover simply offers the new day's session. No line,
   no spoken warning — 06:00 is before he is up, and the offer is the honest statement.
4. **Built before the deploy to `child`**, so the machine he gets carries this rule from the
   first day rather than learning the old one and having it changed underneath him.

**Nobody is left short.** The allowance refills on the same instant the remainder is
discarded, so the trade is always leftover minutes for a full fresh session. The one
exception is `self_service_sessions_per_day: 0`, where there is no self-service allowance
to refill — see the criteria.

## Interface

`rollOverIfNeeded` stops carrying the remainder, and reports what it discarded so the
caller can tell a discard from a charge:

```swift
/// Returns the seconds discarded at the boundary — 0 when there was nothing on the clock.
@discardableResult
private mutating func rollOverIfNeeded(at now: Date, config: Config,
                                       calendar: Calendar) -> TimeInterval
```

The existing conditional clear of `wasRunning`/`isLive` becomes unconditional: with the
remainder always zero on the far side of the boundary, the two cases have collapsed into
one. **`retireIfSpent` (T20) stays exactly as it is** — its straddle door becomes
unreachable, but the other two are same-day and untouched by this.

## The three traps

Each of these ships a bug the user would see or hear. They exist because `Engine` detects
a spent session by comparing `remainingSeconds` before and after, and **a discarded
remainder is byte-for-byte identical to one that ran out.**

1. **`Engine.tick` would say `Czas minął` at six in the morning.** `if before > 0,
   state.remainingSeconds <= 0 { endSession(.expired, at: now) }`, and `.expired` is the
   one end reason that is spoken aloud (§2.4's 0 row). The user asked for silence, and this
   is Polish spoken into an empty room.
2. **`used_s` in the event log would be inflated by the minutes he never used.**
   `charged += max(0, before - state.remainingSeconds)` reads the discard as time spent, so
   a parent looking at why the evening was short sees 30 minutes against a session he played
   15 of.
3. **The wake path is `launch`, not `tick`, and it has both bugs of its own.** `charged =
   max(0, before - state.remainingSeconds)` and `if before > 0, … { endSession(.gap, …) }`.
   **The reported scenario goes through this path**, because sleeping writes the clean-exit
   marker and waking reconciles against it — so a fix that only handles `tick` fixes nothing
   for the case that prompted the task.

## What the log should say

A `session_end` with a **new `EndReason.discarded`**, and `used_s` reporting what he
actually spent rather than what was on the clock. Silent by construction: `endSession`
announces `.expired` and nothing else.

*Specified by the implementing session's predecessor rather than by the user, on the
grounds that the parent reading the log wants to know where the minutes went. It is one
word in an English file behind the PIN — say so and change it if the user would rather it
read differently.*

## What must not change

- **A session still survives a logout within a day** (DESIGN §2.1). He must never learn
  that logging out to free the Mac costs him time. Only 06:00 takes minutes now.
- **A stand-down still re-arms at 06:00** (§2.5), and `disable(until:)` still zeroes the
  remainder while leaving `wasRunning` set — a stand-down lifted early is still the expired
  cover, not a fresh offer.
- **T20's two same-day doors.** `self_service_sessions_per_day: 2` and a PIN grant taken
  before his own session both still need `retireIfSpent`.

## Acceptance criteria

- [x] A session left with minutes on it overnight starts the morning at `Rozpocznij sesję
      — 30 minut`, not `Wznów sesję`
- [x] **Nothing is spoken and no banner appears** when minutes are discarded at 06:00
- [x] The event log records the discard once, with `used_s` equal to what he actually used
- [x] The same holds through the **wake path** (`launch`/`reconcile`), not only the tick —
      this is the reported scenario, and it is the one that would be missed
- [x] Someone actively playing at 06:00 is interrupted there and immediately offered the
      new day's session
- [x] PIN-granted minutes are discarded on the same line as his own
- [x] A stand-down still re-arms at 06:00, unchanged, and lifting it early still gives the
      expired cover
- [x] With `self_service_sessions_per_day: 0`, 06:00 discards and leaves `Na dziś koniec
      sesji` — honest: that household grants every minute by PIN
- [x] `make test` green — **382 in 1.8 s** (was 376). T20's
      `spentAfterRolloverStillOffersTheNewDay` did fail, exactly as predicted, and was
      rewritten to the new rule rather than deleted; the T20 rule it guards is still live
      through its two same-day doors, which two other tests hold

## Done when

Reviewed by a session that did not write it.

**The headless half is the whole of what a session can prove here** — this is `RSTCore`
arithmetic, and the day boundary is exactly what T03's fixed-calendar tests exist for. The
platform half is one line on **T18's checklist**: a real night with a session left
unfinished, or the reset hour moved to make one, and the morning cover read by eye.
