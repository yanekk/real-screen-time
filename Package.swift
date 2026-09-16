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
    ]
)
