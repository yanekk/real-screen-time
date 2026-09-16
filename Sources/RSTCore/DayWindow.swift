import Foundation

/// Which day does this moment belong to.
///
/// The day rolls over at `dayResetHour` (default 6), not midnight — DESIGN §2.1. That
/// buys exactly one morning boundary instead of two: the self-service session count
/// refilling and a `Disable` stand-down expiring are the same instant. It also means
/// someone still awake at 00:30 is inside the previous day rather than being handed two
/// fresh sessions at the least useful hour of the night.
///
/// **There is no curfew.** §2.1 replaced it with sessions, and `isPastCurfew` is
/// deliberately absent — see T03's task doc before adding it back.
///
/// **Evaluated per tick, never by a timer.** Every value here is a pure function of a
/// `now` handed in from the caller's `Clock`. Nothing may schedule a timer to fire at
/// 06:00: a timer set across a sleep does not fire when the machine wakes, and a fixed
/// 24-hour delay drifts by an hour twice a year.
///
/// A namespace, not a type — there is nothing to instantiate, and `enum` says so in a way
/// `struct` cannot. Matches `ClockText` below.
public enum DayWindow {

    /// The hours a day may roll over at.
    ///
    /// `config.json` is edited by hand — there is no Settings UI until T17 — so a
    /// `"day_reset_hour": 99` is a real path, not a theoretical one, and nothing between
    /// the file and here validates it (see the T02 finding on unvalidated config values).
    public static let resetHourRange = 0...23

    /// **The clamp lives at the point of use, and this is it.**
    ///
    /// Decided here because T03 is the first task to put `day_reset_hour` into
    /// arithmetic. Clamping rather than substituting the shipped default: 99 clamps to 23
    /// and -5 to 0, which is the closest thing to what was typed, where falling back to 6
    /// would silently ignore an edit the parent can see in the file and believes took.
    /// The important half is that **both functions below are total** — no input off disk
    /// can make them trap or return a nonsense day.
    ///
    /// Clamping in `Config` on load was the alternative. Rejected for now: it would make
    /// the config a validating type as a side effect of a day-window task, and the other
    /// unvalidated values (`session_minutes: 0` and friends) belong to T05. If T05 wants a
    /// validating `Config`, this clamp becomes redundant rather than wrong.
    static func normalised(resetHour: Int) -> Int {
        min(max(resetHour, resetHourRange.lowerBound), resetHourRange.upperBound)
    }

