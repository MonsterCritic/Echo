// record_realtime.swift — streaming voice-recording daemon.
//
// A parallel alternative to record.swift: instead of writing an m4a file and
// uploading it after release, it streams live mic audio to OpenAI's realtime
// transcription WebSocket DURING the hold, so the (Russian) transcript is ready
// the instant the key is released. dictate.py then translates + pastes.
//
// It also shows a live caption HUD while you speak (see LiveHUD). The HUD is our
// own floating window and nothing is typed into the target app during dictation,
// so it behaves identically in every app — the only interaction with the app
// remains the single final paste.
//
// Trigger is identical to record.swift: Karabiner touches /tmp/rewrite_record_start
// on press and removes it on release. On release this daemon writes the transcript
// to /tmp/rewrite_transcript.txt and touches /tmp/rewrite_record.ready.
//
// The API key is read from ~/Library/Application Support/Echo/openai_key (env
// var also honoured). It canNOT come from ~/Documents/.env — TCC blocks that for
// a launchd/LaunchServices process — and `open -Wg`, which the LaunchAgent needs
// for the app to hold a Microphone grant, drops environment variables anyway.
//
// record.swift + the whisper-1 path stay intact; this runs only when its own
// LaunchAgent is loaded (and dictate.py has REALTIME_MODE = True).

import AVFoundation
import AppKit
import Foundation

// ── Anti-App-Nap ──────────────────────────────────────────────────────────────
let activityToken = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .idleSystemSleepDisabled],
    reason:  "Realtime voice dictation daemon must respond to the hotkey immediately")
_ = activityToken

// ── Paths / config ─────────────────────────────────────────────────────────────
let startFlag      = "/tmp/rewrite_record_start"
let readyFlag      = "/tmp/rewrite_record.ready"
let transcriptPath = "/tmp/rewrite_transcript.txt"
let logPath        = "/tmp/record_realtime.log"

// One append-mode descriptor, held open, writes serialised by a lock.
//
// The previous version re-opened the file per line and seeked to the end, with no
// lock: concurrent writes from the poll thread, the audio tap and the WebSocket
// handler interleaved mid-line, producing entries like "igured — using system
// default". Worse, the fallback branch wrote `atomically: true`, which REPLACES
// the file, so whole runs of history disappeared. That cost real debugging time —
// a missing line could mean either the event never happened or its write was
// lost, which are very different diagnoses.
let logLock = NSLock()
let logFD: Int32 = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)

func log(_ s: String) {
    guard let data = "[\(Date())] \(s)\n".data(using: .utf8) else { return }
    logLock.lock(); defer { logLock.unlock() }
    if logFD >= 0 {
        _ = data.withUnsafeBytes { write(logFD, $0.baseAddress, $0.count) }
    }
}

// Key lookup: environment first (direct exec), then a key file. We can't read
// ~/Documents/.env — TCC blocks that for a launchd/LaunchServices process — but
// ~/Library/Application Support is readable, so the installer mirrors the key
// there (chmod 600). A file also survives `open -Wg`, which drops the
// environment but is required for the app to get a Microphone grant.
let keyFile = NSString(string: "~/Library/Application Support/Echo/openai_key")
              .expandingTildeInPath

func resolveAPIKey() -> String? {
    if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
        return env
    }
    if let s = try? String(contentsOfFile: keyFile, encoding: .utf8) {
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { return k }
    }
    return nil
}

guard let apiKey = resolveAPIKey() else {
    log("FATAL: no API key — set OPENAI_API_KEY or create \(keyFile)")
    exit(1)
}

// ── Live caption HUD ─────────────────────────────────────────────────────────
// Shows what you're saying, as you say it, in our OWN floating window. Nothing
// is typed into the target app while dictating, so this is completely
// independent of how any given app's input behaves — the only interaction with
// the app remains the single final paste that dictate.py already does.
//
// Non-activating + click-through, so the caret stays in the user's input field.
/// The language strip on the right of the caption. Clicking it switches the
/// language the dictation will be pasted in.
/// The controls beside the caption: language, microphone, and clear, stacked top
/// to bottom. Rows divide the column evenly, so they stay usable whether the
/// caption is one line or three.
final class LangStrip: NSView {
    struct Row {
        let label: NSTextField
        let action: (() -> Void)?      // nil = read-only, shown but not clickable
    }

    var rows: [Row] = []
    var ruleView: NSBox?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !rows.isEmpty else { return }
        let rowH = bounds.height / CGFloat(rows.count)
        // Rows are laid out top-down; view coordinates count up from the bottom.
        let idx = min(rows.count - 1, max(0, Int((bounds.height - p.y) / rowH)))
        rows[idx].action?()
    }

    /// Swallow the hit so the labels inside don't take the click themselves.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// A stretched NSTextField draws its text at the top of its frame, so each
    /// label is centred inside its own row rather than resized with the column.
    override func layout() {
        super.layout()
        ruleView?.frame = NSRect(x: 0, y: 8, width: 1, height: max(bounds.height - 16, 0))
        guard !rows.isEmpty else { return }
        let rowH = bounds.height / CGFloat(rows.count)
        let textH: CGFloat = 14
        for (i, row) in rows.enumerated() {
            let top = bounds.height - CGFloat(i + 1) * rowH
            row.label.frame = NSRect(x: 0, y: top + (rowH - textH) / 2,
                                     width: bounds.width, height: textH)
        }
    }
}

/// The caption sits over whatever is being dictated into, so it must not absorb
/// clicks — except on the strip, which is a control. Everything else reports no
/// hit at all and the click reaches the app underneath.
final class HUDContent: NSVisualEffectView {
    var clickable: NSRect = .zero
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: nil)
        guard clickable.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

final class LiveHUD {
    static let shared = LiveHUD()

