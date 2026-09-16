# CR-01 — UI refresh: the wizard, Settings, and the menu bar

**Raised** 2026-09-04 by the product manager, out of a prototyping session.
**Prototype** <https://claude.ai/code/artifact/9d51af16-a3f3-44c3-a625-1bab902f0c38> —
every change below is visible and clickable there, including the states that are hard to
reach in the real app.
**Status** agreed, not implemented. **The session that raised this changed no Swift.**

---

## Why this exists

The three parent-facing surfaces were replicated screen for screen and walked through with
the product manager. Nine changes came out of it. They are not a redesign: every one is
either a macOS convention the app was breaking, a control that could not express a rule the
app enforces, or a door that leads nowhere.

Two of them reverse earlier decisions, and both reversals are called out in place. Read
those before touching the code — one of them undoes a fix that was made after a real
failure on the machine.

---

## Scope

**In:** `FirstRun.swift`, `Settings.swift`, `MenuBar.swift`, and whatever moves into
`FirstRunModel.swift` / `SettingsModel.swift` to stay testable.

**Out, and deliberately:** the cover, the PIN prompt, the banner, every Polish string except
the one deletion in §9, the event log format, `config.json`'s schema, and everything in
DESIGN §8. No new dependency. No `.xcodeproj`.

**The Core/App boundary still binds.** Where a change carries a *rule* — a plural, a
clamp, which menu items exist — the rule goes in `RSTCore` and the AppKit goes in `RSTApp`.
The wizard already splits this way and the split is why `make test` can see any of it.

---

## What can and cannot be proved by this project's tests

`make test` can cover: the summary sentence's plurals (§4), the pop-up's item list and its
mapping to `sessions_per_day` (§2, §5), the minute/second conversion (§7), the hour clamp
(§5), and every existing rule these changes route through.

`make test` **cannot** cover any of: a combo box accepting a typed value, a token field
refusing a non-number, the arming delay in §3, a button's position on screen, or a window
closing. **All of those need the product manager at the keyboard** — see CLAUDE.md,
*Anything that cannot be tested headless*. Do not mark a task ✅ on the strength of the
headless half; say which half is unseen, and hand over the exact command.

---

## The changes

### 1. The wizard's buttons move to the bottom right

**What.** `buildChrome()` adds `progressLabel` and then a left-aligned `[Back][Continue]`
stack to a `.leading`-aligned vertical stack, so both sit against the left edge. Replace
with a single horizontal row: `progressLabel` at the leading edge, a spacer, then
`[Back][Continue]` at the trailing edge, `Continue` rightmost.

**Why.** Apple: *"An action button, which initiates the dialog's primary action, should be
farthest to the right. A Cancel button should be to the immediate left of the action
button."* `Settings.swift`'s own footer already does exactly this — the app disagreed with
itself, and the wizard is the first thing anyone sees.

**Where.** `Sources/RSTApp/FirstRun.swift`, `buildChrome()`.

**Acceptance.** On every step the primary is the rightmost control; the step counter is on
the same row at the leading edge; `Back` sits immediately left of the primary.

**Leave alone.** `nextButton.keyEquivalent = "\r"`, and the `backButton.isHidden` rule that
keeps a reopened wizard from walking back to the PIN step.

---

### 2. Step 3's two numbers become real controls

**What.** Replace the two `NSTextField`s built by `numberField()`:

| Field | Becomes | Values |
|---|---|---|
| Session length | `NSComboBox` | suggests 15, 20, 30, 45, 60; any number still typeable |
| Sessions he can start himself | `NSPopUpButton` | `None — every session needs your PIN`, `1 session`, `2 sessions`, `3 sessions`, `4 sessions` |

**Why.** Nothing stopped a parent typing letters; they found out on Continue. And the zero
rule — *"Sessions per day cannot be negative. Zero is allowed, and means every session needs
your PIN"* — existed only as a telling-off after a mistake. As the first item of a menu it
is a choice you read before you make it.

**Where.** `FirstRun.swift` `showSessions()` and `numberField()`; the item list and its
mapping to `sessions_per_day` belong in `FirstRunModel.swift` so `make test` can reach them.

**Acceptance.** Picking `None` yields `sessionsPerDay == 0`. `SessionLimits.problem` is
still consulted for the combo box's value — the pop-up cannot produce an invalid one.

