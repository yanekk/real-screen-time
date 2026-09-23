// swift-tools-version: 6.0
import PackageDescription

// `dependencies:` stays empty, permanently. Foundation, CryptoKit, AppKit and SwiftUI
// cover everything this app needs — see CLAUDE.md.
//
// Tests are run with `make test`, not `swift test`: this machine has Command Line Tools
// and no Xcode, so `Testing.framework` needs search-path and rpath flags that only the
// command line can supply globally. The Makefile explains the detail. Bare `swift test`
// fails to compile here — deliberately left that way, because the alternative (flags on
// the test target alone) builds and then runs *zero tests while reporting success*.
let package = Package(
    name: "RealScreenTime",
    platforms: [.macOS(.v14)],
    products: [
        // Named for the app rather than the target: every command in the docs says
        // `swift run RealScreenTime`, and the bundle's executable has that name too.
        .executable(name: "RealScreenTime", targets: ["RSTApp"])
    ],
    targets: [
        .target(name: "RSTCore"),                                   // no dependencies, ever
        .executableTarget(name: "RSTApp", dependencies: ["RSTCore"]),
        .testTarget(name: "RSTCoreTests", dependencies: ["RSTCore"]),
        // Tier 1 headed tests (plan headed-and-e2e-tests, T01). It depends on the executable
        // target directly and reaches its window/controller types through `@testable import
        // RSTApp` — no library split was needed on this toolchain (T00, FINDINGS 2026-09-16).
        // It runs under `make test` like any other target; safety is the §3.3 scan inside it,
        // not the build graph.
        .testTarget(name: "RSTAppTests", dependencies: ["RSTApp"]),
        // Tier 2 real-click gate (plan headed-and-e2e-tests, T07). A separate on-demand
        // executable — never part of `make test` — that launches the built app boxed and
        // seatbelted and drives its cover through the Accessibility system. It depends on
        // RSTCore (in-package, not a third-party dependency) to seed a scratch config with a
        // real, verifiable PIN, and imports ApplicationServices/CoreGraphics for AXUIElement
        // and CGEvent, which auto-link from the SDK. Run it with `make ui-gate`.
        .executableTarget(name: "RSTUIDriver", dependencies: ["RSTCore"]),
    ]
)