    private var window: NSWindow?
    private var label: NSTextField?
    private var bgView: NSVisualEffectView?
    private let width: CGFloat = 900
    // The panel grows with the text instead of reserving a fixed block of screen.
    // Growth was what previously made a whole line appear at once, but the cause
    // was specifically setFrame(display: TRUE) forcing a synchronous redraw on
    // the main thread mid-speech. Resizing with display: false lets AppKit
    // coalesce the redraw, so we can have both fit-to-content and smooth text.
    // Tall enough that three control rows beside the caption are not cramped;
    // the caption itself only needs one line at this size.
    private let minHeight: CGFloat = 84
    // Three lines, then it scrolls. Measured from the field's own metrics once it
    // exists rather than set as a pixel guess, so it is exactly three lines
    // whatever the font does. The caption sits over the interface being dictated
    // into, and past a few lines it is in the way — the newest words are what
    // matter while speaking, and the whole text arrives on release anyway.
    private var maxHeight: CGFloat = 420
    private var currentHeight: CGFloat = 0
    private let padX: CGFloat = 18
    private let padY: CGFloat = 12
    // A column down the right for the language, reserved rather than overlaid so a
    // long caption can never run underneath it. It was briefly a strip along the
    // TOP, which was wrong twice over: the panel's height is computed as the text
    // height plus vertical padding, so stealing 18pt from the text field left it
    // permanently too short for its own content — the first line was clipped, and
    // the panel appeared to grow strangely. A column takes width, which the text
    // measurement already accounts for.
    private let rightW: CGFloat = 150
    private var badge: NSTextField?
    private var micLabel: NSTextField?
    private var strip: LangStrip?
    private var badgeTimer: Timer?
    private let bottomInset: CGFloat = 90

    private func build() {
        // NSPanel, not NSWindow: .nonactivatingPanel only means anything on a panel,
        // and the strip is clickable now. An ordinary window would activate this
        // process on click and take focus away from the field being dictated into.
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: minHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.becomesKeyOnlyIfNeeded = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating                 // above normal windows
        w.ignoresMouseEvents = false        // only the strip accepts them
        w.hasShadow = true
        // Follow the user across Spaces / over fullscreen apps.
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = HUDContent(frame: NSRect(x: 0, y: 0, width: width, height: minHeight))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let tf = NSTextField(frame: NSRect(x: padX, y: padY,
                                          width: width - rightW - padX * 2,
                                          height: minHeight - padY * 2))
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.font = .systemFont(ofSize: 16, weight: .medium)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byWordWrapping
        tf.usesSingleLineMode = false
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        tf.maximumNumberOfLines = 0        // grow instead of truncating
        tf.stringValue = "Listening…"
        tf.alignment = .left
        tf.autoresizingMask = [.width, .height]

        // Which language this dictation will be pasted in. Worth showing while
        // speaking: the setting can be flipped mid-hold with Globe + Space, and
        // otherwise the only way to find out which way it went is to finish the
        // sentence and see what language comes back.
        // The column: a hairline separator, the language, and a hint that it can be
        // clicked. Clicking beats reaching for the menubar mid-sentence, and works
        // when the key combination does not.
        let col = LangStrip(frame: NSRect(x: width - rightW, y: 0,
                                          width: rightW, height: minHeight))
        col.autoresizingMask = [.minXMargin, .height]

        let rule = NSBox(frame: NSRect(x: 0, y: 8, width: 1, height: minHeight - 16))
        rule.boxType = .separator
        col.addSubview(rule)

        func row(_ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat) -> NSTextField {
            let f = NSTextField(labelWithString: "")
            f.font = .systemFont(ofSize: size, weight: weight)
            f.textColor = NSColor.labelColor.withAlphaComponent(alpha)
            f.alignment = .center
            f.drawsBackground = false
            f.cell?.usesSingleLineMode = true
            f.cell?.lineBreakMode = .byTruncatingTail
            col.addSubview(f)
            return f
        }

        let bd  = row(12, .semibold, 0.75)   // language — click to switch
        let mic = row(10, .regular, 0.45)    // which microphone is being heard
        let clr = row(11, .semibold, 0.55)   // discard what has been said so far
        clr.stringValue = "CLEAR"

        col.rows = [
            .init(label: bd,  action: { LiveHUD.shared.toggleLanguage() }),
            // Clicking switches device mid-recording. That is a real teardown
            // and rebuild of the audio graph, so it can fail; switchInputDevice
            // restores the previous device if it does.
            .init(label: mic, action: { LiveHUD.shared.cycleInput() }),
            .init(label: clr, action: { LiveHUD.shared.clearTranscript() }),
        ]
        col.ruleView = rule
        col.needsLayout = true
        micLabel = mic

        bg.addSubview(tf)
        bg.addSubview(col)
        bg.clickable = col.frame
        w.contentView = bg
        window = w
        label = tf
        badge = bd
        strip = col
        bgView = bg
        maxHeight = heightFor("X\nX\nX") + padY * 2
    }

