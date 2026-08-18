// history_menubar.swift — menu-bar icon for dictation history.
//
// Left-click  → opens dictate_history.md in your default editor.
// Right-click → menu with "Show in Finder" and "Quit".
//
// LSUIElement=true so no dock icon. Auto-started at login by a LaunchAgent.

import AppKit
import CoreAudio
import Foundation

let historyPath = NSString(string: "~/Documents/context-helper/dictate_history.md")
                  .expandingTildeInPath
let historyURL  = URL(fileURLWithPath: historyPath)

// ── AI Speak control ─────────────────────────────────────────────────────────
// speak.py writes its PID here and puts itself in its own process group, so the
// whole pipeline (synthesis thread + afplay child) can be killed at once. This
// is the same mechanism a second Cmd+Globe uses; we just expose it as a menu
// item so playback can be stopped by mouse too.
let speakPIDPath = "/tmp/rewrite_speak.pid"

// ── Microphone selection ─────────────────────────────────────────────────────
// Two separate facts, deliberately kept apart:
//   inputDeviceFile  — the device the user CHOSE (absent = follow macOS)
//   actualInputFile  — the device the recorder is REALLY on, read back from the
//                      audio unit at startup and published by the daemon
// They can disagree: a pin call can return noErr without the engine honoring it,
// or the chosen device can be unplugged. Showing both makes that visible instead
// of leaving us to guess from sample rates, which are identical across inputs on
// this hardware.
let inputDeviceFile = NSString(string: "~/Library/Application Support/Echo/input_device")
                      .expandingTildeInPath
let actualInputFile = "/tmp/echo_input_actual.txt"
let recorderLabel   = "com.echo.context-helper.record-realtime"

func trimmedContents(of path: String) -> String? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

/// The device the user pinned, or nil to follow the system default.
func chosenInputName() -> String? { trimmedContents(of: inputDeviceFile) }

/// The device the recorder reported it is actually capturing from.
func actualInputName() -> String? { trimmedContents(of: actualInputFile) }

func hasInputChannels(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

func deviceProperty<T>(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                       _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var sz = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &value) == noErr else { return nil }
    return value
}

struct InputDevice {
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Every device that can capture, in CoreAudio's order.
func inputDevices() -> [InputDevice] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                        &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return [] }
    var out: [InputDevice] = []
    for id in ids where hasInputChannels(id) {
        guard let cf: CFString = deviceProperty(id, kAudioObjectPropertyName, "" as CFString) else { continue }
        let transport = deviceProperty(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
        out.append(InputDevice(name: cf as String, transport: transport))
    }
    return out
}

/// The system default input's name. Used when nothing is pinned, so the menu can
/// name the live mic without the daemon having to report anything.
func defaultInputName() -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &sz, &id) == noErr else { return nil }
    guard let cf: CFString = deviceProperty(id, kAudioObjectPropertyName, "" as CFString) else { return nil }
    return cf as String
}

/// Matching mirrors the daemon's: case-insensitive substring, so a stored name
/// keeps working when macOS decorates it.
func nameMatches(_ stored: String, _ device: String) -> Bool {
    device.localizedCaseInsensitiveContains(stored)
}

/// The recorder reads the pin once at startup, so a change only takes effect
/// after a restart. kickstart -k does both halves atomically.
func restartRecorder() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(recorderLabel)"]
    try? p.run()
}

/// The live speak.py process, or nil if nothing is playing.
func speakingPID() -> pid_t? {
    guard let s = try? String(contentsOfFile: speakPIDPath, encoding: .utf8),
          let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0 else { return nil }
    return kill(pid, 0) == 0 ? pid : nil     // signal 0 = liveness check only
}

func stopSpeaking() {
    guard let pid = speakingPID() else { return }
    let pgid = getpgid(pid)
    if pgid > 0 {
        killpg(pgid, SIGTERM)                // kills afplay + pending synthesis
    } else {
        kill(pid, SIGTERM)
    }
    try? FileManager.default.removeItem(atPath: speakPIDPath)
}

