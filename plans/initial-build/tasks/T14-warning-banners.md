# T14 — Warnings: chime, voice, banner

**Phase:** 3 · **Depends on:** T10 · **Weight:** medium

## Goal

Tell someone the limit is coming, in time to save their work, without wrecking what they are
doing — and make sure it reaches them **inside a fullscreen game**, which is the only place
it really has to work.

## Audio is the primary channel

This inverts the obvious priority, for a measured reason. [DESIGN §2.6.1](../DESIGN.md)
established that nothing can be drawn over a fullscreen app's Space, so a banner is
literally invisible at the exact moment it matters most. Sound goes through headphones no
matter what is on screen.

The banner then covers what audio cannot: a muted Mac, headphones off, volume at zero.
Neither is sufficient alone.

**Do not try to raise the volume.** Intrusive, and on the target Mac the output device does
not report volume to the API at all — `output volume of (get volume settings)` returns
`missing value`. A check that fails silently on the actual hardware is worse than none.

## The sequence

`Ping` ×3, **back to back with no gap**, then the spoken line, then the banner.

The chime is not decoration: without it the first two words are missed, because the ear
needs a moment to arrive before the sentence starts. Chosen by ear against the alternatives
in T00.

Thresholds are **10/5/1**, not 15/5/1: on a 30-minute session a 15-minute warning is the
halfway mark, which is a progress report rather than a warning. `warningMinutes` is config.

| Remaining | Spoken (Polish) |
|---|---|
| 10 min | "Zostało Ci dziesięć minut." |
| 5 min | "Zostało Ci pięć minut. Zapisz swoją grę." |
| 1 min | "Ostatnia minuta." |
| 0 | "Czas minął." |
| on a grant | "Dodano piętnaście minut." — **and the number is now the parent's**, so this line has to decline whatever they typed (DESIGN §2.5, changed 2026-08-22). Polish declines the noun by the numeral: *jedną minutę*, *dwie/trzy/cztery minuty*, *pięć…dwadzieścia jeden minut*, then by the last digit again. **Ask before guessing a rule** — a Mac saying "Dodano dwa minut" to a Polish child is exactly the kind of wrong nobody but a listener catches |

`/System/Library/Sounds/Ping.aiff` via `NSSound` or `AVAudioPlayer`. Three sequential plays,
no delay between them.

## Choosing the voice — verify, never trust a name

`AVSpeechSynthesizer`, in `Voice.swift`, the only file that imports `AVFoundation`.

**Measured 2026-08-21:** `say -v "Zosia (Premium)"` with no Premium voice installed
**returns success and speaks in a different voice**. It does not error. Assume the
`AVSpeechSynthesisVoice` APIs behave the same way — enumerate `speechVoices()`, pick the
best match, and **log which voice was actually selected**.

Fallback chain, best first:

1. Premium `pl_PL`
2. Enhanced `pl_PL` — installed on this machine
3. Compact `Zosia` — present on every Mac
4. Any `pl_PL` voice
5. System default

A Mac with no Polish voice must still say *something*. A warning that silently does not
happen is the one failure this feature cannot have, because **apps get quit on the strength
of it** ([DESIGN §2.6.2](../DESIGN.md)).

Rate needs tuning by ear. `say -r 160` is words-per-minute; `AVSpeechUtterance.rate` is a
0–1 scale around `AVSpeechUtteranceDefaultSpeechRate`. The two do not map and the CLI number
cannot be copied across.

## Behaviour

The banner carries the same words as the spoken line, measured against the running
session's remaining time. There is nothing else to warn about — no curfew, no daily pool.

## The warnings carry the consequence

Per [DESIGN.md §2.6.2](../DESIGN.md), a fullscreen app is **quit** when the cover appears,
because it cannot be covered. The warnings are the only notice that happens, so they must
say so explicitly — a consequence nobody was told about is a trap, and the design's stance
is that this is a visible boundary.

This is also what makes quitting defensible at all. Drop the wording and the feature stops
being fair.

## Silent while off-console

No chime, no speech, no banner while another user is switched in
([DESIGN §2.2](../DESIGN.md)). A background session speaking Polish over whoever is actually
using the Mac is the sort of thing that gets an app uninstalled — and the warning would be
wasted anyway, since the person it is aimed at is not there.

The threshold still counts as un-fired, so he gets it when he switches back.

## Must not steal focus

A warning that interrupts a game to say "save your game" defeats itself, and worse, teaches
that the app is something to be endured rather than read.

- `NSPanel` with `.nonactivatingPanel`, or `NSWindow` with `.floating` level
- Never `makeKey`
- `ignoresMouseEvents = true` — a banner that eats a click during a game is a lost round
- Main display only, top-centre, auto-dismiss after ~6 seconds
- Fade in and out; an abruptly appearing rectangle reads as a glitch

## Fire once each

Each threshold fires once per day per limit. `Policy.decide` reports which threshold the
current remaining time falls into and keeps reporting it; **de-duplication lives here**, in
the enforcer, so the decision function stays a pure function of its inputs (T05).

Reset the fired set on the 06:00 day rollover, and on a PIN extension — if 15 minutes are
added after the 5-minute warning, the 5-minute warning should fire again on the way back
down. That is the behaviour someone would expect, and forgetting it produces a silent last
five minutes.

## Notification Center

Not used. Notifications can be suppressed by Focus modes, are silently dropped in a
fullscreen game, and would need an entitlement and a permission prompt. A borrowed window is
smaller and always visible.

## Tests

- Threshold selection at 10:00, 9:59, 5:00, 1:00, 0:59 remaining
- Fires once, not once per tick
- Voice resolution picks the best available tier, and falls through correctly when each is
  absent — including the case where **no** Polish voice exists
- The resolved voice is logged, so a Mac quietly speaking English is visible in the log
  rather than only to whoever is standing there
- No warning fires while `.awaitingStart` or `.awaitingResume` — there is no session to end
- An extension after a warning re-arms that warning
- The day rollover clears the fired set

## Done when

A `RST_TIME_SCALE=60` run shows all three banners in sequence, none of them stealing focus
from whatever is in front.
