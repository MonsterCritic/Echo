// ax_probe.swift — find out whether AI Dictate could paste back into the exact
// text field you started in, rather than just the app you started in.
//
// Today the recorder saves the frontmost APP at press time, and the paste lands
// in whatever field that app happens to have focused. Going finer means holding
// on to the focused element itself through the Accessibility API. Whether that
// actually works depends entirely on the app: native apps expose stable elements,
// while Electron and web apps rebuild their accessibility tree as the view
// re-renders, which can leave a saved reference pointing at nothing.
//
// This measures that instead of assuming it. Nothing here changes any app — it
// reads, and in --restore mode it asks for focus back.
//
// Usage:
//   ax_probe                 watch the focused field for 20s; click around
//   ax_probe --watch 40      ... for 40s
//   ax_probe --restore 8     capture the field, wait 8s while you click away,
//                            then try to put focus back and report whether it held
//   ax_probe --check         report Accessibility status, never prompts
//   ax_probe --grant         report status AND raise the system prompt
//
// Field CONTENTS are never printed — only the length — because the whole point is
// to run this in real inputs containing real text.

import AppKit
import ApplicationServices

// ── Accessibility gate ───────────────────────────────────────────────────────
// Only --grant may prompt. macOS attributes Accessibility to the RESPONSIBLE
// process, so prompting from the wrong parent produces a dialog naming something
// the user cannot usefully grant — that has already happened once in this project.
let args = CommandLine.arguments
let grantMode = args.contains("--grant")
let checkOnly = args.contains("--check")

let trusted: Bool = {
    if grantMode {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    return AXIsProcessTrusted()
}()

if checkOnly || grantMode {
    print(trusted ? "TRUSTED" : "NOT_TRUSTED")
    exit(trusted ? 0 : 2)
}

if !trusted {
    print("""
    Accessibility is not granted to whatever is running this, so the focused
    element cannot be read. Grant it, then run this again:

        \(args[0]) --grant

    If the prompt names a process you don't recognise, cancel it and run this
    probe directly from Terminal instead.
    """)
    exit(2)
}

// ── Reading elements ─────────────────────────────────────────────────────────
let systemWide = AXUIElementCreateSystemWide()

// Asking the system-wide element for the focused field returns cannotComplete
// against Chromium-based apps — Claude Code, VS Code, Slack, browsers. They keep
// their accessibility tree switched off until an assistive client asks for it,
// and the switch is a private attribute set on the application element:
// AXManualAccessibility. Without this the probe reads nothing from precisely the
// apps that matter, which is not the same as those apps having nothing to read.
//
// The messaging timeout is raised for the same reason: building that tree the
// first time is not instant, and the default deadline expires during it.
var enabledApps = Set<pid_t>()

func appElement(for pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    if !enabledApps.contains(pid) {
        enabledApps.insert(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    return app
}

func frontmostAppElement() -> AXUIElement? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    return appElement(for: pid)
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    attr(el, name) as? String
}

func settable(_ el: AXUIElement, _ name: String) -> Bool {
    var s: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(el, name as CFString, &s) == .success else { return false }
    return s.boolValue
}

/// Last error from asking for the focused element, so "nothing printed" can be
/// told apart from "nothing focused" — silence is not a useful probe result.
var lastFocusError: AXError = .success

func focusedElement() -> AXUIElement? {
    // Ask the frontmost application directly — it answers when the system-wide
    // element will not, and asking is what turns the tree on in the first place.
    if let app = frontmostAppElement() {
        var v: CFTypeRef?
        lastFocusError = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &v)
        if lastFocusError == .success, let v = v { return (v as! AXUIElement) }
    }
    var v: CFTypeRef?
    lastFocusError = AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedUIElementAttribute as CFString, &v)
    guard lastFocusError == .success, let v = v else { return nil }
    return (v as! AXUIElement)
}

func focusErrorText() -> String {
    switch lastFocusError {
    case .success:            return "no focused element reported"
    case .noValue:            return "the frontmost app reports no focused element"
    case .attributeUnsupported:
                              return "the frontmost app doesn't expose a focused element at all"
    case .apiDisabled:        return "Accessibility is off for this process"
    case .cannotComplete:     return "the app didn't answer (busy or not accessibility-aware)"
    case .notImplemented:     return "the app doesn't implement the Accessibility API"
    default:                  return "AXError \(lastFocusError.rawValue)"
    }
}

func owningApp(_ el: AXUIElement) -> String {
    var pid: pid_t = 0
    guard AXUIElementGetPid(el, &pid) == .success else { return "?" }
    return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
}

/// What we would have to store at press time in order to find this field again.
struct Fingerprint: Equatable {
    let app: String
    let role: String
    let subrole: String
    let identifier: String
    let label: String
    let window: String
    let frame: String

    var line: String {
        var bits = ["\(app)  [\(role)\(subrole.isEmpty ? "" : "/\(subrole)")]"]
        if !identifier.isEmpty { bits.append("id=\(identifier)") }
        if !label.isEmpty      { bits.append("label=\"\(label)\"") }
        if !window.isEmpty     { bits.append("window=\"\(window)\"") }
        if !frame.isEmpty      { bits.append(frame) }
        return bits.joined(separator: "  ")
    }

