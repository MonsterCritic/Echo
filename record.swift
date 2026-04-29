// record.swift — persistent voice-recording daemon.
//
// Runs continuously in the background. Karabiner (or anything else) signals
// start/stop by touching/removing /tmp/rewrite_record_start. The daemon polls
// that flag every 50ms and starts or stops AVAudioRecorder accordingly.
//
// When a recording ends, the daemon flushes the m4a and touches
// /tmp/rewrite_record.ready so dictate.py knows the audio file is complete.
//
// Auto-started at login by a LaunchAgent, which eliminates the cold-start
// lag the previous "launch record.app per hold" architecture had.

import AVFoundation
import AppKit
import Foundation

// ── Anti-App-Nap ──────────────────────────────────────────────────────────────
// macOS can suspend background LSUIElement apps after idle periods, which
// breaks the "first press works instantly" guarantee — the process wakes up
// mid-request and drops the initial mic audio. Declare ongoing activity so
// macOS treats this like an app actively in use.

let activityToken = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .idleSystemSleepDisabled],
    reason:  "Voice dictation daemon must respond to hotkey immediately"
)
_ = activityToken   // retain so macOS keeps the activity assertion alive

// ── Paths ─────────────────────────────────────────────────────────────────────

let audioPath = "/tmp/rewrite_record.m4a"
let startFlag = "/tmp/rewrite_record_start"
let readyFlag = "/tmp/rewrite_record.ready"

// ── State ─────────────────────────────────────────────────────────────────────

var recorder: AVAudioRecorder? = nil

let settings: [String: Any] = [
    AVFormatIDKey:            kAudioFormatMPEG4AAC,
    AVSampleRateKey:          16000,
    AVNumberOfChannelsKey:    1,
    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
]

// ── Recording control ─────────────────────────────────────────────────────────

func startRecording() {
    guard recorder == nil else { return }
    // Fresh file + clear any stale "ready" signal from the previous session.
    try? FileManager.default.removeItem(atPath: audioPath)
    try? FileManager.default.removeItem(atPath: readyFlag)

    // Dummy warmup: the first AVAudioRecorder record() after idle drops the
    // initial audio because CoreAudio is opening the mic stream. Do a throw-
    // away 100ms record first so the real recording catches clean audio from
    // frame zero. Costs ~100ms of latency before the real recorder starts.
    let warmupURL = URL(fileURLWithPath: "/tmp/rewrite_record_warmup.m4a")
    try? FileManager.default.removeItem(at: warmupURL)
    if let w = try? AVAudioRecorder(url: warmupURL, settings: settings) {
        w.prepareToRecord()
        if w.record() {
            Thread.sleep(forTimeInterval: 0.1)
            w.stop()
        }
    }
    try? FileManager.default.removeItem(at: warmupURL)

    // Real recording — mic stream is now open, audio should flow immediately.
    let url = URL(fileURLWithPath: audioPath)
    guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
    recorder = r
    r.prepareToRecord()
    r.record()
}

func stopRecording() {
    recorder?.stop()
    recorder = nil
    // Tell dictate.py the m4a is flushed and ready to read.
    FileManager.default.createFile(atPath: readyFlag, contents: Data())
}

// ── Pre-warm CoreAudio at daemon startup ──────────────────────────────────────
// First AVAudioRecorder creation + first record() call in this process takes
// ~3 seconds and tends to drop the initial audio. Pay that cost once at login
// (mic indicator flashes for 200ms at daemon start) so the user's first hold
// captures clean audio from the first frame.
//
// We do a 200ms throwaway record to fully open the mic capture stream, then
// throw the data away. Subsequent recordings reuse the warmed audio pipeline.

let prewarmURL = URL(fileURLWithPath: "/tmp/rewrite_record_prewarm.m4a")
try? FileManager.default.removeItem(at: prewarmURL)
if let warmup = try? AVAudioRecorder(url: prewarmURL, settings: settings) {
    warmup.prepareToRecord()
    if warmup.record() {
        Thread.sleep(forTimeInterval: 0.2)
        warmup.stop()
    }
}
try? FileManager.default.removeItem(at: prewarmURL)

// ── Flag-poll loop ────────────────────────────────────────────────────────────
// 50ms polling → ≤50ms latency from "key pressed" to "mic actually capturing."

let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let wantRecording = FileManager.default.fileExists(atPath: startFlag)
    if wantRecording && recorder == nil {
        startRecording()
    } else if !wantRecording && recorder != nil {
        stopRecording()
    }
}
RunLoop.main.add(timer, forMode: .common)

// ── Graceful shutdown ─────────────────────────────────────────────────────────

var signalSources: [DispatchSourceSignal] = []

func installStop(_ sig: Int32) {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        if recorder != nil { stopRecording() }
        // Leave no stale flags behind.
        try? FileManager.default.removeItem(atPath: startFlag)
        try? FileManager.default.removeItem(atPath: readyFlag)
        exit(0)
    }
    src.resume()
    signal(sig, SIG_IGN)
    signalSources.append(src)   // keep source alive for process lifetime
}

installStop(SIGTERM)
installStop(SIGINT)
installStop(SIGHUP)

// Use a real NSApplication run loop (accessory policy = no dock icon / menu
// bar) instead of bare RunLoop.main.run(). This gives the daemon a proper
// AppKit lifecycle so macOS doesn't treat it as a dormant background
// process — the hotkey-to-record latency stays consistent.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
