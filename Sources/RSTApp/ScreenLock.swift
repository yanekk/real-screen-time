import AppKit
import RSTCore

/// `Zablokuj ekran` — the child's own way to end a turn (DESIGN §2.6).
///
/// **Resolved at startup, never at click time**, and whether the button is drawn at all
/// follows what was found. `SACLockScreenImmediate` is private API: acceptable here, since
/// this app is ad-hoc signed and never leaves two machines, but it has to degrade rather
/// than crash — and a `Zablokuj ekran` that does nothing is worse than no button. When the
/// symbol is gone the cover drops `.lock` and offers only its confirmed `Wyloguj`
/// (cover-buttons-logout DESIGN §2.4); the bootout that used to be the fallback here is
/// ``SessionLogout``'s now.
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
        /// The private symbol has vanished from a future macOS. Nothing to lock with, so the
        /// cover does not offer the button (`CoverModel`'s `canLock: false`).
        case unavailable
    }

    private static let framework =
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"

    private typealias LockFunction = @convention(c) () -> Int32
    private static var lockImmediately: LockFunction?

    /// What ``engage(_:at:)`` can do — read by the cover to decide whether `.lock` is drawn.
    static var mechanism: Mechanism { lockImmediately == nil ? .unavailable : .lockImmediately }

    /// Look the symbol up. **Call once, at launch.**
    ///
    /// The handle is deliberately never `dlclose`d: the function pointer outlives this
    /// call, and closing the library under it is a crash at the exact moment the child is
    /// trying to hand the machine back.
    static func resolve(_ diagnostics: Diagnostics, at now: Date) {
        guard let handle = dlopen(framework, RTLD_LAZY) else {
            diagnostics("screen lock: \(framework) will not load — \(dlerror().map { String(cString: $0) } ?? "no reason given"), the cover will offer Wyloguj only",
                        at: now)
            return
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            diagnostics("screen lock: SACLockScreenImmediate is gone from login.framework — the cover will offer Wyloguj only",
                        at: now)
            return
        }
        lockImmediately = unsafeBitCast(symbol, to: LockFunction.self)
        diagnostics("screen lock: SACLockScreenImmediate resolved", at: now)
    }

    /// Lock the screen.
    ///
    /// The event is `Engine.lockScreen(at:)`'s to write, and it is written before this is
    /// called — the rule being that the record is stamped with the decision, not with
    /// whatever the system did about it afterwards.
    @discardableResult
    static func engage(_ diagnostics: Diagnostics, at now: Date) -> Bool {
        guard let lockImmediately else {
            // Unreachable while the cover drops `.lock` for `.unavailable`; said out loud
            // rather than assumed, since the only trace of a dead button is this line.
            diagnostics("screen lock: no SACLockScreenImmediate — nothing to lock with", at: now)
            return false
        }
        let result = lockImmediately()
        diagnostics("screen lock: SACLockScreenImmediate returned \(result)", at: now)
        return result == 0
    }
}
