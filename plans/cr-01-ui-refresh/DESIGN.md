# CR-01 — UI refresh: design

This plan refreshes the three parent-facing surfaces — the first-run wizard, the Settings
window, and the menu-bar dropdown. It changes no behaviour the child sees or the engine
enforces. **The foundational design is [../initial-build/DESIGN.md](../initial-build/DESIGN.md)**;
this file governs only the nine changes below and the decisions taken around them, and every
rule it does not restate still holds.

The binding specification is the change request, [CR-01-ui-refresh.md](CR-01-ui-refresh.md),
walked through screen for screen with the product manager and agreed 2026-09-04. This file
does not repeat it — it numbers the changes so tasks can cite them, records the decisions the
CR left open, and states what the machine can and cannot prove.

---

## 1. Purpose

The three parent-facing surfaces each carry small faults: controls that accept input the app
then refuses, a button order the app disagrees with itself about, and menu items that lead
nowhere. None is a redesign. Every change is a macOS convention the app was breaking, a
control that could not express a rule the app already enforces, or a door that leads nowhere.

### Success criteria

- After the refresh the only fields that can still raise a validation complaint are the combo
  boxes — session length, day-start hour, and the two detection-grace fields — because only a
  combo box accepts a free-typed value; every other input becomes a menu, a pop-up, or a token
  field that cannot express a wrong value.
- The primary button is rightmost on every wizard step and in Settings, matching Apple's
  convention and Settings' own existing footer.
- The menu-bar dropdown holds nothing the child can act on: two status lines and the padlocked
  parent controls, and no door that opens onto nothing.
- No change alters `config.json`'s schema, the event-log format, the cover, the PIN prompt, or
  any Polish string except the one menu-item deletion.

### Stance

The refresh keeps the app's split intact: **a rule the surface enforces lives in `RSTCore`
where `make test` reaches it, and only the AppKit lives in `RSTApp`.** A plural, a value
mapping, a clamp, or which menu items exist is a rule, and it does not move into a view
because a view is the one place this machine cannot test.

---

## 2. Behaviour specification

The nine changes, numbered to match the CR's own sections one-to-one — DESIGN §2.n is CR §n.
Each change's full "what / why / where / acceptance / watch-out" is in the CR; this section
records only what a later session must not lose and the numbers the tasks cite.

### 2.1 The wizard's buttons move to the bottom right (CR §1)

A single horizontal row: the step counter at the leading edge, a spacer, then `[Back][Continue]`
trailing, `Continue` rightmost. Apple's convention, and the one Settings already follows — the
wizard disagreed with the rest of the app. `nextButton.keyEquivalent = "\r"` and the
`backButton.isHidden` rule that stops a reopened wizard walking back to the PIN step are left
alone.

### 2.2 Step 3's two numbers become real controls (CR §2)

Session length becomes an `NSComboBox` suggesting 15/20/30/45/60 with any number still typeable;
sessions-per-day becomes an `NSPopUpButton` whose first item is `None — every session needs your
PIN` (maps to `sessionsPerDay == 0`), then `1`–`4 sessions`. The zero rule that lived only as an
error message becomes the first thing you read. **A stored value outside a control's list is
appended as an extra item, never silently clamped** — a hand-edited `self_service_sessions_per_day: 7` must
show as 7. `SessionLimits.problem` still governs the combo's value; the pop-up cannot produce an
invalid one.

### 2.3 Step 4 gets three buttons, and this reverses a fix (CR §3)

The bottom row becomes `[Back] [Finish without it] [Install login item]`, the install button
primary and rightmost. **This undoes the fix of 2026-08-26, made after a real failure**: leaving
step 3 pauses ~1.3 s while the PIN is hashed, and a corner button that changed identity under the
pointer took a stray second click straight into `launchctl bootstrap`. The layout is right; it
needs a seatbelt. **Required mitigation: the primary button is disabled for ~500 ms after step 4
first appears.** `isKeyRepeat` alone is not enough — it catches a held key, not a second physical
click, which is what happened. This is the highest-risk change in the plan and the one hand test
that must be attacked deliberately.

### 2.4 A final screen the wizard has never had (CR §4)

