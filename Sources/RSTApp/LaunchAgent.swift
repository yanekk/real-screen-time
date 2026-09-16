import Foundation
import RSTCore

/// **Putting the LaunchAgent on the machine** — DESIGN §2.7, T16 step 4.
///
/// `KeepAlive` is what closes the casual kill: killed, the app is back within seconds, and
/// the gap it was away is charged (T04). Together those make killing it pointless rather
/// than merely difficult.
///
/// What the plist *says*, and which binary it names, are ``LaunchAgent``'s over in `RSTCore`
/// where `make test` can reach them. This file is the two things that cannot cross the
/// boundary: a write to `~/Library/LaunchAgents`, and `launchctl`.
///
/// **The known limit, already accepted** (DESIGN §8): the child owns his own
/// `~/Library/LaunchAgents` and can `launchctl bootout` his own agent without admin rights.
/// There is no user-space fix, the gap charging is the answer, and the root daemon is
/// recorded as the upgrade path. Do not add a privileged helper here.
enum LaunchAgentInstaller {

    /// What happened, in the words the wizard puts on the screen.
    enum Outcome: Equatable {
        /// Written and loaded. The ordinary path.
        case bootstrapped(plist: URL, program: String)
        /// Written, but a job with this label was already loaded — very likely *this*
        /// process. See ``install(diagnostics:at:)`` for why that is not booted out.
        case alreadyLoaded(plist: URL, program: String)
        /// There is no copy in `/Applications` to point at.
        case notInstalled
        /// The plist could not be written, or `launchctl` refused it.
        case failed(String)

        var succeeded: Bool {
            switch self {
            case .bootstrapped, .alreadyLoaded: return true
            case .notInstalled, .failed: return false
            }
        }
    }

    /// `~/Library/LaunchAgents/com.krolikowski.realscreentime.agent.plist`.
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(LaunchAgent.plistFileName)
    }

    /// Write the plist and load it.
    ///
    /// **An already-loaded label is not booted out first**, which is where this departs from
    /// the task doc. The doc's worry is real — `bootstrap` fails when the label exists, and
    /// that is the most likely way this step quietly does nothing — but `bootout` on *our
    /// own* agent terminates the process running the wizard, and with the job removed
    /// `KeepAlive` does not bring it back. The parent would watch the window vanish
    /// mid-setup. Detecting the loaded case and saying so costs nothing: the plist is
    /// rewritten either way, and its contents only ever change when the app moves.
    static func install(diagnostics: Diagnostics, at now: Date) -> Outcome {
        let program = LaunchAgent.program(
            runningBinary: Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
            installedBinaryExists: FileManager.default.isExecutableFile(
                atPath: LaunchAgent.installedBinaryPath))

        guard let path = program.path else {
            diagnostics("launch agent: nothing at \(LaunchAgent.installedBinaryPath) to point at",
                        at: now)
            return .notInstalled
        }
        if case .installed = program {
            // Worth a line: this is a development run writing an agent for the installed
            // copy, and the two are not the same binary.
            diagnostics("launch agent: running from a build directory — the plist will name "
                        + "the installed copy at \(path)", at: now)
        }

        let url = plistURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Atomic for the same reason `config.json` is: a torn plist is a plist launchd
            // refuses at every login, and nothing would say why.
            try LaunchAgent.plistData(programPath: path).write(to: url, options: .atomic)
        } catch {
            let message = "launch agent: could not write \(url.path) — \(error.localizedDescription)"
            diagnostics(message, at: now)
            return .failed(message)
        }

        let uid = getuid()
        if launchctl(["print", LaunchAgent.serviceTarget(uid: uid)]).status == 0 {
            diagnostics("launch agent: \(LaunchAgent.label) is already loaded — plist rewritten, "
                        + "the new one takes effect at the next login", at: now)
            return .alreadyLoaded(plist: url, program: path)
        }

        let result = launchctl(["bootstrap", LaunchAgent.domainTarget(uid: uid), url.path])
        guard result.status == 0 else {
            // launchctl's own words, because its exit codes are `5: Input/output error` for
            // half a dozen unrelated causes and the text is the only part worth reading.
            let message = "launch agent: bootstrap failed (\(result.status)) "
                + "— \(result.output.isEmpty ? "no output" : result.output)"
            diagnostics(message, at: now)
            return .failed(message)
        }

        diagnostics("launch agent: bootstrapped \(LaunchAgent.label) → \(path)", at: now)
        return .bootstrapped(plist: url, program: path)
    }

    /// **Stop the agent** — T17's uninstall.
    ///
    /// The mirror of the note on ``install(diagnostics:at:)``: `bootout` on our own agent
    /// terminates this process, which is *wrong* during setup and exactly right here, since
    /// the next thing that happens is the app quitting anyway. What it buys is `KeepAlive`
    /// being gone before the quit rather than after it — booted out afterwards, `launchd`
    /// would have restarted the app the parent had just uninstalled.
    ///
    /// `true` when the job is no longer loaded, including when it never was: a development
    /// run and a `Finish without it` both leave nothing to remove, and neither is a failure.
    static func bootout(diagnostics: Diagnostics, at now: Date) -> Bool {
        let uid = getuid()
        guard launchctl(["print", LaunchAgent.serviceTarget(uid: uid)]).status == 0 else {
            diagnostics("launch agent: \(LaunchAgent.label) is not loaded", at: now)
            return false
        }
        let result = launchctl(["bootout", LaunchAgent.serviceTarget(uid: uid)])
        guard result.status == 0 else {
            // launchctl's own words: its exit codes cover half a dozen unrelated causes.
            diagnostics("launch agent: bootout failed (\(result.status)) — "
                        + "\(result.output.isEmpty ? "no output" : result.output)", at: now)
            return false
        }
        diagnostics("launch agent: booted out \(LaunchAgent.label)", at: now)
        return true
    }

    /// Runs `launchctl` and gives back what it said.
    ///
    /// Synchronous on the main thread: `launchctl` answers in milliseconds, the wizard has
    /// nothing else to do until it does, and there is no cover up during setup for a stall
    /// to matter under.
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "could not run launchctl: \(error.localizedDescription)")
        }
        // Read before waiting: `launchctl print` writes more than a pipe buffer holds, and
        // waiting first would deadlock against a full pipe nobody is draining.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // One line, however many launchctl wrote: this goes into `app.log`.
        return (process.terminationStatus, text.split(separator: "\n").joined(separator: " | "))
    }
}
