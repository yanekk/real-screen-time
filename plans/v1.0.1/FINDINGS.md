# Findings log

**What the build taught.** Read the rows touching the task you pick up; read it whole before
anything only a person can verify — a ✅ row is the *entire* record that something was seen
working for real.

**Newest first. Forty words a row, counted.** The long version is in the commit message.

Legend: 🐞 defect found · ✅ verified by hand with the user · 📌 worth knowing ·
🔄 a decision the user changed.

| Date | | Finding |
|---|---|---|
| 2026-09-16 | 📌 | T05 review: redaction was working-tree only. Child name, admin username, `/Users/admin` paths remain throughout git history. T06 step 1 must choose a fresh initial commit, not whole history, or they publish. |
| 2026-09-15 | 📌 | T05 scan result: no secrets, keys, tokens or `.env` in the working tree or the 181-commit history; no `config`/`ledger`/`events` state file ever committed. App has no third-party services. uids 501/502 kept (generic Mac defaults). |
| 2026-09-16 | 📌 | T05 decisions applied: child's name → "your child"/`child` and admin username → `admin` across code/tests/README/all plan docs (416 green); commit author name+email kept public, no history rewrite. |
| 2026-09-16 | 📌 | T05: bundle id kept as `com.krolikowski.realscreentime` — user declined the `yanekk` rename once told a bundle-id change resets all macOS permissions (Camera/Screen-Recording/Accessibility/Automation) and orphans the old LaunchAgent. Surname stays public in the app id. |
| 2026-09-15 | 📌 | T04 swap.sh (review): with `set -e`, a `ditto` failure after the `mv` old→`.bak` leaves `/Applications` app gone (restore from `.bak`), yet reports "the app was not changed". Confirm/watch during T06 hand run; fix = restore `.bak` on ditto failure. |
| 2026-09-15 | 📌 | T04 `firstAppBundle` (review): finds `.app` at unzip top level only, not nested. Comment corrected; T06 must keep the release asset bundle-at-root or it reports "didn't contain the app". No live bug — our packaging is top-level. |
| 2026-09-15 | 📌 | T04 relaunch: `open`ing the new build races the old `InstanceLock` (`alreadyRunning` → new instance exits quietly), so relaunch is `exit(0)`+KeepAlive, not `open`. launchd's 10s restart throttle only bites a just-started process; a long-up app relaunches at once. Do not switch to `open`. |
| 2026-09-15 | ✅ | T02 hand-run (user): cover required → Chrome/YouTube quit and the sound stopped, as expected. Audio-emitting eviction (CoreAudio, fullscreen∪audio union) works on the real machine; own pid excluded so the app's warnings/cover sound are unaffected. |
| 2026-09-15 | ✅ | T00 spike (hand-run): CoreAudio process API works here, no entitlement, no permission prompt; IsRunningOutput drops on pause. Browser's emitting pid is a HELPER — map to owner via parent chain. Quitting the owner silences it. §2.2 route = CoreAudio + helper→owner map, not the bundle-id fallback. |
| 2026-09-15 | 📌 | Sound-fix root cause: only fullscreen apps are quit (foundational §2.6.2); a Chrome window is covered, not quit, so its audio plays on and lock does not stop it. Fix extends eviction to audio-emitting apps. |
