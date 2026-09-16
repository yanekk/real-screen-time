# T02 — Wizard: the final "You're done" screen

**Phase:** 1 · **Depends on:** T01 · **Weight:** medium

## Goal

Give the wizard the terminal screen it has never had: after step 4, one screen that shows the
parent all four decisions at once and their consequences, built from the answers actually given.
It is the last moment to notice a setting is wrong, and it makes `Finish without it` honest — a
choice today made in silence.

## Design sections this implements

[DESIGN.md](../DESIGN.md) §2.4 and §3.2. The binding detail is
[CR-01-ui-refresh.md](../CR-01-ui-refresh.md) §4 — three paragraphs specified there, with one
wording change below.

## Files

- `Sources/RSTApp/FirstRun.swift` — the terminal screen, its single `Finish` button, and the
  sentence assembly; the two `FirstRunStep.position` use-sites (lines 237, 620) updated
  for the optional return (the enum is defined in `FirstRunModel.swift`).
- `Sources/RSTCore/FirstRunModel.swift` — `FirstRunStep.position` becomes optional; the terminal
  screen is kept out of the four-case counter.
- `Sources/RSTCore/EnglishPlural.swift` (new) — the plural rule, mirroring `PolishPlural`.
- `Tests/RSTCoreTests/FirstRunModelTests.swift`, and a test file for `EnglishPlural`.

## Interface

```swift
// FirstRunModel.swift — position must not count a fifth screen.
extension FirstRunStep {
    /// `(index, count)` for the four real steps, `nil` for anything with no place in the
    /// counter. Making it optional is why the terminal screen does not turn "Step 3 of 4"
    /// into "Step 3 of 5" and break the welcome screen's promise of four questions.
    public var position: (index: Int, count: Int)? { … }
}

// EnglishPlural.swift — the sentences are assembled in RSTApp; the choice of form is the rule.
public enum EnglishPlural {
    public enum Form { case one, many }
    public static func form(_ count: Int) -> Form   // 1 → .one, everything else → .many
}
```

- The terminal screen is **not** a fifth `FirstRunStep` case (that is what forces `position`
  optional); keep it a separate state the window drives, or a case `position` returns `nil` for —
  the recommended shape in CR §4 is the optional `position`.
- Paragraph one is assembled from **both** the sessions-per-day count and the chosen session
  length in minutes: the count drives `one session` / `N sessions` and `it` / `them`, and the
  length fills the `…of N minutes…` figure (DESIGN §2.4, product manager 2026-09-05). Pass both
  into the testable Core helper so a test holds the wording, not only the hand pass.
- Paragraph two's "not installed" variant is **reworded** from the CR: it no longer points to
  `Konfiguracja…`, because that menu item is removed (DESIGN §7). It says only that the app will
  not start on its own and must be opened after each login. Paragraphs one and three are as the CR
  writes them. All three are English, behind the wizard.

## Tests

- [ ] `EnglishPlural.form(1) == .one`; `form(0)`, `form(2)`, `form(4)` == `.many`.
- [ ] `FirstRunStep.position` returns a value for each of the four real steps with the right index
      and a count of 4; returns `nil` for the terminal screen.
- [ ] The sessions-per-day count drives paragraph one's number and agreement: `1` → `one session`
      / `it`; `2` → `2 sessions` / `them`; `0` → the distinct "every session needs your PIN"
      sentence. (Assemble the sentence in a testable Core helper if practical, or test the plural
      and count-mapping and verify the wording by hand.)
- [ ] Paragraph one's minute figure follows the session-length answer: length `30` → `30 minutes`,
      length `45` → `45 minutes`, through the same Core helper.

## Done when

- [ ] `make test` is green, with the plural and optional-position rules covered.
- [ ] Finishing step 4 by either button lands on a `You're done` screen with three paragraphs, one
      `Finish` button, no Back and no step counter.
- [ ] Paragraph one shows the session length the parent set (e.g. 45 reads `45 minutes`), not a fixed 30.
- [ ] The four real steps still read `Step N of 4`; the welcome screen's four-questions promise
      holds.
- [ ] **The task closes with a live-testing session** (see **Needs a person**): the hand pass is
      done with the product manager and its result is recorded in `FINDINGS.md` with the date.
      This task is not ✅ until then, however green `make test` is.

## Needs a person

Observer mode, no cover, no seatbelt.

```
swift run RealScreenTime
```

Expect: run the wizard through to the end (unconfigured — scratch `RST_DATA_DIR`). After step 4
the terminal screen appears with three paragraphs matching the answers given. Try it once with
sessions-per-day set to `None`/0 and once with 1 and with 2, once with a non-default session length
(e.g. 45) to confirm the minutes figure follows it, and once finishing *with* and once *without* the
login item.

Tell me: whether the three paragraphs read correctly in English, whether the count and its
agreement (`one session`/`it` vs `N sessions`/`them`, and the zero case) are right, whether the
minutes figure matches the session length set, and whether the "not installed" paragraph reads
sensibly now that it no longer mentions `Konfiguracja…`.