**Watch out.** The pop-up caps at 4. A hand-edited `config.json` with `sessions_per_day: 7`
has no matching item. **Do not silently clamp it** — append the stored value as an extra
item so the wizard shows what is actually configured. Same trap as §5's hour field.

---

### 3. Step 4 gets three buttons — and this reverses a fix

**What.** The bottom row becomes `[Back] [Finish without it] [Install login item]`, with
the install button as the primary and rightmost. The body's install button and its status
label go; the outcome is reported by the new final screen in §4.

**Why.** Same ordering rule as §1, and it puts the good path where the eye goes.

**Where.** `FirstRun.swift` `showLogin()` and `updateNextButton()`.

> **⚠ This undoes the fix of 2026-08-26, and the fix was made after a real failure.**
>
> The install action *used to* be the corner button. It was moved into the body because
> leaving step 3 pauses about a second while the PIN is hashed, and in that pause the corner
> button changed identity under the pointer — `Continue` → `Saving…` → the install button. A
> second click during the pause installed a system login item nobody had read a word about.
> `app.log` showed **1.3 s** between leaving the sessions step and `launchctl bootstrap`.
>
> **Putting it back in the corner puts it back where that stray click lands.** The layout is
> still the right one; it needs a seatbelt.
>
> **Required mitigation:** the primary button is **disabled for ~500 ms after step 4 first
> appears**. `isKeyRepeat` is not sufficient on its own — it catches a held key, not a second
> physical click, which is what actually happened.
>
> **Acceptance:** a click delivered inside the arming window does nothing, and `app.log`
> contains no `launchctl bootstrap` within 500 ms of leaving step 3. **This one cannot be
> checked headless. It must be tried by hand, deliberately double-clicking Continue on
> step 3.**

---

### 4. A final screen the wizard has never had

**What.** After either exit from step 4, a terminal screen:

- Title: **You're done**
- Three paragraphs, built from the answers actually given (below)
- One button, `Finish`. **No Back. No step counter.**

The three paragraphs:

1. *"the child gets one session of 30 minutes a day, and he can start it himself. Anything beyond
   that needs your PIN, and you choose the amount at the time."* — with `one session` /
   `N sessions` and `it` / `them` agreeing with the count. When sessions per day is **0**,
   this becomes: *"Every session needs your PIN. the child cannot start one himself — you grant
   the minutes, and you choose how many at the time."*
2. Installed: *"Real Screen Time starts when the child logs in, and starts again if it is ever
   quit or killed."*
   Not installed: *"Real Screen Time will not start on its own. You will need to open it
   after each login — or come back to this and install the login item, from Konfiguracja…
   in the menu bar."*
3. *"The countdown sits in the menu bar the whole time. Settings and extra minutes are behind
   your PIN; everything the app does is written to a log you can read."*

**Why.** Today the wizard just closes. This is the only moment a parent sees all four
decisions at once, and the last chance to notice one is wrong. It also makes
`Finish without it` honest — that choice is currently made in silence and never mentioned
again.

**Where.** `FirstRun.swift`, plus `FirstRunModel.swift` for the parts that are rules.

**Watch out — `FirstRunStep` cannot simply gain a fifth case.** `position` is
`(rawValue + 1, FirstRunStep.allCases.count)`, so a fifth case turns every earlier step into
`Step N of 5` and breaks the welcome screen's promise of *"Four questions and you are
done."* Either keep the terminal screen out of `FirstRunStep`, or make `position` return
`nil` for it. **Recommended:** `position` becomes optional and the label is hidden when it
is `nil` — the rule stays in Core where a test can hold it.

**Watch out — the plural logic wants a test.** `PolishPlural` lives in Core precisely
because a plural chosen inside a view cannot be checked. Mirror it: a small `EnglishPlural`
(or an equivalent) in `RSTCore`, with the sentences assembled in `RSTApp`.

**Note on §2.4.2.** This screen is English. It is behind the wizard, which is the parent's,
and it names `Konfiguracja…` in Polish because that is the label the menu actually shows.

---

### 5. Settings › Sessions gets the same controls

**What.**

