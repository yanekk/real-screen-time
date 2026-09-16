import Foundation
import Testing
@testable import RSTCore

/// The 06:00 rollover is when the self-service session count refills and a `Disable`
/// stand-down expires — one boundary, twice a year computed on a day that is not 24 hours
/// long. Every date here is built in a **fixed** `Europe/Warsaw` calendar: the DST cases
/// are the point of this suite, and a test that used the machine's own time zone would
/// pass or fail depending on where the Mac was.
@Suite("DayWindow")
struct DayWindowTests {

    // Poland: forward on 2026-03-29 (02:00 → 03:00, a 23-hour day) and back on
    // 2026-10-25 (03:00 → 02:00, a 25-hour day). Both are last Sundays, as the EU rule says.
    private let warsaw = calendar(in: "Europe/Warsaw")

    // MARK: - The 06:00 rule

    @Test("05:59:59 belongs to the previous day, 06:00:00 to the current one")
    func rollsOverAtSix() {
        let before = warsaw.at(2026, 8, 22, 5, 59, 59)
        let after = warsaw.at(2026, 8, 22, 6, 0, 0)

        #expect(DayWindow.dayKey(for: before, resetHour: 6, calendar: warsaw) == "2026-08-21")
        #expect(DayWindow.dayKey(for: after, resetHour: 6, calendar: warsaw) == "2026-08-22")

        // One second either side of the boundary, so the comparison is `<`, not `<=`.
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 8, 22, 5, 59, 59).addingTimeInterval(1),
                                 resetHour: 6, calendar: warsaw) == "2026-08-22")
        #expect(DayWindow.dayKey(for: after.addingTimeInterval(-1),
                                 resetHour: 6, calendar: warsaw) == "2026-08-21")
    }

    @Test("00:30 is still yesterday — nobody gets two fresh sessions at half past midnight")
    func afterMidnightIsStillYesterday() {
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 8, 22, 0, 30), resetHour: 6, calendar: warsaw)
                == "2026-08-21")
    }

    @Test("a month boundary")
    func monthBoundary() {
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 9, 1, 5, 0), resetHour: 6, calendar: warsaw)
                == "2026-08-31")
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 9, 1, 6, 0), resetHour: 6, calendar: warsaw)
                == "2026-09-01")
    }

    @Test("a year boundary")
    func yearBoundary() {
        #expect(DayWindow.dayKey(for: warsaw.at(2027, 1, 1, 2, 0), resetHour: 6, calendar: warsaw)
                == "2026-12-31")
        #expect(DayWindow.dayKey(for: warsaw.at(2027, 1, 1, 6, 0), resetHour: 6, calendar: warsaw)
                == "2027-01-01")
    }

    @Test("a leap day")
    func leapDay() {
        #expect(DayWindow.dayKey(for: warsaw.at(2028, 3, 1, 3, 0), resetHour: 6, calendar: warsaw)
                == "2028-02-29")
    }

    @Test("resetHour 0 makes the day key the calendar day")
    func midnightReset() {
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 8, 22, 0, 0), resetHour: 0, calendar: warsaw)
                == "2026-08-22")
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 8, 22, 23, 59, 59), resetHour: 0, calendar: warsaw)
                == "2026-08-22")
    }

    // MARK: - DST

    @Test("the 23-hour day produces sane keys and a 23-hour interval")
    func springForward() {
        // 2026-03-29: the clocks go 02:00 → 03:00, so the day is 23 hours long. Computing
        // the key by subtracting six hours of *absolute* time would put 06:30 in the 28th.
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 3, 29, 1, 0), resetHour: 6, calendar: warsaw)
                == "2026-03-28")
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 3, 29, 6, 30), resetHour: 6, calendar: warsaw)
                == "2026-03-29")
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 3, 29, 23, 0), resetHour: 6, calendar: warsaw)
                == "2026-03-29")
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 3, 30, 5, 0), resetHour: 6, calendar: warsaw)
                == "2026-03-29")

        // The rollover is at 06:00 on the wall clock, which is 23 real hours after the
        // previous one — not 24.
        let previous = warsaw.at(2026, 3, 28, 6, 0)
        let next = DayWindow.nextReset(after: previous.addingTimeInterval(1),
                                       resetHour: 6, calendar: warsaw)
        #expect(next == warsaw.at(2026, 3, 29, 6, 0))
        #expect(next.timeIntervalSince(previous) == 23 * 3600)
    }

    @Test("the 25-hour day produces sane keys and a 25-hour interval")
    func fallBack() {
        // 2026-10-25: the clocks go 03:00 → 02:00, so 02:00–02:59 happens twice.
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 10, 25, 1, 0), resetHour: 6, calendar: warsaw)
                == "2026-10-24")
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 10, 25, 7, 0), resetHour: 6, calendar: warsaw)
                == "2026-10-25")

        let previous = warsaw.at(2026, 10, 24, 6, 0)
        let next = DayWindow.nextReset(after: previous.addingTimeInterval(1),
                                       resetHour: 6, calendar: warsaw)
        #expect(next == warsaw.at(2026, 10, 25, 6, 0))
        #expect(next.timeIntervalSince(previous) == 25 * 3600)
    }

    @Test("the key changes exactly once across a 25-hour day, at the reset instant")
    func keyChangesOnceAcrossTheLongDay() {
        // Swept in absolute time, not in wall-clock components: 02:30 exists twice on this
        // day and `date(from:)` can only name one of them. Every instant of the repeated
        // hour is visited this way.
        let start = warsaw.at(2026, 10, 25, 0, 0)
        let boundary = DayWindow.nextReset(after: start, resetHour: 6, calendar: warsaw)
        var changes = 0
        var previousKey = DayWindow.dayKey(for: start, resetHour: 6, calendar: warsaw)

        for step in 1...(26 * 4) {                      // 26 hours in quarter-hour steps
            let moment = start.addingTimeInterval(Double(step) * 900)
            let key = DayWindow.dayKey(for: moment, resetHour: 6, calendar: warsaw)
            if key != previousKey {
                changes += 1
                // The change lands in the quarter hour that contains the reset.
                #expect(moment >= boundary && moment.addingTimeInterval(-900) < boundary)
                previousKey = key
            }
            // Only ever these two days, in this order.
            #expect(key == "2026-10-24" || key == "2026-10-25")
        }
        #expect(changes == 1)
    }

    // MARK: - nextReset

    @Test("nextReset is strictly after now")
    func nextResetIsStrictlyAfter() {
        let sixExactly = warsaw.at(2026, 8, 22, 6, 0, 0)
        // A caller that has just handled this morning's rollover must not be handed the
        // same instant again, or it loops.
        #expect(DayWindow.nextReset(after: sixExactly, resetHour: 6, calendar: warsaw)
                == warsaw.at(2026, 8, 23, 6, 0))
        #expect(DayWindow.nextReset(after: sixExactly.addingTimeInterval(-1), resetHour: 6, calendar: warsaw)
                == sixExactly)
        #expect(DayWindow.nextReset(after: warsaw.at(2026, 8, 22, 23, 59, 59), resetHour: 6, calendar: warsaw)
                == warsaw.at(2026, 8, 23, 6, 0))
        #expect(DayWindow.nextReset(after: warsaw.at(2026, 8, 22, 0, 0, 1), resetHour: 6, calendar: warsaw)
                == warsaw.at(2026, 8, 22, 6, 0))
    }

    @Test("nextReset crosses month, year and leap boundaries")
    func nextResetAcrossBoundaries() {
        #expect(DayWindow.nextReset(after: warsaw.at(2026, 8, 31, 12, 0), resetHour: 6, calendar: warsaw)
                == warsaw.at(2026, 9, 1, 6, 0))
        #expect(DayWindow.nextReset(after: warsaw.at(2026, 12, 31, 12, 0), resetHour: 6, calendar: warsaw)
                == warsaw.at(2027, 1, 1, 6, 0))
        #expect(DayWindow.nextReset(after: warsaw.at(2028, 2, 28, 12, 0), resetHour: 6, calendar: warsaw)
                == warsaw.at(2028, 2, 29, 6, 0))
    }

    @Test("nextReset and dayKey agree: the key changes at exactly that instant")
    func nextResetAgreesWithDayKey() {
        for hour in DayWindow.resetHourRange {
            let now = warsaw.at(2026, 3, 28, 13, 17, 42)          // arbitrary, mid-afternoon
            let next = DayWindow.nextReset(after: now, resetHour: hour, calendar: warsaw)
            #expect(next > now)
            #expect(DayWindow.dayKey(for: next.addingTimeInterval(-1), resetHour: hour, calendar: warsaw)
                    == DayWindow.dayKey(for: now, resetHour: hour, calendar: warsaw))
            #expect(DayWindow.dayKey(for: next, resetHour: hour, calendar: warsaw)
                    != DayWindow.dayKey(for: now, resetHour: hour, calendar: warsaw))
        }
    }

    // MARK: - Values off disk

    @Test("an out-of-range reset hour is clamped, not trusted")
    func clampsResetHour() {
        // `config.json` is hand-edited until T17, so "day_reset_hour": 99 is a real path.
        #expect(DayWindow.normalised(resetHour: 99) == 23)
        #expect(DayWindow.normalised(resetHour: -5) == 0)
        #expect(DayWindow.normalised(resetHour: 6) == 6)

        // 99 behaves as 23 rather than trapping or producing a nonsense key.
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 8, 22, 22, 0), resetHour: 99, calendar: warsaw)
                == "2026-08-21")
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 8, 22, 23, 30), resetHour: 99, calendar: warsaw)
                == "2026-08-22")
        // -5 behaves as midnight.
        #expect(DayWindow.dayKey(for: warsaw.at(2026, 8, 22, 0, 30), resetHour: -5, calendar: warsaw)
                == "2026-08-22")

        #expect(DayWindow.nextReset(after: warsaw.at(2026, 8, 22, 12, 0), resetHour: 99, calendar: warsaw)
                == warsaw.at(2026, 8, 22, 23, 0))
        #expect(DayWindow.nextReset(after: warsaw.at(2026, 8, 22, 12, 0), resetHour: -5, calendar: warsaw)
                == warsaw.at(2026, 8, 23, 0, 0))
    }

    @Test("the day key is independent of the machine's time zone")
    func timeZoneComesFromTheCalendar() {
        // 2026-08-22 05:00 in Warsaw is 2026-08-21 20:00 in Los Angeles — different days
        // before the reset is even considered. The calendar decides, never the machine.
        let moment = warsaw.at(2026, 8, 22, 5, 0)
        #expect(DayWindow.dayKey(for: moment, resetHour: 6, calendar: warsaw) == "2026-08-21")
        #expect(DayWindow.dayKey(for: moment, resetHour: 6,
                                 calendar: Self.calendar(in: "America/Los_Angeles")) == "2026-08-21")
        #expect(DayWindow.dayKey(for: moment, resetHour: 6,
                                 calendar: Self.calendar(in: "UTC")) == "2026-08-21")
        // Same instant, an hour later in Warsaw: Warsaw has rolled over, LA has not.
        let later = warsaw.at(2026, 8, 22, 6, 0)
        #expect(DayWindow.dayKey(for: later, resetHour: 6, calendar: warsaw) == "2026-08-22")
        #expect(DayWindow.dayKey(for: later, resetHour: 6,
                                 calendar: Self.calendar(in: "America/Los_Angeles")) == "2026-08-21")
    }

    // MARK: -

    fileprivate static func calendar(in identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }
}

