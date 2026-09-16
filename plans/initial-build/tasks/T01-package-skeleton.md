# T01 — Package skeleton and build

**Phase:** 1 · **Depends on:** T00 · **Weight:** light

## Goal

A SwiftPM package with the Core/App split, a script that assembles a real `.app` bundle,
and the test that keeps the boundary honest.

## Files

```
Package.swift
Makefile
Sources/RSTCore/Placeholder.swift
Sources/RSTApp/main.swift
Tests/RSTCoreTests/BoundaryTests.swift
Resources/Info.plist
```

## Package

```swift
// swift-tools-version: 6.0
let package = Package(
    name: "RealScreenTime",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RSTCore"),                                   // no dependencies, ever
        .executableTarget(name: "RSTApp", dependencies: ["RSTCore"]),
        .testTarget(name: "RSTCoreTests", dependencies: ["RSTCore"]),
    ]
)
```

`dependencies:` on the package stays empty. Foundation, CryptoKit, AppKit and SwiftUI
cover everything this app needs.

## The boundary test

The most important 20 lines in the repo:

```swift
@Test("RSTCore imports nothing outside Foundation and CryptoKit")
func coreImportsOnlyPermittedModules() throws {
    let permitted: Set<String> = ["Foundation", "CryptoKit"]
    let files = try swiftFilesUnderCore()
    #expect(!files.isEmpty)                    // a vacuous scan protects nothing
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for line in source.split(separator: "\n") {
            guard let module = importedModule(in: String(line)) else { continue }
            #expect(permitted.contains(module), "\(file.lastPathComponent) imports \(module)")
        }
    }
}
```

**Allowlist, not denylist.** A list of banned frameworks — AppKit, SwiftUI, Cocoa, UIKit —
leaves `Darwin`, `os`, `IOKit` and `AVFoundation` free to walk in, and the rule in
CLAUDE.md is *Foundation + CryptoKit only, no system calls*. Enumerating what is permitted
states the rule as written and never needs updating when Apple ships a new framework.

Swift Testing, not XCTest: `XCTest.framework` ships with Xcode and this machine has
Command Line Tools only. See the findings log, `../FINDINGS.md`.

Locate the sources relative to `#filePath`, not the working directory — the test runner
makes no promise about where it runs from.

S.TFU enforces the same rule with an AST test over its Python. A string scan is enough
here and costs nothing to keep.

**If this test fails, move the code. Never relax the test.**

## Bundle assembly

There is no Xcode, so `make bundle` builds the layout by hand:

```
dist/RealScreenTime.app/Contents/
  Info.plist          CFBundleIdentifier com.krolikowski.realscreentime
                      LSUIElement = true   (menu-bar app, no Dock icon)
  MacOS/RealScreenTime
  Resources/
```

Then `codesign --force --deep --sign - dist/RealScreenTime.app`. Ad-hoc is correct here —
the app never leaves these two machines, so a Developer ID buys nothing.

`LSUIElement` sets the launch state; the app still switches to `.regular` activation policy
while covering, because presentation options require it.

## Gotchas

- **Swift 6 strict concurrency is on.** AppKit is main-actor isolated and
  `NotificationCenter` closures arrive `@Sendable`. Write `@MainActor` types and use
  `MainActor.assumeIsolated` inside observers. Do not reach for `.swiftLanguageMode(.v5)`
  to silence it — T00 proved the properly-isolated version compiles fine.
- `swift run` is not a bundled app and some AppKit behaviour differs. Check anything
  surprising against `dist/RealScreenTime.app` before believing it.

## Done when

`swift build`, `make test` and `make bundle` all succeed; the assembled app launches and
does nothing; the boundary test fails if you add `import AppKit` to a Core file.
