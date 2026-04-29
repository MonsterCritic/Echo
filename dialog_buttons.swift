import Cocoa

let args    = CommandLine.arguments
guard args.count >= 2 else { exit(1) }

let preview = args[1]
let options = Array(args[2...])

var isLoading = false   // prevents windowDidResignKey from closing during API call

// ── Layout constants ──────────────────────────────────────────────────────────

let cols:  Int     = 2
let W:     CGFloat = 500
let btnH:  CGFloat = 64
let gap:   CGFloat = 10
let pad:   CGFloat = 16
let btnW:  CGFloat = (W - pad * 2 - gap) / 2

let rows      = Int(ceil(Double(options.count) / Double(cols)))
let previewH: CGFloat = preview.isEmpty ? 0 : 40
let totalH    = pad + previewH + CGFloat(rows) * (btnH + gap) - gap + pad

let screen  = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let winRect = NSRect(x: screen.midX - W / 2, y: screen.midY - totalH / 2,
                     width: W, height: totalH)

// ── Window ────────────────────────────────────────────────────────────────────

let window = NSWindow(
    contentRect: winRect,
    styleMask:   [.borderless],
    backing:     .buffered,
    defer:       false)
window.isReleasedWhenClosed = false
window.isMovableByWindowBackground = true
window.backgroundColor = .clear
window.isOpaque = false

class WinDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ n: Notification) { exit(1) }
    func windowDidResignKey(_ n: Notification) { if !isLoading { exit(1) } }
}
let winDelegate = WinDelegate()
window.delegate = winDelegate

let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: totalH))
content.wantsLayer = true
content.layer?.cornerRadius = 14
content.layer?.masksToBounds = true
content.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.97).cgColor

// ── Shared select action ──────────────────────────────────────────────────────

func selectOption(_ option: String) {
    guard !isLoading else { return }
    if let data = (option + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
    isLoading = true

    for sub in content.subviews { sub.removeFromSuperview() }

    let spinner = NSProgressIndicator(frame: NSRect(
        x: W / 2 - 16, y: totalH / 2 + 10, width: 32, height: 32))
    spinner.style = .spinning
    spinner.isIndeterminate = true
    spinner.startAnimation(nil)
    content.addSubview(spinner)

    let msg = NSTextField(labelWithString: "Rewriting…")
    msg.frame     = NSRect(x: 0, y: totalH / 2 - 34, width: W, height: 28)
    msg.alignment = .center
    msg.font      = .systemFont(ofSize: 16)
    msg.textColor = .secondaryLabelColor
    content.addSubview(msg)

    DispatchQueue.global(qos: .background).async {
        FileHandle.standardInput.readDataToEndOfFile()
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { exit(1) }
}

// ── Custom button view ────────────────────────────────────────────────────────

class BigButton: NSView {
    let label:   String
    let keyHint: String
    let onTap:   () -> Void
    private var hovered = false

    init(_ label: String, keyHint: String, frame: NSRect, onTap: @escaping () -> Void) {
        self.label   = label
        self.keyHint = keyHint
        self.onTap   = onTap
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = bg()
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func bg() -> CGColor {
        hovered
            ? NSColor.white.withAlphaComponent(0.15).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func mouseEntered(with e: NSEvent) { hovered = true;  layer?.backgroundColor = bg() }
    override func mouseExited (with e: NSEvent) { hovered = false; layer?.backgroundColor = bg() }
    override func mouseUp(with e: NSEvent) {
        guard bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        onTap()
    }

    override func draw(_ rect: NSRect) {
        // Main label
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle:  para,
        ]
        let h = (label as NSString).size(withAttributes: attrs).height
        let y = (bounds.height - h) / 2
        (label as NSString).draw(
            in: NSRect(x: 8, y: y, width: bounds.width - 16, height: h),
            withAttributes: attrs)

        // Key hint (top-right corner)
        if !keyHint.isEmpty {
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font:            NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            ]
            let hintSize = (keyHint as NSString).size(withAttributes: hintAttrs)
            (keyHint as NSString).draw(
                in: NSRect(x: bounds.width - hintSize.width - 8,
                           y: bounds.height - hintSize.height - 6,
                           width: hintSize.width, height: hintSize.height),
                withAttributes: hintAttrs)
        }
    }
}

// ── Keyboard shortcuts ────────────────────────────────────────────────────────

NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    guard !isLoading else { return event }
    // Escape → cancel
    if event.keyCode == 53 {
        exit(1)
    }
    let ch = event.charactersIgnoringModifiers ?? ""
    // Space → last option (Custom…)
    if ch == " ", let last = options.last {
        selectOption(last)
        return nil
    }
    // 1–N → preset buttons
    if let digit = Int(ch), digit >= 1, digit < options.count {
        selectOption(options[digit - 1])
        return nil
    }
    return event
}

// ── Build button grid ─────────────────────────────────────────────────────────

// Preview label
if !preview.isEmpty {
    let label = NSTextField(wrappingLabelWithString: preview)
    label.frame = NSRect(x: pad, y: totalH - pad - previewH,
                         width: W - pad * 2, height: previewH)
    label.font               = .systemFont(ofSize: 13)
    label.textColor          = .secondaryLabelColor
    label.maximumNumberOfLines = 2
    content.addSubview(label)
}

var views = [NSView]()

for (i, option) in options.enumerated() {
    let row = i / cols
    let col = i % cols

    // Key hint: "1"…"N-1" for presets, "⎵" for the last (Custom…)
    let hint: String
    if i == options.count - 1 {
        hint = "⎵"
    } else if i < 9 {
        hint = "\(i + 1)"
    } else {
        hint = ""
    }

    let isLastOdd = (i == options.count - 1) && (options.count % cols != 0)
    let x: CGFloat = isLastOdd ? pad : pad + CGFloat(col) * (btnW + gap)
    let w: CGFloat = isLastOdd ? W - pad * 2 : btnW
    let y: CGFloat = pad + CGFloat(rows - 1 - row) * (btnH + gap)

    let btn = BigButton(option, keyHint: hint,
                        frame: NSRect(x: x, y: y, width: w, height: btnH)) {
        selectOption(option)
    }
    content.addSubview(btn)
    views.append(btn)
}

window.contentView = content
window.makeKeyAndOrderFront(nil)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)
app.run()
