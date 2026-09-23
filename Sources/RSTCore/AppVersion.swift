import Foundation

/// The app's version, defined in exactly one place so the code and the bundle can never
/// disagree.
///
/// **``current`` is the single source of truth.** `make bundle` reads it and stamps the same
/// string into the assembled `Info.plist`'s `CFBundleShortVersionString`, so Finder's Get Info
/// and the release tooling agree with the running code. Runtime always reads ``current``, never
/// the plist: a debug `swift run` is not a bundle and has no plist (DESIGN §2.1), so a
/// plist-only version would be blank in exactly the mode a developer uses most.
public enum AppVersion {
    /// The single source of truth. Bump this to release; the build stamps it into the bundle.
    public static let current: String = "1.1.0"

    /// Numeric per-component compare of `MAJOR.MINOR.PATCH` strings, so `1.0.10 > 1.0.9`
    /// (lexical order would put `1.0.10` before `1.0.9`). Returns `.orderedAscending` when
    /// `lhs` is older than `rhs`. A leading `v` is tolerated on either side, because GitHub
    /// tags carry it and the constant does not.
    ///
    /// Pure and total: a malformed component counts as `0` rather than trapping, and the two
    /// version strings are compared component by component, the shorter zero-padded to the
    /// longer. The updater (DESIGN §2.3) feeds this a tag straight from the network, so a
    /// surprising value like `"nightly"` or `"1.x"` must order sanely, never crash.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs)
        let b = components(rhs)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Split on `.` into numeric components, dropping a single leading `v`. A non-numeric
    /// component becomes `0`; an empty string yields `[0]` so it compares as the zero version.
    private static func components(_ version: String) -> [Int] {
        var s = Substring(version)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let nums = parts.map { Int($0) ?? 0 }
        return nums.isEmpty ? [0] : nums
    }
}
