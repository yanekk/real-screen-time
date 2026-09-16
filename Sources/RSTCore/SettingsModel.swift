import Foundation

/// **What the settings window is not allowed to save** — T17.
///
/// The same split `FirstRunModel` (T16), `MenuBarModel` (T10) and `WatchdogModel` (T15)
/// made: every rule the window holds a parent to lives here, where `make test` can reach it,
/// and `Settings.swift` is the AppKit that draws it. There is no UI automation on this
/// machine, so a rule left in `RSTApp` is a rule that can only ever be checked by hand.
///
/// The rules earn the file for the same reason the wizard's did. A window that saves
/// `session_minutes: 0` produces an app that covers the screen for ever the first time a
/// session is started, and one that saves an empty `extension_options` produces a
/// `Dodaj minuty…` dialog that can grant nothing — a PIN prompt with no answer behind it,
/// which DESIGN §2.5 spends a paragraph forbidding.

// MARK: - The list fields

/// **The two settings that are lists of minutes**, on their way to and from a text field.
///
/// `warning_minutes` and `extension_options` are both "some whole numbers, in the parent's
/// own order". Parsing them is a rule — `15,,30` and `15, thirty` have to be refused rather
/// than quietly becoming something else — so it lives here with a test around it rather than
/// beside a text field in `RSTApp`.
public enum MinuteList {

    /// `[15, 30, 60]` → `"15, 30, 60"`. What the field is filled with.
    public static func format(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ", ")
    }

    /// `"15, 30, 60"` → `[15, 30, 60]`, or `nil` if any part of it is not a whole number.
    ///
    /// **Commas separate and spaces do not**, which is stricter than it first looks like it
    /// should be. Allowing a space to separate too makes `"1 000"` — one thousand, typed the
    /// way half of Europe writes it — parse quietly as `1` and `0`, and the complaint the
    /// parent then gets is about a grant of zero minutes they never typed. Refusing the
    /// whole field says the one useful thing instead: use commas.
    ///
    /// Empty text is an empty list rather than an error — whether an empty list is *allowed*
    /// is a different question, answered per setting in ``SettingsDraft/problem``: no
    /// warnings is a choice, no grant amounts is a trap.
    ///
    /// **A trailing comma is not an error either.** `"15, 30, "` is what a field looks like
    /// mid-edit, and refusing it would put a complaint under a parent's cursor while they
    /// are still typing.
    public static func parse(_ text: String) -> [Int]? {
        let parts = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var values: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }
}

// MARK: - Detection, shown in minutes (CR-01 §7, T03)

/// **The two grace settings are stored in seconds and shown in minutes** — CR-01 §7, DESIGN §2.7.
///
/// `config.json` keeps `idle_grace_seconds` and `media_grace_seconds` in seconds, unchanged;
/// the window converts at the edge so a parent reads and types whole minutes. The conversion is
/// a rule, so it lives here with a test around it rather than beside the combo box in `RSTApp`.
///
/// **Accepted consequence (product manager, 2026-09-04): the finest setting becomes one whole
/// minute.** A hand-edited value that is not a round number of minutes is shown rounded to the
/// nearest one, and pressing Save writes that rounded value back — so `100` seconds displays as
/// `2` and, on save, becomes `120`. The rounding is here, in ``toMinutes(seconds:)``; the round
/// trip of any value the window itself wrote (always a multiple of 60) is stable.
public enum GraceMinutes {

    /// Seconds on disk → whole minutes for the field, rounded to the nearest minute. `600 → 10`,
    /// `1800 → 30`, and a non-round `100 → 2`. Rounding rather than truncation so a stored `100`
    /// does not read as `1` and then, on save, silently drop to `60`.
    public static func toMinutes(seconds: Int) -> Int {
        Int((Double(seconds) / 60.0).rounded())
    }

    /// Minutes from the field → seconds for disk. `10 → 600`. Whole minutes in, so nothing to
    /// round here — the rounding a hand-edited value gets is in ``toMinutes(seconds:)`` on the
    /// way to the screen, and this only reverses it.
    public static func toSeconds(minutes: Int) -> Int {
        minutes * 60
    }
}

// MARK: - The combo suggestion lists Settings adds (CR-01 §5, §7, T03)

/// The day-start hour and the two detection-grace lists, added to ``ComboSuggestions`` here so
/// they sit beside the ``ComboSuggestions/merged(_:storedValue:)`` rule they reuse. The rule and
/// the session-length list are T01's, in `FirstRunModel.swift`; these three lists are Settings'
/// own and are the only combos the wizard does not also show.
extension ComboSuggestions {
    /// Day-start hour (CR-01 §5). Deliberately short — a menu of twenty-four is taller than the
    /// window — with any hour 0…23 still typeable and ``SettingsDraft/problem`` capping at 23.
    public static let dayStartHour = [4, 5, 6, 7, 8]

