import Foundation
import RSTCore

/// Somewhere to say something that is **not evidence** — `app.log`, DESIGN §3.5.
///
/// Kept separate from the `EventSink` in the type system rather than by convention, because
/// the two files are read for different reasons and the difference is easy to blur at a
/// call site. `events.jsonl` is the record a parent queries with `jq` and its vocabulary is
/// closed by `Event.Field`; `app.log` is free text nobody parses, for the flags a run
/// started with, a save that failed, and whatever went wrong that the app survived.
///
/// A closure rather than a protocol with two implementations: the only variation is where
/// the string goes, and `discarded` is the whole of the other case.
struct Diagnostics: Sendable {
    let write: @Sendable (String, Date) -> Void

    /// Into the `app.log` beside the event log.
    init(_ sink: FileEventSink) {
        write = { message, date in sink.note(message, at: date) }
    }

    /// Anywhere at all — for a test that asserts on what was said.
    init(writing write: @escaping @Sendable (String, Date) -> Void) {
        self.write = write
    }

    private init(discarding: Void) {
        write = { _, _ in }
    }

    /// Says nothing, for the moments before the data directory is known.
    static let discarded = Diagnostics(discarding: ())

    func callAsFunction(_ message: String, at date: Date) { write(message, date) }
}