After either exit from step 4, a terminal screen: title `You're done`, three paragraphs built
from the answers given, one `Finish` button, no Back and no step counter. Paragraph one's count
agrees with the sessions-per-day answer (`one session` / `N sessions`, `it` / `them`), with the
zero case a distinct sentence. It also carries the chosen **session length** in minutes (`…of 30
minutes…`) from the step-3 answer, not a fixed figure — a parent who set 45 reads `45 minutes`
(product manager, 2026-09-05); the length is passed to the Core assembly helper alongside the
count so a test holds it. **`FirstRunStep` must not simply gain a fifth case** — `position`
is `(rawValue + 1, allCases.count)`, so a fifth case turns every earlier step into `Step N of 5`
and breaks the welcome screen's promise of four questions. `position` becomes optional and the
label is hidden when it is `nil`; the three existing call sites are updated. The English plural
mirrors `PolishPlural`: a small `EnglishPlural` in `RSTCore` with the sentences assembled in
`RSTApp`, because a plural chosen inside a view cannot be tested.

Paragraph two's "not installed" variant is reworded — see §7 decision on the reinstall route.

### 2.5 Settings › Sessions gets the same controls (CR §5)

Session length → `NSComboBox` (15/20/30/45/60); sessions-per-day → the §2.2 pop-up; day-start
hour → `NSComboBox` suggesting 4/5/6/7/8, any hour 0–23 typeable, 23 the cap. The hour list is
deliberately short because a menu of twenty-four is taller than the window. The two windows must
not offer the same setting through two different controls, so the §2.2 pop-up rule is shared, not
copied. Same append-don't-clamp rule as §2.2. The section note loses its zero sentence and keeps
only the day-reset sentence; `SettingsDraft.problem` still rejects an out-of-range hour.

### 2.6 Grants and Warnings become token fields (CR §6)

Both comma-separated fields become `NSTokenField`. **The two lists are not the same shape.**
Grants (`extension_options`): order is preserved and meaningful — the first is pre-selected in
the PIN picker — and the list may never be empty, so the field must refuse to delete its last
token. Warnings (`warning_minutes`): order is irrelevant (`Set(...).sorted()`), duplicates drop,
and empty is allowed. A delegate constrains tokens to whole numbers and offers a short pick-list
of common amounts — grants 5/10/15/20/30/45/60/90, warnings 1/2/3/5/10/15/20/30 — with any number
still typeable (CR §6). After this and §2.2/§2.5/§2.7, the only inputs that can still complain are
the combo boxes — a token field cannot express a wrong value. The warnings note gains the truth
that order does not matter and repeats are dropped.

### 2.7 Detection reads in minutes (CR §7)

The idle and media grace fields become `NSComboBox`es reading and accepting **minutes** — idle
suggesting 2/5/10/15, media 15/30/45/60, any number typeable, a stored value outside the list
appended via the shared `ComboSuggestions.merged` rule, not clamped (CR §7). `config.json` keeps
`idle_grace_seconds` and `media_grace_seconds` in seconds unchanged. The window converts: display
is `seconds / 60`, save is `minutes * 60`. **Accepted consequence, agreed by the product manager 2026-09-04**: the
finest setting becomes one whole minute, and a hand-edited value that is not a round number of
minutes rounds to the nearest one if the parent then presses Save. The conversion is a rule —
it lives in `SettingsModel` and is tested in both directions including the rounding.

### 2.8 Save closes the window (CR §8)

On a successful save, `close()` the window and remove `report("Saved. It is in effect now.")`
entirely — the window disappearing is the confirmation. On a validation failure nothing changes:
the window stays and `complain()` names the reason. `report("The PIN has been changed.")` stays
— that is not a Save, the window stays open, and a parent who typed a PIN three times needs to be
told it took. `Close` keeps its name; no unsaved-changes warning is added (see §8 out of scope).

### 2.9 The menu-bar dropdown becomes a status readout (CR §9 plus decisions A and B)

Three items leave the menu: `Raport użycia…` (CR §9), `Konfiguracja…` (decision A), and
`Zakończ` (decision B). What remains is `Pozostały czas`, `Sesja X z Y`, and the three padlocked
parent controls `Ustawienia… 🔒`, `Dodaj minuty… 🔒`, `Wyłącz do jutra 🔒`. That is the honest
shape: the child's actions live on the cover, and the menu bar is a status readout he can glance
at. The rationale and consequences of the two decisions are in §7.

---

## 3. Architecture

### 3.1 The boundary still binds

```
RSTCore/   Foundation + CryptoKit only. Every rule these changes carry.
RSTApp/    The AppKit that draws them.
```