    /// Move to the next input device, live. Cycles rather than opening a menu: the
    /// caption is not a place for a popup, and there are rarely more than a few.
    func cycleInput() {
        let devices = inputDeviceList()
        guard devices.count > 1 else { return }
        let current = pendingInputName
            ?? (try? String(contentsOfFile: actualInputFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let i = devices.firstIndex { $0.name == current } ?? -1
        let next = devices[(i + 1) % devices.count]
        micLabel?.stringValue = "switching…"
        switchInputDevice(to: next.id, named: next.name)
    }

    /// Update the column immediately, rather than waiting for the next tick.
    func refreshNow() { DispatchQueue.main.async { self.refreshBadge() } }

    /// Discard what has been transcribed so far, without stopping the recording.
    func clearTranscript() {
        session?.clearSoFar()
    }

    /// Flip the language from the caption itself. Writes the same file the menubar
    /// item and Globe + Space write, so all three always agree.
    func toggleLanguage() {
        let path = NSString(string: "~/Library/Application Support/Echo/output_language")
                   .expandingTildeInPath
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let ru = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ru")
        let next = ru ? "en" : "ru"
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (next + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        log("caption: language switched to \(next) by click")
        DispatchQueue.main.async { self.refreshBadge() }
    }

    /// Read fresh each time — dictate.py reads the same file per dictation, so
    /// what the badge says is exactly what will be pasted.
    private func refreshBadge() {
        let path = NSString(string: "~/Library/Application Support/Echo/output_language")
                   .expandingTildeInPath
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let ru = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ru")
        badge?.stringValue = ru ? "RUSSIAN" : "ENGLISH"

        // Published by the recorder when it opens the device, so this is the mic
        // actually in use rather than the one that was asked for.
        let micPath = "/tmp/echo_input_actual.txt"
        var mic = (try? String(contentsOfFile: micPath, encoding: .utf8))?
                  .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Deliberately a file read, not a CoreAudio query: this runs on a timer
        // several times a second while the caption is up, and CoreAudio is exactly
        // the thing that has been hanging on this machine.
        func short(_ n: String) -> String { n.replacingOccurrences(of: " Microphone", with: "") }
        if let pending = pendingInputName {
            // Says plainly that the click landed but the change waits for the next
            // hold — better than showing a device that is not being recorded from.
            micLabel?.stringValue = "NEXT: " + short(pending)
        } else {
            micLabel?.stringValue = mic.isEmpty ? "—" : short(mic)
        }
    }

    /// Height `text` needs at our fixed width, measured with the field's own cell
    /// (which accounts for its internal insets, unlike NSString.boundingRect).
    private func heightFor(_ text: String) -> CGFloat {
        guard let lbl = label, let cell = lbl.cell as? NSTextFieldCell else { return 0 }
        let saved = cell.stringValue
        cell.stringValue = text
        let bounds = NSRect(x: 0, y: 0, width: lbl.frame.width, height: 100_000)
        let needed = cell.cellSize(forBounds: bounds).height
        cell.stringValue = saved
        return ceil(needed)
    }

    /// Bottom-centre of whichever screen holds the pointer — like live captions,
    /// so it doesn't cover the input being typed into. The bottom edge stays put
    /// and the panel grows upward.
    ///
    /// `display: false` is important: the synchronous variant forces an immediate
    /// relayout on the main thread, which is what previously stalled the caption
    /// at each line wrap. This way AppKit redraws on its own next cycle.
    private func reposition(height: CGFloat) {
        guard let w = window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
                  ?? NSScreen.main?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.midX - width / 2
        let y = screen.minY + bottomInset
        w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        // hitTest compares against this, so it has to track the resize.
        if let strip = strip, let bg = bgView as? HUDContent { bg.clickable = strip.frame }
    }

    func show() {
        DispatchQueue.main.async {
            if self.window == nil { self.build() }
            self.label?.stringValue = "Listening…"
            self.refreshBadge()
            // Poll while visible: the language can change mid-hold and there is no
            // notification to hang this off.
            self.badgeTimer?.invalidate()
            let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.refreshBadge()
            }
            RunLoop.main.add(t, forMode: .common)
            self.badgeTimer = t
            self.pendingText = nil
            self.currentHeight = self.minHeight
            self.reposition(height: self.minHeight)
            self.window?.orderFrontRegardless()   // show WITHOUT taking focus
        }
    }

    /// Latest text awaiting display, and whether a flush is already queued.
    /// Deltas can arrive faster than the window can redraw, so the newest text
    /// is applied on a fixed interval instead of once per delta.
    private var pendingText: String?
    private var flushQueued = false
    private let flushInterval = 0.05

    func update(_ text: String) {
        DispatchQueue.main.async {
            self.pendingText = text
            guard !self.flushQueued else { return }
            self.flushQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + self.flushInterval) {
                self.flush()
            }
        }
    }

    /// Main thread only. Sets the visible text, then grows the panel to fit it —
    /// resizing only when the height actually changed, and never with a
    /// synchronous redraw. Past maxHeight the front is trimmed instead, which
    /// reads as the caption scrolling up.
    private func flush() {
        flushQueued = false
        guard let raw = pendingText, let label = label else { return }
        pendingText = nil

        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var display = t.isEmpty ? "Listening…" : t

        let fits = maxHeight - padY * 2
        if heightFor(display) > fits {
            // Binary-search the longest suffix that still fits, so the newest
            // words — what's being spoken right now — stay visible.
            let chars = Array(display)
            var lo = 0, hi = chars.count
            while lo < hi {
                let mid = (lo + hi) / 2                     // drop `mid` chars
                let candidate = "…" + String(chars[mid...])
                if heightFor(candidate) > fits { lo = mid + 1 } else { hi = mid }
            }
            display = lo >= chars.count ? String(chars.suffix(40))
                                        : "…" + String(chars[lo...])
        }
        label.stringValue = display

        let h = min(max(heightFor(display) + padY * 2, minHeight), maxHeight)
        if abs(h - currentHeight) > 0.5 {
            currentHeight = h
            reposition(height: h)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.badgeTimer?.invalidate()
            self.badgeTimer = nil
            self.window?.orderOut(nil)
        }
    }
}

// Declared above RealtimeSession, which reads it when a session is built. Top-level
// globals initialise in source order and the poll thread starts during that init,
// so a start flag already present at launch can reach this before it exists —
// the ordering trap that has already caused one crash in this file.
let delayFile = NSString(string: "~/Library/Application Support/Echo/transcribe_delay")
                .expandingTildeInPath

/// The configured tier, falling back to the default for anything unrecognised — a
/// typo in the file must not be able to take dictation down.
func transcribeDelay() -> String {
    guard let raw = try? String(contentsOfFile: delayFile, encoding: .utf8) else {
        return RealtimeSession.defaultDelay
    }
    let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return RealtimeSession.validDelays.contains(v) ? v : RealtimeSession.defaultDelay
}

// ── Realtime WebSocket session ───────────────────────────────────────────────
final class RealtimeSession {
    // gpt-live-transcribe streams transcript deltas AS SPEECH ARRIVES, which is
    // what makes the live HUD actually live. gpt-4o-transcribe only emits text
    // once an utterance has been committed, so nothing appeared until you
    // paused. The trade-off: this model rejects turn_detection ("Turn detection
    // is not supported for this transcription model"), so there are no
    // speech_started/stopped events and pauses are inferred from gaps between
    // deltas instead.
    static let model = "gpt-live-transcribe"
    // Russian only, not ["ru","en"]. With both listed the model auto-detects per
    // utterance and reliably mis-called the opening word as English before
    // settling into Russian — the first word of almost every dictation. The
    // speaker dictates in Russian; English technical terms inside that speech
    // survive fine, and the translate step in dictate.py turns the whole thing
    // into English regardless, so there is nothing for "en" to earn here.
    static let languages = ["ru"]

    // How much audio the model hears before committing tokens. The server names
    // all five when it rejects a bad one: minimal, low, medium, high, xhigh.
    // Lower gets text on screen sooner and identifies the language worse — which
    // is what made the opening words come back as Chinese or English.
    //
    // Read per session rather than baked in, so it can be changed from the
    // menubar and apply to the next hold. Only the speaker can judge this trade.
    static let validDelays = ["minimal", "low", "medium", "high", "xhigh"]
    static let defaultDelay = "low"
    let delay = transcribeDelay()

