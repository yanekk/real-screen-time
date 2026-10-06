import ApplicationServices
import CoreGraphics
import Foundation
import RSTCore

// The Tier 2 real-click gate (plan headed-and-e2e-tests, T07). It launches the actually-built
// app as a boxed, enforcing, seatbelted cover, drives it through the macOS Accessibility system
// with genuine CGEvent clicks and keystrokes, and asserts the outcome from the scratch
// `events.jsonl`. It proves the one thing the in-memory Tier 1 suite cannot: that the *real
// launched app's* cover takes real input and dismisses correctly — the project's own warning is
// that "`swift run` from a terminal is not a bundled app" and some AppKit behaviour differs
// (CLAUDE.md), so this is the honest witness for the activation and first-responder path.
//
// It is the test: it exits 0 when every assertion holds, 1 on the first failure, 2 when it is
// not trusted for Accessibility. It is never part of `make test` — it needs the one-time grant
// and it drives a real (boxed) window, so it is on-demand via `make ui-gate` only.
//
// **Safety (DESIGN §2.4).** Every launch sets `RST_COVER_FRAME` (box mode withholds the kiosk
// lockdown — Kiosk.swift), `RST_ENFORCE=1`, `RST_MAX_COVER_SECONDS` (the detached-thread
// `exit(0)` backstop if a click fails to dismiss the cover) and a scratch `RST_DATA_DIR`. It
// never drives a full-screen cover; the full kiosk is Tier 3, verified by a person.

// MARK: - The launch box and PINs

/// The seatbelt box. Small, near the top-left, always. This is the string DESIGN §2.4 and the
/// task interface fix; it is never omitted, or the cover would go full-screen.
let coverFrame = "600x400+80+80"
/// The seatbelt: tear any cover down and `exit(0)` after this many real seconds, whatever the
/// clicks did. Each scenario asserts and terminates the app well inside this.
let seatbeltSeconds = 30
/// The PIN the scratch config is seeded with, and a wrong one that shares its length. Four
/// digits because the boxes accept exactly `pinDigits` (RSTCore) and auto-submit on the fourth.
let correctPIN = "1379"
let wrongPIN = "0000"

// MARK: - Accessibility identifiers (set by T06)

// The cover's controls carry these as real `setAccessibilityIdentifier` values, the one form a
// cross-process `AXUIElement` reader can see (the `NSUserInterfaceItemIdentifier` alongside them
// is invisible to AX — T00/T06 findings). They are `CoverModel.Button` raw values plus the PIN
// boxes' own id.
let axStart = "start"
let axPIN = "pin"
let axPINBoxes = "pin-boxes"
// `Wyloguj` on the face, and its in-place confirmation's two buttons (cover-buttons-logout T03).
let axLogout = "logout"
let axLogoutCancel = "logout-cancel"
let axLogoutConfirm = "logout-confirm"

// MARK: - Key codes

// ANSI virtual key codes for the digit row. The digit row is stable across Latin
// keyboard layouts (US and Polish agree on it), which is why a keycode is enough and no unicode
// override is set; the machine's real layout is confirmed on the hand-run first pass.
let digitKeyCodes: [Character: CGKeyCode] = [
    "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
    "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
]

// MARK: - Accessibility reads

/// A child list, or empty. The CFArray of `AXUIElement` bridges straight to `[AXUIElement]`.
func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement]
    else { return [] }
    return children
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? String
}

/// The app's top-level windows. In box mode the app is `LSUIElement` with no Dock icon, so its
/// only window is the cover; when the cover lifts this goes empty, which is the clean "the cover
/// is gone" signal the assertions use.
func axWindows(_ app: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement]
    else { return [] }
    return windows
}

/// The element's frame in global top-left-origin screen coordinates — the same space CGEvent
/// mouse events use, so the centre computed here is posted without any flip.
func axFrame(_ element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
}

/// Depth-first search for the element carrying `identifier`. Bounded depth so a malformed tree
/// cannot spin: the cover is shallow, twenty is generous.
func find(in root: AXUIElement, identifier: String, maxDepth: Int = 20) -> AXUIElement? {
    if axString(root, kAXIdentifierAttribute) == identifier { return root }
    guard maxDepth > 0 else { return nil }
    for child in axChildren(root) {
        if let found = find(in: child, identifier: identifier, maxDepth: maxDepth - 1) { return found }
    }
    return nil
}

