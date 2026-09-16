# Real Screen Time v1.0.1 — Design

> This plan builds on [`../initial-build/DESIGN.md`](../initial-build/DESIGN.md), the
> foundational design. Read it first — everything about sessions, the cover, the warnings,
> the PIN, the Core/App boundary and the environment lives there and is not repeated here.
> This document covers only what v1.0.1 adds or changes, and cites the foundational sections
> by number (its §2.6.2, its §5, etc.).

## 1. Purpose

v1.0.1 is the first named release. It does three things: gives the app a real version number
shown to the parent, adds an on-demand Update button that pulls a new build from GitHub, and
fixes a real bug — sound keeps playing when the cover is up.

### Success criteria

- When the child's time runs out with YouTube playing in a Chrome window, the sound stops. Today
  it does not, because a windowed app is covered, not quit.
- The parent can read the running version and update to a newer one from Settings, entering
  their admin password once.
- The version the bundle reports and the version the code reports can never disagree.

### Stance

- **Silence is part of taking the screen.** The cover that hides the picture must also stop
  the sound, or it has not actually ended the turn. This is why the sound fix is the release's
  centre, not a footnote.
- **The parent owns updates, the child cannot reach them.** No background checks, no
  auto-install. The button is behind the PIN and needs an admin password to land. Updating is
  a deliberate parental act.
- **An update must never be able to brick enforcement or the way back in.** The foundational
  §5 recovery (reboot, log in as admin) stays the ultimate net, and the updater keeps the
  previous build so a bad one can be rolled back by hand.

---

## 2. Behaviour specification

### 2.1 Versioning

**One version string, `1.0.1`, defined once in `RSTCore` and stamped into the bundle at build
time.** The single source is a constant in Core; `make bundle` writes it into the assembled
`Info.plist`'s `CFBundleShortVersionString`. Runtime always reads the Core constant, so
`swift run` (which has no `Info.plist`) and the installed `.app` report the same string.

Why not read `Info.plist` at runtime: a debug `swift run` is not a bundle and has no plist, so
a plist-only version would be blank in exactly the mode a developer uses most. Why stamp the
plist anyway: Finder's Get Info and the release tooling read it, and a plist that disagrees
with the code is the drift this rule exists to prevent.

The version is a plain `MAJOR.MINOR.PATCH` string. Comparison for the updater is numeric per
component (§2.3), not lexical, so `1.0.10` is correctly newer than `1.0.9`.

### 2.2 The sound fix — quit apps that are making sound

**When a cover is required, every app currently emitting audio is quit, on top of the
fullscreen apps already quit** (foundational §2.6.2). Covering a window hides its picture but
does nothing to its sound: a Chrome tab playing YouTube keeps playing behind the cover, and
locking the screen does not help because Chrome is still alive. Quitting the app is what
actually stops the sound.

This reuses the foundational §2.6.2 machinery exactly, and inherits its fairness argument
unchanged — the child has had a chime, a spoken line and a banner at ten, five and one
minutes before anything closes:

- **Only when a cover is actually required.** Never on a warning, never during normal use.
- **`terminate()` first, `forceTerminate()` after 10 seconds.** Let the app save; a modal
  save sheet must not hold the cover off indefinitely.
- **Re-checked on every tick while covered.** A background tab that starts playing after the
  cover is up must be caught too.
- **Logged as `app_quit`** with the app name and whether it was forced, same event as today,
  so the parent can see what was closed and the child is believed about what was lost.
- **Gated behind the same enforcement check.** A debug build must never quit a real app.

**Our own process is excluded.** The app is speaking its own warnings and may play its own
sound; quitting itself would be absurd and would drop the cover. Exclude by pid.

**Detection is by emitting-audio, not by app identity.** The user chose "quit anything making
sound" over "quit browsers": the honest reading is that when the turn ends the machine goes
quiet, whatever the source. Accepted cost: music or a video the parent left playing is also
closed when the child's time runs out. That only happens when a cover is required — the
machine is being taken from the child at that moment — so silencing everything is the intent.

**The detection API is unproven on this machine and is settled by T00 before this is
designed further.** The candidate is CoreAudio's process API
(`kAudioHardwarePropertyProcessObjectList` plus per-process `kAudioProcessPropertyIsRunning`/
`IsRunningOutput` and `kAudioProcessPropertyPID`, macOS 14.4+), which reads which processes
are outputting audio and needs no entitlement for reading. If T00 shows it does not work in an
ad-hoc CLT build here, the fallback is to quit a fixed list of known media apps by bundle id
(browsers, Music, Spotify), which is less thorough but reaches the reported case. T00 decides
which, and this section is finalised then.

### 2.3 The update mechanism

**An Update button in Settings, pressed by the parent, that pulls the latest release from a
public GitHub repo and installs it.** No background checking and no notifications — the user
was explicit: "I apply only… It's my app and I control it." The whole flow, on press:

