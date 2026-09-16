import AppKit
import RSTCore

/// **Chime, then the spoken line, then the banner** — DESIGN §2.4's sequence, in that
/// order, for a warning, for the expiry and for a grant behind the PIN.
///
/// The chime is not decoration. Without it the first two words are missed, because the ear
/// needs a moment to arrive before the sentence starts; `Ping` ×3 was chosen by ear in T00
/// against the alternatives.
///
/// **Only an enforcing run makes any noise** (decided by the user, 2026-08-25). An observer
/// run keeps its promise exactly: it changes nothing about the Mac, not even a sound. What
/// that costs is that T14 cannot be checked without a run that can really cover the screen —
/// with a seatbelt, and boxed into `RST_COVER_FRAME`.
@MainActor
final class Warner {

    /// **How far apart the three pings start, and it is not the file's length.**
    ///
    /// `Ping.aiff` is 1.5 s, nearly all of it decay — playing them strictly end to end would
    /// put four and a half seconds between the trigger and the first word, which is not "a
    /// moment for the ear to arrive", it is long enough to wonder what happened. This is the
    /// audible attack plus a little, so it reads as three pings and not one. **Tunable only
    /// by ear**, like the speech rate.
    static let chimeInterval: TimeInterval = 0.45
    static let chimes = 3

    /// The system sound §2.4 names. `byReference: true` keeps the file mapped rather than
    /// copied into each instance.
    static let chimePath = "/System/Library/Sounds/Ping.aiff"

    /// What ``Voice`` actually resolved, for `app.log` and the `warned` event's `voice`
    /// field. `nonisolated` because ``Engine`` reads it from wherever the tick is.
    nonisolated let voiceLabel: String

    private let speaker: Voice
    private let banner = Banner()
    private let diagnostics: Diagnostics
    /// Held while they play. An `NSSound` released mid-play stops, and the three of them are
    /// separate objects because one `NSSound` cannot overlap itself.
    private var playing: [NSSound] = []

    init(diagnostics: Diagnostics, at now: Date) {
        self.diagnostics = diagnostics
        self.speaker = Voice(diagnostics: diagnostics, at: now)
        self.voiceLabel = speaker.label
    }

    /// Say one thing, once. ``Engine`` owns *whether* — the de-duplication, the day's fired
    /// set and §2.2's silence are all rules, and rules live in `RSTCore`.
    func announce(_ announcement: Announcement, at now: Date) {
        let spoken = Strings.spoken(announcement)
        diagnostics("announce: \(announcement.logDescription) — \"\(spoken)\"", at: now)

        chime(at: now)
        // After the chime has started, not after it has finished: the speech synthesiser
        // queues its own audio, and the two overlapping by a fraction is what "the ear
        // arrives first" actually sounds like.
        after(Self.chimeInterval * Double(Self.chimes)) { warner in warner.speaker.say(spoken) }

        if let text = Strings.banner(announcement) { banner.show(text) }
    }

    /// `Ping` ×3, back to back.
    private func chime(at now: Date) {
        ping(at: now)
        for index in 1 ..< Self.chimes {
            after(Self.chimeInterval * Double(index)) { warner in warner.ping(at: now) }
        }
    }

    private func ping(at now: Date) {
        guard let sound = NSSound(contentsOfFile: Self.chimePath, byReference: true) else {
            // Not a crash: a missing system sound is a broken macOS install, and the spoken
            // line — the channel that actually matters — is still on its way.
            diagnostics("chime: \(Self.chimePath) would not load", at: now)
            return
        }
        // Drop the ones that have finished. Without this the array grows by three every
        // warning for the life of the process, which is small and still wrong.
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.play()
    }

    /// One hop onto the main actor, `seconds` from now.
    ///
    /// `Warner` is `@MainActor` and therefore `Sendable`, so it may be captured here; an
    /// `NSSound` may not, which is why every one of these closures reaches back through
    /// `self` for what it needs rather than carrying it.
    private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor (Warner) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
    }

}
