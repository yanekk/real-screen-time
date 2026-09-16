# T04 — Version + Update button in Settings, and the install flow

**Phase:** 3 · **Depends on:** T01, T03 · **Weight:** heavy

## Goal

The parent-facing surface and the platform work behind it. Add to the existing Settings window
a line showing the running version and an Update button. Pressing it runs the whole §2.3 flow:
fetch the latest release, decide with T03, and if newer download the asset, validate it,
install it over `/Applications/RealScreenTime.app` through one admin-password prompt while
keeping the old build as a backup, then relaunch. Everything here is English (behind the PIN)
and everything except the T03 decision is platform-shaped, so most of it is verified by hand.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.3 (steps 4–5) and §2.4 (offline, up-to-date, corrupt asset,
cancelled prompt).

## Files

- `Sources/RSTApp/Updater.swift` (new) — the flow: fetch, download, unzip, validate, admin
  swap, relaunch.
- `Sources/RSTApp/Settings.swift` (changed) — a version label and the Update button in a new
  section, following the existing `revealLog` / `changePIN` / `uninstall` button pattern.
- English strings live inline in `Settings.swift` as the other Settings strings do — the
  Polish/English split puts everything behind the PIN in English, so `Strings.swift` is not
  touched.

## Interface

```swift
@MainActor
enum Updater {
    enum Outcome {
        case upToDate
        case updating          // download + install started; app will relaunch
        case offline
        case failed(String)    // shown to the parent in English
    }
    /// Owner/repo are constants set at T06 when the public repo is named.
    static func runUpdate(current: String = AppVersion.current) async -> Outcome
}
```

Install specifics, each with its reason:

- **Validate before swapping.** After unzip, confirm it is a real `.app` bundle that
  `codesign --verify` accepts before touching the installed one; a corrupt download must never
  replace a working app (§2.4).
- **Admin swap.** The copy into `/Applications` runs through
  `osascript -e 'do shell script "…" with administrator privileges'` because the child cannot write
  there; this is the one prompt. The shell step also strips quarantine
  (`xattr -dr com.apple.quarantine`) and re-signs ad-hoc if needed.
- **Backup.** Move the current bundle to `RealScreenTime.app.bak` before copying the new one
  in, so a bad build can be restored by hand (§2.3, §6).
- **Relaunch.** After the swap, exit so the KeepAlive LaunchAgent brings up the new binary, or
  `open` the new app then exit. Do not try to relaunch by re-execing the old image. **No
  cover-guard:** Update is allowed even while a cover is up (§2.3), so the relaunch may briefly
  free the screen before the new build re-covers — that gap is accepted, do not add a guard that
  refuses Update while covering.
- **Cancelled prompt / failed copy** leaves the installed app untouched and reports
  `.failed`/nothing changed.

## Tests

`make test` cannot reach the network, the admin prompt or a real swap. What it can cover:

- [ ] The version label shows `AppVersion.current`.
- [ ] Given each `UpdateCheck` case (from T03, injectable), the Updater maps to the right
      `Outcome` and, for `.upToDate`, touches nothing.
- [ ] The Core import scan still passes; no networking leaked into `RSTCore`.

Everything else is on the §5.1 list and verified by hand.

## Done when

- [ ] Settings shows the version and an Update button, in English, matching the existing
      control style; Save/close behaviour is unchanged.
- [ ] Pressing Update against an up-to-date repo says so and changes nothing.
- [ ] Pressing Update against a newer release downloads, validates, installs with one admin
      prompt (old build kept as backup), and relaunches into the new version — verified by
      hand with the user.
- [ ] Offline and cancelled-prompt cases leave the installed app untouched and report clearly.

## Needs a person

Network, admin privileges, a real swap and relaunch cannot be tested headless. To verify the
newer-release path there must be a newer published release than what is installed — coordinate
with T06 (publish 1.0.1, then a throwaway 1.0.2 to test the round trip). Prefer exercising the
swap against a scratch copy first where practical, rather than the live `/Applications` app.

```
# after 1.0.2 is published, from the installed 1.0.1 app: open Settings → Update
```

Expect: "update available", a download, one admin-password prompt, then the app relaunches and
Settings now shows 1.0.2; the previous build is beside it as a backup.
Tell me: whether the prompt appeared once, whether it relaunched into the new version, whether
the backup is present, and what a cancelled prompt or offline press did.