1. Fetch `https://api.github.com/repos/{owner}/{repo}/releases/latest` (public, no auth).
2. Parse `tag_name` (e.g. `v1.0.2`) and the download URL of the `.app.zip` asset.
3. Compare the tag to the running version (§2.1). If not newer, say so and stop.
4. Download the asset to a temp dir, unzip it, and check it is a valid signed `.app` bundle
   before touching the installed one.
5. Install it over `/Applications/RealScreenTime.app`, keeping the old build as a backup, and
   relaunch into the new version.

**The install step needs an admin password.** The app runs as the child, who is not an admin and
cannot write `/Applications` (foundational environment table). The swap is done through a
single macOS admin-authentication prompt (`osascript … with administrator privileges` running
the copy), which the parent — already past the PIN — answers once. The alternative, moving the
app somewhere the child can write, was declined because it weakens where the enforcing binary lives.

**Pressing Update installs straight away** when the release is newer: fetch, compare, and if
newer, download and go to the admin prompt. There is no separate "an update is available —
install?" step. The admin-password prompt is the one point of no return the parent answers, and
a confirm step before it would add a click without adding a real gate (user, 2026-09-15).

**Update is allowed even while a cover is up.** Settings can be open under the cover — a session
can expire while the parent reads it, and `SettingsWindow` already guards for `isCovering()` —
and the parent may press Update then. Installing relaunches the app, which briefly leaves the
screen uncovered before the new build re-covers. That gap is accepted: the parent has just
authenticated and both parent and child are present at that moment, and blocking a rare,
deliberate parental action to avoid a two-second gap is not worth the extra state (user,
2026-09-15). The updater does not special-case the cover.

**Split across the boundary:** parsing the release JSON and comparing versions are pure and
live in `RSTCore` (T03); downloading, unzipping, verifying, the admin swap and the relaunch are
platform-shaped and live in `RSTApp` (T04).

**Reversibility.** Replacing the installed app is close to irreversible on its own, so the
updater keeps the previous bundle (`RealScreenTime.app.bak` or equivalent) after a successful
swap, and the foundational §5 recovery stays the ultimate net if a new build will not run. The
release the app fetches is only as good as what was published; the pre-publish scan (T05) and
the parent's deliberate press are the gates before a build reaches the child's machine.

### 2.4 The unhappy paths

- **Offline / GitHub unreachable when Update is pressed.** Say so plainly in Settings and
  leave the installed app untouched. A failed check must never leave a half-installed app.
- **Already on the latest version.** Say so; do nothing.
- **Downloaded asset is corrupt or not a valid bundle.** Refuse before swapping. The rule is
  that the installed app is only ever replaced by something that passed validation.
- **Admin prompt cancelled.** No change; the installed app stays as it was.
- **Audio detection returns a transient.** Something that made a sound for a moment may be
  quit; acceptable, because this only runs when a cover is required and the child's turn is
  over. We do not try to distinguish "playing media" from "made one beep."
- **An app that is both fullscreen and making sound.** Counted once — the eviction set is the
  union of fullscreen apps and audio-emitting apps, deduplicated by pid.

---

## 3. Architecture

### 3.1 The boundary

Unchanged from the foundational §3.1: `RSTCore` is Foundation + CryptoKit only, `RSTApp` is
everything platform-shaped, and the import-scanning test enforces it. If that test fails the
fix is to move the code, never to relax the test.

What v1.0.1 adds sits on the right side of that line:

- **Pure (`RSTCore`):** the version constant and its comparison (§2.1), and the release-JSON
  parsing and version-newer decision (§2.3). These are functions of their inputs and are
  tested exhaustively.
- **Platform (`RSTApp`):** audio-emitting-process detection (CoreAudio), the extended
  eviction, the network download, unzip, bundle validation, admin swap and relaunch. These are
  verified by hand with the user, because none of them can be established headless.

### 3.2 Modules

- `RSTCore/AppVersion.swift` (new) — the version constant and `compare`. Pure.
- `RSTCore/ReleaseInfo.swift` (new) — parse GitHub release JSON, decide up-to-date/newer/error.
  Pure.
- `RSTApp/FullscreenApps.swift` (changed) — generalised so the evictor's target set is
  fullscreen apps ∪ audio-emitting apps. Detection helper for emitting-audio processes added
  here or in a sibling file.
- `RSTApp/Updater.swift` (new) — download, unzip, validate, admin swap, relaunch. Depends on
  `ReleaseInfo` and `AppVersion`.
- `RSTApp/Settings.swift` (changed) — a version label and the Update button.
- `Makefile` (changed) — stamp the version into the bundle plist; a target to build and zip
  the release asset.

### 3.5 Storage

No new persistent state. The updater works in a temp directory and touches only the installed
`.app`; the backup bundle it leaves beside the installed one is the only new file, and it is
not app state.

---

## 4. Testing

`make test` covers everything pure: version comparison and release-JSON parsing, including the
edge cases in §2.4 (missing asset, malformed JSON, equal version, older version, `1.0.10` vs
`1.0.9`). Everything else in this release — that sound actually stops, that the audio API sees
the right processes, that the admin swap and relaunch work — is on the §5.1 list below and is
verified with the user.