`BoundaryTests` scans `RSTCore` for forbidden imports; if it fails the fix is to move the code,
never to relax the test. The reason is unchanged: everything in `RSTCore` is tested exhaustively
in milliseconds, and every rule that leaks into a view becomes a rule only a person can check on
a machine with no UI automation.

### 3.2 What moves into Core, and where

The refresh adds rules, not just controls. Each goes to Core with a test:

- **The sessions-per-day pop-up** — its ordered items and the two-way mapping to `sessionsPerDay`,
  including the append-don't-clamp rule for a stored value beyond 4. Shared by the wizard and
  Settings, so it is built once (T01) and reused (T03), the way `SessionLimits.problem` already
  is. Lives in `FirstRunModel.swift`.
- **The combo suggestion lists** (session length; day-start hour; the two detection-grace lists,
  idle 2/5/10/15 and media 15/30/45/60) and the shared merge rule that appends a stored value not
  already in the list. The merge rule and session-length list are built in T01; the hour and grace
  lists are added in T03, reusing the same rule.
- **`EnglishPlural`** — mirrors `PolishPlural`, for §2.4's sentences. T02.
- **`FirstRunStep.position` becomes optional**, with the terminal screen returning `nil`. T02.
- **The minute↔second conversion** for §2.7, both directions with the rounding. `SettingsModel.swift`,
  T03.

The AppKit — the combo boxes, the pop-up, the token fields, the button rows, the arming delay,
the window close — stays in `RSTApp` and is the half only a person can verify.

### 3.5 Storage

Unchanged. `config.json`'s schema is untouched: §2.7 converts at the window and stores seconds as
before (the disk keys are `idle_grace_seconds` and `media_grace_seconds`), and every other change
routes through values the config already holds. Atomic writes
(temp then rename) are `ConfigStore`'s and are not touched.

---

## 4. Testing

`make test` covers: the summary sentence's plurals (§2.4), the pop-up's item list and its mapping
to `sessions_per_day` (§2.2, §2.5), the append-don't-clamp merge rule, the minute/second
conversion including rounding (§2.7), `FirstRunStep.position` returning `nil` for the terminal
screen (§2.4), and every existing rule these changes route through.

`make test` **cannot** cover: a combo box accepting a typed value, a token field refusing a
non-number, the ~500 ms arming delay (§2.3), a button's position on screen, or a window closing.
All of those need the product manager at the keyboard. **These surfaces do not cover the screen**
— the wizard, Settings, and the menu all run in plain observer mode — so unlike the cover work
their hand tests need no `RST_ENFORCE` seatbelt. The one action with real reach is §2.3's install
button, which on a landed click runs `launchctl bootstrap`; that is reversible through Settings'
uninstall, and the §2.3 test is precisely to confirm a click inside the arming window does *not*
reach it. No task here is marked ✅ on the headless half alone.

---

## 5. Environment

Unchanged from [../initial-build/DESIGN.md](../initial-build/DESIGN.md) §7 and CLAUDE.md:
macOS 26.5.1 on Apple Silicon, Swift 6.3.2, Command Line Tools only — **no Xcode, no
`.xcodeproj`, no XCUITest, no third-party dependencies**, and this plan adds none.

**The test command is `make test`** — never bare `swift test`, which fails to build here on
purpose (CLT ships no XCTest; the search-path and rpath flags live in the `Makefile`). It is
already cheap to read: `-q` collapses a green run of ~375 tests to a four-line summary while a
failure still prints file, line and expanded values in full, and Swift Testing emits no ANSI to a
captured (non-TTY) stream, so the shell's `FORCE_COLOR=3` never reaches it and there is nothing to
strip. This contract is documented in the `Makefile` and is not re-derived here.

### 5.1 What the test command cannot reach

| Cannot be tested automatically | Why it needs a person |
|---|---|
| A combo box accepting a typed value, and showing a stored value outside its list | No UI automation on this machine |
| A pop-up drawing its items and mapping the chosen one | Same |
| A token field refusing a non-number and refusing to delete the grant list's last token | Same |
| The ~500 ms arming delay on step 4 (§2.3) | Must be attacked by hand — deliberately double-click Continue on step 3 |
| Every button's on-screen position, and the window closing on Save | A person has to look |
| The three final-screen sentences reading correctly in English | A person has to read them |

### 5.2 Seatbelts

