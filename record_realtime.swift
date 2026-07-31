// record_realtime.swift — streaming voice-recording daemon (Stage 1).
//
// A parallel alternative to record.swift: instead of writing an m4a file and
// uploading it after release, it streams live mic audio to OpenAI's realtime
// transcription WebSocket DURING the hold, so the (Russian) transcript is ready
// the instant the key is released. dictate.py then translates + pastes.
//
// Trigger is identical to record.swift: Karabiner touches /tmp/rewrite_record_start
// on press and removes it on release. On release this daemon writes the transcript
// to /tmp/rewrite_transcript.txt and touches /tmp/rewrite_record.ready.
//
// The API key comes from the environment (OPENAI_API_KEY), set via the
// LaunchAgent plist — a launchd daemon can't read ~/Documents/.env (TCC).
//
// record.swift + the whisper-1 path stay intact; this runs only when its own
// LaunchAgent is loaded (and dictate.py is in realtime mode).

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

guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
    log("FATAL: OPENAI_API_KEY not set in environment (set it in the LaunchAgent plist)")
    exit(1)
}

// ── Realtime WebSocket session ───────────────────────────────────────────────
final class RealtimeSession {
    static let model = "gpt-4o-transcribe"
    static let lang  = "ru"

    private let ws: URLSessionWebSocketTask
    private let lock = NSLock()
    private var configured = false
    private var pending: [Data] = []       // audio captured before session.updated
    private(set) var transcript = ""       // concatenated final segments
    private var lastActivity = Date()

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
                    "transcription": ["model": Self.model, "language": Self.lang],
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
        case "conversation.item.input_audio_transcription.completed":
            if let t = obj["transcript"] as? String {
                let seg = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !seg.isEmpty {
                    lock.lock()
                    // Server VAD emits one segment per utterance; join with a
                    // space so sentences don't run together ("...инпуте?Интересно.").
                    transcript += transcript.isEmpty ? seg : " " + seg
                    lastActivity = Date()
                    lock.unlock()
                    log("segment: \(seg)")
                }
            }
        case "conversation.item.input_audio_transcription.delta":
            lock.lock(); lastActivity = Date(); lock.unlock()
        case "error":
            // Server VAD usually commits every utterance on its own, so our
            // final explicit commit often finds an empty buffer. That's
            // expected and harmless — don't log it as an error.
            if s.contains("input_audio_buffer_commit_empty") {
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
        try? "".write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: readyFlag, contents: Data())
        s.close(); session = nil
        return
    }
    s.commit()

    // Wait briefly for the final segment(s) to transcribe, then hand off. We
    // poll for the transcript to stop growing (or a hard cap), so short clips
    // return fast and long ones still finish.
    DispatchQueue.global().async {
        let deadline = Date().addingTimeInterval(4.0)
        var lastLen = -1
        while Date() < deadline {
            let cur = s.transcript.count
            if cur > 0 && cur == lastLen && s.idleSeconds() > 0.6 { break }
            lastLen = cur
            usleep(150_000)
        }
        let text = s.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        try? text.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: readyFlag, contents: Data())
        log("handoff: \(text.count) chars")
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
// Keep the process alive. The poll thread does the work; the main run loop only
// needs to service the WebSocket/audio callbacks.
while true { RunLoop.main.run(until: Date().addingTimeInterval(1.0)) }
