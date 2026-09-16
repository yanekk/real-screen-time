# T18 — Ship

**Phase:** 5 · **Depends on:** all · **Weight:** medium

## Goal

Prove it on a scratch account, prove you can get back in, then put it on `child`'s account.

## 1. Manual checklist

From [TESTING.md](../TESTING.md). Run everything with `RST_MAX_COVER_SECONDS=30` set until
the last item.

**Reconciled against [FINDINGS.md](../FINDINGS.md) on 2026-08-27**, before asking anyone to
run anything: two of these lines are already answered outright and are ticked with the date
they were seen, and six more are half-answered and say which half is missing. The rest have
never been seen at all. Do not re-run a ticked line — re-running it costs a screen and
buys nothing that is not already written down.

- [x] Cover draws over a **fullscreen game** — real hardware; a VM answers this wrongly
      · **✅ 2026-08-28** — and note the design: a fullscreen game is **quit, not covered**
      (§2.6.2). `cover: asking Roblox to quit — it owns a fullscreen display` at
      `07:21:36.249`, `app_quit name:Roblox forced:false`, cover up at `.539`. **`forced:
      false`** — it went on `terminate()` and never reached the 10 s force. First time the
      shipping `FullscreenApps.swift` has ever run against a real game.
      · *Watch for: a **maximised** window is not a fullscreen one — Roblox zoomed measures
      `2560x1410 at (-2560, 30)` against a display of `2560x1440 at (-2560, 0)`, and is
      ignored on purpose. The first run of this line quit nothing for exactly that reason.*
- [ ] Cover draws over fullscreen video and over Mission Control
      · *Half: **Mission Control done** (2026-08-24, L5 pass — it did nothing). Fullscreen
      video unseen.*
- [ ] Covers the second display and the notch area
      · *Half: **second display done** (2026-08-24 — `cover: up on 2 window(s)`, one window
      per display). The notch is unseen, and so is plugging a display in while covered —
      there is still no `cover: screen layout changed while covered` line anywhere.*