    // Told to the model as context, which is why this string is Russian: it is
    // functional input to an acoustic model, not copy anyone reads. Priming with
    // Russian text is what stops the opening words being decoded as some other
    // language — "languages" turns out to be a hint list the model can still
    // depart from, confirmed by asking the server what it applied: it reports
    // languages ["ru"] and a separate, unused prompt field. With delay "minimal"
    // the model commits tokens before it has heard enough to identify the
    // language, so the first word or two came back as Chinese, English or
    // nonsense. The domain words are here for the same reason — they are the
    // vocabulary actually being dictated, so the model reaches for them instead
    // of inventing look-alikes.
    static let prompt = "Транскрибируй речь только на русском языке. "
                      + "Не переключайся на другие языки. Тематика — "
                      + "веб-интерфейсы: инпут, кнопка, дропдаун, домен, "
                      + "воркспейс, мобильная версия, иконка в меню."

    private let ws: URLSessionWebSocketTask
    private let lock = NSLock()
    private var configured = false
    private var pending: [Data] = []       // audio captured before session.updated
    // Two texts, deliberately: `deltaText` is the fast, rougher stream used only
    // to drive the live HUD, while `transcript` holds the server's authoritative
    // completed transcription and is what actually gets pasted. Streaming trades
    // accuracy for latency, so this keeps the preview snappy without degrading
    // the result. deltaText is the fallback if no completed event arrives.
    private(set) var transcript = ""
    private var deltaText = ""
    private var lastActivity = Date()
    // Every committed utterance produces exactly one transcription. Counting
    // both lets stopRecording wait for the LAST segment instead of guessing
    // from "the transcript stopped growing" — which bailed early after a pause
    // and silently dropped the tail of the dictation.
    private var committedCount = 0
    private var completedCount = 0
    // Utterances committed at or before this point were cleared by the user. Their
    // transcriptions are still in flight and will arrive afterwards; without this
    // they would append themselves back into a transcript that was just emptied.
    private var discardThrough = 0
    private var commitRejected = false

    // Pause tracking: a noticeable silence between utterances almost always
    // means a new thought, so it becomes a line break instead of a space.
    // speech_started/stopped bracket each utterance, and they arrive in order,
    // so a FIFO of "was this utterance preceded by a long pause?" lines up with
    // the transcription-completed events.
    // Pause detection for the LIVE CAPTION ONLY. Earlier attempts failed because
    // delta arrival tracked the model's processing rhythm rather than speech, but
    // with delay="minimal" deltas now land as the words are spoken, so a gap
    // between them does correspond to a real pause.
    //
    // This is deliberately cosmetic: it marks up `deltaText` (the HUD string),
    // never `transcript` (what gets pasted). The pasted text is paragraphed by
    // the translate step in dictate.py, which splits on meaning. So a mistuned
    // threshold can only look wrong on screen — it cannot corrupt the output.
    //
    // Threshold picked from 125 logged breaks rather than by feel. Their gaps
    // form a dense cluster from 1.0–2.25s (78% of them) and then collapse to a
    // thin tail — two populations: ordinary between-phrase timing, and pauses the
    // speaker actually meant. 1.2s sliced through the middle of the first one, so
    // the caption broke mid-sentence while dictating normally. 2.5s sits in the
    // gap between them and keeps the 18% that look deliberate.
    static let pauseBreakSeconds = 2.5
    private var lastDeltaAt: Date? = nil

    init(key: String) {
        let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        ws = URLSession(configuration: .default).webSocketTask(with: req)
    }

