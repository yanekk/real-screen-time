# T03 — Parse GitHub release JSON and compare versions (pure)

**Phase:** 3 · **Depends on:** T01 · **Weight:** medium

## Goal

The testable heart of the updater. Given the JSON GitHub returns for a repo's latest release,
work out the latest version, find the downloadable app asset, and decide whether it is newer
than what is running. This is a pure function of its inputs — no network, no clock, no I/O —
so it lives in `RSTCore` and is proven exhaustively by `make test`. T04 does the network and
install around it.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.3 (steps 1–3) and §2.4's parse-error and up-to-date paths.

## Files

- `Sources/RSTCore/ReleaseInfo.swift` (new).

## Interface

```swift
public struct ReleaseInfo: Equatable {
    public let tag: String          // e.g. "v1.0.2"
    public let assetURL: URL        // browser_download_url of the .app.zip asset
}

public enum UpdateCheck: Equatable {
    case upToDate                   // latest <= current
    case available(ReleaseInfo)     // latest > current
    case malformed(String)          // JSON unparseable, or no usable .app.zip asset
}

public enum ReleaseParser {
    /// Parse GitHub's /releases/latest JSON. `assetSuffix` selects the app asset (".app.zip").
    public static func parse(_ data: Data, assetSuffix: String = ".app.zip") -> Result<ReleaseInfo, String>

    /// Decide against the running version using AppVersion.compare.
    public static func check(_ data: Data, current: String = AppVersion.current) -> UpdateCheck
}
```

Why `malformed` is a case, not a crash: the input comes from the network and a surprising or
truncated body must produce a clean "can't update right now", never a trap. Why `assetSuffix`
is a parameter: it keeps the asset-naming convention (`RealScreenTime.app.zip`, set in T06) in
one place and testable.

## Tests

- [ ] A well-formed release with a `.app.zip` asset and a newer tag → `.available` with the
      right tag and URL.
- [ ] Same version → `.upToDate`; older tag than current → `.upToDate`.
- [ ] `1.0.10` vs current `1.0.9` → `.available` (numeric compare via T01).
- [ ] JSON with no `.app.zip` asset (only source tarballs) → `.malformed`.
- [ ] Truncated / non-JSON / empty body → `.malformed`, no trap.
- [ ] `tag_name` with and without leading `v` both compare correctly.
- [ ] Multiple assets: the `.app.zip` one is chosen, not the first.

## Done when

- [ ] `ReleaseParser.check` returns the right case for newer, equal, older and malformed
      inputs, proven by `make test`.
- [ ] It lives in `RSTCore` and the import scan still passes (no networking types leaked in).
- [ ] T04 can drive the whole decision from real GitHub JSON without any further parsing.
