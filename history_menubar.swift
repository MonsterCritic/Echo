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

/// One-shot latch: `claim()` returns true for the first caller only. Used where
/// two racing paths may each want to act and exactly one should.
final class SettledOnce {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

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

// ── Language of the pasted text ──────────────────────────────────────────────
// dictate.py reads this on every dictation, so a change takes effect on the very
// next hold and nothing needs restarting.
let outputLangFile = NSString(string: "~/Library/Application Support/Echo/output_language")
                     .expandingTildeInPath

/// "ru" pastes what was spoken; "en" translates. English is the default.
func pastedLanguage() -> String {
    guard let raw = try? String(contentsOfFile: outputLangFile, encoding: .utf8) else { return "en" }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ru") ? "ru" : "en"
}

func setPastedLanguage(_ code: String) {
    let dir = (outputLangFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? (code + "\n").write(toFile: outputLangFile, atomically: true, encoding: .utf8)
}

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
    let id: AudioDeviceID
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
        out.append(InputDevice(id: id, name: cf as String, transport: transport))
    }
    return out
}

/// The system default input device's id.
func defaultInputDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &sz, &id) == noErr else { return nil }
    return id
}

/// Point macOS at a different input device — the same setting as
/// System Settings → Sound → Input.
///
/// This is how the picker works, rather than overriding the device on the
/// recorder's own audio engine. That override was the original design and it
/// could not be made to work: setting kAudioOutputUnitProperty_CurrentDevice on
/// the engine's input unit leaves the graph unable to start at all (-10868 for
/// every device tried), so choosing a microphone silently ended dictation until
/// the recorder was restarted without it. Moving the system default has no such
/// problem, because "follow the system default" is the configuration the
/// recorder already runs correctly on.
func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
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
        }

        // Attach the menu permanently, so either mouse button opens it. A left
        // click used to copy the newest entry outright, which reads as "nothing
        // happened" — copying is now an explicit item you can see and aim at.
        item.menu = menu

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

        // Recent results, newest first — clicking one copies it. Anything that
        // landed in the wrong window is recoverable from here without opening
        // the file.
        let recents = recentEntries(limit: 8)
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let heading = NSMenuItem(title: "Recent — click to copy", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for (i, entry) in recents.enumerated() {
                let item = NSMenuItem(title: previewText(entry.text, maxLen: 55),
                                      action: #selector(copyEntry(_:)),
                                      // Keep ⌘C on the newest, matching what the
                                      // old single Copy Last item was bound to.
                                      keyEquivalent: i == 0 ? "c" : "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "\(entry.header)\n\n\(entry.text)"
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // ── Microphone ───────────────────────────────────────────────────────
        // Titled with the live input, so the current mic is readable without
        // opening the submenu.
        let devices  = inputDevices()
        let currentID = defaultInputDeviceID()
        let inUse = devices.first { $0.id == currentID }?.name

        let micRoot = NSMenuItem(title: "Microphone: \(inUse ?? "unknown")",
                                 action: nil, keyEquivalent: "")
        let micMenu = NSMenu()

        for dev in devices {
            let item = NSMenuItem(title: dev.isBluetooth ? "\(dev.name)  · Bluetooth" : dev.name,
                                  action: #selector(pickInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: dev.id)
            item.state = (dev.id == currentID) ? .on : .off
            item.toolTip = dev.isBluetooth
                ? "Opening a Bluetooth mic drops the headset to mono call mode: it "
                + "delays the start of recording and degrades whatever you're listening to."
                : "Record from this input."
            micMenu.addItem(item)
        }

        micMenu.addItem(NSMenuItem.separator())
        let note = NSMenuItem(title: "Sets the macOS input device", action: nil, keyEquivalent: "")
        note.isEnabled = false
        micMenu.addItem(note)

        micRoot.submenu = micMenu
        menu.addItem(micRoot)

        // ── Language of the pasted text ──────────────────────────────────────
        let lang = pastedLanguage()
        let langRoot = NSMenuItem(title: "Language: \(lang == "ru" ? "Russian" : "English")",
                                  action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (code, title, tip) in [
            ("en", "English", "Translate what you dictate into English."),
            ("ru", "Russian", "Paste what you actually said, without translating."),
        ] {
            let item = NSMenuItem(title: title, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = (code == lang) ? .on : .off
            item.toolTip = tip
            langMenu.addItem(item)
        }
        langMenu.addItem(NSMenuItem.separator())
        let langNote = NSMenuItem(title: "Language of the pasted text", action: nil, keyEquivalent: "")
        langNote.isEnabled = false
        langMenu.addItem(langNote)

        langRoot.submenu = langMenu
        menu.addItem(langRoot)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Full History",
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
    /// One history entry: its `## ` header line and the output text.
    struct HistoryEntry {
        let header: String      // e.g. "2026-08-18 13:06:38 · Dictate"
        let text: String
    }

    /// The newest `limit` entries, newest first.
    ///
    /// History is prepended, so file order is already newest-first. Entries are
    /// separated by a `---` rule and each begins with a `## <time> · <kind>`
    /// header. The output text sits under a marker that varies by tool, so they
    /// are tried in order of specificity; a Dictate entry carries both a raw
    /// transcript and a final, and the final is the one worth copying.
    func recentEntries(limit: Int) -> [HistoryEntry] {
        guard let content = try? String(contentsOfFile: historyPath,
                                        encoding: .utf8) else { return [] }
        var out: [HistoryEntry] = []
        for block in content.components(separatedBy: "\n---") {
            if out.count >= limit { break }
            guard let hRange = block.range(of: "## ") else { continue }
            let afterHeader = block[hRange.upperBound...]
            guard let nl = afterHeader.firstIndex(of: "\n") else { continue }
            let header = String(afterHeader[..<nl]).trimmingCharacters(in: .whitespaces)
            let rest   = String(afterHeader[afterHeader.index(after: nl)...])

            func textAfter(_ marker: String) -> String? {
                guard let r = rest.range(of: marker) else { return nil }
                return String(rest[r.upperBound...])
            }

            let body = textAfter("**Rewritten:**")          // Rewrite
                    ?? textAfter("**Final:**")              // Dictate, prettified
                    ?? textAfter("**Raw transcript:**")     // Dictate, prettify failed
                    ?? rest                                 // plain entry
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            out.append(HistoryEntry(header: header, text: text))
        }
        return out
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

    /// Copy one entry, carried on the menu item itself.
    @objc func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        playMorse()
    }

    func playMorse() {
        // NSSound works fine here because we're a real NSApplication with
        // .accessory activation policy (unlike record.app's headless context
        // where audio output was suppressed).
        NSSound(contentsOfFile: "/System/Library/Sounds/Morse.aiff",
                byReference: true)?.play()
    }

    /// Switch the microphone by moving the macOS default input, then restart the
    /// recorder so its engine is built against the new device — it reads the
    /// input once at startup, and a running engine does not survive the change.
    @objc func pickInput(_ sender: NSMenuItem) {
        guard let boxed = sender.representedObject as? NSNumber else { return }
        guard setDefaultInputDevice(AudioDeviceID(boxed.uint32Value)) else { return }
        // Any leftover pin would poison the engine on the next start; the picker
        // no longer writes one, but an older install may have left one behind.
        try? FileManager.default.removeItem(atPath: inputDeviceFile)
        try? FileManager.default.removeItem(atPath: actualInputFile)
        restartRecorder()
    }

    /// Takes effect on the next dictation — dictate.py re-reads the setting each
    /// time, so there is nothing to restart here.
    @objc func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        setPastedLanguage(code)
    }

    /// Open the history file for reading.
    ///
    /// Harder than it looks, because the registered handler may be installed and
    /// still not launch. On this machine Sublime Text claims plain text, exists
    /// on disk with a valid signature, and simply never comes up: the synchronous
    /// NSWorkspace.open() blocks for minutes, and the asynchronous one never calls
    /// back at all. Either way the menu item appeared to do nothing.
    ///
    /// So: launch the handler asynchronously (never block the menubar), and if it
    /// hasn't come up shortly, open TextEdit instead — it ships with macOS, so it
    /// is always there. A handler that works keeps working; one that hangs stops
    /// being a dead end.
    @objc func openHistory() {
        ensureHistoryFile()
        let fm = FileManager.default
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: historyURL),
              fm.fileExists(atPath: handler.path),
              handler != textEdit else {
            openHistoryUsing(textEdit)
            return
        }

        // Whichever of the two paths gets here first wins, so the file is never
        // opened twice.
        let settled = SettledOnce()
        NSWorkspace.shared.open([historyURL], withApplicationAt: handler,
                                configuration: NSWorkspace.OpenConfiguration()) { running, _ in
            guard running == nil, settled.claim() else { return }   // only on failure
            DispatchQueue.main.async { [weak self] in self?.openHistoryUsing(textEdit) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard settled.claim() else { return }
            self?.openHistoryUsing(textEdit)
        }
    }

    private func openHistoryUsing(_ app: URL) {
        guard FileManager.default.fileExists(atPath: app.path) else {
            // Nothing can open it — at least put the file in front of the user.
            NSWorkspace.shared.activateFileViewerSelecting([historyURL])
            return
        }
        NSWorkspace.shared.open([historyURL], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
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