/// Poll every window for a control with `identifier`, up to `timeout`. The cover appears a tick
/// after launch, and the PIN prompt a moment after its button is clicked, so every reach for a
/// control waits rather than assuming it is already there.
func waitForControl(app: AXUIElement, identifier: String, timeout: TimeInterval) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        for window in axWindows(app) {
            if let control = find(in: window, identifier: identifier) { return control }
        }
        usleep(200_000)
    } while Date() < deadline
    return nil
}

/// Wait for a control with `identifier` to *disappear* from every window, up to `timeout`.
/// Opening the PIN prompt swaps the cover's whole button row out for the prompt view, so the
/// `pin` button leaving the tree is the signal the prompt is up. This is used instead of
/// waiting for the `pin-boxes` view because that view is a plain `NSView` and AppKit does not
/// surface a non-accessibility-element view to a cross-process reader, identifier or not (T07
/// finding) — a real user does not "find" the boxes either, they just type.
func waitForControlGone(app: AXUIElement, identifier: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let present = axWindows(app).contains { find(in: $0, identifier: identifier) != nil }
        if !present { return true }
        usleep(200_000)
    } while Date() < deadline
    return !axWindows(app).contains { find(in: $0, identifier: identifier) != nil }
}

/// Wait for the app to have no windows — the cover has lifted. Returns whether it did within
/// `timeout`.
func waitForNoWindows(app: AXUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if axWindows(app).isEmpty { return true }
        usleep(200_000)
    } while Date() < deadline
    return axWindows(app).isEmpty
}

// MARK: - Synthetic input

/// A left click at a screen point, posted at the HID level so it lands on whatever is frontmost
/// there — the `.screenSaver`-level cover box, above every ordinary window.
func click(at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                       mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                     mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(40_000)
    up?.post(tap: .cghidEventTap)
}

func clickCentre(of element: AXUIElement) -> Bool {
    guard let frame = axFrame(element) else { return false }
    click(at: CGPoint(x: frame.midX, y: frame.midY))
    return true
}

/// Press and release a key. Keystrokes route to the key window's first responder — which, for
/// the boxed cover, is only true if `NSApp.activate()` really made it key. That is precisely the
/// end-to-end fact this gate exists to prove (DESIGN §2.2).
func typeKey(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(20_000)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
}

/// Type the digits of a PIN, one keystroke each. No Return: the fourth digit auto-submits the
/// boxes (PINPrompt), so a trailing Return would be ignored anyway.
func typePIN(_ pin: String) {
    for digit in pin {
        guard let keyCode = digitKeyCodes[digit] else { continue }
        typeKey(keyCode)
        usleep(80_000)
    }
}

// MARK: - The scratch app under a seeded config

/// Where the scratch data dirs live for this run. One per scenario, so a fresh launch never
/// inherits another's session state.
let scratchBase = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("rst-ui-gate-\(ProcessInfo.processInfo.processIdentifier)")

/// Seed a scratch `config.json` with a real, verifiable PIN — the launched app refuses to cover
/// without one (an empty data dir opens the first-run wizard instead, not a cover). Built with
/// the very functions the app verifies against (`newPINSalt`/`hashPIN`), so the seeded PIN is
/// genuinely the one the cover will accept. `selfService` chooses the face: 1 → the Start face,
/// 0 → the exhausted face that offers PIN and Lock from the first tick.
func seedConfig(dataDir: URL, selfService: Int) {
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    var config = Config()
    config.selfServiceSessionsPerDay = selfService
    let salt = newPINSalt()
    config.pinSalt = salt.base64EncodedString()
    config.pinHash = hashPIN(correctPIN, salt: salt)
    try? ConfigStore(directory: dataDir).save(config)
}