    func start() {
        ws.resume()
        receive()
        // Configure the transcription session (GA format, validated by probe).
        sendJSON([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "transcription": [
                        "model": Self.model,
                        // "languages" (plural array) is the documented field. The
                        // singular "language" was silently ignored, leaving the
                        // model to auto-detect — which is why a stray Chinese
                        // character sometimes appeared at the start. Both ru and
                        // en are listed because dictation mixes them ("localhost",
                        // "restore").
                        "languages": Self.languages,
                        "prompt": Self.prompt,
                        // Lowest latency, so words appear as they're spoken. Safe
                        // because the text we paste comes from the completed
                        // transcript, not this stream — a rougher live preview
                        // costs us nothing.
                        "delay": delay,
                    ],
                    // No turn_detection here: gpt-live-transcribe rejects it.
                ]],
            ],
        ])
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(s)) { e in if let e = e { log("send err: \(e)") } }
    }

    /// Feed 24kHz/PCM16 mono audio. Buffered until the session is configured.
    func sendAudio(_ pcm: Data) {
        lock.lock()
        let ready = configured
        if !ready { pending.append(pcm) }
        lock.unlock()
        if ready {
            sendJSON(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
        }
    }

    func commit() { sendJSON(["type": "input_audio_buffer.commit"]) }
    func close()  { ws.cancel(with: .normalClosure, reason: nil) }
    func idleSeconds() -> TimeInterval { -lastActivity.timeIntervalSinceNow }

    /// The text to hand off: the server's completed transcription, or the
    /// streamed delta text if (unexpectedly) no completed event ever arrived, so
    /// a dictation is never silently lost.
    /// Throw away everything said so far and keep listening.
    ///
    /// For the case where the opening words came out wrong: rather than stopping,
    /// pasting the mistake and starting again, drop what has accumulated and carry
    /// on talking. Only the text after this point is pasted.
    ///
    /// The recording is untouched — this clears what has been transcribed, not the
    /// audio stream, so speech continues to arrive without a gap.
    func clearSoFar() {
        lock.lock()
        transcript = ""
        deltaText = ""
        lastDeltaAt = nil
        // Everything already committed is now unwanted, including the utterances
        // whose transcriptions have not come back yet.
        discardThrough = committedCount
        lock.unlock()
        log("caption: cleared by the user — keeping the recording running")
        LiveHUD.shared.update("")
    }

    func finalText() -> String {
        lock.lock(); defer { lock.unlock() }
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let d = deltaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { log("no completed transcript — falling back to delta text") }
        return d
    }

    /// True once every committed utterance has come back transcribed.
    func allSegmentsTranscribed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return completedCount >= committedCount
    }

    func segmentCounts() -> (committed: Int, completed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (committedCount, completedCount)
    }

    /// Set when a commit is rejected for an empty buffer — that commit will
    /// never produce a transcription, so nothing should wait for it.
    func sawRejectedCommit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return commitRejected
    }

    private func flushPending() {
        lock.lock(); let buffered = pending; pending = []; configured = true; lock.unlock()
        for chunk in buffered {
            sendJSON(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
        }
        if !buffered.isEmpty { log("flushed \(buffered.count) buffered chunks") }
    }

    private func receive() {
        ws.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                log("recv error: \(e)")
            case .success(let msg):
                if case .string(let s) = msg { self.handle(s) }
                self.receive()
            }
        }
    }

    private func handle(_ s: String) {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "session.updated":
            flushPending()
        case "input_audio_buffer.committed":
            lock.lock(); committedCount += 1; let n = committedCount; lock.unlock()
            log("utterance committed (#\(n)) — awaiting its transcription")
        case "conversation.item.input_audio_transcription.completed":
            // Authoritative text for this utterance — this is what gets pasted.
            let seg = (obj["transcript"] as? String ?? "")
                      .trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock()
            completedCount += 1
            let stale = completedCount <= discardThrough
            if !seg.isEmpty && !stale {
                transcript += transcript.isEmpty ? seg : " " + seg
            }
            lastActivity = Date()
            let (c, d) = (committedCount, completedCount)
            lock.unlock()
            // Deliberately does NOT refresh the HUD. `transcript` and `deltaText`
            // accumulate independently, so showing the completed text here made
            // the display jump backwards to a shorter, earlier state mid-speech
            // (text appeared to freeze on a word, then leap forward). The HUD
            // follows only the monotonically growing delta stream.
            log("utterance transcribed \(d)/\(c) (\(seg.count) chars)"
                + (stale ? " — discarded, cleared by the user" : ""))
        case "conversation.item.input_audio_transcription.delta":
            // Deltas stream as speech arrives and are purely additive, so they
            // ARE the transcript — we build it here rather than waiting for the
            // completed event. That also lets us mark pauses: a gap in delta
            // arrival means the speaker stopped talking, i.e. a new thought.
            let d = obj["delta"] as? String ?? ""
            if d.isEmpty { return }
            lock.lock()
            // Time to the first caption text. This is the number that matters when
            // weighing `delay`: "minimal" commits tokens on very little audio,
            // which is why the opening words can be decoded as the wrong language,
            // and "low" (the only other accepted value) trades some of this
            // latency for more evidence before committing.
            let isFirstText = lastDeltaAt == nil
            var gap = 0.0
            if let last = lastDeltaAt { gap = -last.timeIntervalSinceNow }
            let isBreak = lastDeltaAt != nil && gap >= Self.pauseBreakSeconds
                          && !deltaText.isEmpty
            if isBreak {
                // Blank line for a new thought; drop the delta's leading space so
                // the new paragraph isn't indented.
                deltaText += "\n\n" + String(d.drop(while: { $0 == " " }))
            } else {
                deltaText += d
            }
            lastDeltaAt = Date()
            lastActivity = Date()
            let live = deltaText
            lock.unlock()
            if isFirstText {
                let ms = Int(-recordingStartedAt.timeIntervalSinceNow * 1000)
                log("caption: first text \(ms)ms after press (delay: \(delay))")
            }
            if isBreak { log(String(format: "caption: pause %.2fs → break", gap)) }
            LiveHUD.shared.update(live)
        case "error":
            // Server VAD usually commits every utterance on its own, so our
            // final explicit commit often finds an empty buffer. That's
            // expected and harmless — don't log it as an error.
            if s.contains("input_audio_buffer_commit_empty") {
                lock.lock(); commitRejected = true; lock.unlock()
                log("final commit had nothing left (VAD already committed) — ok")
            } else {
                log("API error: \(s)")
            }
        default:
            break
        }
    }
}

// ── Input device pinning ─────────────────────────────────────────────────────
// Opening the mic on a Bluetooth headset forces macOS to switch it from A2DP
// (high-quality output) to HFP/SCO (low-quality two-way), which costs ~1.5-2s
// while the link renegotiates and audibly degrades whatever you're listening to.
// Recording from a wired input instead avoids the switch completely, so the
// headphones are never touched and there's no stall before capture starts.
//
// Opt-in and machine-specific: hardware differs per user, so by default we pin
// nothing and simply use whatever macOS has selected as the input. To pin a
// device, write its name (or any distinctive part of it) into
// ~/Library/Application Support/Echo/input_device. A name that matches nothing
// currently connected also falls back to the system default, so unplugging the
// device never breaks dictation.
//
// Run `record_realtime --list-inputs` to print the available input device names.
let inputDeviceFile = NSString(string: "~/Library/Application Support/Echo/input_device")
                      .expandingTildeInPath

// Where we publish the device the engine is REALLY on, for the menubar to read.
// Only written when a pin was attempted — that's the only case where "what we
// asked for" and "what we got" can disagree. With no pin the menubar resolves
// the system default itself, so the daemon needn't touch the engine at all.
// Lives in /tmp deliberately: it describes this process's live state and should
// not outlive it.
let actualInputFile = "/tmp/echo_input_actual.txt"

/// nil = use whatever macOS has selected.
func preferredInputName() -> String? {
    guard let s = try? String(contentsOfFile: inputDeviceFile, encoding: .utf8) else { return nil }
    let name = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

/// Does this device actually have input channels? (Output-only devices share
/// the same name as their input counterpart on some hardware.)
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

/// The system default input device.
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

/// Point macOS at a different input. Used when a live switch is refused, so the
/// choice still takes effect on the next dictation rather than being discarded.
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

/// Human-readable name of one device.
func deviceName(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfName: CFString = "" as CFString
    var sz = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &cfName) == noErr else { return nil }
    return cfName as String
}

func inputDevice(matching target: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids where hasInputChannels(id) {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString = "" as CFString
        var sz = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &sz, &cfName) == noErr {
            if (cfName as String).localizedCaseInsensitiveContains(target) { return id }
        }
    }
    return nil
}

/// Names of every device that can capture audio.
/// Every capture device, with its id, in CoreAudio's order.
func inputDeviceList() -> [(id: AudioDeviceID, name: String)] {
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
    return ids.filter(hasInputChannels).compactMap { id in
        deviceName(id).map { (id, $0) }
    }
}

