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
    private let minHeight: CGFloat = 56
    private let maxHeight: CGFloat = 420
    private let padX: CGFloat = 18
    private let padY: CGFloat = 14
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

    /// Height needed to render `text` at our fixed width.
    private func heightFor(_ text: String) -> CGFloat {
        guard let font = label?.font else { return minHeight }
        let box = NSSize(width: width - padX * 2, height: .greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(
            with: box,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return min(max(ceil(rect.height) + padY * 2, minHeight), maxHeight)
    }

    /// Place at the bottom-centre of whichever screen holds the pointer — like
    /// live captions. Avoids covering the input the user is looking at. The panel
    /// grows upward as text accumulates, so the bottom edge stays put.
    private func reposition(height: CGFloat) {
        guard let w = window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
                  ?? NSScreen.main?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.midX - width / 2
        let y = screen.minY + bottomInset
        w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func show() {
        DispatchQueue.main.async {
            if self.window == nil { self.build() }
            self.label?.stringValue = "Listening…"
            self.reposition(height: self.minHeight)
            self.window?.orderFrontRegardless()   // show WITHOUT taking focus
        }
    }

    func update(_ text: String) {
        DispatchQueue.main.async {
            guard let label = self.label else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = t.isEmpty ? "Listening…" : t

            // Grow to fit. Only once we hit maxHeight do we start dropping the
            // oldest words, so short and medium dictations are fully visible
            // instead of being clipped to a few lines.
            var display = shown
            var h = self.heightFor(display)
            if h >= self.maxHeight {
                // Trim from the front until it fits the cap, keeping the newest
                // text — that's the part the user is still speaking.
                var chars = Array(display)
                while chars.count > 80 {
                    chars.removeFirst(min(40, chars.count - 80))
                    let candidate = "…" + String(chars)
                    if self.heightFor(candidate) < self.maxHeight {
                        display = candidate
                        break
                    }
                    display = candidate
                }
                h = self.heightFor(display)
            }
            label.stringValue = display
            self.reposition(height: h)
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
    static let lang  = "ru"

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
    // NOTE: paragraph breaks are deliberately NOT inserted here. Timing-based
    // detection was tried twice and both attempts were wrong: VAD speech events
    // aren't available for this model, and gaps between delta arrivals measure
    // the model's processing rhythm rather than the speaker's pauses, so even a
    // brief hesitation produced a break. Paragraphing is now done by the
    // translate step in dictate.py, which can see the whole text and split on
    // meaning instead of milliseconds.

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
                        "language": Self.lang,
                        // Deltas were arriving in slow bursts ("nothing, then a
                        // lot at once"). `delay` trades latency for streaming
                        // quality; "low" is what the docs recommend for live
                        // captions. The text we actually paste comes from the
                        // completed transcript, so a rougher live stream costs
                        // us nothing.
                        "delay": "low",
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
            let shown = transcript
            lock.unlock()
            // Show the corrected version now that it's final.
            LiveHUD.shared.update(shown)
            log("utterance transcribed \(d)/\(c) (\(seg.count) chars)")
        case "conversation.item.input_audio_transcription.delta":
            // Deltas stream as speech arrives and are purely additive, so they
            // ARE the transcript — we build it here rather than waiting for the
            // completed event. That also lets us mark pauses: a gap in delta
            // arrival means the speaker stopped talking, i.e. a new thought.
            let d = obj["delta"] as? String ?? ""
            if d.isEmpty { return }
            lock.lock()
            deltaText += d
            lastActivity = Date()
            let live = deltaText
            lock.unlock()
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

    LiveHUD.shared.show()

    let s = RealtimeSession(key: apiKey)
    s.start()
    session = s

    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    converter = AVAudioConverter(from: inFormat, to: targetFormat)
    var loggedFirst = false
    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
        guard let pcm = convertToPCM16(buffer), !pcm.isEmpty else {
            if !loggedFirst { loggedFirst = true; log("tap: got buffer frames=\(buffer.frameLength) but conversion produced nothing") }
            return
        }
        if !loggedFirst { loggedFirst = true; log("tap: first audio ok — \(buffer.frameLength) frames in → \(pcm.count) bytes out") }
        session?.sendAudio(pcm)
        stateLock.lock(); sentBytes += pcm.count; stateLock.unlock()
    }
    engine.prepare()
    do { try engine.start(); log("recording started (in: \(inFormat.sampleRate)Hz)") }
    catch { log("engine start failed: \(error)") }
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
