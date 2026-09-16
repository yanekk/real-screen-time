# T16 — First run and self-install

**Phase:** 4 · **Depends on:** T13 · **Weight:** heavy

## Goal

Drag the `.app` to `/Applications`, launch it once as `child`, answer four questions, done.
No terminal, no `sudo`, no installer script.

## The wizard

| Step | Asks | Produces |
|---|---|---|
| 1. Welcome | nothing — says what the app does, and that it is not hidden | — |
| 2. PIN | chosen twice | `pinHash`, `pinSalt` |
| 3. Sessions | session length and sessions per day, pre-filled 30 minutes and 1 | `sessionMinutes`, `selfServiceSessionsPerDay` |
| 4. Start at login | writes and bootstraps the LaunchAgent | the plist |

**Step 1 is not politeness.** The design's whole stance is that this works as a visible
boundary rather than a trap, and the first thing it does should say so. S.TFU makes the same
argument for the same reason.

**Step 2 cannot be skipped and has no default.** Per [T05](T05-policy.md) step 1, an app
with no PIN must never cover the screen — so a wizard that lets you past this step produces
an app that does nothing at all.

## Configured or not

The app counts as configured when `config.json` exists **and** `pinHash` is non-empty.
Anything else re-runs the wizard. A half-finished setup is not a usable state, and a
half-finished setup that enforces is a trap.

## The LaunchAgent

`~/Library/LaunchAgents/com.krolikowski.realscreentime.agent.plist`:

```xml
<key>Label</key>            <string>com.krolikowski.realscreentime.agent</string>
<key>ProgramArguments</key> <array><string>/Applications/RealScreenTime.app/Contents/MacOS/RealScreenTime</string></array>
<key>RunAtLoad</key>        <true/>
<key>KeepAlive</key>        <true/>
```

Bootstrap it with `launchctl bootstrap gui/$UID <plist>` via `Process`. If it is already
loaded, `bootout` first — a failed bootstrap because the label exists is the most likely
way this step quietly does nothing.

`KeepAlive` is what closes the casual kill: killed, the app is back within seconds, and the
gap it was away is charged (T04). Together those make killing it pointless rather than
merely difficult.

## Known limits, already accepted

`child` owns his own `~/Library/LaunchAgents` and can run `launchctl bootout` on his own
agent without admin rights. There is no user-space fix; the gap charging is the answer, and
the real fix is the root daemon recorded as the upgrade path in
[DESIGN.md §8](../DESIGN.md#8-explicitly-out-of-scope). **Do not add a privileged helper on
your own initiative** — that decision was made explicitly and answered no.

## Uninstall

A menu item behind the PIN: `bootout`, remove the plist, optionally remove the data
directory, quit. Keeping `events.jsonl` by default is the friendlier choice.

## Gotchas

- **Test with `RST_DATA_DIR`** pointed somewhere disposable, or the first run you test is
  the last one you can test without deleting real state.
- The plist must point at the **installed** binary in `/Applications`, not at
  `.build/debug/…`. A LaunchAgent pointing into a build directory is a confusing
  half-working state that survives a `swift build` and then does not.
- Ad-hoc signing means Gatekeeper will complain on first launch. Right-click ▸ Open once.
  Document it in the README rather than fighting it.

## Done when

On the scratch account: drag in, launch, complete the wizard, reboot, and the app is running
with the budget intact and the countdown in the menu bar.
