import AppKit
import RSTCore

/// `Zablokuj ekran` — the child's own way to end a turn (DESIGN §2.6).
///
/// **Resolved at startup, never at click time**, and the button is labelled from what was
/// found. `SACLockScreenImmediate` is private API: acceptable here, since this app is
/// ad-hoc signed and never leaves two machines, but it has to degrade rather than crash —
/// and a `Zablokuj ekran` that does nothing is worse than an honest `Wyloguj`.
///
/// Measured on macOS 26.5, 2026-08-22: the symbol is present and returns 0, and the lock is
/// immediate — no dim-and-wait, no Automation prompt, no Accessibility grant. Locking beats
/// logging out on every axis that matters here: nothing is killed, nothing unsaved is lost,
/// and the lock screen is also where the parent switches to their own account.
@MainActor
enum ScreenLock {

    /// What the button will actually do, decided once at launch.
    enum Mechanism {
        /// `SACLockScreenImmediate()` — the real thing.
        case lockImmediately
        /// `launchctl bootout gui/$UID`. A hard logout, and the last resort: it kills
        /// everything the child had open. Only ever reached if the private symbol has
        /// vanished from a future macOS.
        case logOut
    }

    private static let framework =
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"

    private typealias LockFunction = @convention(c) () -> Int32
    private static var lockImmediately: LockFunction?

    /// What ``engage(_:at:)`` will do — read by the cover to label its button.
    static var mechanism: Mechanism { lockImmediately == nil ? .logOut : .lockImmediately }

    /// Look the symbol up. **Call once, at launch.**
    ///
    /// The handle is deliberately never `dlclose`d: the function pointer outlives this
    /// call, and closing the library under it is a crash at the exact moment the child is
    /// trying to hand the machine back.
    static func resolve(_ diagnostics: Diagnostics, at now: Date) {
        guard let handle = dlopen(framework, RTLD_LAZY) else {
            diagnostics("screen lock: \(framework) will not load — \(dlerror().map { String(cString: $0) } ?? "no reason given"), falling back to log out",
                        at: now)
            return
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            diagnostics("screen lock: SACLockScreenImmediate is gone from login.framework — falling back to log out",
                        at: now)
            return
        }
        lockImmediately = unsafeBitCast(symbol, to: LockFunction.self)
        diagnostics("screen lock: SACLockScreenImmediate resolved", at: now)
    }

    /// Lock, or log out if there is nothing to lock with.
    ///
    /// The event is `Engine.lockScreen(at:)`'s to write, and it is written before this is
    /// called — the rule being that the record is stamped with the decision, not with
    /// whatever the system did about it afterwards.
    @discardableResult
    static func engage(_ diagnostics: Diagnostics, at now: Date) -> Bool {
        if let lockImmediately {
            let result = lockImmediately()
            diagnostics("screen lock: SACLockScreenImmediate returned \(result)", at: now)
            return result == 0
        }

        // No `sudo`, no root: `gui/$UID` is this user's own session, which is exactly the
        // one being ended. `launchctl` is in /bin on every macOS.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())"]
        do {
            try task.run()
            diagnostics("screen lock: no symbol — logging out with launchctl bootout", at: now)
            return true
        } catch {
            // Both routes gone. Said out loud rather than swallowed: the child is standing
            // in front of a cover pressing a button that does nothing, and the only trace
            // of why is this line.
            diagnostics("screen lock: launchctl bootout failed — \(error)", at: now)
            return false
        }
    }
}
