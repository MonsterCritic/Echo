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

/// Where the captioned field sits on screen, for placing the caption beside it.
/// Accessibility coordinates: top-left origin of the main display.
let fieldFramePath = "/tmp/rewrite_field_frame"

/// The rectangle the caption should keep clear of.
///
/// The field's own frame when it is believable. Some report nonsense — TextEdit
/// gives its whole scrolling document, thousands of points tall and partly
/// off-screen — and for those the line the caret is on is the honest answer.
func fieldAnchor(_ field: AXUIElement, caret: CFTypeRef?) -> CGRect? {
    let screens = NSScreen.screens
    let h0 = screens.first?.frame.height ?? 0
    func onScreen(_ r: CGRect) -> Bool {
        let cocoa = CGRect(x: r.minX, y: h0 - r.maxY, width: r.width, height: r.height)
        return screens.contains { $0.frame.contains(cocoa) }
    }
    if let r = AwaitField.axFrame(field), r.height <= 400, onScreen(r) { return r }
    if let caret = caret {
        var v: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
               field, kAXBoundsForRangeParameterizedAttribute as CFString, caret, &v) == .success,
           let v = v {
            var r = CGRect.zero
            if AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 0, r.height <= 200,
               onScreen(r.insetBy(dx: -1, dy: 0)) {
                return r
            }
        }
    }
    return nil
}

enum Return { case unmoved, restored, failed(String) }

/// Progress for the caller's log. If this process is killed for taking too long,
/// the last stage written is where it was stuck.
func stage(_ name: String) {
    FileHandle.standardError.write("stage:\(name)\n".data(using: .utf8)!)
}

/// Put focus back in the field the hold started in, with the caret where it was.
///
/// If focus never left the field, nothing is touched: the caret may have moved
/// inside it on purpose, and the paste should follow it there. Only when focus has
/// gone somewhere else is the field refocused and the saved caret put back.
func returnFocus(to field: AXUIElement, caret: CFTypeRef?) -> Return {
    var pid: pid_t = 0
    guard AXUIElementGetPid(field, &pid) == .success else { return .failed("FIELD_HAS_NO_APP") }
    // Short deadlines from here on: the paste is waiting. An app that does not
    // answer within half a second is treated as gone, not waited on for the
    // system default of several seconds — which is what stalled 8% of pastes.
    AXUIElementSetMessagingTimeout(field, 0.5)
    stage("probe-field")

    // Web apps rebuild parts of the page as it re-renders, which can destroy the
    // very node that was captured. There is then nothing to return to.
    var probe: CFTypeRef?
    if AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &probe) == .invalidUIElement {
        return .failed("FIELD_GONE")
    }

    let app = AXUIElementCreateApplication(pid)
    enableAX(app, pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    stage("check-focus")
    let frontmost = (axAttr(app, kAXFrontmostAttribute as String) as? Bool) ?? false
    if frontmost, let now = focusedElement(pid: pid), CFEqual(now, field) { return .unmoved }

    if !frontmost, let running = NSRunningApplication(processIdentifier: pid) {
        stage("activate-app")
        running.activate(options: [.activateIgnoringOtherApps])
        usleep(200_000)
    }
    stage("raise-window")
    // A field in another window of the same app needs that window brought forward
    // first: focusing an element inside a background window is quietly ignored.
    if let w = axAttr(field, kAXWindowAttribute as String) {
        let window = w as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        let current = axAttr(app, kAXFocusedWindowAttribute as String)
        if current == nil || !CFEqual(current!, window) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            usleep(120_000)
        }
    }
    stage("focus-field")
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

    // Tell the caption where the field is, so it can sit beside it instead of
    // over it. Written the moment the field is known — the caption appears a
    // few hundred ms later, once audio is flowing.
    if let r = fieldAnchor(field, caret: caret) {
        try? "\(r.origin.x) \(r.origin.y) \(r.width) \(r.height)\n"
            .write(toFile: fieldFramePath, atomically: true, encoding: .utf8)
    }

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

