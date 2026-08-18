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

func log(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
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
final class LiveHUD {
    static let shared = LiveHUD()

    private var window: NSWindow?
    private var label: NSTextField?
    private var bgView: NSVisualEffectView?
    private let width: CGFloat = 760
    // The panel grows with the text instead of reserving a fixed block of screen.
    // Growth was what previously made a whole line appear at once, but the cause
    // was specifically setFrame(display: TRUE) forcing a synchronous redraw on
    // the main thread mid-speech. Resizing with display: false lets AppKit
    // coalesce the redraw, so we can have both fit-to-content and smooth text.
    private let minHeight: CGFloat = 52         // ~1 line
    private let maxHeight: CGFloat = 420        // ~14 lines, then it scrolls
    private var currentHeight: CGFloat = 0
    private let padX: CGFloat = 18
    private let padY: CGFloat = 12
    private let bottomInset: CGFloat = 90

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: minHeight),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating                 // above normal windows
        w.ignoresMouseEvents = true         // clicks pass through
        w.hasShadow = true
        // Follow the user across Spaces / over fullscreen apps.
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: minHeight))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let tf = NSTextField(frame: NSRect(x: padX, y: padY,
                                          width: width - padX * 2,
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

        bg.addSubview(tf)
        w.contentView = bg
        window = w
        label = tf
        bgView = bg
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
    }

    func show() {
        DispatchQueue.main.async {
            if self.window == nil { self.build() }
            self.label?.stringValue = "Listening…"
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
        DispatchQueue.main.async { self.window?.orderOut(nil) }
    }
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
    static let languages = ["ru", "en"]

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
                        // Lowest latency, so words appear as they're spoken. Safe
                        // because the text we paste comes from the completed
                        // transcript, not this stream — a rougher live preview
                        // costs us nothing.
                        "delay": "minimal",
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
            if !seg.isEmpty {
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
            log("utterance transcribed \(d)/\(c) (\(seg.count) chars)")
        case "conversation.item.input_audio_transcription.delta":
            // Deltas stream as speech arrives and are purely additive, so they
            // ARE the transcript — we build it here rather than waiting for the
            // completed event. That also lets us mark pauses: a gap in delta
            // arrival means the speaker stopped talking, i.e. a new thought.
            let d = obj["delta"] as? String ?? ""
            if d.isEmpty { return }
            lock.lock()
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
let pinSettled = DispatchSemaphore(value: 0)
var pinSignalled = false
let pinLock = NSLock()

func signalPinSettled() {
    pinLock.lock(); defer { pinLock.unlock() }
    if !pinSignalled { pinSignalled = true; pinSettled.signal() }
}

/// Point the engine's input at the preferred device, if one is configured.
/// Must run while the engine is stopped and before the input format is read.
func pinInputDevice() {
    defer { signalPinSettled() }
    guard let want = preferredInputName() else {
        log("no input device configured — using system default")
        return
    }
    guard let unit = engine.inputNode.audioUnit else { return }
    guard var devID = inputDevice(matching: want) else {
        log("input '\(want)' not connected — using system default")
        return
    }
    let st = AudioUnitSetProperty(unit,
                                  kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0,
                                  &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
    log(st == noErr ? "input pinned to '\(want)'" : "could not pin input (OSStatus \(st))")

    // Read back what the unit is on now. noErr above does NOT prove the engine
    // honored the request, and on hardware where every input shares a sample rate
    // the "in: NHz" line can't tell the devices apart — so a read-back is the only
    // trustworthy answer to "which mic is this actually recording from?".
    var actual = ""
    if let id = currentInputDevice(unit), let name = deviceName(id) {
        actual = name
        if !name.localizedCaseInsensitiveContains(want) {
            log("WARNING: pin reported success but the unit is on '\(name)'")
        } else {
            log("input device in use: '\(name)'")
        }
    } else {
        log("could not read back the input device in use")
    }
    try? actual.write(toFile: actualInputFile, atomically: true, encoding: .utf8)
}

/// Which device the engine's input unit is on right now.
func currentInputDevice(_ unit: AudioUnit) -> AudioDeviceID? {
    var devID = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &devID, &sz) == noErr else { return nil }
    return devID
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

    let input = engine.inputNode
    let nodeFormat = input.outputFormat(forBus: 0)

    // A device that isn't ready reports a zero format, and handing that to the
    // engine is another way to die. Skip the recording instead, and still raise
    // the ready flag so dictate.py doesn't wait for a handoff that never comes.
    guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
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
    engine.prepare()
    do {
        try engine.start()
        let ms = Int(Date().timeIntervalSince(pressedAt) * 1000)
        log("recording started (in: \(nodeFormat.sampleRate)Hz, \(ms)ms after press)")
    }
    catch {
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
        return
    }
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
