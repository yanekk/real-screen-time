import AppKit
import RSTCore

/// **The on-demand updater** — DESIGN §2.3, §2.4. The parent presses Update in Settings; this
/// fetches the latest GitHub release, decides with `RSTCore`'s already-tested
/// ``ReleaseParser`` whether it is newer, and if so downloads the asset, validates it, and
/// swaps it into `/Applications` behind one admin-password prompt. The relaunch itself is the
/// caller's (see ``Outcome/updating`` and `main.swift`'s `openSettings` host).
///
/// **This whole file is on the hand-verified side of the boundary** (DESIGN §3.2, §5.1): the
/// network, the admin prompt, the swap and the relaunch cannot be reached by `make test`, and
/// there is no `RSTApp` test target on this machine anyway. The one pure decision — is the
/// release newer, and where is its asset — lives in `RSTCore` (T03) and is proven there. What
/// is here is the platform plumbing around that decision, and it is exercised by the §5.1
/// hand run the task doc describes, coordinated with T06 (a published newer release).
///
/// **Order that keeps "cancelled changes nothing" true** (DESIGN §2.4): everything up to the
/// admin prompt is staged in a temp directory the child owns — download, unzip, validate, strip
/// quarantine. The single privileged step then does only the two writes into `/Applications`
/// that need root: back up the current build, then copy the staged one in. If the parent
/// cancels the password prompt the privileged script never runs, so the installed app is
/// untouched.
@MainActor
enum Updater {

    /// What the press did, mapped to English for the parent by `SettingsWindow`.
    enum Outcome: Equatable {
        /// The latest release is not newer than what is running. Nothing was touched.
        case upToDate
        /// A newer build was validated and swapped in. The caller relaunches into it — the
        /// process is about to exit, so `SettingsWindow` never actually renders this case.
        case updating
        /// GitHub could not be reached. The installed app is untouched.
        case offline
        /// Anything else that stopped the update, already phrased for the parent in English.
        /// The installed app is untouched unless the message says otherwise.
        case failed(String)
    }

    // MARK: - The public repo, named at T06

    /// **Set these when the public repo is created (T06).** They are empty on purpose until
    /// then: an empty owner/name short-circuits ``runUpdate`` to a plain "not set up yet"
    /// message rather than firing a request at a nonexistent GitHub path. This is the one
    /// place T06 edits to wire the updater to the real repo.
    static let repoOwner = "yanekk"
    static let repoName = "real-screen-time"

    /// `https://api.github.com/repos/{owner}/{repo}/releases/latest` — public, no auth
    /// (DESIGN §2.3 step 1). `nil` until the repo is named.
    static var latestReleaseURL: URL? {
        guard !repoOwner.isEmpty, !repoName.isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")
    }

    /// Where the installed build lives and where its backup goes (DESIGN §2.3, §6). The path is
    /// the same single source ``LaunchAgent`` points its plist at, so the updater and the login
    /// item can never disagree about where the app is.
    static let installedAppPath = LaunchAgent.installedAppPath
    static let backupAppPath = LaunchAgent.installedAppPath + ".bak"

    // MARK: - The flow

    /// Run the whole §2.3 flow. Returns without exiting; the caller relaunches on
    /// ``Outcome/updating``.
    ///
    /// **`clock` and `diagnostics` are threaded in** rather than defaulted to a fresh
    /// `SystemClock`, because the one-`Date()`-per-process rule (CLAUDE.md) puts every clock
    /// read behind the injected `Clock`, and the log lines want the same `app.log` the rest of
    /// the app writes. Both have defaults so the documented `Updater.runUpdate()` still
    /// compiles; production always passes the app's own.
    static func runUpdate(current: String = AppVersion.current,
                          clock: any Clock = SystemClock(),
                          diagnostics: Diagnostics = .discarded) async -> Outcome {
        guard let url = latestReleaseURL else {
            diagnostics("update: no repo configured — nothing to check", at: clock.now)
            return .failed("Updating isn’t set up yet — the update repository is named when the "
                           + "app is first published.")
        }

        // 1. Fetch the latest-release metadata. A thrown error here is "can't reach GitHub".
        let body: Data
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            (body, _) = try await URLSession.shared.data(for: request)
        } catch {
            diagnostics("update: fetch failed — \(error.localizedDescription)", at: clock.now)
            return .offline
        }