// --await-field <seconds> <preview>: hold a dictation until a text field is
// clicked, for when it ended with no field focused.
//   exit 0 — a field was clicked into and has focus; stdout FIELD:<role>. The
//            caller pastes, so the text lands there.
//   exit 5 — timed out
//   exit 6 — cancelled with Esc
//   (a newer dictation ends this with SIGTERM; the caller treats that as superseded)
//
// Recording often starts before the destination is chosen. Leaving the result on
// the clipboard means remembering to paste it, and it displaces whatever was
// there; holding it until the next field is clicked puts it where you choose.
//
// Only a CLICK inside a field counts, not any focus change. Apps move focus into
// fields on their own — a new browser tab focuses its address bar, a dialog its
// first input — and those would take the text before a choice was made.
if let i = args.firstIndex(of: "--await-field") {
    guard trusted else {
        FileHandle.standardError.write("ACCESSIBILITY_NOT_GRANTED\n".data(using: .utf8)!)
        exit(2)
    }
    let seconds = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 60
    let preview = i + 2 < args.count ? args[i + 2] : ""
    AwaitField.run(seconds: seconds, preview: preview)
}

// --pin-chat <path>: remember the Claude Code chat whose message box has focus.
//   exit 0 — written to <path> as {"url","title"}; stdout the title
//   exit 3 — focus is not inside a Claude chat
//
// A chat is identified by its web area's address, claude.ai/epitaxy/<session>,
// which is stable for the chat's life — unlike the text box element, which the
// app rebuilds whenever the chat is switched away from and back.
if let i = args.firstIndex(of: "--pin-chat"), i + 1 < args.count {
    guard trusted else { FileHandle.standardError.write("ACCESSIBILITY_NOT_GRANTED\n".data(using: .utf8)!); exit(2) }
    guard let el = focusedElement(), let (url, title) = enclosingChat(of: el) else {
        FileHandle.standardError.write("NOT_IN_A_CLAUDE_CHAT\n".data(using: .utf8)!)
        exit(3)
    }
    let json = try! JSONSerialization.data(withJSONObject: ["url": url, "title": title])
    try? json.write(to: URL(fileURLWithPath: args[i + 1]), options: .atomic)
    print(title)
    exit(0)
}