// A device chosen mid-dictation that could not be applied live. Shown in the
// caption so the click is visibly not ignored, and cleared once a recording
// actually opens on it.
var pendingInputName: String?

// Reinstalls the mic tap for the recording in progress. Held here because
// switching devices has to tear the tap down and put it back, and the closure it
// needs captures per-recording state that only startRecording has.
var reinstallTap: (() -> Void)?

// Serialised off the poll thread and off main. Doing CoreAudio device work on the
// poll thread has deadlocked this daemon before, and doing it on main freezes the
// caption while it runs.
let inputSwitchQueue = DispatchQueue(label: "echo.input-switch")

/// Change the microphone without stopping the dictation.
///
/// The engine holds the device open for the duration of a recording, so this is a
/// genuine teardown and rebuild: stop, repoint the input unit, re-read the format,
/// reinstall the tap, start. Roughly half a second of audio is lost in the middle.
///
/// It can fail — -10868 FormatNotSupported is the usual way — so the previous
/// device is restored on failure, and if that fails too the process exits and
/// launchd supplies a clean one rather than leaving a dictation that looks live
/// and is recording nothing.
func switchInputDevice(to target: AudioDeviceID, named: String) {
    inputSwitchQueue.async {
        guard let unit = engine.inputNode.audioUnit else { return }

        var previous = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &previous, &sz)

        func apply(_ dev: AudioDeviceID) -> Bool {
            var d = dev
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &d,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { log("input switch: could not repoint (OSStatus \(st))") }
            reinstallTap?()
            engine.prepare()
            do { try engine.start(); return true }
            catch { log("input switch: engine would not start — \(error)"); return false }
        }

        if apply(target) {
            log("input switched to '\(named)' mid-recording")
            try? named.write(toFile: actualInputFile, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { LiveHUD.shared.refreshNow() }
            return
        }
        log("input switch failed — putting '\(deviceName(previous) ?? "the previous device")' back")
        if apply(previous) {
            if let n = deviceName(previous) {
                try? n.write(toFile: actualInputFile, atomically: true, encoding: .utf8)
            }
            // The recording keeps the old device, but the choice is not thrown
            // away: point macOS at the new one so the next dictation opens it.
            // The menubar's input guard is told too, or it would pull the default
            // straight back to whatever it is holding.
            if setDefaultInputDevice(target) {
                let dir = NSString(string: "~/Library/Application Support/Echo")
                          .expandingTildeInPath
                try? FileManager.default.createDirectory(atPath: dir,
                                                         withIntermediateDirectories: true)
                try? named.write(toFile: dir + "/preferred_input",
                                 atomically: true, encoding: .utf8)
                pendingInputName = named
                log("'\(named)' will be used from the next dictation")
            }
            DispatchQueue.main.async { LiveHUD.shared.refreshNow() }
        } else {
            log("AUDIO STUCK: neither device would start after the switch — exiting for a clean recorder")
            exit(1)
        }
    }
}

func availableInputNames() -> [String] {
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
    var names: [String] = []
    for id in ids where hasInputChannels(id) {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString = "" as CFString
        var sz = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &sz, &cfName) == noErr {
            names.append(cfName as String)
        }
    }
    return names
}

// Signalled once the pin attempt has finished (successfully or not). Recording
// waits on this: changing the input device while the engine is being configured
// invalidates its format, which showed up as a -10868 FormatNotSupported and a
// tap that delivered 0 bytes — the HUD appeared but nothing was ever heard.
// A hang while opening the audio graph needs its own guard.
//
// `engine.inputNode` can block indefinitely when CoreAudio is wedged. It happens
// on the poll thread, so the whole flag loop stops: no recording, no error, no
// further holds, and the zero-capture watchdog below never fires because it counts
// COMPLETED recordings and a hang never completes one. Dictation just stops, which
// is exactly the silent failure this recorder is supposed to have stopped having.
//
// So bound it. If a hold hasn't got the engine running shortly after the key went
// down, say so and exit: launchd supplies a clean process, which cures a wedge
// confined to this one. A wedge in CoreAudio itself will hang the next process
// too — the repeated log lines are then the diagnosis, and the cure is restarting
// coreaudiod, which no amount of restarting this daemon can substitute for.
let engineWatchLock = NSLock()
var engineStartSeq = 0
var engineStartDone = 0

func beginEngineWatch() -> Int {
    engineWatchLock.lock(); defer { engineWatchLock.unlock() }
    engineStartSeq += 1
    return engineStartSeq
}

func finishEngineWatch(_ seq: Int) {
    engineWatchLock.lock(); defer { engineWatchLock.unlock() }
    engineStartDone = max(engineStartDone, seq)
}

func engineWatchPending(_ seq: Int) -> Bool {
    engineWatchLock.lock(); defer { engineWatchLock.unlock() }
    return engineStartDone < seq
}

// Self-healing. Every way this recorder has broken looks the same from outside:
// the process is alive and responsive, the flags still work, and every recording
// captures zero bytes — a wedged CoreAudio graph, a device that vanished, an
// engine that refused to start. None of it recovers in-process; all of it is
// cured by a fresh process, which launchd will hand us for free on exit.
//
// So count consecutive silent recordings and exit once it is clearly not a
// one-off, rather than staying up and quietly dropping every dictation until
// someone notices and restarts by hand.
var deadCaptures = 0
let deadCaptureLimit = 2
var recordingStartedAt = Date()

let pinSettled = DispatchSemaphore(value: 0)
var pinSignalled = false
let pinLock = NSLock()

func signalPinSettled() {
    pinLock.lock(); defer { pinLock.unlock() }
    if !pinSignalled { pinSignalled = true; pinSettled.signal() }
}

