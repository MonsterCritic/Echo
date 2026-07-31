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
//   paste_helper --check             only trigger/verify the Accessibility grant
//
// Prints the app that was frontmost before the keystroke (for the caller's log).
// If Accessibility isn't granted yet it writes ACCESSIBILITY_NOT_GRANTED to
// stderr and exits 2, so callers can fall back to the osascript path until the
// user grants it.

import AppKit
import CoreGraphics

let args = CommandLine.arguments
let checkOnly = args.contains("--check")
let copyMode  = args.contains("--copy")
let target = (args.count > 1 && !args[1].hasPrefix("--")) ? args[1] : ""

let ws = NSWorkspace.shared
let frontBefore = ws.frontmostApplication?.localizedName ?? ""

// Accessibility is required to post key events. Prompt on first run; once
// granted the prompt never reappears.
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

if checkOnly {
    print(trusted ? "TRUSTED" : "NOT_TRUSTED")
    exit(trusted ? 0 : 2)
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
