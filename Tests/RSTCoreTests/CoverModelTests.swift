import Foundation
import Testing
@testable import RSTCore

/// The cover's four rows (T11), and the one of them that carries the daily cap.
///
/// The cover is the app's entire interface for the child, and on a machine with no UI
/// automation everything about it that is *not* checked here can only be checked by taking
/// the screen. What the window looks like still needs a person; which face is on it, and
/// which buttons, does not.
@Suite("Cover model")
struct CoverModelTests {

    private static let configured: Config = {
        var config = Config()
        config.pinHash = "hash"
        config.pinSalt = "c2FsdA=="
        return config
    }()

    private static func cover(_ decision: Decision?,
                              used: Int = 0,
                              config: Config = configured) -> CoverModel? {
        CoverModel(decision: decision, sessionsUsedToday: used, config: config)
    }

    // MARK: - When there is a cover at all

    @Test("the three decisions that cover produce a cover, and the three that do not, do not")
    func onlyCoveringDecisionsProduceAModel() {
        #expect(Self.cover(.awaitingStart(selfServiceLeft: 1)) != nil)
        #expect(Self.cover(.awaitingResume(remaining: 600)) != nil)
        #expect(Self.cover(.expired(selfServiceLeft: 0)) != nil)

        #expect(Self.cover(.dormant) == nil)
        #expect(Self.cover(.allowed(remaining: 600)) == nil)
        #expect(Self.cover(.warning(remaining: 60, threshold: 1)) == nil)
        // Before the first tick. Nothing has been decided, so nothing is covered.
        #expect(Self.cover(nil) == nil)
    }

    /// Every covering decision must be answerable, whatever `Decision` grows next: a face
    /// this switch does not handle is a covered screen with nothing drawn on it.
    @Test("every covering decision has a face and at least one button")
    func everyCoveringDecisionIsDrawable() {
        let covering: [Decision] = [
            .awaitingStart(selfServiceLeft: 3), .awaitingStart(selfServiceLeft: 0),
            .awaitingResume(remaining: 1), .awaitingResume(remaining: 3600),
            .expired(selfServiceLeft: 0), .expired(selfServiceLeft: 2),
        ]
        for decision in covering {
            let model = Self.cover(decision)
            #expect(model != nil, "\(decision) covers but draws nothing")
            #expect(model?.buttons.isEmpty == false, "\(decision) offers no way out")
        }
    }

    // MARK: - The four rows

    @Test("awaitingStart with sessions left offers Rozpocznij and the day's count")
    func startFace() {
        let model = Self.cover(.awaitingStart(selfServiceLeft: 1))
        #expect(model?.face == .start(sessionMinutes: 30, index: 1, limit: 1))
        #expect(model?.buttons == [.start])
    }