/// Lenient in, canonical out. Kept for the start window that would close §2.1's accepted
/// gap; tested now because a parser written twice is a parser wrong once.
@Suite("ClockText")
struct ClockTextTests {

    @Test("accepts the forms someone actually types", arguments: [
        ("20:00", 1200), ("20.00", 1200), ("20,00", 1200),
        ("8pm", 1200), ("8 PM", 1200), ("8:00 PM", 1200), ("8:00pm", 1200), ("8:00p.m.", 1200),
        ("8", 480), ("8am", 480), ("8 A.M.", 480), ("08:00", 480),
        ("12am", 0), ("12:30am", 30), ("12pm", 720), ("12:01pm", 721),
        ("0:00", 0), ("00:00", 0), ("23:59", 1439), ("  7:05  ", 425),
    ])
    func acceptsLenientInput(input: String, expected: Int) {
        #expect(ClockText.parse(input) == expected)
    }

    @Test("rejects anything it would have to guess at", arguments: [
        "24:00",        // midnight written as the end of a day; this returns a point in one
        "19:60", "23:61",
        "banana", "", "   ",
        "13pm", "0am", "13am",      // a 12-hour clock has no 13 and no 0
        "8:5",          // 08:05 or 08:50? no way to tell
        "2000",         // military time is not supported, and 2000 is not an hour
        "-1:00", "+8:00",
        "8:00:00",      // seconds are not a thing here
        "8:", ":30", "::",
        "٨:٠٠",         // non-ASCII digits
        "pm", "am",
    ])
    func rejectsNonsense(input: String) {
        #expect(ClockText.parse(input) == nil)
    }

