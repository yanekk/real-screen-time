import Testing
import Foundation
@testable import RSTCore

/// ``ReleaseParser`` — the pure heart of the updater (DESIGN §2.3 steps 1–3, §2.4). Fed real
/// GitHub `/releases/latest` JSON in T04, so it must pick the right asset, compare numerically,
/// and turn any surprising or truncated body into a clean `.malformed`, never a trap.
@Suite("Release parser")
struct ReleaseInfoTests {

    /// A minimal `/releases/latest` body with the assets a test wants. `assetNames` become
    /// `.app.zip`-or-whatever assets with a plausible download URL each.
    private func releaseJSON(tag: String, assetNames: [String]) -> Data {
        let assets = assetNames.map { name in
            """
            {"name": "\(name)", "browser_download_url": "https://example.com/dl/\(name)"}
            """
        }.joined(separator: ",")
        return Data("""
        {"tag_name": "\(tag)", "assets": [\(assets)]}
        """.utf8)
    }

    @Test("newer tag with a .app.zip asset → available with the right tag and URL")
    func availableNewer() {
        let data = releaseJSON(tag: "v1.0.2", assetNames: ["RealScreenTime.app.zip"])
        let expected = ReleaseInfo(
            tag: "v1.0.2",
            assetURL: URL(string: "https://example.com/dl/RealScreenTime.app.zip")!)
        #expect(ReleaseParser.check(data, current: "1.0.1") == .available(expected))
    }

    @Test("same version → upToDate; older tag → upToDate")
    func upToDate() {
        let same = releaseJSON(tag: "v1.0.1", assetNames: ["RealScreenTime.app.zip"])
        #expect(ReleaseParser.check(same, current: "1.0.1") == .upToDate)

        let older = releaseJSON(tag: "v1.0.0", assetNames: ["RealScreenTime.app.zip"])
        #expect(ReleaseParser.check(older, current: "1.0.1") == .upToDate)
    }

    @Test("1.0.10 vs current 1.0.9 → available (numeric compare, not lexical)")
    func numericCompare() {
        let data = releaseJSON(tag: "v1.0.10", assetNames: ["RealScreenTime.app.zip"])
        guard case .available(let info) = ReleaseParser.check(data, current: "1.0.9") else {
            Issue.record("expected .available for 1.0.10 over 1.0.9")
            return
        }
        #expect(info.tag == "v1.0.10")
    }

    @Test("no .app.zip asset (only source tarballs) → malformed")
    func noAppAsset() {
        let data = releaseJSON(tag: "v1.0.2",
                               assetNames: ["Source code (zip)", "Source code (tar.gz)"])
        guard case .malformed = ReleaseParser.check(data, current: "1.0.1") else {
            Issue.record("expected .malformed when no .app.zip asset present")
            return
        }
    }

    @Test("truncated, non-JSON and empty bodies → malformed, no trap")
    func unparseable() {
        for body in ["{\"tag_name\": \"v1.0.2\", \"assets\": [",  // truncated
                     "not json at all",
                     ""] {                                        // empty
            guard case .malformed = ReleaseParser.check(Data(body.utf8), current: "1.0.1") else {
                Issue.record("expected .malformed for body: \(body.debugDescription)")
                return
            }
        }
    }

    @Test("tag_name with and without a leading v both compare correctly")
    func leadingV() {
        let withV = releaseJSON(tag: "v1.0.2", assetNames: ["RealScreenTime.app.zip"])
        let withoutV = releaseJSON(tag: "1.0.2", assetNames: ["RealScreenTime.app.zip"])
        // Both are newer than 1.0.1.
        guard case .available = ReleaseParser.check(withV, current: "1.0.1"),
              case .available = ReleaseParser.check(withoutV, current: "1.0.1") else {
            Issue.record("both v-prefixed and bare tags should read as available")
            return
        }
        // And a bare current with a bare newer tag still resolves.
        #expect(ReleaseParser.check(withoutV, current: "v1.0.1") == .available(
            ReleaseInfo(tag: "1.0.2",
                        assetURL: URL(string: "https://example.com/dl/RealScreenTime.app.zip")!)))
    }

    @Test("with multiple assets, the .app.zip is chosen, not the first")
    func picksAppZipNotFirst() {
        let data = releaseJSON(tag: "v1.0.2",
                               assetNames: ["Source code (tar.gz)",
                                            "checksums.txt",
                                            "RealScreenTime.app.zip"])
        guard case .available(let info) = ReleaseParser.check(data, current: "1.0.1") else {
            Issue.record("expected .available")
            return
        }
        #expect(info.assetURL == URL(string: "https://example.com/dl/RealScreenTime.app.zip")!)
    }

    @Test("parse surfaces a reason string on each failure path")
    func parseReasons() {
        // Unparseable body.
        if case .success = ReleaseParser.parse(Data("nope".utf8)) {
            Issue.record("expected failure on non-JSON")
        }
        // Valid JSON, no matching asset.
        let data = releaseJSON(tag: "v1.0.2", assetNames: ["other.zip"])
        if case .success = ReleaseParser.parse(data) {
            Issue.record("expected failure when no .app.zip asset")
        }
        // A custom suffix picks a different asset.
        let dmg = releaseJSON(tag: "v1.0.2", assetNames: ["RealScreenTime.dmg"])
        guard case .success(let info) = ReleaseParser.parse(dmg, assetSuffix: ".dmg") else {
            Issue.record("expected success with a matching custom suffix")
            return
        }
        #expect(info.assetURL.lastPathComponent == "RealScreenTime.dmg")
    }
}
