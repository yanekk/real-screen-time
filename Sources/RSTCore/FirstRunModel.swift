import Foundation

/// **What the first-run wizard decides**, as arithmetic — DESIGN §6, T16.
///
/// The same split `MenuBarModel` (T10) and `WatchdogModel` (T15) made: every rule the wizard
/// holds a parent to lives here, where `make test` can reach it, and `FirstRun.swift` is the
/// AppKit that draws it. There is no UI automation on this machine, so a rule left in
/// `RSTApp` is a rule that can only ever be checked by hand.
///
/// The rules are worth the file. A wizard that lets a five-digit PIN through writes a hash
/// nothing in the app can unlock — a cover with no key, which is the one failure DESIGN §2.5
/// exists to prevent — and a wizard that writes `session_minutes: 0` produces an app that
/// covers the screen for ever the first time a session is started.

// MARK: - The four steps

/// The wizard's steps, in order (DESIGN §6).
///
/// **Step 1 is not politeness.** The design's stance is that this works as a *visible*
/// boundary rather than a trap, and the first thing the app says should say so.
///
/// **Step 2 has no default and cannot be skipped.** Per DESIGN §2.5 an app with no PIN must
/// never cover the screen, so a wizard that lets you past it produces an app that does
/// nothing at all.
public enum FirstRunStep: Int, CaseIterable, Comparable, Sendable {
    case welcome
    case pin
    case sessions
    case login
    /// The terminal "You're done" screen (CR-01 §4, T02). It is a step so the window drives it
    /// through the same `show`/`position` path as the others, but it carries no `Step N of 4`
    /// line — ``position`` returns `nil` for it.
    case done

    public var next: FirstRunStep? { FirstRunStep(rawValue: rawValue + 1) }
    public var previous: FirstRunStep? { FirstRunStep(rawValue: rawValue - 1) }

    /// The steps the counter numbers. **`.done` is deliberately absent**: it is why a fifth
    /// case does not turn `Step 3 of 4` into `Step 3 of 5` and break the welcome screen's
    /// promise of four questions (CR-01 §4). The count comes from this list, not
    /// `allCases.count`, for exactly that reason.
    static let counted: [FirstRunStep] = [.welcome, .pin, .sessions, .login]

    /// `Step 2 of 4` — the wizard's own progress line, or `nil` for a screen with no place in
    /// the counter (the terminal screen). Optional so the label can be hidden when it is `nil`
    /// rather than the terminal screen renumbering the four real steps.
    public var position: (index: Int, count: Int)? {
        guard let index = FirstRunStep.counted.firstIndex(of: self) else { return nil }
        return (index + 1, FirstRunStep.counted.count)
    }