/// Input-device selection is NOT done here any more.
///
/// This used to set kAudioOutputUnitProperty_CurrentDevice on the engine's input
/// unit. Doing so leaves the graph unable to start at all: engine.start() then
/// fails with -10868 FormatNotSupported for every device tried, captures nothing,
/// and does not recover in-process — pointing the unit back at the system default
/// and resetting the engine fails identically. The practical effect was that
/// choosing a microphone silently ended dictation, with no caption and no audio,
/// until the recorder was restarted without a pin.
///
/// The menubar's Microphone picker moves the macOS default input instead, which
/// is the configuration this recorder already runs correctly on. So there is
/// nothing to override here; we only warn about a leftover config file, because
/// applying it is what used to break capture.
func pinInputDevice() {
    defer { signalPinSettled() }
    guard let want = preferredInputName() else {
        log("using the system default input")
        return
    }
    log("ignoring stale pin '\(want)' — pinning broke capture and is no longer applied")
    log("delete \(inputDeviceFile) to silence this")
}

// ── Live PCM capture (AVAudioEngine → 24kHz Int16) ───────────────────────────
let engine = AVAudioEngine()
var converter: AVAudioConverter?
var session: RealtimeSession?
let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                                 channels: 1, interleaved: true)!

func convertToPCM16(_ input: AVAudioPCMBuffer) -> Data? {
    guard let converter = converter else { return nil }
    let ratio = targetFormat.sampleRate / input.format.sampleRate
    let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return nil }
    var fed = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    if let err = err { log("convert err: \(err)"); return nil }
    guard let ch = out.int16ChannelData, out.frameLength > 0 else { return nil }
    return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
}

let stateLock = NSLock()
var isRecording = false
var sentBytes = 0

func startRecording() {
    // Guard against a double-start: the poll loop and any retry path must not
    // create two sessions / two mic taps.
    stateLock.lock()
    if isRecording { stateLock.unlock(); return }
    isRecording = true
    sentBytes = 0
    stateLock.unlock()

    log("hold: start")   // everything below has hung at least once; mark the phases
    pendingInputName = nil      // whatever opens now is the real device

    // Watch this attempt: if the engine isn't running shortly, the graph is stuck
    // and only a fresh process can help.
    let watch = beginEngineWatch()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8.0) {
        guard engineWatchPending(watch) else { return }
        log("AUDIO STUCK: the engine did not start within 8s of the key going down.")
        log("Exiting for a clean recorder. If this repeats, CoreAudio itself is wedged —")
        log("reset it with: sudo launchctl kickstart -k system/com.apple.audio.coreaudiod")
        exit(1)
    }

    try? FileManager.default.removeItem(atPath: readyFlag)
    try? FileManager.default.removeItem(atPath: transcriptPath)

    // The HUD is deliberately NOT shown here. It used to appear the moment the
    // key went down, but everything below still has to happen first — the
    // WebSocket connect, the device-pin wait, and the CoreAudio device open — so
    // the caption sat on screen while the microphone was still closed. It read as
    // "go ahead, speak", and the first few words were spoken into a mic that
    // wasn't open yet. It now appears from the audio tap on the first buffer that
    // actually reaches us, so the HUD being visible means we really are listening.
    let pressedAt = Date()
    recordingStartedAt = pressedAt

    let s = RealtimeSession(key: apiKey)
    s.start()
    session = s

    // Don't read the input format until the device pin has settled — doing so
    // mid-pin picked up a stale format and the tap then produced no audio at all.
    // Bounded, so a slow/hung CoreAudio call costs one recording's device
    // preference rather than the recording itself.
    if pinSettled.wait(timeout: .now() + 3.0) == .timedOut {
        log("input pin still pending — recording from the current device")
    }
    pinSettled.signal()   // keep it available for later recordings

    log("hold: session opened, reading the input")
    let input = engine.inputNode
    let nodeFormat = input.outputFormat(forBus: 0)

    // A device that isn't ready reports a zero format, and handing that to the
    // engine is another way to die. Skip the recording instead, and still raise
    // the ready flag so dictate.py doesn't wait for a handoff that never comes.
    guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
        finishEngineWatch(watch)
        log("input not ready (\(nodeFormat.sampleRate)Hz, \(nodeFormat.channelCount)ch) — skipping this recording")
        stateLock.lock(); isRecording = false; stateLock.unlock()
        LiveHUD.shared.hide()
        try? "".write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: readyFlag, contents: Data())
        s.close(); session = nil
        return
    }

    // Pass nil, never a format we read ourselves. Pinning a different input
    // device changes this node's format, and installTap raises an Objective-C
    // exception when the format handed to it disagrees with the node's own:
    // "Failed to create tap due to format mismatch". Swift cannot catch that, so
    // it terminated the daemon outright and KeepAlive restarted it straight into
    // the same crash — the recorder ceased to exist the moment a mic was pinned.
    // nil means "use whatever this node is on right now".
    converter = nil                 // rebuilt below from the first real buffer
    var loggedFirst = false
    var hudShown = false
    // Named so a device switch can put it back after tearing the graph down.
    let installMicTap: () -> Void = {
    input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
        // Build the converter from the buffer we are actually handed, so a device
        // change can't leave one behind that still expects the previous rate.
        if let c = converter, c.inputFormat.isEqual(buffer.format) {
            // reuse
        } else {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let pcm = convertToPCM16(buffer), !pcm.isEmpty else {
            if !loggedFirst { loggedFirst = true; log("tap: got buffer frames=\(buffer.frameLength) but conversion produced nothing") }
            return
        }
        if !loggedFirst {
            loggedFirst = true
            let ms = Int(Date().timeIntervalSince(pressedAt) * 1000)
            log("tap: first audio ok — \(buffer.frameLength) frames in → \(pcm.count) bytes out (\(ms)ms after press)")
        }
        // Tied to a converted, non-empty buffer rather than to `loggedFirst`,
        // which the failure branch above also sets — the caption must only ever
        // promise what the mic is actually delivering.
        if !hudShown { hudShown = true; LiveHUD.shared.show() }
        session?.sendAudio(pcm)
        stateLock.lock(); sentBytes += pcm.count; stateLock.unlock()
    }
    }
    installMicTap()
    reinstallTap = installMicTap
    engine.prepare()
    do {
        try engine.start()
        let ms = Int(Date().timeIntervalSince(pressedAt) * 1000)
        finishEngineWatch(watch)
        log("recording started (in: \(nodeFormat.sampleRate)Hz, delay: \(s.delay), \(ms)ms after press)")

        // Publish which device is actually being heard, for the caption to show.
        // Once per recording, off the HUD's refresh path.
        if let unit = input.audioUnit {
            var dev = AudioDeviceID(0)
            var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &dev, &sz) == noErr,
               var name = deviceName(dev) {
                // When the engine follows the system default it reports an internal
                // aggregate ("CADefaultDeviceAggregate-3338-0"), which is true but
                // unreadable. Resolve it to the device that aggregate stands for.
                if name.hasPrefix("CADefaultDeviceAggregate"),
                   let def = defaultInputDeviceID(), let real = deviceName(def) {
                    name = real
                }
                try? name.write(toFile: actualInputFile, atomically: true, encoding: .utf8)
            }
        }
    }
    catch {
        finishEngineWatch(watch)
        log("engine start failed: \(error)")

        // -10868 (FormatNotSupported) here means an input pin is configured.
        // Merely setting kAudioOutputUnitProperty_CurrentDevice on this engine's
        // input unit at startup leaves the graph unable to start at all, and it
        // does not recover in-process: switching the unit back to the system
        // default and resetting the engine fails identically. So the pin is not
        // just ineffective, it is fatal to capture, and the only cure is removing
        // it and restarting. Say so plainly rather than leaving silent recordings.
        if let want = preferredInputName() {
            log("PIN IS BREAKING CAPTURE: '\(want)' is pinned and this engine cannot start.")
            log("Remove it — menubar → Microphone → System Default — then restart the recorder.")
        }
    }
}

