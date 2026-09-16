import Foundation

/// The parsed, usable facts of a GitHub release: its version tag and where to download the
/// app from. Everything else GitHub returns is discarded here.
public struct ReleaseInfo: Equatable {
    /// The release tag, e.g. `"v1.0.2"`. Fed straight to ``AppVersion/compare(_:_:)``, which
    /// tolerates the leading `v`.
    public let tag: String
    /// The `browser_download_url` of the `.app.zip` asset — what T04 downloads.
    public let assetURL: URL

    public init(tag: String, assetURL: URL) {
        self.tag = tag
        self.assetURL = assetURL
    }
}

/// Why a release body could not be turned into a ``ReleaseInfo`` — carries a short reason for
/// the log and the `.malformed` case. A dedicated type because `Result`'s failure must be an
/// `Error`, and `String` is not one; a global `String: Error` conformance would leak across the
/// whole module.
public struct ReleaseParseError: Error, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// The updater's decision after looking at the latest release (DESIGN §2.3 step 3, §2.4).
public enum UpdateCheck: Equatable {
    /// The latest release is not newer than the running version. Nothing to do.
    case upToDate
    /// A newer release with a usable asset exists.
    case available(ReleaseInfo)
    /// The JSON could not be parsed, or carried no usable `.app.zip` asset. Carries a short
    /// reason for the log. This is a clean "can't update right now", never a trap: the input
    /// comes from the network and a truncated or surprising body must not crash the app.
    case malformed(String)
}

/// Parses the JSON GitHub returns for `/releases/latest` and decides whether it is newer than
/// what is running. Pure — no network, no clock, no I/O — so it lives in `RSTCore` and is
/// proven exhaustively by `make test`. T04 does the network and install around it.
public enum ReleaseParser {

    /// GitHub's `/releases/latest` shape, only the fields we use. Decoding is lenient by
    /// omission: any extra keys GitHub adds are ignored.
    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    /// Parse GitHub's `/releases/latest` JSON into a ``ReleaseInfo``. `assetSuffix` selects the
    /// app asset by the end of its file name (`".app.zip"`); keeping the naming convention in
    /// one parameter means the T06 asset name and this parser cannot drift apart.
    ///
    /// Fails with a short reason — never traps — when the body is not the expected JSON, or
    /// when no asset's name ends in `assetSuffix` (only source tarballs, say). The chosen asset
    /// is the one matching the suffix, not the first in the list.
    public static func parse(_ data: Data, assetSuffix: String = ".app.zip") -> Result<ReleaseInfo, ReleaseParseError> {
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            return .failure(ReleaseParseError("release JSON unparseable"))
        }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(assetSuffix) }) else {
            return .failure(ReleaseParseError("no \(assetSuffix) asset in latest release"))
        }
        guard let url = URL(string: asset.browser_download_url) else {
            return .failure(ReleaseParseError("asset download URL invalid"))
        }
        return .success(ReleaseInfo(tag: release.tag_name, assetURL: url))
    }

    /// Decide against the running version. Newer tag → ``UpdateCheck/available(_:)``; same or
    /// older → ``UpdateCheck/upToDate``; unparseable or assetless → ``UpdateCheck/malformed(_:)``.
    /// "Newer" is the numeric per-component compare of ``AppVersion/compare(_:_:)``, so `1.0.10`
    /// beats `1.0.9`.
    public static func check(_ data: Data, current: String = AppVersion.current) -> UpdateCheck {
        switch parse(data) {
        case .failure(let error):
            return .malformed(error.reason)
        case .success(let info):
            return AppVersion.compare(current, info.tag) == .orderedAscending
                ? .available(info)
                : .upToDate
        }
    }
}
