import AVFoundation
import RSTCore

/// **The only file in the app that imports `AVFoundation`** (DESIGN §2.4.1), and the only
/// thing that knows a warning is spoken at all — `RSTCore` decides *that* one is due.
///
/// The whole of the care in here is one measured fact: **an unknown voice does not fail.**
/// `say -v "Zosia (Premium)"` with no Premium voice installed returns success and speaks in
/// a different one (2026-08-21), and `AVSpeechSynthesisVoice(language:)` has the same shape.
/// So nothing is asked for by name: the installed voices are enumerated, ``VoiceChoice``
/// picks from what is really there, and what it picked is written to `app.log`. A Mac
/// quietly warning a Polish child in English is invisible to everyone except whoever is
/// standing in the room, and apps get quit on the strength of these warnings (§2.6.2).
@MainActor
final class Voice {

    /// Which voice was actually resolved, for `app.log` and for the `warned` event's
    /// `voice` field. `nonisolated` because ``Engine`` reads it through
    /// ``Enforcing/announcerVoice`` from wherever the tick is, and it never changes after
    /// `init`.
    nonisolated let label: String

    private let voice: AVSpeechSynthesisVoice?

    /// **Built on the first line spoken, not here.** `Voice` is constructed in `main.swift`
    /// before `NSApplication` exists, and an `AVSpeechSynthesizer` made that early is a
    /// larger assumption about AppKit's state than this file needs to make.
    private lazy var synthesizer = AVSpeechSynthesizer()

    /// A shade under the default, by ear.
    ///
    /// `AVSpeechUtteranceDefaultSpeechRate` is 0.5 on this machine and reads a warning
    /// faster than a child listening through a game takes it in. **This is the number
    /// DESIGN §2.4.1 says can only be tuned by ear** — `say -r 160` is words per minute and
    /// does not map onto this 0–1 scale at all, so the CLI value cannot be copied across.
    static let rate: Float = 0.45

    /// Enumerate, choose, and say what was chosen.
    init(diagnostics: Diagnostics, at now: Date) {
        let installed = AVSpeechSynthesisVoice.speechVoices().map {
            VoiceOption(identifier: $0.identifier, name: $0.name,
                        language: $0.language, quality: $0.quality.rawValue)
        }
        let chosen = VoiceChoice.pick(from: installed)

        // Resolved by **identifier**, which is the one handle that cannot silently match
        // something else — and checked, because a voice that vanished between the
        // enumeration and here would otherwise become a system-default line claiming to be
        // Zosia.
        voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }

        switch (chosen, voice) {
        case (let chosen?, .some):
            label = "\(chosen.name) (\(chosen.language), quality \(chosen.quality))"
        case (let chosen?, .none):
            label = "system default — \(chosen.identifier) would not resolve"
        default:
            let polish = installed.filter { VoiceChoice.speaks($0.language, VoiceChoice.language) }
            label = "system default — no \(VoiceChoice.language) voice among "
                + "\(installed.count) installed (\(polish.count) Polish)"
        }
        diagnostics("voice: \(label)", at: now)
    }

    /// Say it, interrupting whatever is still being said.
    ///
    /// **Interrupting is deliberate.** Two announcements can overlap under
    /// `RST_TIME_SCALE`, where 10, 5 and 1 minutes apart is ten, five and one second apart —
    /// and at real speed a grant landing on top of a warning is the same shape. The newer
    /// line is always the more urgent one, and two Polish sentences at once are neither.
    func say(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.rate
        utterance.volume = 1
        synthesizer.speak(utterance)
    }
}
