// globe_listener — the Globe (fn) key, without Karabiner-Elements.
//
// Karabiner used to own the Globe key for Echo. After a macOS update its
// virtual keyboard driver stopped loading ("virtual_hid_keyboard is not ready"),
// and Karabiner runs none of its rules without that driver, so dictation died
// with it. Nothing Echo needs from the key requires a driver: a session event
// tap sees the Globe press and release, and can swallow the keys it acts on.
//
// Same behavior as the Karabiner rules it replaces:
//   hold Globe          dictate (starts on key down, ends on release)
//   tap Globe           AI Rewrite — Tink, then Ctrl+Opt+Shift+Cmd+A, the
//                       shortcut of the "AI Rewrite Global" service
//   Globe + Space       switch the dictation language
//   Cmd + Globe         speak the selection
//
// The tap is an active one (it swallows Space while Globe is down, and Globe
// itself), so it needs Accessibility. Children it starts — dictate.py, the paste
// helper — are attributed to this app by TCC, so it also needs access to the
// repo folder when that is in ~/Documents.

import Cocoa
import ApplicationServices

let logPath = "/tmp/globe_listener.log"
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

let support = NSString(string: "~/Library/Application Support/Echo").expandingTildeInPath
/// Where the Python tools live. setup.sh records it; the default is where the
/// repo has always been cloned.
let repo: String = {
    let f = support + "/repo_dir"
    if let s = try? String(contentsOfFile: f, encoding: .utf8) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    return NSString(string: "~/Documents/context-helper").expandingTildeInPath
}()

let startFlag = "/tmp/rewrite_record_start"
// Karabiner's default to_if_alone timeout: a press held longer than this is not
// a tap, even with no other key in between.
let tapMaxSeconds = 1.0

func sh(_ command: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { log("could not run: \(command) — \(error)") }
}

func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// ── Actions ──────────────────────────────────────────────────────────────────
func startDictation() {
    FileManager.default.createFile(atPath: startFlag, contents: Data())
    // The frontmost app, as System Events names it — dictate.py reactivates it
    // by that name, so it must be the same name, not NSWorkspace's.
    sh("/usr/bin/osascript -e 'tell application \"System Events\" to return name of first process whose frontmost is true' > /tmp/rewrite_record_app.txt")
    sh("/usr/bin/python3 \(q(repo + "/dictate.py")) >> /tmp/dictate.err.log 2>&1")
}

func endDictation() {
    try? FileManager.default.removeItem(atPath: startFlag)
}

func rewrite() {
    sh("/usr/bin/afplay /System/Library/Sounds/Tink.aiff")
    let src = CGEventSource(stateID: .hidSystemState)
    let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: down)   // A
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}

func toggleLanguage() { sh(q(support + "/bin/lang_toggle")) }
func speak() { sh("/usr/bin/python3 \(q(repo + "/speak.py"))") }

// ── The key ──────────────────────────────────────────────────────────────────
let kVKFunction: Int64 = 63
let kVKSpace: Int64 = 49

var globeDown = false
var downAt = Date()
var alone = true
var speakMode = false
var swallowSpaceUp = false
var tap: CFMachPort?

func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("event tap was disabled (\(type.rawValue)) — re-enabling")
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)

    if type == .flagsChanged && code == kVKFunction {
        let down = event.flags.contains(.maskSecondaryFn)
        if down && !globeDown {
            globeDown = true
            downAt = Date()
            alone = true
            speakMode = event.flags.contains(.maskCommand)
            if speakMode { speak(); log("Cmd+Globe → speak") }
            else { startDictation(); log("Globe down → dictation start") }
        } else if !down && globeDown {
            globeDown = false
            if !speakMode {
                endDictation()
                let held = -downAt.timeIntervalSinceNow
                if alone && held < tapMaxSeconds { rewrite(); log(String(format: "Globe tap (%.2fs) → rewrite", held)) }
                else { log(String(format: "Globe up after %.2fs", held)) }
            }
        }
        // Swallowed, as under Karabiner: macOS never sees Globe itself, so its
        // own Globe action (emoji, input source, dictation) does not fire too.
        return nil
    }

    if type == .keyDown && globeDown {
        alone = false
        if code == kVKSpace && !speakMode {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                toggleLanguage(); log("Globe + Space → language")
            }
            swallowSpaceUp = true
            return nil
        }
    }
    if type == .keyUp && code == kVKSpace && swallowSpaceUp {
        swallowSpaceUp = false
        return nil
    }
    // A click while held also means it was not a tap.
    if globeDown && (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown) {
        alone = false
    }
    return Unmanaged.passUnretained(event)
}

func installTap() -> Bool {
    let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                    options: .defaultTap, eventsOfInterest: mask,
                                    callback: { _, type, event, _ in handle(type, event) },
                                    userInfo: nil) else { return false }
    tap = t
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
}

// ── Start ────────────────────────────────────────────────────────────────────
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
log("globe_listener started (repo: \(repo))")

// Touch the repo once now, so a folder-access prompt (if any) appears at login
// rather than on the first dictation — and is answered for this app, which is
// what its children are checked against.
if FileManager.default.isReadableFile(atPath: repo + "/dictate.py"),
   (try? Data(contentsOf: URL(fileURLWithPath: repo + "/dictate.py"))) != nil {
    log("repo readable")
} else {
    log("repo NOT readable — dictate.py will fail to start; allow folder access for Echo Globe")
}

if !installTap() {
    log("no event tap — asking for Accessibility")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    // Retry until granted; launchd keeps this process alive meanwhile.
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
        if installTap() { log("event tap installed"); t.invalidate() }
    }
} else {
    log("event tap installed")
}
app.run()