    @Test("formats canonically")
    func formatsCanonically() {
        #expect(ClockText.format(0) == "00:00")
        #expect(ClockText.format(90) == "01:30")
        #expect(ClockText.format(1200) == "20:00")
        #expect(ClockText.format(1439) == "23:59")
    }

    @Test("format is total — out-of-range minutes wrap rather than lie")
    func formatWraps() {
        #expect(ClockText.format(1440) == "00:00")
        #expect(ClockText.format(1441) == "00:01")
        #expect(ClockText.format(-60) == "23:00")
        #expect(ClockText.format(-1) == "23:59")
    }

    @Test("whatever was typed, one canonical string is stored")
    func roundTrip() throws {
        for input in ["8pm", "20:00", "20.00", "8:00 PM"] {
            #expect(ClockText.format(try #require(ClockText.parse(input))) == "20:00")
        }
        // And the canonical form parses back to itself.
        for minutes in stride(from: 0, to: 1440, by: 7) {
            #expect(ClockText.parse(ClockText.format(minutes)) == minutes)
        }
    }
}

private extension Calendar {
    /// A date from wall-clock components in this calendar's time zone.
    func at(_ year: Int, _ month: Int, _ day: Int,
            _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let parts = DateComponents(year: year, month: month, day: day,
                                   hour: hour, minute: minute, second: second)
        guard let date = date(from: parts) else {
            fatalError("no such local time: \(year)-\(month)-\(day) \(hour):\(minute):\(second)")
        }
        return date
    }
}