| Field | Becomes | Values |
|---|---|---|
| Session length | `NSComboBox` | 15, 20, 30, 45, 60 suggested |
| Sessions he can start himself | `NSPopUpButton` | as §2 |
| The day starts at | `NSComboBox` | suggests 4, 5, 6, 7, 8; **any hour 0–23 typeable, 23 is the cap** |

The hour list is deliberately short: a menu of all twenty-four is taller than the window.

**Why.** The same reasons as §2, and the two windows must not offer the same setting through
two different controls.

**Where.** `Settings.swift`; the rules stay in `SettingsModel.swift`, which already shares
them with the wizard.

**Acceptance.** The section note loses its zero sentence — the menu says it now — and keeps
only *"The day's sessions come back at the hour above. Any hour from 0 to 23."*
`SettingsDraft.problem` still rejects an out-of-range hour typed into the combo.

**Watch out.** Same as §2: a stored value outside the suggestion list must be shown, not
clamped.

---

### 6. Grants and Warnings become token fields

**What.** Both comma-separated `NSTextField`s become `NSTokenField` — the pill field Mail
uses for recipients. Each amount is an object with a delete affordance; values are added
from a short menu (grants: 5, 10, 15, 20, 30, 45, 60, 90 — warnings: 1, 2, 3, 5, 10, 15,
20, 30) and any number remains typeable.

**Why.** There is no comma syntax left to get wrong, and two whole classes of error message
disappear. After §2, §5 and this, the **only** fields in the app that can still produce a
validation complaint are the three combo boxes.

**Where.** `Settings.swift`.

**The two lists are not the same shape, and the difference is load-bearing:**

| | Grants (`extension_options`) | Warnings (`warning_minutes`) |
|---|---|---|
| Order | **Preserved and meaningful** — `Config.extensionChoices` keeps it, and the first is pre-selected in the PIN picker | **Irrelevant** — `Config.warningThresholds` is `Set(...).sorted()` |
| Duplicates | dropped by `extensionChoices` | dropped by the `Set` |
| May be empty? | **No.** With nothing to offer, `Dodaj minuty…` asks for a PIN and then grants nothing | **Yes.** No warnings; the countdown stays in the menu bar |

So the grant field must refuse to delete its last token, and must let the parent control the
running order. The warning field needs neither.

**Acceptance.** The warnings note gains the truth that was never stated: *"Order does not
matter — they are sorted for you, and repeats are dropped."*

**Watch out.** `NSTokenField` needs a delegate to constrain entries to whole numbers, and
its `tokenizingCharacterSet` should not leave a comma doing something surprising. Tokens
show the bare number; the unit stays as the trailing field label, as now.

**Housekeeping.** Check the remaining callers of `MinuteList` in `SettingsModel.swift` and
`Settings.swift`. `parse` is likely to become unused in production. **Do not delete it
without checking** — it is also exercised by `SettingsModelTests`, and a description string
uses `format`. If it genuinely has no production caller left, removing it and its tests is
in scope; leaving it is also acceptable. Say which you did.

---

### 7. Detection reads in minutes

**What.** *"Pause the clock after **10 minutes** idle"* and *"…or, with something playing,
after **30 minutes** idle"*. Combo boxes suggesting 2, 5, 10, 15 and 15, 30, 45, 60.

**`config.json` keeps seconds.** `idle_grace_s` and `media_grace_s` are unchanged on disk;
only the window converts — display is `seconds / 60`, save is `minutes * 60`.

**Why.** 600 and 1800 are ten minutes and half an hour. Nobody thinks in seconds.

**Accepted consequence, agreed by the product manager 2026-09-04.** The finest setting a
parent can express becomes one whole minute, and a hand-edited value that is not a round
number of minutes will round to the nearest one if that parent then presses Save. Nothing
the app itself writes has ever been anything but a round number of minutes.

**Where.** `Settings.swift` for the fields; the conversion is a rule — put it in
`SettingsModel.swift` and test both directions, including the rounding.

---

### 8. Save closes the window

**What.** On a successful save, `close()` the window. **Remove**
`report("Saved. It is in effect now.")` entirely. On a validation failure, nothing changes:
the window stays open and `complain()` puts the reason in the footer strip.

**Why.** The window disappearing is the confirmation. A label saying it saved, on a window
that is still sitting there, invites a second press.

**Where.** `Settings.swift` `savePressed()`.