class StatusController: NSObject, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    private var showingSpeakingIcon = false
    private var iconTimer: Timer?

    func install() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform",
                                   accessibilityDescription: "Dictation History")
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Re-populate the menu every time it opens so the "Copy Last…" item
        // reflects the actual most-recent dictation.
        menu.delegate = self
        rebuildMenu()

        // Poll for playback so the icon reflects it. Cheap: a stat + a signal-0
        // liveness check once a second, and the icon is only redrawn on change.
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
        if let t = iconTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func rebuildMenu() {
        menu.removeAllItems()

        // Only offered while something is actually playing, so the menu doesn't
        // carry a dead action the rest of the time.
        if speakingPID() != nil {
            let stopItem = NSMenuItem(title: "Stop Speaking",
                                      action: #selector(stopSpeech),
                                      keyEquivalent: ".")
            stopItem.target = self
            menu.addItem(stopItem)
            menu.addItem(NSMenuItem.separator())
        }

        let last = lastFinal()
        let preview = last.flatMap { previewText($0) }
        let copyTitle = preview.map { "Copy Last: \"\($0)\"" } ?? "Copy Last Message"
        let copyItem = NSMenuItem(title: copyTitle,
                                  action: #selector(copyLast),
                                  keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = (last != nil)
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // ── Microphone ───────────────────────────────────────────────────────
        // Titled with the device actually in use, so the truth is visible without
        // opening the submenu.
        let devices = inputDevices()
        let chosen  = chosenInputName()
        // With a pin, only the daemon's read-back can say whether it stuck. Without
        // one, the answer is just the system default, which we can resolve here.
        let inUse   = (chosen == nil) ? defaultInputName() : actualInputName()

        let micRoot = NSMenuItem(title: "Microphone: \(inUse ?? chosen ?? "System Default")",
                                 action: nil, keyEquivalent: "")
        let micMenu = NSMenu()

        let defaultItem = NSMenuItem(title: "System Default",
                                     action: #selector(pickInput(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = nil        // nil = remove the pin
        defaultItem.state = (chosen == nil) ? .on : .off
        defaultItem.toolTip = inUse.map { "Follow whatever input macOS has selected (now \($0))." }
                              ?? "Follow whatever input macOS has selected."
        micMenu.addItem(defaultItem)
        micMenu.addItem(NSMenuItem.separator())

        for dev in devices {
            let item = NSMenuItem(title: dev.isBluetooth ? "\(dev.name)  · Bluetooth" : dev.name,
                                  action: #selector(pickInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.name
            item.state = (chosen.map { nameMatches($0, dev.name) } ?? false) ? .on : .off
            if dev.isBluetooth {
                item.toolTip = "Opening a Bluetooth mic drops the headset to mono call "
                             + "mode: it delays the start of recording and degrades "
                             + "whatever you're listening to."
            }
            micMenu.addItem(item)
        }

        // A pin can fail silently — surface the disagreement instead of hiding it.
        if let chosen = chosen, let inUse = inUse, !nameMatches(chosen, inUse) {
            micMenu.addItem(NSMenuItem.separator())
            let warn = NSMenuItem(title: "⚠︎ pinned to \(chosen) — recording from \(inUse)",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            micMenu.addItem(warn)
        }

        micRoot.submenu = micMenu
        menu.addItem(micRoot)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open History",
                                  action: #selector(openHistory),
                                  keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let finderItem = NSMenuItem(title: "Show in Finder",
                                    action: #selector(showInFinder),
                                    keyEquivalent: "")
        finderItem.target = self
        menu.addItem(finderItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Read the history file and return the output text of the MOST RECENT
    /// entry, or nil if empty/missing. History is prepended (newest first), so
    /// the newest entry is the first `## ` block. Handles all entry shapes:
    ///   • Dictate single-call — plain text under the header
    ///   • Dictate two-step    — text under `**Final:**`
    ///   • Rewrite             — text under `**Rewritten:**`
    func lastFinal() -> String? {
        guard let content = try? String(contentsOfFile: historyPath,
                                        encoding: .utf8) else { return nil }
        // Newest entry = first "## " header (prepended history).
        guard let headerRange = content.range(of: "## ") else { return nil }
        let afterHeader = content[headerRange.lowerBound...]
        // Block ends at the next "---" separator or end of file.
        let blockEnd = afterHeader.range(of: "\n---")
        let block = blockEnd.map { String(afterHeader[..<$0.lowerBound]) }
                    ?? String(afterHeader)

        func textAfter(_ marker: String) -> String? {
            guard let r = block.range(of: marker) else { return nil }
            return String(block[r.upperBound...])
        }

        let body: String
        if let t = textAfter("**Rewritten:**") {        // rewrite → corrected text
            body = t
        } else if let t = textAfter("**Final:**") {      // dictate two-step → final
            body = t
        } else if let nl = block.firstIndex(of: "\n") {  // plain entry → drop header line
            body = String(block[block.index(after: nl)...])
        } else {
            body = block
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Short truncated preview for the menu item label.
    func previewText(_ s: String, maxLen: Int = 50) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
                       .trimmingCharacters(in: .whitespaces)
        if oneLine.count <= maxLen { return oneLine }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: maxLen)
        return String(oneLine[..<idx]) + "…"
    }

    @objc func stopSpeech() {
        stopSpeaking()
        refreshIcon()
    }

    /// Swap the menubar glyph while speech is playing, so it's visible that
    /// playback is running (and therefore that Stop Speaking is available).
    func refreshIcon() {
        guard let button = item.button else { return }
        let speaking = speakingPID() != nil
        if speaking == showingSpeakingIcon { return }   // avoid needless redraws
        showingSpeakingIcon = speaking
        let name = speaking ? "speaker.wave.2.fill" : "waveform"
        let desc = speaking ? "Speaking — click menu to stop" : "Dictation History"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: desc)
    }

    @objc func copyLast() {
        guard let text = lastFinal() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Show the menu on right-click.
            item.menu = menu
            item.button?.performClick(nil)
            // Detach so subsequent left-clicks fire the action again.
            DispatchQueue.main.async { [weak self] in self?.item.menu = nil }
        } else {
            // Left click: copy last message + audible click feedback.
            copyLast()
            playMorse()
        }
    }

    func playMorse() {
        // NSSound works fine here because we're a real NSApplication with
        // .accessory activation policy (unlike record.app's headless context
        // where audio output was suppressed).
        NSSound(contentsOfFile: "/System/Library/Sounds/Morse.aiff",
                byReference: true)?.play()
    }

    /// nil representedObject = "System Default", i.e. remove the pin entirely.
    @objc func pickInput(_ sender: NSMenuItem) {
        let fm = FileManager.default
        if let name = sender.representedObject as? String {
            let dir = (inputDeviceFile as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? (name + "\n").write(toFile: inputDeviceFile, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(atPath: inputDeviceFile)
        }
        // Drop the published read-back too: it describes the device the daemon was
        // on before this change, and showing it as current would be a lie until
        // the restarted daemon republishes.
        try? fm.removeItem(atPath: actualInputFile)
        restartRecorder()
    }

    @objc func openHistory() {
        ensureHistoryFile()
        NSWorkspace.shared.open(historyURL)
    }

    @objc func showInFinder() {
        ensureHistoryFile()
        NSWorkspace.shared.activateFileViewerSelecting([historyURL])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // NSMenuDelegate — refresh the menu right before it appears so the
    // "Copy Last…" preview is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    /// Make sure the file exists so opening it never fails when no
    /// dictations have been recorded yet.
    private func ensureHistoryFile() {
        if !FileManager.default.fileExists(atPath: historyPath) {
            let placeholder = "# Dictation History\n\n_No dictations yet — hold the Globe key and speak._\n"
            try? placeholder.write(toFile: historyPath,
                                   atomically: true,
                                   encoding: .utf8)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = StatusController()
controller.install()

app.run()