    /// The day `now` belongs to, as `"YYYY-MM-DD"` — the key `SessionState` counts
    /// self-service sessions against (T04).
    ///
    /// 2026-08-22 05:59 is `"2026-08-21"`; 2026-08-22 06:00 is `"2026-08-22"`.
    ///
    /// **Calendar arithmetic, never `now - resetHour * 3600`.** Subtracting six hours of
    /// absolute time gets the wrong day on both DST changes: on a spring-forward morning
    /// 06:30 local is only five real hours after midnight, so the subtraction lands in the
    /// previous day and the session count refills an hour late — twice a year, in the
    /// morning, when it is least likely to be understood as a bug.
    ///
    /// The calendar carries its own time zone, and it is injected: reading
    /// `Calendar.current` here would be a system query, which `RSTCore` does not make, and
    /// would leave the DST cases untestable.
    public static func dayKey(for now: Date, resetHour: Int, calendar: Calendar) -> String {
        let hour = normalised(resetHour: resetHour)
        let day: Date
        if calendar.component(.hour, from: now) < hour {
            // Before the reset: this moment belongs to yesterday. `startOfDay` first, so
            // the subtraction cannot land on a local time that does not exist.
            day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(-86_400)
        } else {
            day = now
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        // Formatted by hand rather than with a `DateFormatter`: this string is a ledger
        // key, not something anyone reads, and it must not depend on a locale or on a
        // formatter's calendar being set the same way as the one passed in.
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The next instant the day rolls over, **strictly after** `now`.
    ///
    /// At 05:00 that is 06:00 today; at exactly 06:00:00 it is 06:00 tomorrow, because a
    /// caller that has just handled this morning's rollover must not be handed the same
    /// instant again.
    ///
    /// Strictly after also means the result is never `now` itself, so a caller comparing
    /// `now >= nextReset` cannot loop.
    ///
    /// The `calendar` parameter is a deliberate departure from T03's interface snippet,
    /// which omits it. Without one this would have to read `Calendar.current` — a system
    /// query `RSTCore` may not make, and the reason the 23- and 25-hour days below are
    /// testable at all.
    public static func nextReset(after now: Date, resetHour: Int, calendar: Calendar) -> Date {
        let hour = normalised(resetHour: resetHour)
        if let today = reset(onDayOf: now, hour: hour, calendar: calendar), today > now {
            return today
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        return reset(onDayOf: tomorrow, hour: hour, calendar: calendar) ?? tomorrow
    }

    /// `hour:00:00` local on whatever day `date` falls in.
    ///
    /// Built from calendar components rather than by adding `hour * 3600` to the start of
    /// the day: on a DST morning those differ by an hour, and it is the wall clock that
    /// says 06:00, not the elapsed seconds.
    private static func reset(onDayOf date: Date, hour: Int, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = 0
        parts.second = 0
        parts.nanosecond = 0
        return calendar.date(from: parts)
    }
}

/// Times of day as text: lenient on the way in, canonical on the way out.
///
/// **Unused for now, and kept on purpose.** §2.1 replaced the curfew with sessions, which
/// left no wall-clock rule in the app and an accepted gap with it: a session can start at
/// 06:05 or at 22:30. The recorded way to close that gap is a *start window* — sessions
/// may only begin between two times — and this is the parsing it would need. Small,
/// tested, and cheaper to keep than to write again.
public enum ClockText {

    /// Minutes since local midnight, or `nil` if the text is not a time.
    ///
    /// Lenient because refusing `8pm`, `20.00` or `8:00 PM` from someone who plainly means
    /// 20:00 would be perverse. Strict where leniency would mean guessing: `nil` is
    /// returned rather than a substituted value so the caller keeps whatever it had, which
    /// is a time somebody actually chose.
    ///
    /// Accepts `"20:00"`, `"20.00"`, `"8pm"`, `"8 PM"`, `"8:00 PM"`, `"8:00p.m."`, `"8"`.
    /// Rejects `"24:00"`, `"19:60"`, `"13pm"`, `"8:5"`, `"2000"`, `"banana"`, `""`.
    public static func parse(_ text: String) -> Int? {
        // Whitespace anywhere, so `"8 : 00 PM"` and a stray trailing space both work.
        var body = text.lowercased().filter { !$0.isWhitespace }
        guard !body.isEmpty else { return nil }

        // Longest first: `"a.m."` must not be tested after a rule that would strip `"m."`.
        var meridiem: Meridiem?
        for (suffix, marker) in [("a.m.", Meridiem.am), ("p.m.", .pm), ("am", .am), ("pm", .pm)]
        where body.hasSuffix(suffix) {
            body.removeLast(suffix.count)
            meridiem = marker
            break
        }

        // `20.00` and `20,00` mean what `20:00` means; nobody typing either means anything
        // else. Done after the meridiem strip so `p.m.`'s dots are already gone.
        body = body.replacingOccurrences(of: ".", with: ":")
                   .replacingOccurrences(of: ",", with: ":")

        let fields = body.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 1 || fields.count == 2 else { return nil }

        guard let hour = number(fields[0], digits: 1...2) else { return nil }
        var minute = 0
        if fields.count == 2 {
            // Exactly two digits: `"8:5"` is either 08:05 or 08:50 and there is no way to
            // tell, so it is rejected rather than guessed.
            guard let parsed = number(fields[1], digits: 2...2) else { return nil }
            minute = parsed
        }
        guard (0...59).contains(minute) else { return nil }

        switch meridiem {
        case .am:
            // 12am is 00:xx. `13am` is not a time anyone meant.
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12) * 60 + minute
        case .pm:
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + 12) * 60 + minute
        case nil:
            // 24:00 is rejected: it is midnight written as the end of the day, and this
            // returns a point in a day, not a duration.
            guard (0...23).contains(hour) else { return nil }
            return hour * 60 + minute
        }
    }

    /// Canonical `"HH:MM"` — the form stored in `config.json`, whatever was typed.
    ///
    /// Total: minutes outside a day wrap rather than producing `"25:00"` or `"-1:00"`.
    /// A caller handing this an out-of-range value has a bug, and a wrapped time is a
    /// visible one where an impossible string would be copied into a config file.
    public static func format(_ minutes: Int) -> String {
        let inDay = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", inDay / 60, inDay % 60)
    }

    private enum Meridiem { case am, pm }

    /// ASCII digits only, in a given count. `Int(_:)` alone would accept `"+8"` and
    /// `Character.isNumber` alone would accept non-ASCII digits.
    private static func number(_ field: Substring, digits: ClosedRange<Int>) -> Int? {
        guard digits.contains(field.count),
              field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(field)
    }
}