    /// Idle detection grace, in minutes (CR-01 §7).
    public static let idleGraceMinutes = [2, 5, 10, 15]

    /// Media detection grace, in minutes (CR-01 §7).
    public static let mediaGraceMinutes = [15, 30, 45, 60]
}

// MARK: - The fields, and what can be wrong with them

/// Which control a problem belongs under. The window uses it to put the complaint beside
/// the box that caused it rather than at the bottom of a long window.
public enum SettingsField: String, CaseIterable, Sendable {
    case sessionMinutes
    case selfServiceSessionsPerDay
    case dayResetHour
    case extensionOptions
    case idleGraceSeconds
    case mediaGraceSeconds
    case warningMinutes
}

/// Why these settings cannot be saved.
///
/// One at a time, in field order: a window that lights up five complaints at once reads as
/// broken, and the first one is the one the parent is looking at.
public enum SettingsProblem: Equatable, Sendable {
    /// A box that should hold a whole number holds something else.
    case notANumber(SettingsField)
    /// A zero-minute session starts already spent — see ``SessionLimits/problem``.
    case sessionTooShort
    /// Zero is legal and means every session needs the PIN. Negative is not a stricter
    /// setting, it is a number nobody chose.
    case negativeSessions
    /// The day rolls over at an hour of the day, and there are 24 of those.
    case resetHourOutOfRange
    /// A grace is a number of seconds to wait. Negative is not a shorter wait.
    case negativeGrace(SettingsField)
    /// **The one this window exists to refuse** (DESIGN §2.5). A `Dodaj minuty…` dialog
    /// with nothing on it is a PIN prompt that can grant nothing.
    case noGrants
    /// A grant or a warning of zero or fewer minutes. `Config.extensionChoices` and the
    /// warning arithmetic both drop these silently, so saving one means saving a line the
    /// parent will never see again and never be told about.
    case notPositive(SettingsField)
    /// The same amount twice. Legal on disk — `extensionChoices` de-duplicates — and
    /// refused here, because a list that draws differently from the way it was typed is a
    /// window quietly disagreeing with its own field.
    case duplicate(SettingsField, Int)

    /// Which box to put the complaint under.
    public var field: SettingsField {
        switch self {
        case .notANumber(let field), .negativeGrace(let field),
             .notPositive(let field), .duplicate(let field, _):
            return field
        // **The two halves of `LimitsProblem` are two different boxes.** Grouped, they take
        // whichever field was written first, and `negativeSessions` — which is entirely
        // about sessions *per day* — sent the keyboard to the session-length field instead:
        // a complaint filed under a number that was perfectly good (T17 review).
        case .sessionTooShort: return .sessionMinutes
        case .negativeSessions: return .selfServiceSessionsPerDay
        case .resetHourOutOfRange: return .dayResetHour
        case .noGrants: return .extensionOptions
        }
    }
}

// MARK: - The draft

/// **One editable copy of every setting**, as the window holds it between opening and saving.
///
/// Deliberately not a `Config`: a `Config` is what is on disk and what `Engine` reads every
/// tick, and half-typed numbers have no business in either. The PIN is absent for the same
/// reason — it is changed through its own flow, against the current one, and never edited as
/// a field (``PINChangeFlow``).
public struct SettingsDraft: Equatable, Sendable {
    public var sessionMinutes: Int
    public var selfServiceSessionsPerDay: Int
    public var dayResetHour: Int
    public var idleGraceSeconds: Int
    public var mediaGraceSeconds: Int
    public var warningMinutes: [Int]
    public var extensionOptions: [Int]

    public init(sessionMinutes: Int,
                selfServiceSessionsPerDay: Int,
                dayResetHour: Int,
                idleGraceSeconds: Int,
                mediaGraceSeconds: Int,
                warningMinutes: [Int],
                extensionOptions: [Int]) {
        self.sessionMinutes = sessionMinutes
        self.selfServiceSessionsPerDay = selfServiceSessionsPerDay
        self.dayResetHour = dayResetHour
        self.idleGraceSeconds = idleGraceSeconds
        self.mediaGraceSeconds = mediaGraceSeconds
        self.warningMinutes = warningMinutes
        self.extensionOptions = extensionOptions
    }