    /// `Sesja 2 z 2` — the session he is about to start, not the one already spent. The
    /// menu bar's line counts the other way on purpose.
    @Test("the start face counts the session about to begin")
    func startFaceCountsForwards() {
        var config = Self.configured
        config.selfServiceSessionsPerDay = 2
        #expect(Self.cover(.awaitingStart(selfServiceLeft: 1), used: 1, config: config)?.face
                == .start(sessionMinutes: 30, index: 2, limit: 2))
    }

    @Test("awaitingResume offers Wznów and the minutes still on the session")
    func resumeFace() {
        let model = Self.cover(.awaitingResume(remaining: 1200))
        #expect(model?.face == .resume(minutesLeft: 20))
        #expect(model?.buttons == [.resume])
    }

    @Test("an expired session with sessions left still says the time ran out")
    func expiredFace() {
        let model = Self.cover(.expired(selfServiceLeft: 2))
        #expect(model?.face == .expired)
        #expect(model?.buttons == [.pin, .lock])
    }

    @Test("an expired session with nothing left says the day is over")
    func exhaustedAfterASession() {
        let model = Self.cover(.expired(selfServiceLeft: 0))
        #expect(model?.face == .exhausted)
        #expect(model?.buttons == [.pin, .lock])
    }

    // MARK: - The daily cap

    /// **The one test that pins the only limit the app enforces for itself.**
    ///
    /// `SessionState.startSelfService` is ungated and `decide` reports
    /// `.awaitingStart(selfServiceLeft: 0)` like any other state, so if the cover drew
    /// `Rozpocznij` here the day's allowance would simply not exist — and no test below
    /// this layer would fail.
    @Test("awaitingStart(0) offers no Rozpocznij at all")
    func spentAllowanceOffersNoStart() {
        let model = Self.cover(.awaitingStart(selfServiceLeft: 0), used: 1)
        #expect(model?.face == .exhausted)
        #expect(model?.buttons == [.pin, .lock])
        #expect(model?.buttons.contains(.start) == false)
    }

    /// It is not only reachable through a spent allowance: `self_service_sessions_per_day: 0`
    /// means *every* session needs the PIN, and it produces this face from the first tick.
    @Test("with no self-service sessions configured the cover is the PIN path from the start")
    func zeroSelfServiceSessionsNeverOffersStart() {
        var config = Self.configured
        config.selfServiceSessionsPerDay = 0
        let snapshot = Snapshot(now: Date(timeIntervalSince1970: 1_800_000_000), hasPIN: true)
        let decision = decide(snapshot, config)

        #expect(decision == .awaitingStart(selfServiceLeft: 0))
        let model = CoverModel(decision: decision, sessionsUsedToday: 0, config: config)
        #expect(model?.face == .exhausted)
        #expect(model?.buttons.contains(.start) == false)
    }

    @Test("offersSelfServiceStart is true for exactly one case")
    func startGate() {
        #expect(Decision.awaitingStart(selfServiceLeft: 1).offersSelfServiceStart)
        #expect(Decision.awaitingStart(selfServiceLeft: 99).offersSelfServiceStart)
        #expect(!Decision.awaitingStart(selfServiceLeft: 0).offersSelfServiceStart)
        #expect(!Decision.awaitingStart(selfServiceLeft: -1).offersSelfServiceStart)
        #expect(!Decision.expired(selfServiceLeft: 3).offersSelfServiceStart)
        #expect(!Decision.awaitingResume(remaining: 60).offersSelfServiceStart)
        #expect(!Decision.allowed(remaining: 60).offersSelfServiceStart)
        #expect(!Decision.dormant.offersSelfServiceStart)
    }

    /// `Zablokuj ekran` is on every dead-end cover, and it is the only thing on those
    /// covers that needs no parent. Losing it would leave a child sitting in front of a
    /// wall until an adult appears.
    @Test("every PIN-only face also offers the screen lock")
    func lockIsAlwaysOfferedOnADeadEnd() {
        for decision: Decision in [.expired(selfServiceLeft: 0), .expired(selfServiceLeft: 1),
                                   .awaitingStart(selfServiceLeft: 0)] {
            #expect(Self.cover(decision)?.buttons.contains(.lock) == true, "\(decision)")
        }
    }

    /// Start and resume are the front door, not a punishment: neither may grow a PIN.
    @Test("the start and resume faces are PIN-free")
    func theOfferedFacesNeedNoPIN() {
        #expect(Self.cover(.awaitingStart(selfServiceLeft: 1))?.buttons.contains(.pin) == false)
        #expect(Self.cover(.awaitingResume(remaining: 60))?.buttons.contains(.pin) == false)
    }

    // MARK: - Numbers that came from a file nobody validated

    @Test("the resume offer rounds up, so the last part-minute is not offered as nothing")
    func resumeMinutesRoundUp() {
        #expect(CoverModel.minutes(1200) == 20)
        #expect(CoverModel.minutes(1141) == 20)     // 19:01
        #expect(CoverModel.minutes(1140) == 19)     // 19:00 exactly
        #expect(CoverModel.minutes(30) == 1)
        #expect(CoverModel.minutes(0.4) == 1)
        #expect(CoverModel.minutes(0) == 0)
    }

    /// The same trap `MenuBarModel.clockText` was caught by on 2026-08-23: an `Int`
    /// conversion with no ceiling **traps**, and this one takes whatever a `Decision`
    /// carries.
    @Test("an absurd remainder is clamped rather than trapping")
    func absurdRemaindersDoNotTrap() {
        // 3_599_999 s is 59 999 minutes and 59 seconds, and the rounding is upwards.
        #expect(CoverModel.minutes(.greatestFiniteMagnitude) == 60_000)
        #expect(CoverModel.minutes(.infinity) == 60_000)
        #expect(CoverModel.minutes(.nan) == 0)
        #expect(CoverModel.minutes(-1) == 0)
        #expect(Self.cover(.awaitingResume(remaining: .infinity)) != nil)
    }

    /// `config.json` is hand-edited and nothing validates it. The cover must not promise
    /// minutes the ledger will refuse to grant — `SessionState.fullSession` floors the same
    /// value at zero.
    @Test("a negative session length is clamped, not offered")
    func negativeSessionMinutesClamp() {
        var config = Self.configured
        config.sessionMinutes = -30
        #expect(Self.cover(.awaitingStart(selfServiceLeft: 1), config: config)?.face
                == .start(sessionMinutes: 0, index: 1, limit: 1))
    }

    /// A hand-edited `self_service_sessions_per_day` below zero reads as zero everywhere
    /// else; the cover must not print `Sesja 1 z -2`.
    @Test("a negative daily allowance never reaches the screen")
    func negativeAllowance() {
        var config = Self.configured
        config.selfServiceSessionsPerDay = -2
        // `decide` would report 0 left, which is the exhausted face; asked directly for the
        // start face, the count still has to be sane.
        #expect(Self.cover(.awaitingStart(selfServiceLeft: 1), config: config)?.face
                == .start(sessionMinutes: 30, index: 1, limit: 0))
    }

    // MARK: - Polish counts its nouns in three forms

    @Test("1 minuta, 2 minuty, 5 minut")
    func plurals() {
        #expect(PolishPlural.form(1) == .one)
        #expect(PolishPlural.form(2) == .few)
        #expect(PolishPlural.form(3) == .few)
        #expect(PolishPlural.form(4) == .few)
        #expect(PolishPlural.form(5) == .many)
        #expect(PolishPlural.form(0) == .many)
    }

    /// The teens are the trap: 12 is *not* `12 minuty`, although 22 is `22 minuty`.
    @Test("the teens take the many form and the twenties do not")
    func pluralTeens() {
        for n in 11...14 { #expect(PolishPlural.form(n) == .many, "\(n)") }
        for n in 22...24 { #expect(PolishPlural.form(n) == .few, "\(n)") }
        #expect(PolishPlural.form(21) == .many)
        #expect(PolishPlural.form(25) == .many)
        #expect(PolishPlural.form(102) == .few)
        #expect(PolishPlural.form(112) == .many)
        #expect(PolishPlural.form(122) == .few)
    }

    @Test("a negative count reads as its magnitude rather than crashing")
    func pluralNegatives() {
        #expect(PolishPlural.form(-1) == .one)
        #expect(PolishPlural.form(-3) == .few)
        #expect(PolishPlural.form(Int.min + 1) == .many)
        // `Int.min` itself, which `abs` cannot express and therefore traps on — the whole
        // test binary went down against the first version of this function. Found
        // reviewing T11, 2026-08-23.
        #expect(PolishPlural.form(Int.min) == .many)
    }
}
