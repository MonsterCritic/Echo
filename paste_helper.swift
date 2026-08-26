// paste_helper.swift — focus the target app (only if focus drifted) and send
// Cmd+V, using CGEvent + NSWorkspace instead of osascript → System Events.
//
// Why: System Events has a multi-second cold-start when the machine is under
// load (locationd/fileproviderd/Spotlight churn), and that landed directly on
// AI Dictate's paste step. CGEvent key posting and NSWorkspace activation have
// no such dependency, so the paste stays ~instant regardless of system load.
//
// Usage:
//   paste_helper [target-app-name]   focus target if needed, then Cmd+V
//   paste_helper --copy              send Cmd+C to the current frontmost app
//   paste_helper --check             report Accessibility status, never prompts
//   paste_helper --grant             report status AND raise the system prompt
//
// Prints the app that was frontmost before the keystroke (for the caller's log).
// If Accessibility isn't granted yet it writes ACCESSIBILITY_NOT_GRANTED to
// stderr and exits 2, so callers can fall back to the osascript path until the
// user grants it.

import AppKit
import ApplicationServices
import CoreGraphics

// ── Focused-field capture (--capture) ────────────────────────────────────────
// Pasting has always targeted the frontmost APP, so leaving the input you started
// dictating in — without leaving the app — is invisible to it: the text goes
// wherever focus happens to be. Targeting the field itself means holding on to
// the focused accessibility element for the length of the hold.
//
// That reference cannot be handed between processes, and the field usually has no
// stable identifier to look up later (measured: the Claude Code input exposes
// neither an id nor a label). So one process has to capture at hold start and
// still be alive at paste time — which is what this mode is: launched when the
// key goes down, it waits for the text and then puts it where the hold began.
// Deliberately left on the default timeout. Calling AXUIElementSetMessagingTimeout
// on the SYSTEM-WIDE element sets a global default for every element in the
// process, and doing so here made every query fail with cannotComplete — no
// focused element could be read from any app at all, for four seconds at a
// stretch, while the same code without it answers immediately. Per-application
// elements get their timeout raised individually in enableAX.
let systemWide = AXUIElementCreateSystemWide()
var axEnabled = Set<pid_t>()

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

func axSettable(_ el: AXUIElement, _ name: String) -> Bool {
    var s: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(el, name as CFString, &s) == .success else { return false }
    return s.boolValue
}

/// Chromium apps keep their accessibility tree off until an assistive client asks
/// for it, via this private attribute — without it the focused element cannot be
/// read from Claude Code, VS Code, Slack or a browser at all.
func enableAX(_ app: AXUIElement, _ pid: pid_t) {
    // The timeout is a property of THIS element instance, not of the app, so it
    // has to be set on every element we are about to query. Skipping it for an app
    // already primed left the element doing the real work on the default deadline,
    // which expires while a Chromium tree is still being built — reported as
    // cannotComplete, i.e. "no focused field" for a field that was clearly focused.
    AXUIElementSetMessagingTimeout(app, 2.0)
    guard !axEnabled.contains(pid) else { return }
    axEnabled.insert(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

/// Why the last lookup failed, so a refusal can be told from an empty result.
var lastAXError: AXError = .success
var lastAXStage = ""

/// Switch on the frontmost app's accessibility tree before asking it anything.
///
/// There is a cycle otherwise: AXManualAccessibility has to be set on the
/// application element, but finding that element by asking the accessibility layer
/// which app is focused fails with cannotComplete precisely while the tree is
/// still off. Seeding from NSWorkspace breaks it. This runs once, at hold start,
/// in a process that has just launched — so NSWorkspace's answer is current, which
/// it would not be in a long-lived watcher with no run loop.
func primeFrontmostApp() {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
    let app = AXUIElementCreateApplication(pid)
    enableAX(app, pid)
}

func focusedElement() -> AXUIElement? {
    // Ask the focused application, not NSWorkspace: NSWorkspace tracks the
    // frontmost app through run-loop notifications this tool does not have.
    var appV: CFTypeRef?
    lastAXError = AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedApplicationAttribute as CFString, &appV)
    lastAXStage = "focused-app"
    if lastAXError == .success, let appV = appV {
        let app = appV as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(app, &pid) == .success { enableAX(app, pid) }
        var v: CFTypeRef?
        lastAXError = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &v)
        lastAXStage = "focused-element-of-app"
        if lastAXError == .success, let v = v { return (v as! AXUIElement) }
    }
    var v: CFTypeRef?
    lastAXError = AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedUIElementAttribute as CFString, &v)
    lastAXStage = "focused-element-systemwide"
    guard lastAXError == .success, let v = v else { return nil }
    return (v as! AXUIElement)
}