    /// What the window opens with: whatever is on disk, **exactly** as it is on disk.
    ///
    /// `extensionOptions` rather than ``Config/extensionChoices``, and that is the point of
    /// the distinction. `extensionChoices` is the *repaired* list the dialog draws — a
    /// hand-edited `[]` reads back as the shipped three — and showing the repair here would
    /// tell the parent their file says something it does not. They see what they wrote, and
    /// ``problem`` then refuses to save it until they fix it.
    public init(_ config: Config) {
        self.init(sessionMinutes: config.sessionMinutes,
                  selfServiceSessionsPerDay: config.selfServiceSessionsPerDay,
                  dayResetHour: config.dayResetHour,
                  idleGraceSeconds: config.idleGraceSeconds,
                  mediaGraceSeconds: config.mediaGraceSeconds,
                  warningMinutes: config.warningMinutes,
                  extensionOptions: config.extensionOptions)
    }

    /// The two numbers T16's wizard asks for, so the rule behind them is one rule.
    ///
    /// Shared on purpose, as ``SessionLimits/problem`` says: the wizard and this window ask
    /// the same question and must not drift into two answers.
    public var limits: SessionLimits {
        SessionLimits(minutes: sessionMinutes, sessionsPerDay: selfServiceSessionsPerDay)
    }

    /// Why this cannot be saved, or `nil` if it can.
    ///
    /// **Never save a value nobody chose** (T17). Every rule here is one that would
    /// otherwise be applied silently somewhere downstream — `max(0,)` at the point of use,
    /// or `extensionChoices` falling back — leaving a parent looking at a field that says
    /// one thing and an app doing another.
    public var problem: SettingsProblem? {
        // Field order, top to bottom, so the complaint lands where the eye already is.
        if let limitsProblem = limits.problem {
            switch limitsProblem {
            case .sessionTooShort: return .sessionTooShort
            case .negativeSessions: return .negativeSessions
            }
        }
        // Clamped at the point of use since T03, which turns 25 into a day that never rolls
        // over the way it says it does. There are 24 hours and this is where they are known.
        guard (0...23).contains(dayResetHour) else { return .resetHourOutOfRange }

        if let problem = listProblem(extensionOptions, .extensionOptions, mayBeEmpty: false) {
            return problem
        }
        guard idleGraceSeconds >= 0 else { return .negativeGrace(.idleGraceSeconds) }
        guard mediaGraceSeconds >= 0 else { return .negativeGrace(.mediaGraceSeconds) }
        // **Empty is allowed here and forbidden above.** No warnings is a defensible choice
        // — the countdown in the menu bar is still there, and DESIGN §2.4 makes the spoken
        // lines a courtesy rather than a mechanism. No grant amounts is not a choice, it is
        // a dialog that cannot answer the question it opens.
        return listProblem(warningMinutes, .warningMinutes, mayBeEmpty: true)
    }

    private func listProblem(_ values: [Int], _ field: SettingsField,
                             mayBeEmpty: Bool) -> SettingsProblem? {
        if values.isEmpty { return mayBeEmpty ? nil : .noGrants }
        var seen = Set<Int>()
        for value in values {
            guard value > 0 else { return .notPositive(field) }
            guard seen.insert(value).inserted else { return .duplicate(field, value) }
        }
        return nil
    }
}

// MARK: - What the window writes

extension Config {

    /// This config with the draft's seven values applied, and **nothing else touched**.
    ///
    /// The PIN especially: it is changed through ``changingPIN(hash:salt:)`` and never as a
    /// side effect of saving a number. Unknown keys a newer build wrote survive too, but
    /// that is `ConfigStore`'s doing rather than this function's.
    public func applying(_ draft: SettingsDraft) -> Config {
        var updated = self
        updated.sessionMinutes = draft.sessionMinutes
        updated.selfServiceSessionsPerDay = draft.selfServiceSessionsPerDay
        updated.dayResetHour = draft.dayResetHour
        updated.idleGraceSeconds = draft.idleGraceSeconds
        updated.mediaGraceSeconds = draft.mediaGraceSeconds
        updated.warningMinutes = draft.warningMinutes
        updated.extensionOptions = draft.extensionOptions
        return updated
    }

    /// This config with a different PIN. **A fresh salt every time** (T17).
    ///
    /// Re-using the salt would leave the old hash and the new one derived from the same
    /// bytes, which is the one thing a per-install salt exists to prevent — and it costs
    /// nothing to generate another. The hashing itself is the caller's, off the main thread:
    /// a derivation is ~0.5 s (`pinRounds`), and this is a window a parent is looking at.
    public func changingPIN(hash: String, salt: Data) -> Config {
        var updated = self
        updated.pinHash = hash
        updated.pinSalt = salt.base64EncodedString()
        return updated
    }