---

## 5. Environment

Unchanged from the foundational design: macOS 26.5.1 (Tahoe), Apple Silicon, Swift 6.3.2,
Command Line Tools only (no Xcode), kid account `child` (uid 502, not admin), admin
`admin` (uid 501). The test command is `make test`. No third-party dependencies —
the updater uses Foundation's `URLSession` and `JSONDecoder`, `Process` for unzip and the
admin `osascript`, all already available.

**New this release:** there is no GitHub remote configured yet. Setting up a public repo and
its release pipeline is T06, and it is the one outward, hard-to-undo step in the plan.

### 5.1 What the test command cannot reach

| Cannot be tested automatically | Why it needs a person |
|---|---|
| Sound actually stopping when the cover goes up | Needs a real app playing real audio and a person listening; `make test` never plays a sound |
| The CoreAudio process API seeing the right emitting processes on this machine | T00 spike, run by the user — the API is unproven in an ad-hoc CLT build here |
| The admin-password prompt, the swap into /Applications, and relaunch into the new build | Two accounts' privileges, a real /Applications write, and a real relaunch |
| The Update button against a real newer GitHub release | Needs a published later release (a throwaway 1.0.2) and network |
| Nothing our own warning audio is caught and quit as "making sound" | Needs the app speaking while the detector runs — a listener |

### 5.2 Seatbelts

The foundational seatbelt is unchanged and still governs any enforcing run:
`RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30`. The sound fix (T02) is exercised inside an enforcing
cover, so it is run under that seatbelt and never a bare enforcing run.

The updater's seatbelt is that it validates before it swaps and keeps a backup after
(§2.3), and that T04 is first exercised against a scratch install directory rather than the
real `/Applications` where practical. Publishing the repo (T06) is gated behind the T05 scan
and the user's explicit go — the seatbelt there is the scan, because a secret pushed to a
public repo cannot be unpublished.

---

## 6. Recovery

Unchanged: the foundational [`../initial-build/RECOVERY.md`](../initial-build/RECOVERY.md) —
reboot and log in as `admin`. New for the updater: if a freshly installed build will
not run, the previous build is beside it as a backup and can be restored by hand from the admin
account; the LaunchAgent will relaunch whatever is at the installed path.

---

## 7. Decisions and rationale

| Decision | Alternative | Why this |
|---|---|---|
| Quit **any** app making sound, not just browsers | Quit browsers only; or mute the Mac | User chose "anything making sound" (2026-09-15). Muting was declined: volume APIs are unreliable on this Mac (foundational §2.4) and a covered-but-audible app is the exact bug |
| Update is a manual button, no check, no notify | Check-and-notify; fully automatic self-update | User: "I apply only… It's my app and I control it (for now)" (2026-09-15). Keeps the child out and the parent deliberate |
| Pressing Update installs straight away if newer | A separate "update available — install?" confirm first | User chose install-straight-away (2026-09-15). The admin-password prompt is the point of no return the parent answers; a prior confirm adds a click, not a gate |
| Update works even while the screen is covered | Refuse Update until the cover is down | User chose allow (2026-09-15). The parent is present and authenticating; the two-second uncovered gap on relaunch is acceptable, and a cover-guard is state not worth its keep |
| Public GitHub repo, public releases | Private repo + embedded token | User chose public (2026-09-15). A token inside a binary the child can read is a leak waiting to happen; public releases need no auth |
| Admin password at install time | Move the app where the child can write | Keeps the enforcing binary in /Applications where it belongs; the parent is present and past the PIN, so one prompt is acceptable |
| Version and Update button both in Settings | A separate About window | User chose Settings (2026-09-15). Least new surface; Settings is already the parent-facing English window |
| Version single source in Core, stamped into plist | Read Info.plist at runtime | A debug `swift run` has no plist; a Core constant reports correctly in both modes and the build stamps the plist so it cannot drift |
| Keep the previous build as a backup on update | Trust the new build | Replacing the enforcing app is near-irreversible; a backup plus §5 recovery means a bad build is not a lockout |
| A pre-publish secrets/private-data scan gates going public | Just push | User asked for it (2026-09-15). The repo and docs carry the admin username, an email, the child's name and home paths; a secret on a public repo cannot be recalled |

---

## 8. Explicitly out of scope

- **Background update checks and notifications** — declined by the user; updating is a manual
  parental act.
- **Automatic self-update with no password** — would mean moving the app out of /Applications
  and weakening where the enforcing binary lives.
- **Notarisation and Gatekeeper distribution** — still out (foundational §8). The app is
  ad-hoc signed for two machines; the updater strips the download's quarantine flag itself.
- **Muting or volume control as the sound fix** — declined; quitting the app is the fix, and
  volume APIs are unreliable on this Mac.
- **Distinguishing "watching media" from "a stray beep"** when deciding what to quit — the
  cover only goes up when the turn is over, so silencing everything is intended.
