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
// key goes down, it waits for the text, then puts focus and the caret back where
// the hold began so the caller's ordinary Cmd+V lands there.
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

/// The focused element of an app — the frontmost one unless a pid is given.
///
/// Asks the APPLICATION element. The system-wide element is the usual way to ask
/// "what is focused", and on this machine it fails with cannotComplete (-25204) on
/// every call, for every app, with Accessibility granted. That one failure is why
/// field capture failed on all 661 dictations it was tried on, and why the "is a
/// text field focused" check always answered UNKNOWN. The same question put to an
/// application element answers at once.
///
/// The frontmost app comes from NSWorkspace. That goes stale in a long-lived
/// process with no run loop, but every mode of this tool is launched fresh at the
/// moment it asks, so here it is current.
func focusedElement(pid: pid_t? = nil) -> AXUIElement? {
    guard let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
        lastAXStage = "frontmost-app"
        return nil
    }
    let app = AXUIElementCreateApplication(pid)
    enableAX(app, pid)
    var v: CFTypeRef?
    lastAXError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v)
    lastAXStage = "focused-element-of-app"
    guard lastAXError == .success, let v = v else { return nil }
    return (v as! AXUIElement)
}

/// Whether text can be typed into this element.
///
/// The role catches ordinary fields. The fallbacks catch editors built on
/// contenteditable, which a web app can expose under a generic role: anything
/// whose caret can be placed, or whose string value can be written, takes text.
func acceptsText(_ el: AXUIElement, role: String) -> Bool {
    if role.contains("Text") || role == (kAXComboBoxRole as String) { return true }
    if axSettable(el, kAXSelectedTextRangeAttribute as String) { return true }
    return axSettable(el, kAXValueAttribute as String)
        && axAttr(el, kAXValueAttribute as String) is String
}

enum Return { case unmoved, restored, failed(String) }

/// Put focus back in the field the hold started in, with the caret where it was.
///
/// If focus never left the field, nothing is touched: the caret may have moved
/// inside it on purpose, and the paste should follow it there. Only when focus has
/// gone somewhere else is the field refocused and the saved caret put back.
func returnFocus(to field: AXUIElement, caret: CFTypeRef?) -> Return {
    var pid: pid_t = 0
    guard AXUIElementGetPid(field, &pid) == .success else { return .failed("FIELD_HAS_NO_APP") }

    // Web apps rebuild parts of the page as it re-renders, which can destroy the
    // very node that was captured. There is then nothing to return to.
    var probe: CFTypeRef?
    if AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &probe) == .invalidUIElement {
        return .failed("FIELD_GONE")
    }

    let app = AXUIElementCreateApplication(pid)
    enableAX(app, pid)
    let frontmost = (axAttr(app, kAXFrontmostAttribute as String) as? Bool) ?? false
    if frontmost, let now = focusedElement(pid: pid), CFEqual(now, field) { return .unmoved }

    if !frontmost, let running = NSRunningApplication(processIdentifier: pid) {
        running.activate(options: [.activateIgnoringOtherApps])
        usleep(200_000)
    }
    // A field in another window of the same app needs that window brought forward
    // first: focusing an element inside a background window is quietly ignored.
    if let w = axAttr(field, kAXWindowAttribute as String) {
        let window = w as! AXUIElement
        let current = axAttr(app, kAXFocusedWindowAttribute as String)
        if current == nil || !CFEqual(current!, window) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            usleep(120_000)
        }
    }
    let setErr = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard setErr == .success else { return .failed("SET_FOCUS_REFUSED:\(setErr.rawValue)") }
    usleep(120_000)

    // Refocusing a field puts the caret wherever the app decides — often the end,
    // sometimes selecting everything. Put back the position it had at hold start.
    if let caret = caret, axSettable(field, kAXSelectedTextRangeAttribute as String) {
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, caret)
    }

    guard let now = focusedElement(pid: pid) else { return .failed("FOCUS_UNREADABLE_AFTER_SET") }
    return CFEqual(now, field) ? .restored : .failed("FOCUS_WENT_ELSEWHERE")
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

    // Short budget: this sits on the paste path, and a slow answer costs the user
    // more than a missing one. The tree is primed at hold start, so by now it is
    // usually warm.
    var role: String?
    var focused: AXUIElement?
    var budget = 0.5
    if let i = args.firstIndex(of: "--focus-kind"), i + 1 < args.count,
       let v = Double(args[i + 1]) { budget = v }
    let deadline = Date().addingTimeInterval(budget)
    repeat {
        if let el = focusedElement(),
           let r = axAttr(el, kAXRoleAttribute as String) as? String {
            role = r
            focused = el
            break
        }
        usleep(60_000)
    } while Date() < deadline

    guard let role = role, let focused = focused else {
        print("UNKNOWN")
        FileHandle.standardError.write(
            "stage=\(lastAXStage) AXError=\(lastAXError.rawValue) trusted=\(trusted)\n"
                .data(using: .utf8)!)
        exit(2)
    }
    if acceptsText(focused, role: role) {
        print("TEXT")
        exit(0)
    }
    print("NOT_TEXT:\(role)")
    exit(1)
}

// --capture <handoff-path>: hold the focused field, then return focus to it.
//   exit 4 — focus is in the field the hold started in; the caller's Cmd+V lands
//            there. stdout says UNMOVED (it never left) or RESTORED (it was put back)
//   exit 3 — could not; the caller should fall back to activate-app + Cmd+V
//
// Delivery is always the caller's Cmd+V, never a direct accessibility write.
// Writing the selected-text attribute reports success in Chromium editors without
// always inserting anything, and a false success here means a lost dictation,
// because the caller would skip its paste. Cmd+V into a focused field is the path
// every dictation has used, so this only decides WHERE it lands.
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
    // Keep asking for several seconds. Switching a Chromium app's accessibility
    // tree on is not instant, and its first answers come back as cannotComplete
    // while it is still being built — 1.5s of trying was not enough, and reported
    // "no focused field" for a field that was plainly focused. This costs nothing:
    // the hold is still in progress and this process is doing nothing else.
    //
    // Stops early in two cases. If the text arrives first, the hold was short and
    // the caller is already waiting — carrying on here is what used to stall a
    // paste by 2.5s. And a steady non-text answer is an answer: a canvas stays a
    // canvas, so after a second and a half there is nothing more to wait for.
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var captured: AXUIElement?
    var lastRole = ""
    var firstNonText: Date?
    let findDeadline = Date().addingTimeInterval(6.0)
    repeat {
        if FileManager.default.fileExists(atPath: handoff) { break }
        if let el = focusedElement(pid: pid) {
            let role = (axAttr(el, kAXRoleAttribute as String) as? String) ?? ""
            lastRole = role
            // Only elements that take text: capturing a button or a canvas would
            // restore focus somewhere the text could never land.
            if acceptsText(el, role: role) {
                captured = el
                break
            }
            if firstNonText == nil { firstNonText = Date() }
            if let t = firstNonText, -t.timeIntervalSinceNow > 1.5 { break }
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
    // Where the caret sits now, to put it back if focus wanders off and returns.
    let caret = axAttr(field, kAXSelectedTextRangeAttribute as String)

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

    _ = text   // the caller pastes it; the file's arrival is the signal

    switch returnFocus(to: field, caret: caret) {
    case .unmoved:  print("UNMOVED:\(lastRole)");  exit(4)
    case .restored: print("RESTORED:\(lastRole)"); exit(4)
    case .failed(let why):
        FileHandle.standardError.write((why + "\n").data(using: .utf8)!)
        exit(3)
    }
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
