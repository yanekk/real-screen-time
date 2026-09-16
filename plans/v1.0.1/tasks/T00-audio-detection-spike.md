# T00 — Spike: can this machine list which processes are making sound?

**Phase:** 0 · **Depends on:** — · **Weight:** light

## Goal

The whole sound fix (T02) rests on one unproven assumption: that this Mac — ad-hoc signed,
Command Line Tools only, macOS 26.5 — can tell which running processes are outputting audio,
and get their pids, without a special entitlement or a permission prompt the child could
refuse. Apple's audio APIs are fussy and behave differently outside a real notarised `.app`,
so this is measured here before §2.2 is designed on top of it. Throwaway code, deleted when
the answer is written down.

## Design sections this implements

Settles [DESIGN.md](../DESIGN.md) §2.2 — it names the candidate API and the fallback; this
spike picks between them.

## Files

A throwaway file under a scratch location (e.g. a tiny `Sources/` target or a standalone
`.swift` run with `swift`), not wired into the app. Deleted after; nothing in `RSTCore` or the
shipped `RSTApp` is touched by this task.

## What to try

The candidate is CoreAudio's process API (macOS 14.4+):

```
kAudioHardwarePropertyProcessObjectList   // enumerate process AudioObjectIDs
kAudioProcessPropertyPID                   // → pid_t for each
kAudioProcessPropertyIsRunningOutput       // → is it outputting audio right now?
```

Reading these should need no entitlement (only *tapping* audio does). Confirm: with a browser
playing a YouTube video, does the list include Chrome's pid with `IsRunningOutput == true`,
and does it drop out when the video is paused? Does it work run as `child`?

**Confirm the pid is one T02 can act on.** T02 quits the *application* by pid
(`NSRunningApplication(processIdentifier:).terminate()`). Chrome plays audio from a helper
(renderer) process, so if the API reports the helper's pid rather than the main app's, quitting
that pid closes a tab's helper, not Chrome, and the sound may not stop. Record which pid the
API returns for a browser — the main app or a helper — and whether terminating it actually
quits the app and silences it. If it is a helper, T02's detection has to map it to the owning
application; note that so §2.2 can account for it.

**If it does not work** (symbol missing, always empty, needs a grant, or wrong in an ad-hoc
CLT build), record why, and confirm the fallback is viable: quitting a fixed list of media-app
bundle ids (`com.google.Chrome`, `com.apple.Safari`, `com.apple.Music`,
`com.spotify.client`, …) found running via `NSRunningApplication`.

## Done when

- [ ] It is known, on this machine, whether the CoreAudio process API reports emitting
      processes with pids and no entitlement — yes or no, with the evidence.
- [ ] It is known whether the reported pid is the quittable application or a helper process,
      so T02 knows whether it must map a helper back to its owning app.
- [ ] The answer and the chosen route (CoreAudio, or the bundle-id fallback) are written to
      `FINDINGS.md` with the date.
- [ ] The spike code is deleted; nothing shipped depends on it.

## Needs a person

This is the user's to run — it needs a real audio source, a look at whether any permission
prompt appears, and a run in the child's account. The implementing session writes the probe,
hands it over, and waits.

```
# built by the implementing session; run by the user, e.g.:
swift run <spike-target>        # with a YouTube video playing in Chrome, then paused
```

Expect: the probe prints the pids and names of processes currently making sound, updating as
audio starts and stops.
Tell me: whether Chrome shows up while playing and drops when paused, whether the pid it
reports is Chrome itself or a helper (and whether quitting that pid actually closes Chrome and
stops the sound), whether any permission prompt appeared, and whether it behaves the same run
from the child's account.
