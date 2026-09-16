# T01 — Single-source version `1.0.1`, stamped into the bundle

**Phase:** 1 · **Depends on:** — · **Weight:** light

## Goal

Give the app one honest version number, `1.0.1`, defined in exactly one place so the code and
the bundle can never disagree. The updater (T03/T04) compares against it, and Settings (T04)
shows it, so it has to be readable both in a debug `swift run` (no bundle, no `Info.plist`)
and in the installed `.app`. A constant in `RSTCore` is the source; the build stamps the same
value into the bundle plist.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.1.

## Files

- `Sources/RSTCore/AppVersion.swift` (new) — the constant and the comparison.
- `Makefile` (changed) — in `bundle`, write the version into
  `$(CONTENTS)/Info.plist`'s `CFBundleShortVersionString` from the Core constant (e.g. via
  `plutil -replace` or `PlistBuddy`), so the assembled app always matches the code.
- `Resources/Info.plist` — its committed `CFBundleShortVersionString` becomes a placeholder
  the build overwrites; note that in a comment so nobody hand-edits it expecting it to ship.

## Interface

```swift
public enum AppVersion {
    /// The single source of truth. Bump this to release; the build stamps it into the bundle.
    public static let current: String = "1.0.1"

    /// Numeric per-component compare of "MAJOR.MINOR.PATCH" strings, so 1.0.10 > 1.0.9.
    /// Returns .orderedAscending when `lhs` is older than `rhs`. Leading "v" tolerated on
    /// either side, because GitHub tags carry it and the constant does not.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult
}
```

`compare` is pure and total: a malformed component counts as 0 rather than trapping, because
the updater must not crash on a surprising tag from the network.

## Tests

- [ ] `compare` orders `1.0.0 < 1.0.1 < 1.1.0 < 2.0.0`.
- [ ] `1.0.10 > 1.0.9` (numeric, not lexical).
- [ ] Equal versions compare `.orderedSame`, with and without a leading `v`.
- [ ] `v1.0.1` and `1.0.1` compare equal.
- [ ] A malformed tag (`""`, `"nightly"`, `"1.x"`) does not trap and orders sanely.
- [ ] `AppVersion.current` is `"1.0.1"`.

## Done when

- [ ] `AppVersion.current` returns `1.0.1` and `make test` proves `compare`.
- [ ] `make bundle` produces an app whose `Info.plist` `CFBundleShortVersionString` is
      `1.0.1`, taken from the constant (check the assembled plist).
- [ ] Bumping the constant is the only edit needed to change the version everywhere.
