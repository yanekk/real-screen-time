import Foundation

/// One app per account. Two would double-charge the ledger — both would tick, both would
/// `advance` the same session, and the child would lose two seconds for every one he spent.
///
/// `flock` on a file in the data directory, which is the cheapest mechanism that is also
/// correct across a crash: the lock is owned by the file descriptor, so the kernel drops it
/// when the process dies however it dies. A pid file would need a liveness check and would
/// still be wrong after a pid was reused.
///
/// The descriptor is deliberately never closed. It is released when the process exits, and
/// that is exactly the lifetime the lock should have.
final class InstanceLock {

    enum Outcome {
        case acquired(InstanceLock)
        /// Another instance holds the lock. The right response is to exit quietly.
        case alreadyRunning
        /// The lock file could not be opened at all — a data directory that does not exist
        /// and cannot be created, or one somebody made read-only.
        ///
        /// **Not a reason to refuse to start.** This app's job is to be running; declining
        /// to enforce because a lock file was unavailable would turn a permissions oddity
        /// into a free evening. The caller logs it and carries on unprotected.
        case unavailable(String)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) -> Outcome {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        let descriptor = open(url.path, O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else {
            return .unavailable("open \(url.path): \(String(cString: strerror(errno)))")
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            // `EWOULDBLOCK` is the answer this exists to get; anything else is a broken
            // filesystem rather than a second copy of the app, and is reported as such.
            return failure == EWOULDBLOCK
                ? .alreadyRunning
                : .unavailable("flock \(url.path): \(String(cString: strerror(failure)))")
        }

        // The pid is for whoever is reading `plans/initial-build/RECOVERY.md` at the time, and nothing
        // reads it back — the lock, not the contents, is what makes the guarantee.
        ftruncate(descriptor, 0)
        let line = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = Array(line.utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }

        return .acquired(InstanceLock(descriptor: descriptor))
    }
}