/// Launch the built app boxed, enforcing and seatbelted, pointed at the scratch dir.
func launchApp(appPath: String, dataDir: URL) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: appPath)
    var environment = ProcessInfo.processInfo.environment
    environment[Flags.Name.enforce] = "1"
    environment[Flags.Name.coverFrame] = coverFrame
    environment[Flags.Name.maxCoverSeconds] = String(seatbeltSeconds)
    environment[Flags.Name.dataDirectory] = dataDir.path
    // A real log-out ends the session running this gate. Dry run on every launch, which
    // wins over `RST_ALLOW_LOGOUT=1` and holds even against a release binary (§2.5).
    environment[Flags.Name.logoutDryRun] = "1"
    process.environment = environment
    try? process.run()
    return process
}

/// How many `events.jsonl` lines carry this event type. A substring match on `"type":"<t>"` is
/// enough: the sink writes compact JSON with `ts` first and `type` second (EventLog).
func eventCount(dataDir: URL, type: String) -> Int {
    let url = dataDir.appendingPathComponent("events.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
    return text.split(separator: "\n").filter { $0.contains("\"type\":\"\(type)\"") }.count
}

/// Whether the scratch `app.log` contains `needle`. A wrong PIN writes no event by design, so
/// its only trace is the diagnostic line `pin: rejected …` — checking it is what keeps the
/// wrong-PIN scenario from passing vacuously when no keystroke ever reached the field.
func appLogContains(dataDir: URL, _ needle: String) -> Bool {
    let url = dataDir.appendingPathComponent("app.log")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return text.contains(needle)
}

/// Non-fatal note on whether the `pin-boxes` view is reachable by a cross-process AX reader.
/// It is not, as the boxes stand (see `waitForControlGone`); printed so the gate's own output
/// documents the T06/T07 finding rather than leaving it to a comment.
func notePINBoxesReachability(app: AXUIElement) {
    let reachable = axWindows(app).contains { find(in: $0, identifier: axPINBoxes) != nil }
    print("  note: pin-boxes reachable via AX = \(reachable ? "yes" : "no") — the gate types blind to the key window")
}

// MARK: - Scenarios

/// One line of gate output, so a green run reads as a short checklist and a failure names the
/// scenario and the reason.
func report(_ passed: Bool, _ name: String, _ detail: String) {
    print("\(passed ? "PASS" : "FAIL") — \(name): \(detail)")
}

/// A real Start click lifts the boxed cover and logs the self-service grant.
func scenarioStart(appPath: String) -> Bool {
    let dataDir = scratchBase.appendingPathComponent("start")
    seedConfig(dataDir: dataDir, selfService: 1)
    let app = launchApp(appPath: appPath, dataDir: dataDir)
    defer { app.terminate(); app.waitUntilExit() }
    let element = AXUIElementCreateApplication(app.processIdentifier)

    guard let start = waitForControl(app: element, identifier: axStart, timeout: 12) else {
        report(false, "start", "the Start button never appeared (\(dataDir.path))")
        return false
    }
    guard clickCentre(of: start) else {
        report(false, "start", "could not read the Start button's frame")
        return false
    }
    let lifted = waitForNoWindows(app: element, timeout: 12)
    let logged = eventCount(dataDir: dataDir, type: "session_start") >= 1
    let passed = lifted && logged
    report(passed, "start",
           passed ? "click lifted the cover and logged session_start"
                  : "cover lifted=\(lifted), session_start logged=\(logged) (\(dataDir.path))")
    return passed
}

/// A wrong PIN leaves the cover up and logs no grant. The correct PIN is not typed here, so an
/// `extended` line would mean the wrong PIN was accepted.
func scenarioWrongPIN(appPath: String) -> Bool {
    let dataDir = scratchBase.appendingPathComponent("wrong-pin")
    seedConfig(dataDir: dataDir, selfService: 0)
    let app = launchApp(appPath: appPath, dataDir: dataDir)
    defer { app.terminate(); app.waitUntilExit() }
    let element = AXUIElementCreateApplication(app.processIdentifier)

    guard let pinButton = waitForControl(app: element, identifier: axPIN, timeout: 12),
          clickCentre(of: pinButton) else {
        report(false, "wrong-pin", "the PIN button never appeared or had no frame (\(dataDir.path))")
        return false
    }
    guard waitForControlGone(app: element, identifier: axPIN, timeout: 6) else {
        report(false, "wrong-pin", "the PIN prompt did not open — PIN button still present (\(dataDir.path))")
        return false
    }
    notePINBoxesReachability(app: element)
    typePIN(wrongPIN)
    // Let the off-main verification run (~1s in debug) and reject before asserting.
    Thread.sleep(forTimeInterval: 3)
    let stillUp = !axWindows(element).isEmpty
    let noGrant = eventCount(dataDir: dataDir, type: "extended") == 0
    // The rejection line proves the four digits actually reached the field — without it a
    // "cover still up, nothing granted" pass would also hold if no keystroke ever landed.
    let rejected = appLogContains(dataDir: dataDir, "pin: rejected")
    let passed = stillUp && noGrant && rejected
    report(passed, "wrong-pin",
           passed ? "wrong PIN reached the field, was rejected, cover held, nothing granted"
                  : "cover still up=\(stillUp), no extended=\(noGrant), rejection logged=\(rejected) (\(dataDir.path))")
    return passed
}

/// The correct PIN, then a click on `+15`, lifts the cover and logs the grant.
func scenarioRightPIN(appPath: String) -> Bool {
    let dataDir = scratchBase.appendingPathComponent("right-pin")
    seedConfig(dataDir: dataDir, selfService: 0)
    let app = launchApp(appPath: appPath, dataDir: dataDir)
    defer { app.terminate(); app.waitUntilExit() }
    let element = AXUIElementCreateApplication(app.processIdentifier)

    guard let pinButton = waitForControl(app: element, identifier: axPIN, timeout: 12),
          clickCentre(of: pinButton) else {
        report(false, "right-pin", "the PIN button never appeared or had no frame (\(dataDir.path))")
        return false
    }
    guard waitForControlGone(app: element, identifier: axPIN, timeout: 6) else {
        report(false, "right-pin", "the PIN prompt did not open — PIN button still present (\(dataDir.path))")
        return false
    }
    notePINBoxesReachability(app: element)
    typePIN(correctPIN)

    // After the correct PIN verifies (~1s off-main) the prompt swaps to the amount buttons. No
    // amount answers Return (sort-grant-amounts), so the grant is a click on `amount-15`.
    guard let amount = waitForControl(app: element, identifier: "amount-15", timeout: 12),
          clickCentre(of: amount) else {
        report(false, "right-pin", "the +15 button never appeared or had no frame (\(dataDir.path))")
        return false
    }
    let deadline = Date().addingTimeInterval(8)
    var granted = false
    repeat {
        if eventCount(dataDir: dataDir, type: "extended") >= 1 { granted = true; break }
        usleep(300_000)
    } while Date() < deadline

    let lifted = waitForNoWindows(app: element, timeout: 8)
    let passed = granted && lifted
    report(passed, "right-pin",
           passed ? "PIN accepted, amount confirmed, cover lifted and logged extended"
                  : "extended logged=\(granted), cover lifted=\(lifted) (\(dataDir.path))")
    return passed
}

/// `Wyloguj` asks before it acts: cancel leaves no `logged_out`; confirm writes exactly one and
/// reaches the performer, which is a dry run here (`RST_LOGOUT_DRY_RUN=1`, `launchApp`). The
/// face comes back after either answer, and the cover never lifts.
func scenarioLogout(appPath: String) -> Bool {
    let dataDir = scratchBase.appendingPathComponent("logout")
    seedConfig(dataDir: dataDir, selfService: 0)
    let app = launchApp(appPath: appPath, dataDir: dataDir)
    defer { app.terminate(); app.waitUntilExit() }
    let element = AXUIElementCreateApplication(app.processIdentifier)

    func fail(_ why: String) -> Bool {
        report(false, "logout", "\(why) (\(dataDir.path))")
        return false
    }

    // Cancel first.
    guard let logout = waitForControl(app: element, identifier: axLogout, timeout: 12),
          clickCentre(of: logout) else { return fail("the Wyloguj button never appeared or had no frame") }
    guard let cancel = waitForControl(app: element, identifier: axLogoutCancel, timeout: 6),
          waitForControl(app: element, identifier: axLogoutConfirm, timeout: 1) != nil,
          clickCentre(of: cancel) else { return fail("the confirmation did not open after Wyloguj") }
    guard let again = waitForControl(app: element, identifier: axLogout, timeout: 6) else {
        return fail("Anuluj did not bring the face back")
    }
    guard eventCount(dataDir: dataDir, type: "logged_out") == 0 else {
        return fail("Anuluj wrote a logged_out event")
    }

    // Then confirm.
    guard clickCentre(of: again),
          let confirm = waitForControl(app: element, identifier: axLogoutConfirm, timeout: 6),
          clickCentre(of: confirm) else { return fail("the confirmation did not reopen, or Wyloguj had no frame") }
    let deadline = Date().addingTimeInterval(6)
    while eventCount(dataDir: dataDir, type: "logged_out") == 0 && Date() < deadline { usleep(200_000) }
    let faceBack = waitForControl(app: element, identifier: axLogout, timeout: 6) != nil
    let events = eventCount(dataDir: dataDir, type: "logged_out")
    let dryRun = appLogContains(dataDir: dataDir, "logout: dry run")
    let stillUp = !axWindows(element).isEmpty
    let passed = events == 1 && dryRun && faceBack && stillUp
    report(passed, "logout",
           passed ? "cancel wrote nothing; confirm logged one logged_out, dry-ran, face back, cover held"
                  : "logged_out=\(events), dry run logged=\(dryRun), face back=\(faceBack), cover up=\(stillUp) (\(dataDir.path))")
    return passed
}

// MARK: - Grant gate and run

/// Print exactly which binary to grant and where. Nothing is launched and no cover is shown from
/// this path, so an ungranted first run is safe and self-explaining (it is also T07's fourth
/// assertion, verified on the very first invocation before the grant exists).
func printGrantInstructions() {
    let binary = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "the driver binary"
    FileHandle.standardError.write(Data("""
        RSTUIDriver is not trusted for Accessibility, so it cannot post real clicks or
        keystrokes. Grant this exact binary, then run `make ui-gate` again:

            \(binary)

        System Settings ▸ Privacy & Security ▸ Accessibility ▸ + ▸ add the binary above ▸
        turn it on. (A rebuild that changes the binary may need the grant again — see
        plans/headed-and-e2e-tests/FINDINGS.md.)

        Nothing was launched and no cover was shown.

        """.utf8))
}

// argv[1] is the built app binary, passed by `make ui-gate`.
guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: RSTUIDriver <path-to-RealScreenTime>\n".utf8))
    exit(64) // EX_USAGE
}
let appPath = CommandLine.arguments[1]
guard FileManager.default.isExecutableFile(atPath: appPath) else {
    FileHandle.standardError.write(Data("not an executable: \(appPath)\n".utf8))
    exit(64)
}