    /// Could this element be found again from stored attributes alone?
    var isIdentifiable: Bool { !identifier.isEmpty || !label.isEmpty }
}

func fingerprint(_ el: AXUIElement) -> Fingerprint {
    var frame = ""
    if let posV = attr(el, kAXPositionAttribute as String),
       let sizeV = attr(el, kAXSizeAttribute as String) {
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        frame = "at(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
    }
    var window = ""
    if let w = attr(el, kAXWindowAttribute as String) {
        window = str(w as! AXUIElement, kAXTitleAttribute as String) ?? ""
    }
    return Fingerprint(
        app: owningApp(el),
        role: str(el, kAXRoleAttribute as String) ?? "?",
        subrole: str(el, kAXSubroleAttribute as String) ?? "",
        identifier: str(el, kAXIdentifierAttribute as String) ?? "",
        // Whichever of these the app bothers to expose is what we'd match on.
        label: str(el, kAXPlaceholderValueAttribute as String)
            ?? str(el, kAXTitleAttribute as String)
            ?? str(el, kAXDescriptionAttribute as String) ?? "",
        window: window,
        frame: frame
    )
}

/// Can we write into it directly, skipping the clipboard and Cmd+V entirely?
func writability(_ el: AXUIElement) -> String {
    let value = settable(el, kAXValueAttribute as String)
    let sel   = settable(el, kAXSelectedTextAttribute as String)
    let len   = (attr(el, kAXValueAttribute as String) as? String)?.count
    let lenNote = len.map { "\($0) chars" } ?? "no text value"
    switch (value, sel) {
    case (_, true):  return "insertable via AXSelectedText  (\(lenNote))"
    case (true, _):  return "whole value settable only      (\(lenNote))"
    default:         return "NOT writable — would need Cmd+V (\(lenNote))"
    }
}

// ── Modes ────────────────────────────────────────────────────────────────────
func value(after flag: String, default d: Double) -> Double {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return d }
    return Double(args[i + 1]) ?? d
}

if args.contains("--restore") {
    let wait = value(after: "--restore", default: 8)
    guard let saved = focusedElement() else {
        print("Nothing is focused. Click into a text field first, then run this again.")
        exit(1)
    }
    let savedPrint = fingerprint(saved)
    print("captured:  \(savedPrint.line)")
    print("           \(writability(saved))")
    print("           findable from stored attributes: \(savedPrint.isIdentifiable ? "yes" : "NO — only a live reference)")")
    print("\nnow click into a DIFFERENT field or app. restoring in \(Int(wait))s…\n")
    Thread.sleep(forTimeInterval: wait)

    let drifted = focusedElement().map { fingerprint($0) }
    print("focus drifted to: \(drifted?.line ?? "(nothing)")")

    // Bring the owning app forward first — an element in a background app will
    // not take focus on its own.
    var pid: pid_t = 0
    AXUIElementGetPid(saved, &pid)
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.25)
    }
    let err = AXUIElementSetAttributeValue(saved, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)

    let now = focusedElement()
    let back = now.map { CFEqual($0, saved) } ?? false
    print("\nset AXFocused: \(err == .success ? "accepted" : "REFUSED (\(err.rawValue))")")
    print("focus now on:  \(now.map { fingerprint($0).line } ?? "(nothing)")")
    print(back
        ? "\nRESULT: the original field took focus back. Paste-where-you-started would work here."
        : "\nRESULT: it did NOT come back. This app would need the app-level fallback.")
    exit(0)
}

// Default: watch. Stops early once it has seen enough distinct fields, so it
// waits for the person rather than making them race a timer — the first run of
// this collected nothing because the window closed before anyone clicked.
let seconds = value(after: "--watch", default: 20)
let wantFields = Int(value(after: "--until", default: 0))
print("Watching the focused field for up to \(Int(seconds))s"
      + (wantFields > 0 ? ", or until \(wantFields) different fields have been seen." : "."))
print("Click through the inputs you dictate into.")
print("(field contents are never printed, only their length)\n")

var last: Fingerprint?
var lastNote = ""
var seenAny = false
var distinct = 0
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    if let el = focusedElement() {
        let fp = fingerprint(el)
        if fp != last {
            last = fp
            seenAny = true
            distinct += 1
            print("• \(fp.line)")
            print("    \(writability(el))")
            print("    findable from stored attributes: \(fp.isIdentifiable ? "yes" : "NO — live reference only")")
        }
    } else {
        let note = "(\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")) \(focusErrorText())"
        if note != lastNote { lastNote = note; print("· \(note)") }
    }
    if wantFields > 0 && distinct >= wantFields { break }
    Thread.sleep(forTimeInterval: 0.4)
}
print(seenAny ? "\ndone — \(distinct) field(s) seen."
              : "\ndone — nothing was focused the whole time. Click into a text field while this runs.")