    public static func < (lhs: FirstRunStep, rhs: FirstRunStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// **Where setup resumes**, which is not always the beginning.
///
/// An app that already has a PIN must never offer the PIN step again from an ungated menu
/// item: the child owns his home directory, so he can delete the login-item plist, and if
/// that reopened a wizard with step 2 on it he could set a PIN of his own and own the app.
/// Once configured there is exactly one thing left worth finishing, and it is step 4.
public func firstRunEntryStep(isConfigured: Bool) -> FirstRunStep {
    isConfigured ? .login : .welcome
}

// MARK: - Step 2: the PIN

/// Why a typed PIN pair cannot be accepted.
///
/// ``PINProblem/empty`` is separated from the rest because it is not a mistake: it is the
/// state the step opens in, and a wizard that greets a parent with an error before they have
/// typed anything is a wizard that has already told them off.
public enum PINProblem: Equatable, Sendable {
    /// Nothing typed yet. Not an error — the button is simply not ready.
    case empty
    /// Something other than a digit. Unreachable through `PINBoxes`, which takes no other
    /// key, and checked anyway: this function is the rule, not that view.
    case notDigits
    /// Not exactly ``pinDigits`` long. Carries what was typed so the message can say it.
    case wrongLength(Int)
    /// The two entries differ. The reason the PIN is asked for twice at all.
    case mismatch
}

/// Whether the two entries make a PIN this app can actually check later.
///
/// **The length rule is the load-bearing one.** T13's prompt is exactly ``pinDigits`` boxes
/// that submit themselves on the last digit, so a PIN of any other length can never be typed
/// into the thing that lifts the cover — see the comment on ``pinDigits``. The hash reveals
/// no length, so nothing downstream would ever notice; it has to be refused here.
///
/// Returns `nil` when the pair is good.
public func firstRunPINProblem(entered: String, repeated: String) -> PINProblem? {
    if entered.isEmpty && repeated.isEmpty { return .empty }
    // Digits before length, so `abcd` is reported as the wrong kind of character rather
    // than as the right number of them.
    guard entered.allSatisfy(\.isASCIIDigit), repeated.allSatisfy(\.isASCIIDigit) else {
        return .notDigits
    }
    guard entered.count == pinDigits else { return .wrongLength(entered.count) }
    guard entered == repeated else { return .mismatch }
    return nil
}

private extension Character {
    /// ASCII `0`–`9` only. `isNumber` is true for `٤`, `৪` and `Ⅳ`, none of which survive
    /// the round trip through a PIN hash the way the person typing them would expect.
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Step 3: the limits

/// The two numbers step 3 asks for.
public struct SessionLimits: Equatable, Sendable {
    public var minutes: Int
    public var sessionsPerDay: Int

    public init(minutes: Int, sessionsPerDay: Int) {
        self.minutes = minutes
        self.sessionsPerDay = sessionsPerDay
    }

    /// What the fields are pre-filled with: 30 minutes, one self-service session.
    ///
    /// Taken from ``Config``'s own defaults rather than written out again, so the wizard
    /// cannot start suggesting a different number from the one the app ships with.
    public static let suggested = SessionLimits(
        minutes: Config().sessionMinutes,
        sessionsPerDay: Config().selfServiceSessionsPerDay
    )

    /// Why these two numbers cannot be saved, or `nil` if they can.
    ///
    /// Shared with T17's settings window on purpose — the rule is the same rule, and two
    /// copies of it is two places for it to drift.
    public var problem: LimitsProblem? {
        // A zero-minute session is not a short session: it starts already spent, so the
        // cover goes straight back up and `Rozpocznij` becomes a button that does nothing.
        if minutes < 1 { return .sessionTooShort }
        // Zero is legal and means every session needs a parent (DESIGN §2.1). Negative is
        // not a stricter setting, it is a number nobody chose.
        if sessionsPerDay < 0 { return .negativeSessions }
        return nil
    }
}

public enum LimitsProblem: Equatable, Sendable {
    case sessionTooShort
    case negativeSessions
}

// MARK: - Step 3's controls, as rules (CR-01 §2, shared with Settings in T03)

/// One row of the sessions-per-day pop-up. **The label is not here** — it is English text
/// assembled in `RSTApp` (the wizard is behind the parent's side, DESIGN §2.4.2's exception),
/// and a label chosen inside a view cannot be tested. Only the value and which case it is are
/// the rule.
public struct SessionsItem: Equatable, Sendable {
    /// The `sessionsPerDay` this row maps to. `0` is the None case.
    public let value: Int
    /// Drives the "None — every session needs your PIN" label in `RSTApp`.
    public let isNoneCase: Bool

    public init(value: Int, isNoneCase: Bool) {
        self.value = value
        self.isNoneCase = isNoneCase
    }
}

/// **The sessions-per-day pop-up as arithmetic** — its ordered rows and the two-way mapping
/// to `sessionsPerDay` — CR-01 §2. Built once here and reused by Settings (T03), the way
/// ``SessionLimits/problem`` already is, so the two windows cannot offer the same setting
/// through two rules that have drifted apart.
///
/// **Append, never clamp.** The pop-up caps at ``maxSessions``, but a hand-edited
/// `config.json` with `self_service_sessions_per_day: 7` must show `7`, not a silent 4 —
/// otherwise saving the window would quietly rewrite a value the parent set on purpose. An
/// out-of-range stored value is added as an extra trailing row (DESIGN §2.2).
public enum SessionsPerDayChoice {
    /// The most self-service sessions the menu offers. Rows are None, 1…`maxSessions`.
    public static let maxSessions = 4

    /// The rows the pop-up shows, in order, for a given stored value. Row 0 is always the
    /// None case (value 0); rows 1…``maxSessions`` are 1…``maxSessions`` sessions. A stored
    /// value outside `0...maxSessions` is appended as an extra trailing row.
    public static func items(storedValue: Int) -> [SessionsItem] {
        var items = [SessionsItem(value: 0, isNoneCase: true)]
        items += (1...maxSessions).map { SessionsItem(value: $0, isNoneCase: false) }
        if !items.contains(where: { $0.value == storedValue }) {
            items.append(SessionsItem(value: storedValue, isNoneCase: false))
        }
        return items
    }

    /// The `sessionsPerDay` a chosen row index maps to. Out-of-bounds falls back to the None
    /// case's `0` — a safe value, never a crash, though a real pop-up cannot select one.
    public static func value(atIndex index: Int, storedValue: Int) -> Int {
        let items = items(storedValue: storedValue)
        return items.indices.contains(index) ? items[index].value : 0
    }

    /// The row to pre-select for a stored value — the appended row when it is out of range.
    public static func selectedIndex(storedValue: Int) -> Int {
        items(storedValue: storedValue).firstIndex { $0.value == storedValue } ?? 0
    }
}

/// **A combo box's suggestion list, with the stored value guaranteed present** — CR-01 §2, §7.
/// A combo box suggests a few common values while any number stays typeable; a stored value
/// that is not one of the suggestions must still appear, so the box shows what is actually
/// configured rather than an empty field or a clamp. Shared by session length here and by the
/// day-start hour and the two detection-grace lists in T03.
public enum ComboSuggestions {
    /// Session length, in minutes (CR-01 §2).
    public static let sessionLength = [15, 20, 30, 45, 60]

    /// `suggestions` unchanged when `storedValue` is already one of them; otherwise the stored
    /// value appended. Order is preserved and nothing is duplicated.
    public static func merged(_ suggestions: [Int], storedValue: Int) -> [Int] {
        suggestions.contains(storedValue) ? suggestions : suggestions + [storedValue]
    }
}

// MARK: - The final screen (CR-01 §4, T02)

/// **Paragraph one of the wizard's "You're done" screen**, assembled from the two answers it
/// depends on — CR-01 §4, DESIGN §2.4. The count decides `one session` / `N sessions` and
/// `it` / `them` (``EnglishPlural``) and drives a distinct sentence when it is zero; the
/// session length fills the minutes figure, so a parent who set 45 reads `45 minutes`, not a
/// fixed 30 (product manager, 2026-09-05).
///
/// **This one paragraph's wording is here, not in the window, on purpose.** DESIGN §2.4.2
/// keeps the wizard's English out of `Strings.swift`, and ``SessionsItem`` keeps its labels in
/// `RSTApp` — but the count-and-minutes agreement is a *rule*, and a rule chosen inside a view
/// is invisible to `make test`. Paragraphs two and three carry no such agreement: paragraph
/// two is one of two fixed sentences picked by whether the login item was installed, its exact
/// wording eyeballed on the hand pass (DESIGN §7), so those stay in `RSTApp` with the rest of
/// the wizard's literals.
public enum FinalScreenSummary {
    public static func sessionsParagraph(sessionsPerDay: Int, minutes: Int) -> String {
        guard sessionsPerDay >= 1 else {
            return "Every session needs your PIN. Your child cannot start one himself — you grant "
                + "the minutes, and you choose how many at the time."
        }
        let (noun, pronoun): (String, String)
        switch EnglishPlural.form(sessionsPerDay) {
        case .one:  (noun, pronoun) = ("one session", "it")
        case .many: (noun, pronoun) = ("\(sessionsPerDay) sessions", "them")
        }
        return "Your child gets \(noun) of \(minutes) minutes a day, and he can start \(pronoun) "
            + "himself. Anything beyond that needs your PIN, and you choose the amount at the "
            + "time."
    }
}

// MARK: - What the wizard writes

/// Everything the wizard produces, ready to be folded into the config on disk.
public struct FirstRunAnswers: Equatable, Sendable {
    public var limits: SessionLimits
    public var pinHash: String
    public var pinSalt: String

    public init(limits: SessionLimits, pinHash: String, pinSalt: String) {
        self.limits = limits
        self.pinHash = pinHash
        self.pinSalt = pinSalt
    }
}

extension Config {
    /// The config the wizard saves: this one, with the four answers applied.
    ///
    /// **Everything else is left alone.** The wizard is not the only way a `config.json`
    /// comes into existence — a hand-edited file with no `pin_hash` re-runs the wizard by
    /// DESIGN §6, and that file's warning thresholds and grant amounts are the parent's.
    /// Building a fresh `Config()` here would quietly discard them.
    public func applying(_ answers: FirstRunAnswers) -> Config {
        var updated = self
        updated.sessionMinutes = answers.limits.minutes
        updated.selfServiceSessionsPerDay = answers.limits.sessionsPerDay
        updated.pinHash = answers.pinHash
        updated.pinSalt = answers.pinSalt
        return updated
    }
}

// MARK: - The LaunchAgent

/// **The plist that brings the app back**, and which binary it must name — DESIGN §2.7.
///
/// `KeepAlive` is what closes the casual kill: killed, the app is back within seconds, and
/// the gap it was away is charged (T04). Together those make killing it pointless rather
/// than merely difficult. `launchctl` itself is `RSTApp`'s — this is the file's *contents*
/// and the arithmetic about where it should point, both of which are pure.
public enum LaunchAgent {

    /// The job's label, and therefore also the plist's file name.
    public static let label = "com.krolikowski.realscreentime.agent"

    public static let plistFileName = "com.krolikowski.realscreentime.agent.plist"

    /// Where the app lives once it is installed. The `.app` name is `Makefile`'s `APP_NAME`.
    public static let installedAppPath = "/Applications/RealScreenTime.app"

    /// The binary inside it — what `ProgramArguments` has to name. A LaunchAgent points at
    /// an executable, not at a bundle.
    public static let installedBinaryPath =
        "/Applications/RealScreenTime.app/Contents/MacOS/RealScreenTime"

    /// Which binary the plist should name, given where this process is running from.
    public enum Program: Equatable, Sendable {
        /// This process *is* the installed copy. The ordinary first run.
        case running(path: String)
        /// A copy is installed in `/Applications` but this is not it — a `swift run` on a
        /// Mac that has been set up. The plist names the installed copy regardless.
        case installed(path: String)
        /// Nothing in `/Applications`. There is no binary worth naming and the step has to
        /// say so instead of writing a plist that will fail at every login.
        case notInstalled

        public var path: String? {
            switch self {
            case .running(let path), .installed(let path): return path
            case .notInstalled: return nil
            }
        }
    }

    /// **Never the build directory.** A LaunchAgent pointing into `.build/debug` is a
    /// confusing half-working state: it survives a `swift build`, and then one `swift package
    /// clean` later the agent silently stops having anything to launch. If the app is not in
    /// `/Applications` the honest answer is that this step cannot be done yet.
    ///
    /// `installedBinaryExists` is the caller's file-system read — `RSTCore` asks the system
    /// nothing.
    public static func program(runningBinary: String,
                               installedBinaryExists: Bool) -> Program {
        let running = URL(fileURLWithPath: runningBinary).standardizedFileURL.path
        let installed = URL(fileURLWithPath: installedBinaryPath).standardizedFileURL.path
        if running == installed { return .running(path: installed) }
        return installedBinaryExists ? .installed(path: installed) : .notInstalled
    }

    /// The plist, as it goes on disk.
    ///
    /// Serialised rather than written out as XML by hand: a path is allowed to contain `&`
    /// and `<`, and a plist that has to be escaped correctly is a plist that will one day be
    /// escaped incorrectly. The format is the same standard XML either way.
    public static func plistData(programPath: String) throws -> Data {
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [programPath],
            // The two that matter: start it at login, and start it again if it goes away.
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: contents,
                                                  format: .xml,
                                                  options: 0)
    }

    /// `gui/501/com.krolikowski.realscreentime.agent` — what `bootout` names.
    public static func serviceTarget(uid: UInt32) -> String { "gui/\(uid)/\(label)" }

    /// `gui/501` — the domain `bootstrap` loads into.
    public static func domainTarget(uid: UInt32) -> String { "gui/\(uid)" }
}