// --send-to-chat <url>: paste the clipboard into that chat's message box, press
// Return, then give focus back to wherever it was.
//   exit 0 — sent
//   exit 3 — the chat is not on screen in any Claude window (stderr says why)
//
// The clipboard already holds the text; the caller restores it afterwards.
if let i = args.firstIndex(of: "--send-to-chat"), i + 1 < args.count {
    guard trusted else { FileHandle.standardError.write("ACCESSIBILITY_NOT_GRANTED\n".data(using: .utf8)!); exit(2) }
    let wanted = args[i + 1]
    guard let claude = NSWorkspace.shared.runningApplications.first(where: {
              $0.bundleIdentifier == "com.anthropic.claudefordesktop" }) else {
        FileHandle.standardError.write("CLAUDE_NOT_RUNNING\n".data(using: .utf8)!); exit(3)
    }
    let pid = claude.processIdentifier
    let appEl = AXUIElementCreateApplication(pid)
    enableAX(appEl, pid)
    guard let (window, box) = findChatBox(in: appEl, url: wanted) else {
        FileHandle.standardError.write("CHAT_NOT_ON_SCREEN\n".data(using: .utf8)!); exit(3)
    }
    if args.contains("--dry") { print("FOUND"); exit(0) }   // lookup only, for testing

    // Where to come back to.
    let prevApp = NSWorkspace.shared.frontmostApplication
    let prevField = focusedElement()

    if !claude.isActive { claude.activate(options: [.activateIgnoringOtherApps]); usleep(200_000) }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    usleep(100_000)
    AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    guard let now = focusedElement(pid: pid), CFEqual(now, box) else {
        FileHandle.standardError.write("COULD_NOT_FOCUS_THE_BOX\n".data(using: .utf8)!); exit(3)
    }
    // Append after whatever is already typed there rather than replacing it.
    if let v = axAttr(box, kAXNumberOfCharactersAttribute as String) as? Int {
        var r = CFRange(location: v, length: 0)
        if let end = AXValueCreate(.cfRange, &r) {
            AXUIElementSetAttributeValue(box, kAXSelectedTextRangeAttribute as CFString, end)
        }
    }
    postKey(0x09, command: true)      // Cmd+V
    usleep(250_000)                   // let the editor take the paste before submitting
    postKey(0x24, command: false)     // Return
    usleep(200_000)

    if let prev = prevApp, prev.processIdentifier != pid {
        prev.activate(options: [.activateIgnoringOtherApps])
        usleep(150_000)
    }
    if let f = prevField, !CFEqual(f, box) {
        AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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


// ── Waiting for a field (--await-field) ──────────────────────────────────────
enum AwaitField {
    /// Mouse presses since waiting began, in accessibility coordinates.
    static var clicks: [(at: Date, point: CGPoint)] = []
    static var panel: NSPanel?
    static var bar: NSView?
    static var began = Date()
    static var seconds = 60.0

    static func run(seconds: Double, preview: String) -> Never {
        self.seconds = seconds
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)      // no Dock icon, never takes focus
        showPill(preview: preview)

        // Global monitors observe events bound for other apps without consuming
        // them, so the click still does its normal job in the app underneath.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            clicks.append((Date(), axPoint(NSEvent.mouseLocation)))
            clicks.removeAll { -$0.at.timeIntervalSinceNow > 2 }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { e in
            if e.keyCode == 53 { finish(6) }     // Esc
        }
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            let elapsed = -began.timeIntervalSinceNow
            if elapsed > seconds { finish(5) }
            if let bar = bar, let w = panel?.contentView?.bounds.width {
                bar.frame.size.width = w * CGFloat(max(0, 1 - elapsed / seconds))
            }
            check()
        }
        app.run()
        exit(5)
    }

    /// Done when a press landed inside the field that now has focus.
    static func check() {
        // Wait out the press itself: pasting mid-click can land before the caret
        // is placed, or turn a drag-selection into a replacement.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let recent = clicks.filter { -$0.at.timeIntervalSinceNow < 1.5 }
        guard !recent.isEmpty, let el = focusedElement() else { return }
        let role = (axAttr(el, kAXRoleAttribute as String) as? String) ?? ""
        let subrole = (axAttr(el, kAXSubroleAttribute as String) as? String) ?? ""
        // Never a password field.
        guard subrole != (kAXSecureTextFieldSubrole as String),
              acceptsText(el, role: role) else { return }
        // The click must be inside the field. Without this, clicking a button that
        // doesn't take focus would count, if a field happened to be focused already.
        // Some fields don't report a frame; the recent click is all there is then.
        if let frame = axFrame(el) {
            let hit = frame.insetBy(dx: -6, dy: -6)
            guard recent.contains(where: { hit.contains($0.point) }) else { return }
        }
        print("FIELD:\(role)")
        finish(0)
    }

    static func finish(_ code: Int32) -> Never {
        panel?.orderOut(nil)
        exit(code)
    }

    /// Cocoa's global coordinates start bottom-left; accessibility's top-left.
    static func axPoint(_ p: NSPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    static func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let pv = axAttr(el, kAXPositionAttribute as String),
              let sv = axAttr(el, kAXSizeAttribute as String) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sv as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Where the caption was, in the same material, so it reads as the dictation
    /// still being in hand rather than as a new alert. Clicks pass straight
    /// through: the field you want may be right underneath.
    static func showPill(preview: String) {
        let size = NSSize(width: 560, height: 62)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        func label(_ text: String, _ font: NSFont, _ color: NSColor,
                   _ frame: NSRect, _ align: NSTextAlignment = .left) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = font
            f.textColor = color
            f.alignment = align
            f.lineBreakMode = .byTruncatingTail
            f.frame = frame
            return f
        }
        let hintW: CGFloat = 110, padX: CGFloat = 18
        let textW = size.width - padX * 2 - hintW
        // The text sits in its own layer so it can fade in once the window has
        // finished growing out of the caption's loading circle.
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        bg.addSubview(content)
        content.addSubview(label("Click a text field to insert",
                            .systemFont(ofSize: 15, weight: .medium), .labelColor,
                            NSRect(x: padX, y: 32, width: textW, height: 20)))
        let quoted = preview.isEmpty ? "" : "\u{201C}\(preview)\u{201D}"
        content.addSubview(label(quoted, .systemFont(ofSize: 13), .secondaryLabelColor,
                            NSRect(x: padX, y: 12, width: textW, height: 17)))
        content.addSubview(label("Esc to cancel", .systemFont(ofSize: 12), .tertiaryLabelColor,
                            NSRect(x: size.width - padX - hintW, y: 23, width: hintW, height: 16),
                            .right))

        // Time left, draining along the bottom edge.
        let b = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: 2))
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.28).cgColor
        bg.addSubview(b)
        bar = b

        p.contentView = bg
        panel = p

        // Grow out of the caption's loading circle when there is one: the
        // dictation visibly turns into this window instead of a new one popping
        // up somewhere else.
        if let dot = dotFrame() {
            let screen = NSScreen.screens.first { $0.frame.intersects(dot) }?.visibleFrame
                      ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var x = dot.midX - size.width / 2
            x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
            var y = dot.midY - size.height / 2
            y = min(max(y, screen.minY + 8), screen.maxY - size.height - 8)
            let final = NSRect(x: x, y: y, width: size.width, height: size.height)
            content.alphaValue = 0
            b.isHidden = true
            bg.layer?.cornerRadius = dot.height / 2
            p.setFrame(dot, display: false)
            p.orderFrontRegardless()
            markHandedOver()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.18, 0.55, 1.0)
                p.animator().setFrame(final, display: true)
            }, completionHandler: {
                bg.layer?.cornerRadius = 14
                b.isHidden = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    content.animator().alphaValue = 1
                }
            })
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
                  ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 90))
        p.alphaValue = 0
        p.orderFrontRegardless()
        markHandedOver()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
    }

    /// The recorder's loading circle, in Cocoa screen coordinates, if this
    /// dictation left one (written on release, removed when the next hold starts).
    static func dotFrame() -> NSRect? {
        let path = "/tmp/rewrite_hud_dot"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              -m.timeIntervalSinceNow < 120 else { return nil }
        let n = raw.split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        return NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// Tells the recorder this window has taken over, so its circle fades out.
    static func markHandedOver() {
        FileManager.default.createFile(atPath: "/tmp/rewrite_insert_done", contents: Data())
    }
}


