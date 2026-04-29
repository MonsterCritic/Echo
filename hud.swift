import Cocoa

// Floating "Rewriting…" HUD near the mouse cursor.
// Closes when stdin is closed (parent signals "done" by closing its stdin pipe).

// ── Geometry ──────────────────────────────────────────────────────────────────

let W: CGFloat = 170
let H: CGFloat = 96

let mouse  = NSEvent.mouseLocation
let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
          ?? NSScreen.main?.visibleFrame
          ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

var x = mouse.x - W / 2
var y = mouse.y - H - 24          // a little below the cursor
// Clamp to visible screen
x = max(screen.minX + 8, min(x, screen.maxX - W - 8))
y = max(screen.minY + 8, min(y, screen.maxY - H - 8))

let winRect = NSRect(x: x, y: y, width: W, height: H)

// ── Window ────────────────────────────────────────────────────────────────────

let window = NSWindow(
    contentRect: winRect,
    styleMask:   [.borderless],
    backing:     .buffered,
    defer:       false)
window.isReleasedWhenClosed = false
window.level                = .floating
window.backgroundColor      = .clear
window.isOpaque             = false
window.hasShadow            = true
window.ignoresMouseEvents   = true        // clicks pass through
window.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
content.wantsLayer = true
content.layer?.cornerRadius     = 14
content.layer?.masksToBounds    = true
content.layer?.backgroundColor  = NSColor(white: 0.08, alpha: 0.92).cgColor

// Spinner
let spinnerSize: CGFloat = 28
let spinner = NSProgressIndicator(frame: NSRect(
    x: (W - spinnerSize) / 2,
    y: H / 2 + 4,
    width: spinnerSize,
    height: spinnerSize))
spinner.style          = .spinning
spinner.isIndeterminate = true
spinner.appearance     = NSAppearance(named: .darkAqua)
spinner.startAnimation(nil)
content.addSubview(spinner)

// Label
let label = NSTextField(labelWithString: "Rewriting…")
label.frame          = NSRect(x: 0, y: 14, width: W, height: 20)
label.alignment      = .center
label.font           = .systemFont(ofSize: 13, weight: .medium)
label.textColor      = .white
label.backgroundColor = .clear
label.isBordered      = false
label.isEditable      = false
content.addSubview(label)

window.contentView = content
window.orderFrontRegardless()

// ── Lifecycle ─────────────────────────────────────────────────────────────────

// Close when parent closes stdin.
DispatchQueue.global(qos: .background).async {
    _ = FileHandle.standardInput.readDataToEndOfFile()
    DispatchQueue.main.async { exit(0) }
}

// Safety timeout — never hang forever.
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { exit(1) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, no menu bar, no focus steal
app.run()
