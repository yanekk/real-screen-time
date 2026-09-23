import AppKit
import Testing
@testable import RSTApp

/// **The smoke test** — the whole of T01's behavioural coverage; the real coverage arrives in
/// T02–T05. It exists to prove three things at once: that the headed target builds, that it
/// links the real `RSTApp` window code (`@testable import RSTApp`, no library split — T00,
/// FINDINGS 2026-09-16), and that it runs under `make test` without ordering anything onto a
/// display.
///
/// It reaches for `CoverWindow` on purpose. That class exists for one reason — a borderless
/// `NSWindow` returns `false` from `canBecomeKey`, so the PIN field inside an un-overridden
/// cover would silently refuse every keystroke — and asserting the override is both harmless
/// and the single most load-bearing fact about the cover. Constructing the window does not
/// order it; `defer: true` withholds even the backing store until it is shown, which it never
/// is here.
@Suite("Headed smoke")
@MainActor
struct SmokeTests {

    @Test("CoverWindow links and overrides canBecomeKey")
    func coverWindowLinksAndBecomesKey() {
        HeadedHarness.withApp { _ in
            let cover = CoverWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: .borderless, backing: .buffered, defer: true)
            #expect(cover.canBecomeKey)
            #expect(cover.canBecomeMain)

            // The control that makes the override matter: a plain borderless window refuses
            // the keyboard, which is exactly what the subclass exists to fix.
            let plain = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: .borderless, backing: .buffered, defer: true)
            #expect(!plain.canBecomeKey)
        }
    }

    @Test("the scratch data dir exists during the body and is scrubbed after")
    func scratchDataDirIsIsolated() {
        var captured: URL?
        HeadedHarness.withApp { dir in
            captured = dir
            #expect(FileManager.default.fileExists(atPath: dir.path))
            #expect(ProcessInfo.processInfo.environment["RST_DATA_DIR"] == dir.path)
        }
        // Removed on the way out, so no test leaves state behind.
        #expect(captured != nil)
        if let captured { #expect(!FileManager.default.fileExists(atPath: captured.path)) }
    }
}