// ── Claude chats (--pin-chat, --send-to-chat) ────────────────────────────────
/// The chat an element sits in: the nearest web area whose address is a Claude
/// Code session, with its title minus the " - Claude Code" suffix.
func enclosingChat(of el: AXUIElement) -> (String, String)? {
    var cur: AXUIElement? = el
    for _ in 0..<60 {
        guard let c = cur else { return nil }
        if (axAttr(c, kAXRoleAttribute as String) as? String) == "AXWebArea",
           let url = axAttr(c, "AXURL").map({ "\($0)" }), url.contains("/epitaxy/") {
            var title = (axAttr(c, kAXTitleAttribute as String) as? String) ?? "Claude chat"
            if title.hasSuffix(" - Claude Code") { title = String(title.dropLast(14)) }
            return (url, title)
        }
        cur = axAttr(c, kAXParentAttribute as String).map { $0 as! AXUIElement }
    }
    return nil
}

/// The window and message box of the chat at `url`, if it is on screen.
func findChatBox(in app: AXUIElement, url: String) -> (AXUIElement, AXUIElement)? {
    for w in (axAttr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
        var queue = [w]
        var seen = 0
        while !queue.isEmpty && seen < 40_000 {
            let e = queue.removeFirst(); seen += 1
            if (axAttr(e, kAXRoleAttribute as String) as? String) == "AXWebArea",
               axAttr(e, "AXURL").map({ "\($0)" }) == url {
                // The message box is this chat's own "Prompt" text area.
                var inner = [e]; var n = 0
                while !inner.isEmpty && n < 40_000 {
                    let x = inner.removeFirst(); n += 1
                    if (axAttr(x, kAXRoleAttribute as String) as? String) == "AXTextArea",
                       (axAttr(x, kAXDescriptionAttribute as String) as? String) == "Prompt" {
                        return (w, x)
                    }
                    if let k = axAttr(x, kAXChildrenAttribute as String) as? [AXUIElement] { inner += k }
                }
                return nil
            }
            if let k = axAttr(e, kAXChildrenAttribute as String) as? [AXUIElement] { queue += k }
        }
    }
    return nil
}

/// One key press, with an explicit Command down/up around it when asked —
/// Electron apps ignore the flag-only form.
func postKey(_ key: CGKeyCode, command: Bool) {
    let src = CGEventSource(stateID: .combinedSessionState)
    if command { CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)?.post(tap: .cghidEventTap); usleep(8_000) }
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    if command { down?.flags = .maskCommand; up?.flags = .maskCommand }
    down?.post(tap: .cghidEventTap); usleep(8_000)
    up?.post(tap: .cghidEventTap); usleep(8_000)
    if command { CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)?.post(tap: .cghidEventTap) }
}