/// Bring the field's app forward, then ask the field itself for focus, and only
/// report success if it actually took it.
func restoreFocus(to el: AXUIElement) -> Bool {
    var pid: pid_t = 0
    if AXUIElementGetPid(el, &pid) == .success,
       let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
        app.activate(options: [.activateIgnoringOtherApps])
        usleep(200_000)
    }
    let setErr = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard setErr == .success else {
        FileHandle.standardError.write("SET_FOCUS_REFUSED:\(setErr.rawValue)\n".data(using: .utf8)!)
        return false
    }
    usleep(120_000)
    guard let now = focusedElement() else {
        FileHandle.standardError.write("FOCUS_UNREADABLE_AFTER_SET\n".data(using: .utf8)!)
        return false
    }
    if CFEqual(now, el) { return true }
    FileHandle.standardError.write("FOCUS_WENT_ELSEWHERE\n".data(using: .utf8)!)
    return false
}

/// Write straight into the field, which skips the clipboard entirely — no saving
/// and restoring, and nothing of yours is overwritten even briefly.
func insert(_ text: String, into el: AXUIElement) -> Bool {
    guard axSettable(el, kAXSelectedTextAttribute as String) else { return false }
    return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString,
                                        text as CFTypeRef) == .success
}

let args = CommandLine.arguments
let checkOnly = args.contains("--check")
let grantMode = args.contains("--grant")
let copyMode  = args.contains("--copy")
let target = (args.count > 1 && !args[1].hasPrefix("--")) ? args[1] : ""

let ws = NSWorkspace.shared
let frontBefore = ws.frontmostApplication?.localizedName ?? ""

// Accessibility is required to post key events.
//
// Only --grant may raise the system prompt. Everything else checks silently,
// because macOS attributes Accessibility to the RESPONSIBLE process, not to this
// binary: when AI Rewrite runs us from its Automator Quick Action, the
// responsible process is WorkflowServiceRunner.xpc. Prompting there produced a
// recurring "WorkflowServiceRunner.xpc would like to control this Mac" dialog
// naming a system XPC service the user cannot usefully grant — while the paste
// itself still succeeded via the caller's osascript fallback. So: never prompt
// on the normal path, just report untrusted and let the caller fall back.
let trusted: Bool = {
    if grantMode {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
    return AXIsProcessTrusted()
}()

if checkOnly || grantMode {
    print(trusted ? "TRUSTED" : "NOT_TRUSTED")
    exit(trusted ? 0 : 2)
}

// --focus-kind: is a text field focused right now?
//   prints TEXT / NOT_TEXT:<role> / UNKNOWN, and exits 0 / 1 / 2 respectively.
//
// Used to decide whether pasting is safe. If the caller pastes while no text
// field has focus, the keystroke goes wherever it lands — into a page, a canvas,
// or a shortcut — and the dictation is simply gone. UNKNOWN is deliberately its
// own answer rather than being folded into NOT_TEXT: not knowing is not the same
// as knowing there is nowhere to type, and the caller should carry on as before
// rather than change behaviour on a failed reading.
if args.contains("--focus-kind") {
    guard trusted else { print("UNKNOWN"); exit(2) }
    primeFrontmostApp()

    // Short budget: this sits on the paste path, and a slow answer costs the user
    // more than a missing one. The tree is primed at hold start, so by now it is
    // usually warm.
    var role: String?
    var budget = 0.5
    if let i = args.firstIndex(of: "--focus-kind"), i + 1 < args.count,
       let v = Double(args[i + 1]) { budget = v }
    let deadline = Date().addingTimeInterval(budget)
    repeat {
        if let el = focusedElement(),
           let r = axAttr(el, kAXRoleAttribute as String) as? String {
            role = r
            break
        }
        usleep(60_000)
    } while Date() < deadline

    guard let role = role else {
        print("UNKNOWN")
        FileHandle.standardError.write(
            "stage=\(lastAXStage) AXError=\(lastAXError.rawValue) trusted=\(trusted)\n"
                .data(using: .utf8)!)
        exit(2)
    }
    if role.contains("Text") || role == (kAXComboBoxRole as String) {
        print("TEXT")
        exit(0)
    }
    print("NOT_TEXT:\(role)")
    exit(1)
}

// --capture <handoff-path>: hold the focused field, then place the text in it.
//   exit 0 — text inserted into the field the hold started in
//   exit 3 — could not; the caller should fall back to activate-app + Cmd+V
if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
    let handoff = args[i + 1]
    guard trusted else {
        FileHandle.standardError.write("ACCESSIBILITY_NOT_GRANTED\n".data(using: .utf8)!)
        exit(2)
    }
    // Poll briefly rather than reading once. This starts a fraction of a second
    // into the hold, and an app asked for its focused element the instant it comes
    // forward — or the first time its accessibility tree is switched on — can
    // answer with nothing before it settles. A single read turned a perfectly
    // focused TextEdit document into NO_FOCUSED_FIELD.
    primeFrontmostApp()

    // Keep asking for several seconds. Switching a Chromium app's accessibility
    // tree on is not instant, and its first answers come back as cannotComplete
    // while it is still being built — 1.5s of trying was not enough, and reported
    // "no focused field" for a field that was plainly focused. This costs nothing:
    // the hold is still in progress and this process is doing nothing else.
    var captured: AXUIElement?
    var lastRole = ""
    var reprimeAt = Date().addingTimeInterval(1.0)
    let findDeadline = Date().addingTimeInterval(6.0)
    repeat {
        if Date() > reprimeAt {          // the tree may have been switched off again
            primeFrontmostApp()
            reprimeAt = Date().addingTimeInterval(1.0)
        }
        if let el = focusedElement() {
            let role = (axAttr(el, kAXRoleAttribute as String) as? String) ?? ""
            lastRole = role
            // Only text-ish elements: capturing a button or a canvas would restore
            // focus somewhere the text could never land.
            if role.contains("Text") || role == (kAXComboBoxRole as String) {
                captured = el
                break
            }
        }
        usleep(100_000)
    } while Date() < findDeadline

    guard let field = captured else {
        let detail = lastRole.isEmpty
            ? "NO_FOCUSED_FIELD (\(lastAXStage) → AXError \(lastAXError.rawValue))"
            : "NOT_A_TEXT_FIELD:\(lastRole)"
        FileHandle.standardError.write((detail + "\n").data(using: .utf8)!)
        exit(3)
    }
    let role = lastRole
    print("CAPTURED:\(role)")

    // Wait for the dictation to finish. The caller writes the handoff atomically,
    // so seeing the file means the whole text is there.
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline && !FileManager.default.fileExists(atPath: handoff) {
        usleep(40_000)
    }
    guard let text = try? String(contentsOfFile: handoff, encoding: .utf8) else {
        exit(3)   // never arrived: the hold was abandoned, or dictation produced nothing
    }
    try? FileManager.default.removeItem(atPath: handoff)

    guard restoreFocus(to: field) else {
        FileHandle.standardError.write("FOCUS_NOT_RESTORED\n".data(using: .utf8)!)
        exit(3)
    }
    guard insert(text, into: field) else {
        // Focus is back on the right field, so the caller's Cmd+V will now land
        // in the right place even though direct insertion was refused.
        FileHandle.standardError.write("FOCUS_RESTORED_BUT_NOT_WRITABLE\n".data(using: .utf8)!)
        exit(4)
    }
    exit(0)
}

