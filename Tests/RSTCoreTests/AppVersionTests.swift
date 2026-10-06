import Testing
import Foundation
@testable import RSTCore

/// ``AppVersion`` — the single-source version and the updater's version compare (DESIGN §2.1,
/// §2.3). `compare` is fed tags straight from the network, so it must be numeric, tolerate a
/// leading `v`, and never trap on a malformed value.
@Suite("App version")
struct AppVersionTests {

    @Test("current is 1.2.1")
    func current() {
        #expect(AppVersion.current == "1.2.1")
    }

    @Test("orders the release line ascending")
    func ordering() {
        #expect(AppVersion.compare("1.0.0", "1.0.1") == .orderedAscending)
        #expect(AppVersion.compare("1.0.1", "1.1.0") == .orderedAscending)
        #expect(AppVersion.compare("1.1.0", "2.0.0") == .orderedAscending)
        #expect(AppVersion.compare("2.0.0", "1.1.0") == .orderedDescending)
    }

    @Test("compares components numerically, not lexically")
    func numeric() {
        #expect(AppVersion.compare("1.0.10", "1.0.9") == .orderedDescending)
        #expect(AppVersion.compare("1.0.9", "1.0.10") == .orderedAscending)
    }

    @Test("equal versions are orderedSame, with or without a leading v")
    func equal() {
        #expect(AppVersion.compare("1.0.1", "1.0.1") == .orderedSame)
        #expect(AppVersion.compare("v1.0.1", "1.0.1") == .orderedSame)
        #expect(AppVersion.compare("1.0.1", "v1.0.1") == .orderedSame)
        #expect(AppVersion.compare("v1.0.1", "v1.0.1") == .orderedSame)
    }

    @Test("a malformed tag does not trap and orders sanely")
    func malformed() {
        // Non-numeric or missing components count as 0, so each is older than a real release.
        #expect(AppVersion.compare("", "1.0.1") == .orderedAscending)
        #expect(AppVersion.compare("nightly", "1.0.1") == .orderedAscending)
        #expect(AppVersion.compare("1.x", "1.0.1") == .orderedAscending)
        #expect(AppVersion.compare("", "") == .orderedSame)
        #expect(AppVersion.compare("nightly", "nightly") == .orderedSame)
    }
}