    /// **What changed, in the log's own words** — `session_minutes 30→45`.
    ///
    /// DESIGN §3.5 gives the log the job of explaining a sudden change in behaviour six
    /// weeks later, and a settings change is exactly that: minutes that used to be enough
    /// stop being enough, and nothing else in the file says why. The wire names are used so
    /// the line reads against `config.json` itself.
    ///
    /// The PIN is reported as having changed and never printed, in either direction.
    public func changes(to updated: Config) -> [String] {
        var changes: [String] = []
        func note<T: Equatable>(_ key: CodingKeys, _ old: T, _ new: T,
                                _ describe: (T) -> String = { "\($0)" }) {
            guard old != new else { return }
            changes.append("\(key.rawValue) \(describe(old))→\(describe(new))")
        }
        func list(_ values: [Int]) -> String { "[\(MinuteList.format(values))]" }

        note(.sessionMinutes, sessionMinutes, updated.sessionMinutes)
        note(.selfServiceSessionsPerDay, selfServiceSessionsPerDay,
             updated.selfServiceSessionsPerDay)
        note(.dayResetHour, dayResetHour, updated.dayResetHour)
        note(.idleGraceSeconds, idleGraceSeconds, updated.idleGraceSeconds)
        note(.mediaGraceSeconds, mediaGraceSeconds, updated.mediaGraceSeconds)
        note(.warningMinutes, warningMinutes, updated.warningMinutes, list)
        note(.extensionOptions, extensionOptions, updated.extensionOptions, list)
        // Never the value, in either direction — the log is a plain file a child can read.
        if pinHash != updated.pinHash || pinSalt != updated.pinSalt {
            changes.append("\(CodingKeys.pinHash.rawValue) changed")
        }
        return changes
    }
}

// MARK: - Changing the PIN

/// Where a PIN change has got to.
public enum PINChangeStage: Equatable, Sendable {
    /// Prove you are the parent. **The reason this flow exists at all** — the window is
    /// already behind one PIN prompt, but a window left open on a Mac a child is sitting at
    /// is not the same thing as a parent standing over it.
    case current
    /// The new PIN, first time.
    case new
    /// The new PIN again. Asked because a mistyped new PIN is a PIN nobody knows, and the
    /// only way back from one is `RECOVERY.md`.
    case repeated
}

/// What the host should do next.
public enum PINChangeStep: Equatable, Sendable {
    /// Check these digits against the stored hash — off the main thread — and call back
    /// ``PINChangeFlow/currentAccepted()`` or ``PINChangeFlow/currentRejected()``.
    case verifyCurrent(String)
    /// Draw this stage and wait for four more digits.
    case ask(PINChangeStage)
    /// The two new entries agree. Hash this and save it.
    case settled(String)
    /// They did not. The flow is back at ``PINChangeStage/new``; say why.
    case rejected(PINProblem)
}

/// **The three-stage PIN change**, as a value.
///
/// One ``PINBoxes`` control on the screen, asked three questions in turn: the current PIN,
/// the new one, the new one again. The sequence is a rule — an implementation that let the
/// second and third stages swap, or that settled on a single entry, would write a hash
/// nothing can unlock — so it lives here rather than as three booleans in a window.
///
/// The verification of the *current* PIN is not here: it is 200 000 rounds of HMAC and
/// belongs off the main thread (`PINVerifier`). This type asks for it and waits.
public struct PINChangeFlow: Equatable, Sendable {

    public private(set) var stage: PINChangeStage = .current
    /// The first of the two new entries, held only until the second one arrives.
    private var firstEntry = ""

    public init() {}

    /// Four digits landed in the boxes.
    public mutating func entered(_ digits: String) -> PINChangeStep {
        switch stage {
        case .current:
            return .verifyCurrent(digits)

        case .new:
            firstEntry = digits
            stage = .repeated
            return .ask(.repeated)

        case .repeated:
            let problem = firstRunPINProblem(entered: firstEntry, repeated: digits)
            guard problem == nil else {
                // All the way back to the new PIN, not to this stage: half of a mismatched
                // pair is not a PIN anyone has confirmed, and offering "try the second one
                // again" would settle on whichever entry was typed twice by accident.
                firstEntry = ""
                stage = .new
                return .rejected(problem ?? .mismatch)
            }
            let settled = firstEntry
            firstEntry = ""
            return .settled(settled)
        }
    }

    /// The stored PIN matched. On to the new one.
    public mutating func currentAccepted() -> PINChangeStep {
        stage = .new
        return .ask(.new)
    }

    /// It did not. Stay where we are — `PINGate` owns the waiting.
    public mutating func currentRejected() -> PINChangeStep {
        stage = .current
        firstEntry = ""
        return .ask(.current)
    }
}
