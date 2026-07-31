// pcm_play.swift — play raw PCM16 audio from stdin as it arrives.
//
// afplay needs a complete file before it will make a sound, so AI Speak had to
// wait for a whole TTS response to download before any audio started. This
// reads headerless PCM from stdin and schedules it into AVAudioEngine in small
// buffers, so playback begins as soon as the first bytes land and continues
// while the rest is still downloading.
//
// Usage:  pcm_play [sampleRate]        (default 24000 — OpenAI TTS pcm output:
//                                       24kHz, 16-bit signed, mono, LE)
//
// Exits once stdin closes AND every scheduled buffer has finished playing, so
// the caller can simply wait on the process. SIGTERM/SIGINT stop immediately,
// which is what the Stop Speaking control relies on.

import AVFoundation
import Foundation

let sampleRate = CommandLine.arguments.count > 1
    ? (Double(CommandLine.arguments[1]) ?? 24000) : 24000

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                 sampleRate: sampleRate,
                                 channels: 1,
                                 interleaved: true) else { die("bad format") }

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
// Connecting with the source format lets the engine resample to the output
// device's rate for us.
engine.connect(player, to: engine.mainMixerNode, format: format)

do { try engine.start() } catch { die("engine start failed: \(error)") }

// Track outstanding buffers so we don't exit while audio is still queued.
let lock = NSLock()
var scheduled = 0
var inputDone = false

func bufferFinished() {
    lock.lock(); scheduled -= 1; lock.unlock()
}

// Stop promptly when the pipeline is killed (Cmd+Globe again / Stop Speaking).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler { player.stop(); engine.stop(); exit(0) }
    src.resume()
    signal(sig, SIG_IGN)
    signalSources.append(src)      // keep alive for the process lifetime
}

func schedule(_ data: Data) {
    let frames = data.count / 2                     // Int16 mono
    guard frames > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: format,
                                     frameCapacity: AVAudioFrameCount(frames)),
          let dst = buf.int16ChannelData else { return }
    buf.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { raw in
        guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
        dst[0].update(from: src, count: frames)
    }
    lock.lock(); scheduled += 1; lock.unlock()
    player.scheduleBuffer(buf, completionHandler: bufferFinished)
}

// Read stdin in modest blocks. `carry` holds a trailing odd byte so a sample is
// never split across buffers.
let stdinHandle = FileHandle.standardInput
var carry = Data()
var totalBytes = 0
// Pre-roll a little audio before starting so the very first buffers don't
// underrun on a slow first TCP segment.
let preRollBytes = Int(sampleRate) * 2 / 10          // 100ms
var started = false

while true {
    let chunk = stdinHandle.availableData
    if chunk.isEmpty { break }
    totalBytes += chunk.count
    var data = carry + chunk
    if data.count % 2 == 1 {
        carry = data.suffix(1)
        data = data.dropLast()
    } else {
        carry = Data()
    }
    if !data.isEmpty { schedule(data) }
    if !started && totalBytes >= preRollBytes {
        player.play()
        started = true
    }
}
inputDone = true
if !started { player.play() }        // short clip: never reached the pre-roll

// Wait for the queue to drain.
while true {
    lock.lock(); let left = scheduled; lock.unlock()
    if left == 0 { break }
    usleep(30_000)
}
// Let the last buffer's tail actually reach the speakers.
usleep(120_000)
player.stop()
engine.stop()
_ = inputDone
