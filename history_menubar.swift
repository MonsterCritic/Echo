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

class StatusController: NSObject, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()

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
    }

    func rebuildMenu() {
        menu.removeAllItems()

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

    /// Read the history file and return the text of the most recent
    /// `**Final:**` block, or nil if the file is empty/missing.
    func lastFinal() -> String? {
        guard let content = try? String(contentsOfFile: historyPath,
                                        encoding: .utf8) else { return nil }
        guard let markerRange = content.range(of: "**Final:**",
                                              options: .backwards) else { return nil }
        let afterMarker = content[markerRange.upperBound...]
        // Trim leading whitespace/newline after the marker.
        let trimmedStart = afterMarker.drop(while: { $0.isWhitespace })
        // The block ends at the next "---" separator or end of file.
        let endRange = trimmedStart.range(of: "\n---")
        let body = endRange.map { String(trimmedStart[..<$0.lowerBound]) }
                   ?? String(trimmedStart)
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
