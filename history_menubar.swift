// history_menubar.swift — menu-bar icon for dictation history.
//
// Left-click  → opens dictate_history.md in your default editor.
// Right-click → menu with "Show in Finder" and "Quit".
//
// LSUIElement=true so no dock icon. Auto-started at login by a LaunchAgent.

import AppKit
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