print(frontBefore)   // stdout → caller logs this

if !trusted {
    FileHandle.standardError.write("ACCESSIBILITY_NOT_GRANTED\n".data(using: .utf8)!)
    exit(2)
}

// Paste only: reactivate the target if focus drifted (an unnecessary switch is
// slow and can disturb the caret). Copy acts on the current frontmost app, so
// it never activates anything.
if !copyMode && !target.isEmpty && target != frontBefore {
    if let app = ws.runningApplications.first(where: { $0.localizedName == target }) {
        app.activate(options: [.activateIgnoringOtherApps])
        usleep(180_000)   // let the app take focus before the keystroke lands
    }
}

// Post Cmd+C (copy) or Cmd+V (paste). Post EXPLICIT Command key down/up around
// the letter (not just the .maskCommand flag) — Electron apps (Claude Desktop,
// VS Code) frequently ignore the flag-only form and need a real modifier event.
let src = CGEventSource(stateID: .combinedSessionState)
let cmdKey: CGKeyCode = 0x37                      // Left Command
let letter: CGKeyCode = copyMode ? 0x08 : 0x09    // 'c' : 'v'

let cmdDown  = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true)
let keyDown  = CGEvent(keyboardEventSource: src, virtualKey: letter, keyDown: true)
let keyUp    = CGEvent(keyboardEventSource: src, virtualKey: letter, keyDown: false)
let cmdUp    = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false)

keyDown?.flags = .maskCommand
keyUp?.flags   = .maskCommand

cmdDown?.post(tap: .cghidEventTap); usleep(8_000)
keyDown?.post(tap: .cghidEventTap); usleep(8_000)
keyUp?.post(tap: .cghidEventTap);   usleep(8_000)
cmdUp?.post(tap: .cghidEventTap)
