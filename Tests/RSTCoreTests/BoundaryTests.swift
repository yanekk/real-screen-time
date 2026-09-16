import Foundation

// Reached by a bare `swift test`, which cannot see Testing.framework on a Command Line
// Tools install. The module error alone does not say what to do about it; this does.
#if !canImport(Testing)
#error("Testing.framework not on the search path — run `make test`, not `swift test`.")
#endif

import Testing
@testable import RSTCore

// Swift Testing, not XCTest: `XCTest.framework` ships with Xcode, and this machine has
// Command Line Tools only — `import XCTest` fails to build. `Testing.framework` is in the
// CLT toolchain, so it is the framework for the whole project.

/// The most important twenty lines in the repo.
///
/// `RSTCore` is what makes a full day of behaviour testable in milliseconds on a machine
/// with no UI automation. The moment a platform import lands in it, some rule becomes
/// checkable only by hand.
///
/// **Allowlist, not denylist.** CLAUDE.md's rule is "Foundation + CryptoKit ONLY … no
/// system calls", which is wider than any list of banned frameworks can express: naming
/// AppKit, SwiftUI, Cocoa and UIKit leaves `Darwin`, `os`, `IOKit` and `AVFoundation` free
/// to walk in. Enumerating what is *permitted* enforces the rule as written and never
/// needs updating when Apple ships a new framework.
///
/// **If this test fails, move the code. Never relax the test.**
@Suite("Core/App boundary")
struct BoundaryTests {

    /// Everything `RSTCore` is allowed to see. Adding to this list is a design decision,
    /// not a build fix — see CLAUDE.md, "The Core/App boundary is the most important rule".
    private static let permitted: Set<String> = ["Foundation", "CryptoKit"]

    @Test("RSTCore imports nothing outside Foundation and CryptoKit")
    func coreImportsOnlyPermittedModules() throws {
        let files = try Self.swiftFilesUnderCore()

        // A scan over zero files passes vacuously, which is the one way this test can
        // silently stop protecting anything — so assert it found something first.
        #expect(!files.isEmpty, "no Swift sources found under \(Self.coreDirectory.path)")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() {
                guard let module = Self.importedModule(in: String(line)) else { continue }
                #expect(
                    Self.permitted.contains(module),
                    "\(file.lastPathComponent):\(offset + 1) imports \(module) — RSTCore may import only \(Self.permitted.sorted().joined(separator: ", "))"
                )
            }
        }
    }

    /// The scanner is the thing actually doing the work, so it gets tested directly.
    /// Without this, a parser that quietly matched nothing would leave the suite green
    /// while protecting nothing at all.
    @Test("the import scanner recognises the forms Swift accepts")
    func importScannerRecognisesRealImportForms() {
        #expect(Self.importedModule(in: "import AppKit") == "AppKit")
        #expect(Self.importedModule(in: "    import SwiftUI") == "SwiftUI")
        #expect(Self.importedModule(in: "import Foundation") == "Foundation")
        #expect(Self.importedModule(in: "@testable import RSTCore") == "RSTCore")
        #expect(Self.importedModule(in: "@_exported import Darwin") == "Darwin")
        // Submodule form — the module is what matters, not the declaration pulled from it.
        #expect(Self.importedModule(in: "import class AppKit.NSWindow") == "AppKit")
        #expect(Self.importedModule(in: "import struct Foundation.Date") == "Foundation")
        #expect(Self.importedModule(in: "import os.log") == "os")
        // Not imports.
        #expect(Self.importedModule(in: "// import AppKit — forbidden here") == nil)
        #expect(Self.importedModule(in: "let importantThing = 1") == nil)
        #expect(Self.importedModule(in: "") == nil)
    }

    // MARK: - Scanning

    /// A line scan, not an AST walk — the task doc's judgement, and it costs nothing to
    /// keep. The known blind spot is an `import` written inside a block comment; a leading
    /// `//` is handled, `/* … */` is not. Worth the simplicity.
    static func importedModule(in line: String) -> String? {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard !rest.hasPrefix("//") else { return nil }

        // Attributes may precede the keyword: `@testable import`, `@_exported import`.
        while rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            rest = rest[rest.index(after: space)...].drop { $0 == " " }
        }

        guard rest.hasPrefix("import ") else { return nil }
        rest = rest.dropFirst("import ".count).drop { $0 == " " }

        // `import struct Foundation.Date` — step over the declaration kind to reach the module.
        for kind in ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]
        where rest.hasPrefix(kind + " ") {
            rest = rest.dropFirst(kind.count + 1).drop { $0 == " " }
            break
        }

        // First path component only: `os.log` is the `os` module.
        let module = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return module.isEmpty ? nil : String(module)
    }

    // MARK: - Locating the sources

    /// Relative to `#filePath`, never the working directory: `swift test` makes no promise
    /// about where it runs from.
    private static let coreDirectory: URL = URL(fileURLWithPath: #filePath)   // …/Tests/RSTCoreTests/BoundaryTests.swift
        .deletingLastPathComponent()                                         // …/Tests/RSTCoreTests
        .deletingLastPathComponent()                                         // …/Tests
        .deletingLastPathComponent()                                         // …/  (package root)
        .appendingPathComponent("Sources")
        .appendingPathComponent("RSTCore")

    private static func swiftFilesUnderCore() throws -> [URL] {
        // A nil enumerator means the directory is missing — a failure, not an empty scan.
        let walker = try #require(
            FileManager.default.enumerator(
                at: coreDirectory,
                includingPropertiesForKeys: [.isRegularFileKey]
            ),
            "cannot enumerate \(coreDirectory.path)"
        )
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
