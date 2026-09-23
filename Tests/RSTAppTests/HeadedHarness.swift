import AppKit
import Foundation

// Reached by a bare `swift test`, which cannot see Testing.framework on a Command Line
// Tools install. The module error alone does not say what to do about it; this does. The
// same guard sits in `Tests/RSTCoreTests/BoundaryTests.swift` — one per test target is
// enough, and this is the headed target's.
#if !canImport(Testing)
#error("Testing.framework not on the search path — run `make test`, not `swift test`.")
#endif

import Testing
@testable import RSTApp

/// **The Tier 1 headed harness** (DESIGN §2.1, §3.1).
///
/// It gives each headed test a scratch `RST_DATA_DIR` and a fresh, empty app-support tree,
/// so no test ever touches real config, ledger or event state; and it guarantees teardown
/// leaves nothing ordered on a display. It never orders a window itself — Tier 1's whole
/// safety rule (§2.4) is that no headed test does — so the backstop below is defence in
/// depth against a test that slipped one on screen, not the normal path.
///
/// `NSApplication.shared` is initialised once, here, the first time `withApp` runs; no test
/// ever calls `.run()`. Constructing the app's real borderless windows and querying them
/// works with only the shared application and no run loop (T00, FINDINGS 2026-09-16).
@MainActor
enum HeadedHarness {

    private static let dataDirKey = "RST_DATA_DIR"

    /// Run `body` against a scratch data directory, then tear everything down.
    ///
    /// - The directory is created fresh under the system temp dir and removed afterwards.
    /// - `RST_DATA_DIR` is pointed at it for the duration and restored to its prior value
    ///   (or unset) afterwards, so app code that resolves the data directory from the
    ///   environment sees the scratch tree and nothing leaks between tests.
    /// - On the way out, any window that ended up visible is ordered *out* — `orderOut` is
    ///   not one of the §2.4 ordering calls; it only ever hides. Nothing should be visible,
    ///   because nothing here orders anything in.
    static func withApp<T>(_ body: (URL) throws -> T) rethrows -> T {
        // Accessing `.shared` is what creates the `NSApplication`; do it before any window.
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rst-headed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let previous = ProcessInfo.processInfo.environment[dataDirKey]
        setenv(dataDirKey, dir.path, 1)

        defer {
            if let previous { setenv(dataDirKey, previous, 1) } else { unsetenv(dataDirKey) }
            for window in NSApp.windows where window.isVisible { window.orderOut(nil) }
            try? FileManager.default.removeItem(at: dir)
        }

        return try body(dir)
    }
}
