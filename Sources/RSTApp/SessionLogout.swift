import Foundation
import RSTCore

/// Whatever ends the child's session when `Wyloguj` is confirmed on the cover
/// (cover-buttons-logout DESIGN §2.2, §2.3).
///
/// A protocol so `CoverEnforcer` holds an injected performer: the headed tests pass a
/// recording double, and the real ``SessionLogout`` is constructed in `main.swift` and
/// nowhere else — a test process that could reach it could log the developer out.
@MainActor
protocol LogoutPerforming: AnyObject {
    /// Called once per confirmation. Returns false if the log-out could not be started.
    @discardableResult func logOut(at now: Date) -> Bool
}

/// **The hard log-out**: `launchctl bootout gui/<uid>` on the app's own session.
///
/// Hard on purpose (DESIGN §2.3): a polite log-out lets any app with unsaved work cancel it
/// with a save dialog that would sit hidden under the cover. Verified in the non-admin
/// `rsttest` account on 2026-10-02 (T00): no dialog, no root needed, the session just ends —
/// this process with it, by `SIGTERM`, which the app already treats as a clean exit.
///
/// **A dry run unless `real`** (DESIGN §2.5). `real` is `Flags.logoutIsReal`: false in every
/// debug build without `RST_ALLOW_LOGOUT=1`, and false wherever `RST_LOGOUT_DRY_RUN=1` is
/// set, which `make ui-gate` always sets. A real log-out in a development run kills the
/// developer's own session — terminal, tests and all.
@MainActor
final class SessionLogout: LogoutPerforming {

    private let real: Bool
    private let diagnostics: Diagnostics
    private let launch: (URL, [String]) throws -> Void

    /// - Parameter launch: starts the process. Injected so a test can see what would run
    ///   without anything running; the default is the only thing that ever starts one.
    init(real: Bool, diagnostics: Diagnostics,
         launch: @escaping (URL, [String]) throws -> Void = SessionLogout.runProcess) {
        self.real = real
        self.diagnostics = diagnostics
        self.launch = launch
    }

    /// `/bin/launchctl` on every macOS. `gui/<uid>` is this user's own session — exactly the
    /// one being ended — so no `sudo`, no root.
    static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    static var bootoutArguments: [String] { ["bootout", "gui/\(getuid())"] }

    @discardableResult
    func logOut(at now: Date) -> Bool {
        let command = "launchctl bootout gui/\(getuid())"
        guard real else {
            diagnostics("logout: dry run — would run \(command)", at: now)
            return true
        }
        do {
            // Written before the launch, not after: a successful bootout ends this process
            // before a line written afterwards could reach the disk.
            diagnostics("logout: \(command)", at: now)
            try launch(Self.launchctl, Self.bootoutArguments)
            return true
        } catch {
            // Said out loud rather than swallowed: the child pressed a button that did
            // nothing, and this line is the only trace of why. The face is already back
            // (DESIGN §2.2), so there is nothing more to do here.
            diagnostics("logout: launchctl bootout failed — \(error)", at: now)
            return false
        }
    }

    /// Start the process and do not wait for it: if it works, this process is among the
    /// things it kills.
    nonisolated static func runProcess(_ executable: URL, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        try task.run()
    }
}

/// **`Wyloguj`, confirmed, as an `Engine` command** — the `logged_out` event first, then the
/// performer (CLAUDE.md: write the event before dispatching the action).
///
/// A type of its own, beside `GrantCommand`, so the headed tests can drive the event-then-act
/// order against a real `Engine` without going through `CoverEnforcer.apply(_:at:)`, which
/// orders a real window.
@MainActor
struct LogoutCommand {
    let engine: Engine
    let performer: any LogoutPerforming

    func apply(at now: Date) {
        engine.logOut(at: now)
        // A false return is already logged by the performer and needs nothing more: the
        // cover stays up either way, and the face is already back (DESIGN §2.2, §2.7).
        performer.logOut(at: now)
    }
}