// The grant check, with the system prompt as a courtesy on the first run. If it is not trusted,
// exit before launching anything — posting events that silently do nothing would look like a
// broken cover rather than a missing permission.
// The key is `kAXTrustedCheckOptionPrompt`, but that symbol is a mutable CFString global the
// Swift 6 concurrency checker refuses to touch; its documented value is this literal.
let promptOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
guard AXIsProcessTrustedWithOptions(promptOptions) else {
    printGrantInstructions()
    exit(2)
}

try? FileManager.default.createDirectory(at: scratchBase, withIntermediateDirectories: true)
print("RSTUIDriver — boxed (\(coverFrame)), enforcing, \(seatbeltSeconds)s seatbelt, scratch data dir per scenario.")

// Run every scenario even if one fails, so a first hand-run pass shows the whole picture rather
// than stopping at the first red.
let results = [
    scenarioStart(appPath: appPath),
    scenarioWrongPIN(appPath: appPath),
    scenarioRightPIN(appPath: appPath),
    scenarioLogout(appPath: appPath),
]

let passedAll = results.allSatisfy { $0 }
if passedAll {
    try? FileManager.default.removeItem(at: scratchBase)
    print("ui-gate: all \(results.count) scenarios passed.")
    exit(0)
} else {
    let failed = results.filter { !$0 }.count
    print("ui-gate: \(failed) of \(results.count) scenarios failed — scratch dirs left under \(scratchBase.path)")
    exit(1)
}
