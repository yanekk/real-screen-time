# Findings log

**What the build taught.** Read the rows touching the task you pick up; read it whole before
anything only a person can verify — a ✅ row is the *entire* record that something was seen
working for real.

**Newest first. Forty words a row, counted, not estimated.** The long version is in the commit
message that carried the fix. This is the index, not the account.

**Whoever appends, compacts.** Before adding a row, if this file is over 60 rows or 15 KB, spend
two minutes shrinking it — merge rows that are one lesson twice, drop a row whose lesson a test or
a `DESIGN.md` rule now enforces (naming where it went). Never drop a ✅ row or its date, and never
drop what someone would grep for — a flag, an error string, a path.

Legend: 🐞 defect found · ✅ verified by hand with the user · 📌 worth knowing ·
🔄 a decision the user changed.

| Date | | Finding |
|---|---|---|
| 2026-09-05 | ✅ | T04 hand pass: the menu reads as the five lines — `Pozostały czas`, `Sesja X z Y`, then `Ustawienia… 🔒`/`Dodaj minuty… 🔒`/`Wyłącz do jutra 🔒`. No `Raport użycia…`, `Konfiguracja…` or `Zakończ`. Unconfigured launch opens the wizard on its own, no menu route. |
| 2026-09-05 | 📌 | T04 hand pass: a scratch `RST_DATA_DIR` isolates data but NOT the login item. Advancing the wizard to step 4 bootstraps the real LaunchAgent → launchd starts the installed `/Applications` app, which (if its data was removed) opens a second wizard. Stop before step 4, or boot out the agent after. |
| 2026-09-05 | 📌 | T04: `FirstRun.swift:640`'s doc comment still cites `Konfiguracja…` as a menu route to the wizard — now removed. Reasoning (defer the write, don't suppress the cover) still holds via the auto-open; only the example is stale. Out of scope, left. |
| 2026-09-05 | ✅ | T03 hand pass: combos accept typed values and show out-of-range stored (hour 3/23); grant field refuses to empty its last token; a typed-but-untokenized number still saves; Save closes on success, stays open on failure; detection minutes = seconds÷60. |
| 2026-09-05 | ✅ | T02 hand pass: the `.done` screen reads right — three paragraphs, one/N-session agreement, the zero case, minutes following the length. Reopen shows the saved settings (45 min / 2 sessions), confirming today's fix, not the default 30/1. |
| 2026-09-05 | 📌 | T02 hand pass, installed bundle: a small blank window appeared at the Sessions step and cleared itself. Pre-existing bundled-app draw quirk (initial-build FINDINGS 2026-08-26), not T02; `swift run` renders fine. Left alone. |
| 2026-09-05 | 📌 | T01 review: step-4 arming re-visit wrinkle. Back to step 3 then forward re-schedules a timer while the first is pending; the earlier timer can arm the button ~0.2s early. Benign — the harmful click lands before either fires. Not fixed. |
| 2026-09-05 | ✅ | T01 hand pass complete: fast double-click after step 3 did not install (arming delay held); step-3 fields aligned under the title; primary button rightmost with step counter leading on every step. Install and uninstall both work. |
| 2026-09-05 | 🐞 | T01: step-3 field rows drifted to the window's left edge, not under the title. Cause: the `custom` sub-stack had no width constraint. Fixed: pinned `custom.widthAnchor` to content−64 like the labels/footer. Confirmed by hand. |
| 2026-09-05 | 📌 | Wire keys: `self_service_sessions_per_day`, `idle_grace_seconds`, `media_grace_seconds`. Warnings dedup/sort via `Policy.warningThresholds` = `Set(warningMinutes.filter{$0>0}).sorted()`, not on `Config`. |
| 2026-09-05 | 📌 | `FirstRunStep.position` is used at two sites in `FirstRun.swift` (lines 237, 620); the enum is defined in `FirstRunModel.swift:35`. Making it optional (§2.4) must update both use-sites. |
| 2026-09-05 | 📌 | An unconfigured app auto-opens the wizard on `didFinishLaunching` (+2 s backstop) in `main.swift`. This is why removing `Konfiguracja…` (§2.9) does not strand a fresh Mac. |
| 2026-09-05 | 📌 | `FirstRun.swift` already has a `saving` flag and an `isKeyRepeat` guard on step transitions. §2.3's arming delay sits alongside them; `isKeyRepeat` catches a held key, not a second physical click. |
