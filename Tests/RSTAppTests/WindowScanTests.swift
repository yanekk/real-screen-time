import Foundation
import Testing

/// **The no-window-on-screen scan** (DESIGN §2.4, §3.3) — the headed suite's twin of the
/// Core/App import-boundary scan in `BoundaryTests`. It reads the headed test sources as text
/// and fails on any call by which a Tier 1 test could order a window onto a display or lock
/// the machine down. Its whole purpose is that the safety rule survives the session that finds
/// it inconvenient: a headed test that "just needs to see the window" is the one that raises a
/// cover on the real screen.
///
/// **If this scan fails, remove the call. Never relax the scan.** Every Tier 1 surface is
/// reachable through the build-but-do-not-show seam (§3.1), so no test ever needs one of these.
///
/// The scan cannot see ordering reached *indirectly* through production code a test drives —
/// it reads source, not stacks. The seam is what makes that unnecessary: it gives every test a
/// way to build a window that never touches an ordering call at all (§3.3).
@Suite("No window on screen")
struct WindowScanTests {

    /// The forbidden set, as literal substrings. Matched anywhere on a non-comment line.
    ///
    /// `orderFront` also catches `orderFrontRegardless`. The two app-activation forms are
    /// spelled out rather than a bare `.activate(`, which would false-positive on the
    /// legitimate `NSLayoutConstraint.activate([…])` a headed test uses to build a view.
    static let forbidden: [String] = [
        "orderFront",                     // orderFront(_:) and orderFrontRegardless(_:)
        "makeKeyAndOrderFront",
        "NSApp.run",                      // the run loop — no test starts one
        "NSApplication.shared.run",
        "NSApp.activate",                 // makes a window key and the app active
        "NSApplication.shared.activate",
        "setActivationPolicy(.regular)",  // presentation options require .regular
        "presentationOptions",            // the app-global kiosk lockdown
        "beginSheet",
        ".show(",                         // a class's own show() entry point
        ".present(",                      // …or present()
    ]

    @Test("no headed test source orders a window or locks the machine")
    func noHeadedTestOrdersAWindowOrLocksTheMachine() throws {
        let files = try Self.swiftFiles(under: Self.headedTestDirectory)

        // A scan over zero files passes vacuously — the one way this can silently stop
        // protecting anything. Assert it found sources, and that it found *itself* is proof
        // the directory is the right one.
        #expect(!files.isEmpty, "no Swift sources found under \(Self.headedTestDirectory.path)")

        // This file names every forbidden call in its own list and doc comments, so it is the
        // one source the scan must not read, exactly as `BoundaryTests` scans `Sources/RSTCore`
        // and not itself.
        let ownFile = URL(fileURLWithPath: #filePath).lastPathComponent

        for file in files where file.lastPathComponent != ownFile {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() {
                let hit = Self.forbiddenHit(in: String(line))
                #expect(
                    hit == nil,
                    "\(file.lastPathComponent):\(offset + 1) calls \(hit ?? "") — a headed test may not order a window or lock the machine (DESIGN §2.4). Remove the call; never relax the scan."
                )
            }
        }
    }

    /// The scanner is the thing doing the work, so it is tested directly on inline samples —
    /// without this, a matcher that quietly matched nothing would leave the suite green while
    /// protecting nothing. Mirrors `BoundaryTests.importScannerRecognisesRealImportForms`.
    @Test("the scanner flags the forbidden calls and clears the safe ones")
    func scannerRecognisesForbiddenForms() {
        #expect(Self.forbiddenHit(in: "cover.orderFront(nil)") == "orderFront")
        #expect(Self.forbiddenHit(in: "w.orderFrontRegardless()") == "orderFront")
        #expect(Self.forbiddenHit(in: "w.makeKeyAndOrderFront(nil)") == "makeKeyAndOrderFront")
        #expect(Self.forbiddenHit(in: "NSApp.run()") != nil)
        #expect(Self.forbiddenHit(in: "NSApp.activate(ignoringOtherApps: true)") != nil)
        #expect(Self.forbiddenHit(in: "app.setActivationPolicy(.regular)") == "setActivationPolicy(.regular)")
        #expect(Self.forbiddenHit(in: "NSApp.presentationOptions = [.hideDock]") == "presentationOptions")
        #expect(Self.forbiddenHit(in: "sheet.beginSheet(w) { _ in }") == "beginSheet")
        #expect(Self.forbiddenHit(in: "controller.show()") == ".show(")
        #expect(Self.forbiddenHit(in: "window.present(child)") == ".present(")

        // Safe: the teardown backstop, first responder, layout activation, and a full-line
        // comment that merely names a forbidden call.
        #expect(Self.forbiddenHit(in: "window.orderOut(nil)") == nil)
        #expect(Self.forbiddenHit(in: "window.makeFirstResponder(field)") == nil)
        #expect(Self.forbiddenHit(in: "NSLayoutConstraint.activate([constraint])") == nil)
        #expect(Self.forbiddenHit(in: "// a headed test must never call orderFront") == nil)
    }

    // MARK: - Scanning

    /// A line scan, not an AST walk — the same judgement `BoundaryTests` makes, and the same
    /// blind spot: a forbidden call written inside a `/* … */` block comment is not seen. A
    /// leading `//` is. Worth the simplicity.
    static func forbiddenHit(in line: String) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard !trimmed.hasPrefix("//") else { return nil }
        return forbidden.first { line.contains($0) }
    }

    // MARK: - Locating the sources

    /// Relative to `#filePath`, never the working directory: `swift test` makes no promise
    /// about where it runs from. This resolves to `…/Tests/RSTAppTests`.
    static let headedTestDirectory: URL =
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    static func swiftFiles(under dir: URL) throws -> [URL] {
        // A nil enumerator means the directory is missing — a failure, not an empty scan.
        let walker = try #require(
            FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]),
            "cannot enumerate \(dir.path)"
        )
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
