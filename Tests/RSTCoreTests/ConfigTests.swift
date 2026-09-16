import Foundation
import Testing
@testable import RSTCore

/// `config.json` is written by a process the watchdog is entitled to kill, and read at
/// launch by an app that must keep enforcing whatever it finds. Both halves of that are
/// what these tests are about.
@Suite("Config")
struct ConfigTests {

    // MARK: - Round trip and defaults

    @Test("a saved config comes back identical")
    func roundTrip() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            var config = Config()
            config.sessionMinutes = 45
            config.selfServiceSessionsPerDay = 3
            config.warningMinutes = [20, 5]
            config.pinHash = "aGFzaA=="
            config.pinSalt = "c2FsdA=="

            try store.save(config)
            let loaded = store.load()

            #expect(loaded.config == config)
            #expect(loaded.outcome == .loaded)
        }
    }

    @Test("a missing file yields shipped defaults and writes nothing")
    func missingFile() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            let loaded = store.load()

            #expect(loaded.config == Config())
            #expect(loaded.outcome == .missing)
            // First run owns the first write; a `load` that created files would make the
            // wizard's "is this configured?" question answer itself wrongly.
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    @Test("the shipped defaults are the ones the design specifies")
    func shippedDefaults() {
        let config = Config()
        #expect(config.sessionMinutes == 30)
        #expect(config.selfServiceSessionsPerDay == 1)   // one a day since 2026-08-22
        #expect(config.dayResetHour == 6)
        #expect(config.idleGraceSeconds == 600)
        #expect(config.mediaGraceSeconds == 1800)
        #expect(config.warningMinutes == [10, 5, 1])
        #expect(config.extensionOptions == [15, 30, 60])  // what `Dodaj minuty…` offers
        #expect(config.extensionChoices == [15, 30, 60])
        #expect(config.pinHash.isEmpty)
        #expect(config.pinSalt.isEmpty)
        #expect(!config.isConfigured)
    }

    @Test("a file missing keys defaults just those keys")
    func partialFileDefaultsMissingKeys() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            // What an older build's file looks like to a newer one. Not corruption.
            try Data(#"{"session_minutes": 20, "pin_hash": "abc"}"#.utf8).write(to: store.url)

            let loaded = store.load()
            #expect(loaded.outcome == .loaded)
            #expect(loaded.config.sessionMinutes == 20)
            #expect(loaded.config.pinHash == "abc")
            #expect(loaded.config.idleGraceSeconds == Config().idleGraceSeconds)
            #expect(loaded.config.warningMinutes == Config().warningMinutes)
        }
    }

    @Test("keys are snake_case on disk")
    func wireFormat() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            try store.save(Config())
            let text = try String(contentsOf: store.url, encoding: .utf8)
            // DESIGN §6 names `pin_hash` specifically; the rest follow the same rule.
            #expect(text.contains("\"pin_hash\""))
            #expect(text.contains("\"self_service_sessions_per_day\""))
            #expect(!text.contains("\"pinHash\""))
        }
    }

    // MARK: - Corruption

    @Test("a corrupt file is moved aside, defaults are written, and the app carries on")
    func corruptFile() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            let garbage = Data(#"{"session_minutes": 30, "trunc"#.utf8)   // a torn write
            try garbage.write(to: store.url)

            let loaded = store.load()

            #expect(loaded.config == Config())
            #expect(loaded.outcome == .reset(backup: store.backupURL))
            // The original is kept: it is the only evidence of what went wrong.
            #expect(try Data(contentsOf: store.backupURL) == garbage)
            // And a valid file is left behind, so the next launch is an ordinary load
            // rather than a second quarantine.
            let again = store.load()
            #expect(again.outcome == .loaded)
            #expect(again.config == Config())
        }
    }

    @Test("a second corruption overwrites the first backup rather than failing")
    func repeatedCorruption() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            try Data("first".utf8).write(to: store.url)
            _ = store.load()
            try Data("second".utf8).write(to: store.url)
            _ = store.load()

            #expect(try Data(contentsOf: store.backupURL) == Data("second".utf8))
        }
    }

    @Test("valid JSON that is not a config object is treated as corrupt")
    func wrongShapeIsCorrupt() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            try Data("[1, 2, 3]".utf8).write(to: store.url)
            #expect(store.load().outcome == .reset(backup: store.backupURL))
        }
    }

    // MARK: - Atomic writes

    @Test("a save leaves the directory holding exactly one file")
    func saveLeavesNoTemporaries() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            try store.save(Config())
            try store.save(Config())

            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(contents == ["config.json"])
        }
    }

    @Test("a save that cannot complete leaves the previous config intact")
    func failedSaveDoesNotDestroyTheOldFile() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            var original = Config()
            original.sessionMinutes = 25
            try store.save(original)
            let bytesBefore = try Data(contentsOf: store.url)

            // Take write permission off the directory so both the temp write and the
            // rename fail. This is the property atomicity buys: an interrupted write
            // cannot produce a truncated config, only no new config.
            let fm = FileManager.default
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

            var next = Config()
            next.sessionMinutes = 45
            #expect(throws: (any Error).self) { try store.save(next) }

            #expect(try Data(contentsOf: store.url) == bytesBefore)
            #expect(store.load().config == original)
        }
    }

    // MARK: - Forward compatibility

    @Test("keys a newer build wrote survive a save by this one")
    func unknownKeysPreserved() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            let fromTheFuture = #"""
            {"session_minutes": 40, "bedtime_hour": 21, "experimental": {"a": [1, 2]}}
            """#
            try Data(fromTheFuture.utf8).write(to: store.url)

            var config = store.load().config
            #expect(config.sessionMinutes == 40)
            config.sessionMinutes = 35
            try store.save(config)

            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
            )
            #expect(object["session_minutes"] as? Int == 35)
            #expect(object["bedtime_hour"] as? Int == 21)
            #expect(((object["experimental"] as? [String: Any])?["a"] as? [Int]) == [1, 2])
        }
    }

    @Test("a known key is never shadowed by the copy of an older file")
    func knownKeysWin() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            try store.save(Config())
            var config = Config()
            config.extensionOptions = [5, 45]
            try store.save(config)
            #expect(store.load().config.extensionOptions == [5, 45])
        }
    }

    // MARK: - The grant amounts

    /// The list is what `Dodaj minuty…` draws, and `config.json` is hand-editable with
    /// nothing validating it (T03 finding). A dialog with no amounts on it is a PIN prompt
    /// that can grant nothing — the one shape this list must never take.
    @Test("an unusable list of amounts falls back to what ships")
    func emptyChoicesFallBack() {
        var config = Config()
        config.extensionOptions = []
        #expect(config.extensionChoices == [15, 30, 60])
        config.extensionOptions = [0, -30]
        #expect(config.extensionChoices == [15, 30, 60])
    }

    /// **Order is the parent's**, because the first entry is what the dialog pre-selects.
    /// Sorting it here would quietly take that away.
    @Test("the parent's order survives, and duplicates do not")
    func choicesKeepOrderAndDropDuplicates() {
        var config = Config()
        config.extensionOptions = [60, 15, 60, 0, 30, -5, 15]
        #expect(config.extensionChoices == [60, 15, 30])
    }

    /// §2.5 unchanged in substance: the app still never argues with an amount its owner
    /// chose. It only asks for the choice in advance rather than in the moment.
    @Test("any amount a parent means can be put on the list")
    func anyAmountIsAllowedOnTheList() {
        var config = Config()
        config.extensionOptions = [5, 240, 1440]
        #expect(config.extensionChoices == [5, 240, 1440])
    }

    // MARK: - PIN fields

    @Test("isConfigured needs both halves of the PIN")
    func configuredNeedsHashAndSalt() {
        var config = Config()
        #expect(!config.isConfigured)
        config.pinHash = "aGFzaA=="
        #expect(!config.isConfigured)
        config.pinSalt = "c2FsdA=="
        #expect(config.isConfigured)
    }

    @Test("a salt that is not base64 reads as no salt at all")
    func malformedSaltIsNoSalt() {
        var config = Config()
        #expect(config.pinSaltData == nil)
        config.pinSalt = "not base64!!"
        #expect(config.pinSaltData == nil)

        let salt = newPINSalt()
        config.pinSalt = salt.base64EncodedString()
        #expect(config.pinSaltData == salt)
    }

    // MARK: - Helpers

    /// A fresh directory per test, removed afterwards. Nothing here may touch the real
    /// `~/Library/Application Support/RealScreenTime` — a test that eats the parent's PIN
    /// is worse than no test.
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rst-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            // Restore permissions first: the read-only test would otherwise leave a
            // directory nothing can delete.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }
}