        // 2–3. Parse and compare — the pure decision, proven in T03. A 404 body before any
        // release is published parses to `.malformed` (no asset), which is a clean "nothing to
        // update to", not a crash.
        switch ReleaseParser.check(body, current: current) {
        case .upToDate:
            diagnostics("update: already on \(current) — nothing newer", at: clock.now)
            return .upToDate
        case .malformed(let reason):
            diagnostics("update: no usable release — \(reason)", at: clock.now)
            return .failed("Couldn’t find a newer release to install.")
        case .available(let info):
            diagnostics("update: \(info.tag) is newer than \(current) — installing", at: clock.now)
            return await install(info, clock: clock, diagnostics: diagnostics)
        }
    }

    /// Download, unzip, validate, then the one privileged swap. Everything before the swap is
    /// staged in a temp directory so a cancelled prompt or a bad download leaves the installed
    /// app exactly as it was (DESIGN §2.4).
    private static func install(_ info: ReleaseInfo, clock: any Clock,
                                diagnostics: Diagnostics) async -> Outcome {
        let fm = FileManager.default
        // A plain unique temp dir the child owns — not `.itemReplacementDirectory`, which can throw
        // when the target app does not exist yet (a dev build, or before T06 publishes). The
        // final copy into `/Applications` is a `ditto`, which crosses volumes fine, so a
        // same-volume workspace buys nothing here.
        let work = fm.temporaryDirectory.appendingPathComponent("rst-update-" + UUID().uuidString,
                                                                 isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            diagnostics("update: no temp dir — \(error.localizedDescription)", at: clock.now)
            return .failed("Couldn’t prepare the update. Try again.")
        }
        defer { try? fm.removeItem(at: work) }

        // Download the asset into the workspace.
        let zip = work.appendingPathComponent("update.zip")
        do {
            let (downloaded, _) = try await URLSession.shared.download(from: info.assetURL)
            try fm.moveItem(at: downloaded, to: zip)
        } catch {
            diagnostics("update: download failed — \(error.localizedDescription)", at: clock.now)
            return .failed("The download didn’t finish. Check the connection and try again.")
        }

        // Unzip with ditto, which is the tool that preserves an app bundle's signature and
        // extended attributes (a plain `unzip` can strip them and break the signature check).
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = await runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard unzip.status == 0 else {
            diagnostics("update: unzip failed (\(unzip.status)) — \(unzip.output)", at: clock.now)
            return .failed("The downloaded update couldn’t be unpacked.")
        }

        // Find the .app inside. A source tarball or an unexpected layout has none.
        guard let staged = firstAppBundle(in: unpacked, fm: fm) else {
            diagnostics("update: no .app in the download", at: clock.now)
            return .failed("The downloaded update didn’t contain the app.")
        }

        // Validate before touching the installed app (DESIGN §2.4): it must be our bundle and
        // it must pass `codesign --verify`. A corrupt download never replaces a working app.
        guard fm.isExecutableFile(atPath:
                staged.appendingPathComponent("Contents/MacOS/RealScreenTime").path) else {
            diagnostics("update: staged bundle has no RealScreenTime binary", at: clock.now)
            return .failed("The downloaded app didn’t look right and was not installed.")
        }
        // Strip quarantine on the staged copy first (no admin needed — the child owns the temp
        // dir), so the signature check and the launched app are clean.
        _ = await runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        let verify = await runProcess("/usr/bin/codesign", ["--verify", "--deep", staged.path])
        guard verify.status == 0 else {
            diagnostics("update: codesign --verify failed (\(verify.status)) — \(verify.output)",
                        at: clock.now)
            return .failed("The downloaded app failed its signature check and was not installed.")
        }

        return await swap(staged: staged, work: work, clock: clock, diagnostics: diagnostics)
    }

    /// The one privileged step: back up the current build, then copy the staged one in, under a
    /// single admin-password prompt (DESIGN §2.3). The shell script is written to a file the child
    /// owns and run with `/bin/sh`, so no path has to survive AppleScript's string quoting — the
    /// staged path can sit safely single-quoted inside the script.
    private static func swap(staged: URL, work: URL, clock: any Clock,
                             diagnostics: Diagnostics) async -> Outcome {
        // `set -e`: any step failing aborts the script, so a failed copy cannot be reported as
        // success. The backup is removed and rebuilt each time. `codesign --force` re-signs
        // ad-hoc only if the copied bundle does not already verify (DESIGN §2.3).
        let script = """
            #!/bin/sh
            set -e
            INSTALLED='\(installedAppPath)'
            BACKUP='\(backupAppPath)'
            STAGED='\(staged.path)'
            /bin/rm -rf "$BACKUP"
            if [ -d "$INSTALLED" ]; then /bin/mv "$INSTALLED" "$BACKUP"; fi
            /usr/bin/ditto "$STAGED" "$INSTALLED"
            /usr/bin/xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
            /usr/bin/codesign --verify "$INSTALLED" 2>/dev/null || /usr/bin/codesign --force --deep --sign - "$INSTALLED"
            """
        let scriptURL = work.appendingPathComponent("swap.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            diagnostics("update: could not stage swap script — \(error.localizedDescription)",
                        at: clock.now)
            return .failed("Couldn’t prepare the install step. Try again.")
        }

        let apple = "do shell script \"/bin/sh '\(scriptURL.path)'\" with administrator privileges"
        let result = await runProcess("/usr/bin/osascript", ["-e", apple])
        guard result.status == 0 else {
            // osascript reports a cancelled password prompt as error -128 / "User canceled".
            if result.output.lowercased().contains("cancel") {
                diagnostics("update: admin prompt cancelled — nothing changed", at: clock.now)
                return .failed("Update cancelled — nothing was changed.")
            }
            diagnostics("update: swap failed (\(result.status)) — \(result.output)", at: clock.now)
            return .failed("The install step didn’t complete — the app was not changed. "
                           + "See the event folder’s app.log.")
        }

        diagnostics("update: installed, backup at \(backupAppPath) — relaunching", at: clock.now)
        return .updating
    }

    // MARK: - Small helpers

    /// The first `*.app` directly inside `dir`, if any — the top level only, not nested. Our
    /// release asset is zipped with the bundle at the root (T06's Makefile target), so the
    /// `.app` lands directly here after unzip. A layout that buries the bundle in a subfolder is
    /// not searched and reports "didn't contain the app" — T06 must keep the asset top-level.
    private static func firstAppBundle(in dir: URL, fm: FileManager) -> URL? {
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension == "app" }
    }

    /// Run a command off the main actor and give back its status and combined output.
    ///
    /// `Process.waitUntilExit()` blocks the calling thread, so it is hopped to a background
    /// queue — the main actor stays free for the engine tick and the UI while an unzip or the
    /// admin prompt runs. Output is drained before waiting, or a command that outprints the
    /// pipe buffer would deadlock against a pipe nobody is reading (the `launchctl` finding).
    private static func runProcess(_ launchPath: String, _ arguments: [String]) async
        -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "could not run \(launchPath): "
                                                    + error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n").joined(separator: " | ")
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
    }
}