These surfaces do not take the screen, so the cover's `RST_ENFORCE=1 RST_MAX_COVER_SECONDS=30`
seatbelt does not apply — the hand tests run under a plain `swift run RealScreenTime` in observer
mode. The one bounded action is §2.3's login-item install; the test confirms the arming delay
*prevents* it, and a login item installed by mistake is removed through Settings' uninstall.

---

## 6. Recovery

Unchanged: [../initial-build/RECOVERY.md](../initial-build/RECOVERY.md) — reboot and log in as
`admin`. One new gap this plan opens deliberately (§7 decision on the reinstall route):
after setup, a deleted login item can no longer be reinstalled from inside the app. The way back
is `make install`, which is the developer's, not the parent's — accepted, because the parent's
copy on `child` is installed once and the child cannot reach the wizard.

---

## 7. Decisions and rationale

**Task numbering restarts at T01 for this plan.** Product manager, 2026-09-05. The planning
session first continued the global sequence at T22, reasoning that the initial-build plan's
cross-references used T00–T21; the manager chose plan-local numbering instead. Each plan folder
carries its own `PROGRESS.md`, `FINDINGS.md` and `tasks/`, so T01–T04 here never collide with
the other plan's numbers, and a reference across plans names the plan it belongs to (the ship
checklist is "initial-build T18", not a bare T18).

**Decision A — `Konfiguracja…` is removed from the menu entirely.** Product manager, 2026-09-05.
The item showed on `!isConfigured || the login-item plist is missing`; the second half was a
stopgap from before Settings existed (the `main.swift` comment named T17 as its deadline, and T17
shipped). The manager chose full removal over keeping it for the no-PIN case, and the code makes
that safe: an unconfigured app auto-opens the wizard on every launch (on `didFinishLaunching`, with
a 2 s backstop), so a fresh Mac reaches setup by relaunching rather than by a menu click. The
auto-open path and `openFirstRun()` stay; only the menu's `onSetup`/`setupNeeded` plumbing goes.

**Decision A, consequence — the in-app login-item reinstall route is dropped.** Product manager,
2026-09-05. Installing the login item lives only in the wizard, which no longer reopens once a PIN
exists, and `Konfiguracja…` was its only post-setup trigger. Rather than move install into Settings,
the manager chose to drop the route: the login item is installed only during first setup.
`Finish without it` on step 4 becomes genuinely final, and **§2.4's "not installed" final-screen
paragraph is reworded to stop promising the `Konfiguracja…` route** — it now says only that the app
will not start on its own and must be opened after each login. The exact wording is the parent's
English and the manager eyeballs it on the hand pass.

The wizard's configured-resume path (`firstRunEntryStep` returning `.login`) becomes unreachable,
because `openFirstRun()` is now only called when unconfigured. It is left in place — a tested Core
rule, harmless, and removing it is out of this plan's scope.

**Decision B — `Zakończ` is removed.** Product manager, 2026-09-05. It was shown padlocked and
wired to nothing, on the argument that a dead item taught the child the padlock is real. Removed
because §2.9 already strips the menu to a status readout, a working Quit would be defeated by
`KeepAlive` and is duplicated by `Wyłącz do jutra`, and the padlock's meaning is carried by the
three remaining gated items.

**§2.7's rounding consequence** was accepted by the manager 2026-09-04: the finest grace becomes
one whole minute. See §2.7.

**The prototype** at the URL in [CR-01-ui-refresh.md](CR-01-ui-refresh.md) confirmed the direction
and was approved 2026-09-04. It is the non-binding reference; the CR is the specification. No local
copy is kept — the artifact lives on claude.ai and cannot be checked in here.

---

## 8. Explicitly out of scope

Everything in [../initial-build/DESIGN.md](../initial-build/DESIGN.md) §8 stays out, and this plan
adds:

- **The cover, the PIN prompt, the banner, and every Polish string** except the three menu-item
  deletions in §2.9. These are the child's surfaces and this refresh is the parent's.
- **`config.json`'s schema and the event-log format.** §2.7 converts at the window precisely so
  the file on disk does not change.
- **An unsaved-changes warning on `Close`.** Considered and declined: it is a seven-field form a
  parent opens rarely, and a dialog blocking the exit is more irritating than the loss it prevents.
  Revisit only if asked.
- **A red `Finish without it`.** Declined: on a Mac red means "this destroys something you will not
  get back", and finishing without the login item destroys nothing and is recoverable at any time.
  Red would blunt the warning `Uninstall…` has earned.
- **Moving login-item install into Settings.** Declined with decision A's consequence above.