func stopRecording() {
    stateLock.lock()
    if !isRecording { stateLock.unlock(); return }
    isRecording = false
    let bytes = sentBytes
    stateLock.unlock()

    reinstallTap = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    log("stopped — streamed \(bytes) bytes of PCM")
    guard let s = session else { return }
    // Committing an empty buffer is an API error; skip it and hand off empty.
    if bytes < 4800 {          // < 100ms at 24kHz/16-bit
        log("too little audio (\(bytes) bytes) — skipping commit")
        LiveHUD.shared.hide()
        try? "".write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: readyFlag, contents: Data())
        s.close(); session = nil

        // Nothing at all, from a hold long enough that there should have been
        // something. A brief tap is not evidence of anything, so it doesn't count.
        let held = -recordingStartedAt.timeIntervalSinceNow
        if bytes == 0 && held >= 1.0 {
            deadCaptures += 1
            log("captured nothing after \(String(format: "%.1f", held))s (\(deadCaptures)/\(deadCaptureLimit))")
            if deadCaptures >= deadCaptureLimit {
                // The handoff above already completed, so dictate.py is not left
                // waiting on a process that is about to disappear.
                log("audio is not working — exiting so launchd starts a clean recorder")
                exit(1)
            }
        }
        return
    }
    deadCaptures = 0
    s.commit()

    // Wait for EVERY committed utterance to come back transcribed before handing
    // off. The previous heuristic ("transcript stopped growing and went quiet")
    // bailed ~150ms after release whenever the user had paused, silently losing
    // the tail of the dictation. Now we wait on the actual segment count.
    DispatchQueue.global().async {
        // Give the trailing commit a moment to register before we compare counts.
        usleep(250_000)
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if s.allSegmentsTranscribed() {
                // All known utterances are in. Allow a brief grace period in case
                // the server is still opening one more segment for trailing audio.
                if s.idleSeconds() > 0.5 { break }
            }
            usleep(100_000)
        }
        let (c, d) = s.segmentCounts()
        if d < c { log("WARNING: timed out with \(d)/\(c) segments transcribed") }
        let text = s.finalText()
        try? text.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: readyFlag, contents: Data())
        log("handoff: \(text.count) chars (\(d)/\(c) segments)")
        // Keep the HUD up until the text is handed off, then let dictate.py's
        // translate + paste take over.
        LiveHUD.shared.hide()
        s.close()
    }
    session = nil
}

// ── Poll loop (same trigger as record.swift) ─────────────────────────────────
// A dedicated thread rather than a Timer on the main run loop: audio capture
// and the WebSocket both drive their own queues, and a plain sleep-poll loop is
// immune to whether AppKit is servicing the main run loop in this launch
// context (a Timer silently never fired when launched outside launchd).
// `--list-inputs` prints the microphones this Mac can record from, then exits,
// so you can copy an exact name into the input_device file. Placed here because
// top-level globals in a Swift main file initialize in source order — running it
// earlier touched inputDeviceFile before it existed and segfaulted.
if CommandLine.arguments.contains("--list-inputs") {
    print("Available audio input devices:\n")
    for n in availableInputNames() { print("  \(n)") }
    print("\nCurrently configured: \(preferredInputName() ?? "(none — using the system default)")")
    print("\nTo pin one, write its name into:")
    print("  \(inputDeviceFile)")
    print("\nFor example:")
    print("  mkdir -p \"$HOME/Library/Application Support/Echo\"")
    print("  echo 'Your Device Name' > \"\(inputDeviceFile)\"")
    exit(0)
}

// Pin the input device once, in the background.
//
// This is an optimisation, not a requirement, so it must never gate startup:
// AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice) goes through the
// CoreAudio HAL and has been observed to block indefinitely (stack sits in
// HALC_ProxyObject::SetPropertyData) when the audio daemon is in a bad state.
// On the main thread that hung the whole recorder — no logging, no hotkey
// response. Off the main thread the daemon starts normally and simply records
// from the system default if the pin never lands.
//
// It must also not run on the poll thread while the engine is starting, which
// deadlocked in a different way, hence its own queue here.
DispatchQueue.global(qos: .userInitiated).async { pinInputDevice() }

let pollThread = Thread {
    log("poll thread running")
    var recording = false
    while true {
        let want = FileManager.default.fileExists(atPath: startFlag)
        if want && !recording {
            recording = true
            startRecording()
        } else if !want && recording {
            recording = false
            stopRecording()
        }
        usleep(50_000)   // 50ms → ≤50ms hotkey latency
    }
}
pollThread.qualityOfService = .userInteractive
pollThread.start()

// ── Graceful shutdown ────────────────────────────────────────────────────────
for sig in [SIGTERM, SIGINT, SIGHUP] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        try? FileManager.default.removeItem(atPath: startFlag)
        exit(0)
    }
    src.resume()
    signal(sig, SIG_IGN)
}

log("record_realtime daemon started")
// A real NSApplication run loop, needed to draw the live HUD. Safe now that the
// flag polling lives on its own thread — an earlier main-run-loop Timer was
// what silently never fired. .accessory = no dock icon, no menu bar.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
