# T04 — Menu bar: remove three items and their plumbing

**Phase:** 1 · **Depends on:** — · **Weight:** light

## Goal

Strip the menu-bar dropdown down to what it honestly is: a status readout the child can glance at,
plus the padlocked parent controls. Three items leave — a third door to the event log, a setup
entry that outlived its purpose, and a Quit that never did anything — and with them the plumbing
that fed them.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.9 and §7 (decisions A and B). Binding detail:
[CR-01-ui-refresh.md](../CR-01-ui-refresh.md) §9, and the "Open decisions" section — both settled
2026-09-05, so build the removals, not the alternatives.

## Files

- `Sources/RSTApp/MenuBar.swift` — remove the `Raport użycia…` item and `revealReport()`; remove
  the `Konfiguracja…` item and its `setupItems`/`onSetup`/`setupNeeded` plumbing; remove the
  `Zakończ` item; remove `MenuBarController`'s `eventsURL` parameter and stored property.
- `Sources/RSTApp/Strings.swift` — remove `menuReport`, `menuSetup`, `menuQuit`.
- `Sources/RSTApp/main.swift` — remove the `eventsURL:` argument (line ~291), the
  `menuBar.onSetup` wiring (line ~481) and the `menuBar.setupNeeded` closure (lines ~487–490).
  **Keep the `didFinishLaunching` auto-open (lines ~513–531) and `openFirstRun()`** — that is how
  an unconfigured Mac still reaches the wizard, and it is what makes removing `Konfiguracja…` safe.

## Interface

No new interface. Removals only. The menu after this task holds, in order:

```
Pozostały czas: HH:MM:SS      (info line)
Sesja X z Y                   (info line)
——
Ustawienia… 🔒                (gated → PIN → Settings)
Dodaj minuty… 🔒              (gated)
Wyłącz do jutra 🔒            (gated)
```

- `openFirstRun()` stays but is now reached only by the auto-open, which only fires when
  unconfigured; the wizard's configured-resume path becomes unreachable and is left in place
  (DESIGN §7) — do not remove `firstRunEntryStep`'s `.login` branch, it is a tested Core rule.
- `LaunchAgentInstaller` stays — the wizard still installs the login item at step 4; only the
  menu's `setupNeeded` reference to its `plistURL` goes.

## Tests

- [ ] `make test` stays green. There is little to add here — the removals are `RSTApp` and the menu
      has no `RSTCore` rule of its own to test — but the boundary and existing suites must still
      pass, and any test naming a removed string or the `eventsURL` parameter is updated.

## Done when

- [ ] `make test` is green and the project builds with the three items, their selectors, the three
      strings, and the `eventsURL` parameter gone.
- [ ] The menu shows the two status lines and the three padlocked items, and nothing else.
- [ ] An unconfigured Mac still opens the wizard on launch (the auto-open path is untouched).
- [ ] **The task closes with a live-testing session** (see **Needs a person**): the hand pass is
      done with the product manager and its result is recorded in `FINDINGS.md` with the date.
      This task is not ✅ until then, however green `make test` is.

## Needs a person

Observer mode, no cover, no seatbelt.

```
swift run RealScreenTime
```

Expect: click the menu-bar icon. The dropdown holds `Pozostały czas`, `Sesja X z Y`, and the three
padlocked items `Ustawienia… 🔒`, `Dodaj minuty… 🔒`, `Wyłącz do jutra 🔒` — no `Raport użycia…`,
no `Konfiguracja…`, no `Zakończ`. Separately, launch once with a scratch unconfigured
`RST_DATA_DIR` and confirm the wizard still opens on its own.

Tell me: whether the three items are gone and the menu reads as the five lines above, and whether an
unconfigured launch still brings up the wizard without a menu route.
