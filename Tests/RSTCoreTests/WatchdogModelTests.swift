import Foundation
import Testing
@testable import RSTCore

/// The hang watchdog's rule — DESIGN §2.8, T15.
///
/// The thread that survives a wedged main thread is `RSTApp`'s and is proved by `make
/// watchdog`, which parks a real main thread in a real process. What is proved here is the
/// arithmetic that decides a hang has happened, and above all the two rules that stop it
/// killing an app that is perfectly well: **only under a cover**, and **only after the
/// whole threshold**.
@Suite("Watchdog rule")
struct WatchdogModelTests {

    /// A minute of silence, a second at a time, the way the watcher thread feeds it.
    private func silence(_ model: inout WatchdogModel, seconds: Int) -> WatchdogModel.Verdict {
        var verdict = WatchdogModel.Verdict.keepWatching
        for _ in 0..<seconds {
            verdict = model.advance(by: 1)
            if case .leave = verdict { return verdict }
        }
        return verdict
    }

    // MARK: - The two rules

    @Test("thirty silent seconds under a cover ends the process")
    func firesUnderACover() {
        var model = WatchdogModel()
        model.coverBegan()
        #expect(silence(&model, seconds: 29) == .keepWatching)
        #expect(model.advance(by: 1) == .leave(coveredSeconds: 30, stalledSeconds: 30))
    }

    /// A hang with nothing covered is a bug to investigate, not a reason to kill a process
    /// that is harming nobody — and this is the case an observer run is in all day.
    @Test("the same silence with no cover is left alone")
    func neverFiresWithoutACover() {
        var model = WatchdogModel()
        #expect(silence(&model, seconds: 600) == .keepWatching)
        #expect(model.stalledSeconds == 600)
        #expect(model.coveredSeconds == 0)
    }

    @Test("a tick resets the count")
    func pettingResets() {
        var model = WatchdogModel()
        model.coverBegan()
        _ = silence(&model, seconds: 29)
        model.pet()
        #expect(model.stalledSeconds == 0)
        #expect(silence(&model, seconds: 29) == .keepWatching, "the count started again")
        #expect(model.advance(by: 1) == .leave(coveredSeconds: 59, stalledSeconds: 30))
    }

    /// The cover coming down is the main thread doing work, so it is proof of life — and
    /// after it there is nothing left for the watchdog to rescue anyway.
    @Test("a cover that comes down stops the countdown")
    func uncoveringStops() {
        var model = WatchdogModel()
        model.coverBegan()
        _ = silence(&model, seconds: 29)
        model.coverEnded()
        #expect(silence(&model, seconds: 600) == .keepWatching)
    }

    /// **The stale-count trap.** `AppController` stops ticking across sleep, so a run can
    /// legitimately be silent for hours and then put a cover up in the first tick after the
    /// wake. Without the pet inside `coverBegan` that cover would be killed on its first
    /// second, over and over, for as long as the child was blocked.
    @Test("a cover going up after a long silence is not killed for it")
    func coveringIsProofOfLife() {
        var model = WatchdogModel()
        #expect(silence(&model, seconds: 3_600) == .keepWatching)
        model.coverBegan()
        #expect(model.stalledSeconds == 0)
        #expect(silence(&model, seconds: 29) == .keepWatching)
    }

    // MARK: - What the event says

    @Test("covered_s is the age of the cover, not of the silence")
    func coveredSecondsIsTheCoverAge() {
        var model = WatchdogModel()
        model.coverBegan()
        // Ten minutes of a healthy app under a cover: the tick keeps petting.
        for _ in 0..<600 {
            _ = model.advance(by: 1)
            model.pet()
        }
        #expect(model.coveredSeconds == 600)
        let verdict = silence(&model, seconds: 30)
        #expect(verdict == .leave(coveredSeconds: 630, stalledSeconds: 30))
    }

    @Test("a second cover counts from its own beginning")
    func coveredSecondsResetPerCover() {
        var model = WatchdogModel()
        model.coverBegan()
        for _ in 0..<100 { _ = model.advance(by: 1); model.pet() }
        model.coverEnded()
        model.coverBegan()
        #expect(model.coveredSeconds == 0)
        #expect(silence(&model, seconds: 30) == .leave(coveredSeconds: 30, stalledSeconds: 30))
    }

    // MARK: - The threshold

    @Test("the threshold is DESIGN §2.8's thirty seconds unless it is asked to be otherwise")
    func defaultThreshold() {
        #expect(WatchdogModel.defaultStallSeconds == 30)
        #expect(WatchdogModel().stallSeconds == 30)
        #expect(WatchdogModel(stallSeconds: 3).stallSeconds == 3)
    }

    /// The tick is a one-second timer with a 200 ms tolerance. Any threshold near it is a
    /// watchdog that kills a perfectly healthy app on an ordinary scheduling hiccup.
    @Test("a threshold below a second is refused", arguments: [0.0, 0.5, -30.0])
    func thresholdFloor(_ requested: TimeInterval) {
        #expect(WatchdogModel(stallSeconds: requested).stallSeconds
                == WatchdogModel.minimumStallSeconds)
    }

    /// `Flags` refuses these before they arrive, and this is the second line of it: an
    /// infinite threshold is a watchdog that never fires, which is the one failure the
    /// whole mechanism exists to prevent — the same trap `RST_MAX_COVER_SECONDS` fell into
    /// on 2026-08-22.
    @Test("an infinite or unreadable threshold falls back to thirty",
          arguments: [Double.infinity, -Double.infinity, Double.nan])
    func thresholdMustBeFinite(_ requested: TimeInterval) {
        #expect(WatchdogModel(stallSeconds: requested).stallSeconds
                == WatchdogModel.defaultStallSeconds)
    }

    // MARK: - The interval it is fed

    /// `Thread.sleep` guarantees a floor, not a period: a loaded machine hands back two
    /// seconds for one, and the watcher measures rather than counting iterations.
    @Test("a slow poll counts what really elapsed")
    func longPollsCountInFull() {
        var model = WatchdogModel()
        model.coverBegan()
        #expect(model.advance(by: 12) == .keepWatching)
        #expect(model.advance(by: 12) == .keepWatching)
        #expect(model.advance(by: 12) == .leave(coveredSeconds: 36, stalledSeconds: 36))
    }

    /// A watchdog that could be wound backwards would have a bypass in it.
    @Test("a negative or unreadable interval moves nothing",
          arguments: [-10.0, -0.001, Double.nan, -Double.infinity])
    func negativeIntervalsAreIgnored(_ interval: TimeInterval) {
        var model = WatchdogModel()
        model.coverBegan()
        _ = silence(&model, seconds: 29)
        #expect(model.advance(by: interval) == .keepWatching)
        #expect(model.stalledSeconds == 29)
    }

    @Test("the threshold is reached, not passed")
    func firesExactlyAtTheThreshold() {
        var model = WatchdogModel(stallSeconds: 30)
        model.coverBegan()
        #expect(model.advance(by: 29.999) == .keepWatching)
        #expect(model.advance(by: 0.001) != .keepWatching)
    }
}
