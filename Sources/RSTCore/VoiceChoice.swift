import Foundation

/// One installed voice, reduced to the four things choosing between them needs.
///
/// `AVSpeechSynthesisVoice` lives in `AVFoundation` and so cannot be named here; `RSTApp`
/// maps each one onto this and hands the list over. That is the whole trick that makes the
/// fallback chain testable on a machine where the voices installed are a fact about the
/// machine rather than an input to the test.
public struct VoiceOption: Equatable, Sendable {
    public let identifier: String
    public let name: String
    /// BCP-47 as `AVFoundation` reports it — **`pl-PL`, with a hyphen**, not the `pl_PL`
    /// that `say -v '?'` and DESIGN §2.4.1 both print. Measured on this Mac 2026-08-25;
    /// matching on the underscore form finds nothing at all.
    public let language: String
    /// `AVSpeechSynthesisVoiceQuality`'s raw value: 1 default (compact), 2 enhanced,
    /// 3 premium. An `Int` rather than the enum, for the same reason as the rest of it.
    public let quality: Int

    public init(identifier: String, name: String, language: String, quality: Int) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
    }
}

/// **Picking a voice, and never trusting a name** (DESIGN §2.4.1).
///
/// Measured 2026-08-21: `say -v "Zosia (Premium)"` with no Premium voice installed returns
/// success and speaks in a different voice. It does not error. So the app enumerates what
/// is actually installed, chooses from that, and logs what it got — a Mac quietly speaking
/// English is otherwise visible only to whoever is standing in the room, and apps get quit
/// on the strength of these warnings (§2.6.2).
public enum VoiceChoice {

    /// The language the child is warned in. Matched as a prefix, so `pl`, `pl-PL` and
    /// `pl_PL` all count — three spellings of one language is exactly the sort of thing a
    /// silent fallback hides.
    public static let language = "pl"

    /// The best available Polish voice, or `nil` for "there is none — use the system
    /// default and say so in the log".
    ///
    /// DESIGN §2.4.1's chain is *Premium `pl` → Enhanced `pl` → compact Zosia → any `pl`*,
    /// which is quality first and then the one name worth preferring. `preferring` is a
    /// parameter rather than a literal so the tie-break is visible in the tests.
    ///
    /// **Nothing here falls back to an English voice on purpose.** Returning `nil` and
    /// letting `AVSpeechSynthesizer` use the system default is the same outcome and one
    /// fewer decision, and the log line is what makes it visible either way.
    public static func pick(from voices: [VoiceOption],
                            preferring name: String = "Zosia") -> VoiceOption? {
        voices
            .filter { speaks($0.language, language) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let preferredA = a.name.localizedCaseInsensitiveContains(name)
                let preferredB = b.name.localizedCaseInsensitiveContains(name)
                if preferredA != preferredB { return preferredA }
                // Anything still level is settled by the identifier, because a chooser that
                // depends on the order the system enumerated its voices in is a chooser that
                // changes its mind after a software update.
                return a.identifier < b.identifier
            }
            .first
    }

    /// Does `tag` name `language`? `pl-PL`, `pl_PL` and a bare `pl` all do; `plt` (Malagasy,
    /// and a real ISO code) does not, which is why this is not `hasPrefix` on its own.
    public static func speaks(_ tag: String, _ language: String) -> Bool {
        let lower = tag.lowercased()
        guard lower.hasPrefix(language.lowercased()) else { return false }
        let rest = lower.dropFirst(language.count)
        return rest.isEmpty || rest.first == "-" || rest.first == "_"
    }
}
