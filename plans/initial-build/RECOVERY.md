# Recovery — getting the Mac back

**The guarantee: reboot, and log in as `admin` instead of `child`.**

A LaunchAgent exists only inside a logged-in user's session. The login window is a context
this app can never reach, has no code running in, and cannot influence. That path needs no
network, no prior setup, no terminal skill and no cooperation from the app — and it is why
the app carries only one automatic safety net instead of five.

Everything below is a faster route to the same place.

---

## First: is it hung, or is it working?

They look identical and need different answers.

**A crashed app cannot leave the screen covered.** Windows belong to processes; when a
process dies the window server destroys its windows and releases the kiosk presentation
options in the same instant. If the screen is covered, something is *running*.

Type a digit into the PIN field. If the field shows a character, the app is alive and
working — you are in "I disagree with it" territory, not "it is broken". Go to Route 1.

If nothing appears, it is hung. **Wait 30 seconds.** The watchdog should kill it by
itself, the cover should vanish, and launchd should bring back a fresh instance. If that
happens, the app is fine and something transient went wrong; check `app.log`.

---

## Route 1 — The PIN (app is healthy)

| You want | Do |
|---|---|
| 15 more minutes | Type the PIN |
| The Mac back for the evening | PIN ▸ **Disable** — stands down until 06:00 tomorrow |
| The Mac back for good | PIN ▸ Disable, then uninstall from the menu bar |

This covers almost every real situation. The routes below are for when the app is not
cooperating.

## Route 2 — Wait for the watchdog (app is hung)

30 seconds. It calls `exit(0)`, the cover dies with the process, launchd relaunches it.

If the fresh instance immediately covers again and hangs again, you have a reproducible
bug — go to Route 3 and take `app.log` with you.

## Route 3 — Reboot to the login window ★

**This always works.**

1. Hold the power button until the Mac restarts.
2. At the login window, choose **`admin`**, not `child`.
3. Stop the agent and take it out of the way:

```bash
sudo launchctl bootout gui/502/com.krolikowski.realscreentime.agent
sudo mv /Users/child/Library/LaunchAgents/com.krolikowski.realscreentime.agent.plist ~/rst-agent.plist.bak
```

**The `bootout` will fail here with `Could not find domain`, and that is correct.** You have just
rebooted, so `child` has no session and `gui/502` does not exist — there is nothing loaded to
remove. **Moving the plist is what does the work on this route.** The line is kept because it is
harmless and because the same command is the whole job on the route below.

4. Fast-user-switch to `child` — the session comes up with nothing enforcing.

To put it back: move the plist home and `sudo launchctl bootstrap gui/502 <path>`.

### If you did *not* reboot — `bootout` alone is not enough

**Measured 2026-08-28, in the T18 drill, and it cost a confused ten minutes.** `bootout` removes
the launchd *job*. It does not touch a copy of the app that launchd did not start — one opened
from Finder, say. The command reported success and the cover stayed on the screen.

So while `child` is still logged in, disabling has **two halves**:

```bash
sudo launchctl bootout gui/502/com.krolikowski.realscreentime.agent   # stop it restarting
sudo pkill -TERM -u 502 -x RealScreenTime                             # stop what is on screen
```

`SIGTERM`, not `SIGKILL`: the app catches it, hands the Dock and menu bar back, and writes its
clean-exit marker, so **nothing is charged**. It does not go through the `Cmd+Q` refusal, which
guards only the AppKit quit path. Verify with `pgrep -u 502 -x RealScreenTime` — silence is
success. Force with `-KILL` only if `-TERM` does not take, and expect a `tamper_gap`.

## Route 4 — Fast user switch — ⚠️ DOES NOT WORK

Kept here because it is the obvious thing to try, and trying it during an actual lockout
would waste the minutes you least want to waste.

`Ctrl+Cmd+Q` **does not lock the screen** while the cover is up — measured 2026-08-21
on the T00 spike and confirmed 2026-08-24 on the shipping app (T12, L5 scratch account).
Kiosk mode suppresses it; the chord reaches the app as an ordinary keystroke. With the
menu bar hidden there is no fast-user-switching menu either.

There is no way to reach another session from inside a covered one. **Use Route 3.**

## Route 5 — Recovery Mode

The last resort. Needs the admin password; works when nothing else does, including a
login window that will not appear.

1. Shut down. Hold the **power button** until "Loading startup options".
2. **Options** ▸ Continue ▸ authenticate.
3. **Utilities ▸ Terminal**:

```bash
ls /Volumes
mv "/Volumes/Macintosh HD - Data/Users/child/Library/LaunchAgents/com.krolikowski.realscreentime.agent.plist" \
   "/Volumes/Macintosh HD - Data/Users/child/rst-agent.plist.bak"
```

4. Reboot.

---

## Uninstalling completely

From `child`'s session with the app cooperating: menu bar ▸ Settings 🔒 ▸ Uninstall.

By hand, from the admin account:

```bash
sudo launchctl bootout gui/502/com.krolikowski.realscreentime.agent
sudo pkill -TERM -u 502 -x RealScreenTime      # or the rm below races a running app
sudo rm -f /Users/child/Library/LaunchAgents/com.krolikowski.realscreentime.agent.plist
sudo rm -rf "/Users/child/Library/Application Support/RealScreenTime"
sudo rm -rf /Applications/RealScreenTime.app
```

The `pkill` matters here for the same reason as on Route 3: `bootout` may leave a running copy
behind, and deleting the data directory underneath a live app is how you get a half-written
ledger instead of a clean uninstall.

Keep `events.jsonl` first if the history is of interest.

---

## Reading the log

```bash
LOG=~child/Library/Application\ Support/RealScreenTime/events.jsonl

sudo jq -c 'select(.type=="tamper_gap")' "$LOG"        # was it killed?
sudo jq -c 'select(.type=="extended")'   "$LOG"        # how often was the PIN used?
sudo jq -c 'select(.type=="watchdog_exit")' "$LOG"     # has it been hanging?
```

A `watchdog_exit` means it hung and recovered by itself. More than one or two of those is
a bug worth chasing, not a machine worth rebooting.

---

## What is deliberately not here

- **SSH.** It only helps if Remote Login was enabled before you needed it, and Route 3
  already always works. Not worth a permanently open service.
- **A master unlock code.** A second secret that can leak, solving a problem Route 3
  already solves.
- **A `DISABLED` sentinel file.** Considered and declined — another way for enforcement to
  switch itself off for reasons nobody chose.
- **Fail-open on a corrupt config.** A corrupt config is repaired from shipped defaults
  and enforcement continues. The single exception, which is a logical necessity rather
  than a policy: **no PIN hash means the app must not cover anything**, because nothing
  could then uncover it.
