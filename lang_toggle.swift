// lang_toggle.swift — Globe + Space switches the language dictation is pasted in,
// and says so on screen the way macOS does when you switch input source.
//
// It flips the same setting the menubar's Language item writes, so the two always
// agree: "English" translates what you dictate, "Russian" pastes what you actually
// said. The point of the hotkey is that the choice changes mid-flow — you switch
// languages between one message and the next, and reaching for a menu each time
// defeats it.
//
// The HUD matters as much as the toggle. A silent switch is indistinguishable from
// a missed keypress, and you would only find out which by dictating a sentence and
// seeing what language came back.

import AppKit

// ── The setting ──────────────────────────────────────────────────────────────
// Shared with dictate.py, which re-reads it per dictation — so a switch applies
// to the very next hold with nothing to restart.
let settingPath = NSString(string: "~/Library/Application Support/Echo/output_language")
                  .expandingTildeInPath

func currentLanguage() -> String {
    guard let raw = try? String(contentsOfFile: settingPath, encoding: .utf8) else { return "en" }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ru")
        ? "ru" : "en"
}

func write(_ code: String) {
    let dir = (settingPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? (code + "\n").write(toFile: settingPath, atomically: true, encoding: .utf8)
}

/// English names on purpose. macOS writes each language in its own script, but
/// every other string this project puts on screen is English, and mixing scripts
/// in one HUD reads as a bug rather than a style.
func name(_ code: String) -> String { code == "ru" ? "Russian" : "English" }

let from = currentLanguage()
let to   = (from == "ru") ? "en" : "ru"
write(to)

// Globe is also the dictation key: held past 300ms it starts recording. Pressing
// Space a beat late would otherwise leave a recording running and a dictate.py
// waiting on it, so clear the flag — the recorder stops on its own and discards
// the fragment as too short.
try? FileManager.default.removeItem(atPath: "/tmp/rewrite_record_start")

// ── The HUD ──────────────────────────────────────────────────────────────────
let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // no dock icon, and it never takes focus

let panelSize = NSSize(width: 340, height: 150)
let panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = .statusBar                 // above ordinary windows, below alerts
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.ignoresMouseEvents = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

// Same material macOS uses for its own switcher, so it belongs on the screen.
let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
blur.material = .hudWindow
blur.blendingMode = .behindWindow
blur.state = .active
blur.wantsLayer = true
blur.layer?.cornerRadius = 22
blur.layer?.masksToBounds = true

func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
           alpha: CGFloat, y: CGFloat, height: CGFloat) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = NSColor.labelColor.withAlphaComponent(alpha)
    f.alignment = .center
    f.frame = NSRect(x: 0, y: y, width: panelSize.width, height: height)
    return f
}

// The language being switched TO is the answer; the one being left is context.
blur.addSubview(label(name(to), size: 30, weight: .medium, alpha: 1.0, y: 58, height: 38))
blur.addSubview(label("\(name(from))  →  \(name(to))", size: 13, weight: .regular,
                      alpha: 0.55, y: 34, height: 18))
blur.addSubview(label("Dictation language", size: 11, weight: .regular,
                      alpha: 0.4, y: 16, height: 16))

panel.contentView = blur

if let screen = NSScreen.main {
    let f = screen.frame
    panel.setFrameOrigin(NSPoint(x: f.midX - panelSize.width / 2,
                                 y: f.midY - panelSize.height / 2))
}
panel.orderFrontRegardless()             // show without stealing focus

// Fade out and quit. Long enough to read, short enough not to sit in the way.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.25
        panel.animator().alphaValue = 0
    }, completionHandler: { app.terminate(nil) })
}

// A hard stop in case the animation never completes — this must never linger.
DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(0) }

app.run()
