# T12 — Kiosk lockdown

**Phase:** 3 · **Depends on:** T11, T00 · **Weight:** medium

## Goal

Turn the cover from a window you can Cmd+Tab away from into one you cannot. This is the
task that makes the app do what Screen Time did not.

## The options — verified, not assumed

T00 measured this exact set as valid on macOS 26.5.1:

```swift
NSApp.presentationOptions = [
    .hideDock, .hideMenuBar,
    .disableProcessSwitching,     // Cmd+Tab
    .disableForceQuit,            // Cmd+Opt+Esc
    .disableSessionTermination,   // Apple ▸ Log Out / Shut Down
    .disableHideApplication,      // Cmd+H
    .disableAppleMenu,
]
```

**Set the whole set at once.** T00 also established that `hideMenuBar`,
`disableProcessSwitching`, `disableForceQuit` and `disableSessionTermination` each *raise*
when set without `hideDock`. Never build the set up incrementally.

**And a raise is not a crash.** `NSApplication` catches exceptions thrown in its run loop,
logs them, and carries on — so a bad set hangs rather than crashing. Set the options, read
them back, compare, and log a mismatch loudly. Do not rely on a crash to tell you.

## Cmd+Q is not covered by any of them

Measured in T00: **`Cmd+Q` closed the spike straight through the full option set.**
`disableForceQuit` is the `Cmd+Opt+Esc` panel; `disableSessionTermination` is Log Out /
Restart / Shut Down. An app terminating itself is neither.

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    covering ? .terminateCancel : .terminateNow
}
```

Add a local `NSEvent` monitor swallowing `Cmd+Q` as well, and keep **both**. They cover
different things: the monitor sees keystrokes only while the app is frontmost and cannot
see a scripted quit, while `applicationShouldTerminate` catches every `terminate(_:)` —
AppleScript, the Dock menu, another app asking politely — but not `SIGKILL`.

In the T00 re-run the monitor caught all 14 `Cmd+Q` presses *before* the delegate method
was reached, so that method is still unverified. Test it directly:
`osascript -e 'quit app "RealScreenTime"'`.

The watchdog's `exit(0)` bypasses this method, deliberately — the escape hatch must not be
blockable by the thing it is escaping (T15).

Treat this as the general lesson: **every quit path you have not personally tested is
open.** Check the Dock menu's Quit, `osascript -e 'quit app "RealScreenTime"'`, and
`launchctl kickstart -k`.

## Three more behaviours to get right

1. **Activation policy.** Presentation options require `.regular`. The app runs
   `.accessory` for its menu bar, so: switch to `.regular` before covering, back to
   `.accessory` after. Confirm the status item survives the round trip (T10).
2. **Frontmost only.** The options lapse whenever the app is not active. Observe
   `didResignActiveNotification`, call `NSApp.activate(ignoringOtherApps: true)`, and
   re-assert. The T00 spike prints `RESIGNED ACTIVE` when this happens — keep that as a
   logged event, because it means something got through.
3. **Release cleanly.** On uncover, set `presentationOptions = []` before dropping the
   windows. Leaving them set with no cover on screen is a Mac with no Dock and no menu bar
   and no explanation.

## Fullscreen

Drop `RST_COVER_FRAME` and cover `screen.frame` on every display.

If T00 Part 3 found that a `.screenSaver` window does *not* draw over a fullscreen game,
apply S.TFU's accepted trade-off: `NSRunningApplication.hide()` on the frontmost app, or
`NSWorkspace.shared.hideOtherApplications()`, before covering. Leave the game running
underneath; do not kill it.

## Testing — L5, scratch account

This is the one thing that cannot be tested in a box: `presentationOptions` locks the whole
app, so real Cmd+Tab blocking only exists when it is really on.

```bash
sudo sysadminctl -addUser rst-test -password test -fullName "RST Test"
```

Fast-user-switch in, run with `RST_MAX_COVER_SECONDS=30` and `RST_DATA_DIR` pointed
somewhere disposable, then switch back and assert from your own account:

```bash
sudo jq -c . /Users/rst-test/Library/Application\ Support/RealScreenTime/events.jsonl
```

Being locked out of a session does not mean being locked out of its filesystem.

- [ ] Cmd+Tab, Cmd+Q, Cmd+Opt+Esc all do nothing
- [ ] Apple ▸ Log Out and Shut Down unavailable
- [ ] Mission Control and the Spaces swipe reveal nothing
- [ ] `Ctrl+Cmd+Q` — record the result; it decides RECOVERY.md Route 4
- [ ] Kill the process from the admin account → cover vanishes, launchd relaunches, cover
      returns, `tamper_gap` logged
- [ ] Uncover leaves the Dock and menu bar restored

## Done when

The scratch-account checklist is complete and the findings — especially `Ctrl+Cmd+Q` — are
recorded in [PROGRESS.md](../PROGRESS.md) and reflected in
[RECOVERY.md](../RECOVERY.md).