- [ ] **Safe Mode**: does the LaunchAgent still load? If not, record it in
      [DESIGN.md §8](../DESIGN.md#8-explicitly-out-of-scope) — it is a real bypass
- [ ] Reboot → running again at login, budget intact
      · *Never seen. T16 watched `launchctl bootstrap` succeed from a button press
      (2026-08-26); nobody has watched a **login** bring the app back.*
- [x] Sleep 20 min → nothing charged · **✅ 2026-08-30 — about eight hours**, not twenty
      minutes: a session left with 15 minutes on it overnight still had 15 in the morning.
      · *The rule this checked — a clean exit charges nothing (§2.3) — is unchanged, and the
      code behind it was not touched by T21. **The observation is now the old rule**: that
      night crossed 06:00, and since 2026-09-04 the boundary discards the remainder, so the
      same run today would show 0 in the morning. Repeat it, if at all, with a sleep that does
      not cross 06:00 — otherwise a discard is indistinguishable from a charge by eye.*
- [ ] **A night with a session left unfinished** → the morning cover offers `Rozpocznij
      sesję — 30 minut`, not `Wznów sesję — pozostało N minut`, and **nothing is spoken at
      06:00** (§2.1, T21). Either a real night, or `day_reset_hour` moved to make one an hour
      away. Also worth reading afterwards: one `session_end` with `"reason":"discarded"`, and
      its `used_s` matching what he actually played rather than what was on the clock.
- [ ] Log out 20 min → nothing charged
- [ ] `kill -9` → gap charged, `tamper_gap` logged, app back within seconds
      · *Half: process death does release the presentation options — the 2026-08-24
      seatbelt exit gave the Dock and menu bar back, and charged `exit_kind: "unknown"`.
      The `tamper_gap` line on relaunch, and `KeepAlive` restarting the app, are unseen.*
- [x] Warnings do not steal focus from a game · **✅ 2026-08-28** — both warnings heard
      clearly over fullscreen Roblox's own audio, the game undisturbed. Add the finding
      that matters: **in a fullscreen Space no banner can be drawn at all**, so the spoken
      line is the only warning that exists there, not merely the primary one.
- [x] Menu-bar countdown matches the log · **✅ 2026-08-23** — the countdown was watched
      tracking a real ledger for a whole session, digits holding still.
- [x] PIN ▸ Disable stands down and re-arms by itself the next morning
      · **✅ 2026-08-29** — `day_reset_hour` moved to 21, `Wyłącz do jutra` at ~20:50, and at
      21:00 the cover returned **unaided**. Nothing clicked, nothing restarted.
      · *The count did **not** refill — the cover read `Na dziś koniec sesji`. Correct: the
      21:00 crossing landed back on Sat 29th, whose one session had been spent at 20:45
      under the old hour. **Refilling is a separate rule and still unverified**; it wants a
      genuinely unused date, i.e. the natural 06:00 crossing.*
- [ ] Cover appears immediately at login when the budget is already spent
- [ ] Fast user switch to the admin account → his clock pauses instantly, nothing charged
      · *Half: **no `Wznów` overlay** on return, verified 2026-08-29 — a switch is a
      pause/resume on the workspace notifications, where a logout ends the process and comes
      back through `awaitingResume`. **Still open: the countdown unchanged across the
      switch**, which is the half that costs him minutes if it is wrong.*
- [ ] A warning threshold crossed while switched away → **silent**, and fires on return
- [ ] A video playing with no input keeps counting to the 30-minute cap and stops there
      (DESIGN §2.2 — the cap is the whole answer since T19 was dropped, 2026-08-27)
- [ ] **System Settings ▸ Lock Screen ▸ Require password = immediately** on `child`'s account
- [x] `Zablokuj ekran` locks instantly; unlocking returns to the cover, not to the desktop
      · **✅ 2026-08-23** — locked immediately with no prompt, and the cover was still
      standing after the unlock.
- [ ] The lock screen offers **Switch User**, so you can take the Mac without him logging out

## 2. The recovery drill — do this before you need it

The single most important item in the list. Practise it while nothing is wrong.

> **A worked drill sheet lives at `/Users/Shared/rst-drill/drill.html`** (2026-08-28), readable
> from the throwaway account because a home directory is not — open it there before starting.
> It carries the four ways out of a cover, the admin/standard split (`sudo` does not exist on
> the child's account), and the two shapes recovery takes depending on whether he is logged in.
> **Deliberately not in the repo**: it hardcodes a scratch PIN and UID 503, and dies with the
> throwaway account. Regenerate it for `child` with his UID and no PIN in it.

- [ ] Reboot, log in as `admin` instead of `child`
- [ ] `sudo launchctl bootout gui/502/com.krolikowski.realscreentime.agent`
- [ ] Move the plist aside, confirm `child` logs in with nothing enforcing
- [ ] Put it back and confirm enforcement returns

A recovery procedure you have never run is a procedure you do not have.

## 3. README

Written for you in six months, not for a stranger: what it does, the four flags, where the
data lives, the three `jq` lines, and a pointer to [RECOVERY.md](../RECOVERY.md) in the
first paragraph.

Note the Gatekeeper prompt on first launch — the app is ad-hoc signed, so right-click ▸ Open
once. That is expected, not a defect.

## 4. Deploy

1. `make bundle`, copy to `/Applications`
2. Log in as `child`, launch, complete the wizard
3. **Show him the app.** The countdown, the warnings, what the PIN does, and that you can
   see the log. The design's stance is that this works as a visible boundary rather than a
   trap — that stance only holds if the conversation actually happens
4. Reboot and confirm it comes back
5. Delete `spike/`
6. Update [PROGRESS.md](../PROGRESS.md): all tasks ✅, findings recorded in [FINDINGS.md](../FINDINGS.md)

## 5. Done when

**Dropped 2026-08-28, at the user's direction: the "watch it for a week" section and the
week-long clause in this gate.** It was the one requirement no session could ever close —
a task cannot be finished by waiting — and the monitoring it asked for is not lost: the
three `jq` lines live in the README, where the person who needs them will actually look.

T18 is done when:

- the checklist in §1 is green, or every remaining line is named and waived on purpose
- **the recovery drill in §2 is something you have actually done**, not something you have read
- it is installed on `child`'s account, he has been shown it, and it comes back after a reboot
- `spike/` is deleted and `PROGRESS.md` records the findings

The PIN will get used in anger on its own schedule; it is not a gate.
