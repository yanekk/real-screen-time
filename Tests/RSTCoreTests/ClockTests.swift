import Foundation
import Testing
@testable import RSTCore

/// Time is injected everywhere, so these three types are load-bearing for every test that
/// follows in T03–T07. A `ScaledClock` that drifts would make an accelerated manual run
/// disagree with the suite, and the suite would be the one believed.
@Suite("Clock")
struct ClockTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("FakeClock.advance moves now and nothing else")
    func fakeClockAdvances() {
        let clock = FakeClock(t0)
        #expect(clock.now == t0)

        clock.advance(60)
        #expect(clock.now == t0.addingTimeInterval(60))

        clock.advance(-30)
        #expect(clock.now == t0.addingTimeInterval(30))

        // Independent instances: one test's clock cannot move another's.
        let other = FakeClock(t0)
        clock.advance(3600)
        #expect(other.now == t0)
    }

    @Test("FakeClock.now is settable outright")
    func fakeClockSets() {
        let clock = FakeClock(t0)
        clock.now = t0.addingTimeInterval(86_400)
        #expect(clock.now == t0.addingTimeInterval(86_400))
    }

    @Test("ScaledClock at scale 60 advances 60 simulated seconds per real second")
    func scaledClockScales() {
        // Injected wall clock, not `sleep`: a test that proves 60× by waiting a real
        // second is a test nobody runs twice.
        let wall = FakeClock(Date(timeIntervalSince1970: 0))
        let clock = ScaledClock(origin: t0, scale: 60, wall: wall)

        #expect(clock.now == t0)                                    // no real time passed

        wall.advance(1)
        #expect(clock.now == t0.addingTimeInterval(60))

        wall.advance(1)
        #expect(clock.now == t0.addingTimeInterval(120))

        wall.advance(60)
        #expect(clock.now == t0.addingTimeInterval(3600 + 120))      // an hour of real time
    }

    @Test("ScaledClock at scale 1 tracks the wall clock exactly")
    func scaledClockAtUnity() {
        let wall = FakeClock(Date(timeIntervalSince1970: 500))
        let clock = ScaledClock(origin: t0, scale: 1, wall: wall)
        wall.advance(42)
        #expect(clock.now == t0.addingTimeInterval(42))
    }

    @Test("ScaledClock takes its wall origin at construction, not at first read")
    func scaledClockOriginIsFixed() {
        let wall = FakeClock(t0)
        let clock = ScaledClock(origin: t0, scale: 10, wall: wall)
        wall.advance(5)
        // 5 real seconds since construction → 50 simulated, not 50 from wherever it was
        // first read.
        #expect(clock.now == t0.addingTimeInterval(50))
    }

    @Test("SystemClock reads the real clock and does not go backwards")
    func systemClockMovesForward() {
        let clock = SystemClock()
        let first = clock.now
        let second = clock.now
        #expect(second >= first)
        // Sanity that it is the wall clock and not a fixed epoch: after 2020-01-01.
        #expect(first.timeIntervalSince1970 > 1_577_836_800)
    }
}