**Keep `report("The PIN has been changed.")`.** Deliberate, and confirmed with the product
manager: that is not a Save, the window stays open afterwards, and a parent who has just
typed a PIN three times needs to be told it took.

**Not changing, and considered:** `Close` keeps its name — `Cancel` would be a lie, because
`Change PIN…` and `Uninstall…` both act the moment they are clicked and no Cancel undoes
them. No unsaved-changes warning is being added; see *Raised and declined* below.

---

### 9. `Raport użycia…` comes out of the menu

**What.** Delete the menu item, `revealReport()`, and `Strings.menuReport`.
`MenuBarController`'s `eventsURL` parameter has no other caller — remove it, and the
argument at `main.swift:291`.

**Why.** Three reasons, in order of weight:

1. It runs character-for-character the same code as `Settings › Reveal the event log`. It is
   a third door to one file, and the only one on the child's side of the PIN.
2. What it reveals is `events.jsonl` — English, machine-shaped, `jq` territory. The item is
   Polish because it is ungated, so an ungated Polish label opens a parent's file. The design
   declined a report UI outright (DESIGN §8: *"the JSONL log is the report"*), so the label
   promises something that will never exist.
3. The child's usage question is already answered two lines above it, by
   `Pozostały czas` and `Sesja 1 z 1`.

**Consequence, and it is intended.** The dropdown then holds nothing the child can act on —
two information lines, `Konfiguracja…` when it applies, and four padlocked items. That is the
honest shape: his actions live on the cover, and the menu bar is a status readout he can
glance at.

**Where.** `MenuBar.swift`, `Strings.swift`, `main.swift`.

---

## Open decisions — do not implement

These were raised in the same session and **not settled**. Bring them to the product manager
rather than choosing.

**A. `Konfiguracja…` on a configured Mac.** It is shown when `!isConfigured || the
LaunchAgent plist is missing`. The second half means it reappears if the child deletes the login
item — which he can, he owns his home folder. The comment at `main.swift:483` says that
condition exists *"with no way back until T17's settings window exists"*. **T17 exists, and
nothing in it installs a login item, so the stopgap outlived its deadline.**

*Recommendation:* show `Konfiguracja…` only when there is no PIN — that path must stay,
because a parent who closes the wizard on a fresh Mac has no other way back to it — and move
installing the login item into Settings, behind the PIN, where every other parent control
lives. Reopening the wizard already lands on step 4 and never step 2, so this was never a
route to a second PIN; that protection is independent.

**B. `Zakończ`.** Still shown, still padlocked, still wired to nothing at all. It has been
that way since T10, on the argument that an item opening no dialog would teach the child the
padlock is decorative. Either wire it or remove it.

---

## Raised and declined

**An unsaved-changes warning on `Close`.** Now that Save closes, `Close` reads as "leave
without applying", and edits are lost silently. Recommendation was **not** to add a warning:
it is a seven-field form a parent opens rarely, and a dialog blocking the exit of a settings
window is more irritating than the loss it prevents. Not acted on; revisit only if asked.

**A red `Finish without it` on step 4.** Considered, and advised against. On a Mac a red
button means *this destroys something you will not get back*; finishing without the login
item destroys nothing and is recoverable at any time. Red would spend a warning we have not
earned, and blunt it for `Uninstall…`, which has.

---

## How this becomes work

**`work` will not see this file.** It reads `docs/PROGRESS.md` and picks a task from there,
so until rows exist this change request is inert. Proposed split — four tasks, each a
session's worth, each reviewable by a session that did not write it:

| | Task | Covers |
|---|---|---|
| T22 | Wizard: button row, step 3 controls, step 4's three buttons and its arming delay | §1, §2, §3 |
| T23 | Wizard: the final screen | §4 |
| T24 | Settings: all seven fields, and Save closing | §5, §6, §7, §8 |
| T25 | Menu bar: remove the report item | §9 |

T25 is small enough to fold into T24 if you would rather have three.

**Sequencing: before T18.** T18 is the ship checklist and it hand-verifies the wizard and
Settings on the real machine. Shipping first means walking that checklist twice.

**Every one of these tasks ends with a hand pass.** None of the nine changes can be fully
proved by `make test`; §3's arming delay in particular has to be attacked deliberately.
Whatever comes back from the machine goes in `docs/FINDINGS.md` with the date.
