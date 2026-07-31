#!/usr/bin/env python3
"""
AI Speak — copies the current selection, translates to Russian via OpenAI
(skipped if text is already Cyrillic), splits into sentences, then streams
audio playback: while sentence N is playing, sentence N+1 is being
synthesized. Latency to first audio is the first-sentence TTS time
(~1s), independent of total length.

A second invocation while playback is in progress kills the whole pipeline
(playing afplay + pending synthesis).

Triggered by Cmd+Globe via Karabiner.
"""
from __future__ import annotations
import sys
import os
import re
import json
import time
import queue
import tempfile
import threading
import subprocess
import signal
import urllib.request
import urllib.error
from datetime import datetime

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, ".env")
LOG_PATH    = os.path.join(SCRIPT_DIR, "rewrite.log")

PID_PATH    = "/tmp/rewrite_speak.pid"
CHUNK_DIR   = "/tmp/rewrite_speak_chunks"

TRANSLATE_MODEL = "gpt-4.1-nano"
TTS_MODEL       = "tts-1"      # lowest-latency TTS; gpt-4o-mini-tts is nicer but slower
# wav/pcm are the formats OpenAI recommends for fastest response — the audio
# needs no decoding before playback, unlike mp3. afplay handles wav natively.
AUDIO_FORMAT    = "wav"
AUDIO_EXT       = "wav"
# Sentences after the first are grouped up to this size: once audio is playing
# there's no latency pressure, and bigger chunks give the translator more context.
CHUNK_TARGET_CHARS = 400
# Streaming player for the first chunk: afplay needs a complete file, so it
# can't start until the whole response has downloaded. pcm_play consumes raw PCM
# on stdin and plays it as it arrives.
PCM_PLAY         = os.path.join(SCRIPT_DIR, "pcm_play")
PCM_SAMPLE_RATE  = 24000      # OpenAI TTS "pcm": 24kHz, 16-bit signed, mono, LE
TTS_VOICE       = "nova"       # alloy / echo / fable / onyx / nova / shimmer

TRANSLATE_PROMPT = (
    "Translate the user's text into natural Russian. "
    "Output ONLY the Russian text — no preamble, no commentary, no quotes."
)


# ── Helpers ───────────────────────────────────────────────────────────────────

def log(msg: str):
    with open(LOG_PATH, "a") as f:
        f.write(f"[{datetime.now().isoformat()}] [SPK] {msg}\n")


def load_env(name: str) -> str | None:
    val = os.environ.get(name, "").strip()
    if val:
        return val
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{name}="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    return None


def run_applescript(script: str) -> tuple[int, str, str]:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".applescript", delete=False) as f:
        f.write(script)
        tmp = f.name
    try:
        r = subprocess.run(["osascript", tmp], capture_output=True, text=True)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    finally:
        os.unlink(tmp)


def copy_selection():
    run_applescript(
        'tell application "System Events" to keystroke "c" using command down'
    )
    time.sleep(0.3)


def read_clipboard() -> str:
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def write_clipboard(text: str):
    subprocess.run(["pbcopy"], input=text, text=True)


def show_error(message: str):
    safe = message.replace("\\", "\\\\").replace('"', '\\"')[:300]
    run_applescript(f'''
tell application "Finder" to activate
delay 0.2
display dialog "{safe}" with title "AI Speak — Error" buttons {{"OK"}} default button "OK" with icon stop
''')


# ── Stop-on-second-press ──────────────────────────────────────────────────────

def kill_running() -> bool:
    """If a previous speak.py session is still alive, kill its whole process
    group (it owns the pipeline thread + afplay child) and return True."""
    if not os.path.exists(PID_PATH):
        return False
    try:
        with open(PID_PATH) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)   # liveness check
    except (ProcessLookupError, FileNotFoundError, ValueError, PermissionError):
        try: os.remove(PID_PATH)
        except Exception: pass
        return False
    try:
        # Kill the whole process group so afplay and any in-flight synthesis dies.
        pgid = os.getpgid(pid)
        os.killpg(pgid, signal.SIGTERM)
        log(f"killed pgid {pgid} (root pid {pid})")
    except Exception as e:
        log(f"kill error: {e}")
    try: os.remove(PID_PATH)
    except Exception: pass
    return True


# ── Language detection ───────────────────────────────────────────────────────

def is_already_russian(text: str) -> bool:
    """Heuristic: >30% Cyrillic chars among letters → treat as Russian and
    skip the translate round-trip."""
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return False
    cyrillic = sum(1 for c in letters if "Ѐ" <= c <= "ӿ")
    return cyrillic / len(letters) > 0.3


# ── OpenAI calls ──────────────────────────────────────────────────────────────

def translate_to_russian(text: str, api_key: str) -> str:
    payload = {
        "model": TRANSLATE_MODEL,
        "max_tokens": 4096,
        "messages": [
            {"role": "system", "content": TRANSLATE_PROMPT},
            {"role": "user",   "content": text},
        ],
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type":  "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
        return data["choices"][0]["message"]["content"]


def synthesize_to_file(text: str, api_key: str, output_path: str):
    payload = {
        "model":           TTS_MODEL,
        "voice":           TTS_VOICE,
        "input":           text,
        "response_format": AUDIO_FORMAT,
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type":  "application/json",
        },
    )
    # The response is chunked, so copy it through as it arrives instead of
    # buffering the whole body in memory before writing.
    with urllib.request.urlopen(req, timeout=60) as resp:
        with open(output_path, "wb") as f:
            while True:
                buf = resp.read(16384)
                if not buf:
                    break
                f.write(buf)


# ── Sentence chunking ────────────────────────────────────────────────────────

def stream_to_player(text: str, api_key: str) -> bool:
    """Synthesize `text` and play it as the audio arrives, via pcm_play.

    Used for the first chunk, where latency is all that matters: requesting raw
    pcm and piping the chunked response straight into the player means sound
    starts after the first few KB instead of after the whole file. Returns False
    if the player isn't available, so the caller can fall back to afplay."""
    if not os.path.exists(PCM_PLAY):
        return False

    payload = {
        "model":           TTS_MODEL,
        "voice":           TTS_VOICE,
        "input":           text,
        "response_format": "pcm",     # headerless; pcm_play adds no decode step
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type":  "application/json",
        },
    )
    proc = subprocess.Popen(
        [PCM_PLAY, str(PCM_SAMPLE_RATE)],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            while True:
                buf = resp.read(8192)
                if not buf:
                    break
                proc.stdin.write(buf)
                proc.stdin.flush()
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        proc.wait()          # returns when playback finishes
    return True


def group_sentences(sentences: list[str]) -> list[str]:
    """Batch sentences into chunks for the translate→TTS pipeline.

    The first chunk is deliberately a single sentence so playback starts as soon
    as possible; later chunks are grouped up to CHUNK_TARGET_CHARS because there
    is no latency pressure once audio is already playing, and larger chunks give
    the translator more context and cost fewer round-trips."""
    if not sentences:
        return []
    chunks = [sentences[0]]
    buf = ""
    for s in sentences[1:]:
        if buf and len(buf) + len(s) + 1 > CHUNK_TARGET_CHARS:
            chunks.append(buf)
            buf = s
        else:
            buf = f"{buf} {s}".strip()
    if buf:
        chunks.append(buf)
    return chunks


def split_sentences(text: str) -> list[str]:
    """Naive sentence splitter — works fine for prose. Keeps the trailing
    punctuation with the sentence."""
    parts = re.split(r"(?<=[.!?…])\s+", text.strip())
    return [p.strip() for p in parts if p.strip()]


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    log("START")

    if kill_running():
        log("playback stopped, exiting")
        return

    # New session — claim our own process group so a future kill_running
    # can clobber the entire pipeline (synthesizer thread + afplay).
    try:
        os.setpgrp()
    except Exception:
        pass

    # Write our PID *before* any work so a second Cmd+Globe can SIGTERM us
    # during ANY phase: clipboard read, translate API call, TTS API call,
    # or playback. Previously the PID was written only after API calls
    # finished, so cancels during those phases didn't take effect.
    with open(PID_PATH, "w") as f:
        f.write(str(os.getpid()))

    saved = read_clipboard()
    copy_selection()
    selection = read_clipboard()
    write_clipboard(saved)

    if not selection.strip():
        log("nothing selected, exiting")
        return

    log(f"selection ({len(selection)} chars): {repr(selection[:100])}")

    api_key = load_env("OPENAI_API_KEY")
    if not api_key:
        show_error(f"OPENAI_API_KEY not set in:\n{CONFIG_PATH}")
        return

    try:
        started = time.time()
        already_russian = is_already_russian(selection)
        if already_russian:
            log("already Russian — skipping translate")

        # 1. Split the SOURCE text, so translation happens per chunk inside the
        #    pipeline rather than once over everything up front. Translating the
        #    whole selection first was pure dead time before any audio (~2.8s on
        #    a 483-char selection); now only the first chunk has to be translated
        #    before playback can start.
        chunks = group_sentences(split_sentences(selection))
        log(f"{len(chunks)} chunk(s) from {len(split_sentences(selection))} sentence(s)")

        os.makedirs(CHUNK_DIR, exist_ok=True)

        # 2. Producer thread: translate (if needed) then synthesize each chunk,
        #    feeding paths into the queue. Sentinel `None` marks completion.
        chunk_q: queue.Queue[str | None] = queue.Queue(maxsize=4)
        stop = threading.Event()

        # Chunks 1.. are pre-rendered to files in the background. This starts
        # BEFORE the first chunk plays, so by the time chunk 0 finishes the next
        # one is already waiting and there's no gap.
        def producer():
            for i, source in enumerate(chunks[1:], start=1):
                if stop.is_set():
                    break
                chunk_path = os.path.join(CHUNK_DIR, f"chunk_{i}.{AUDIO_EXT}")
                try:
                    if already_russian:
                        text = source
                    else:
                        t0 = time.time()
                        text = translate_to_russian(source, api_key)
                        log(f"chunk {i} translate {time.time()-t0:.2f}s")
                    t0 = time.time()
                    synthesize_to_file(text, api_key, chunk_path)
                    log(f"chunk {i} synth {time.time()-t0:.2f}s ({len(text)} chars)")
                    chunk_q.put(chunk_path)
                except Exception as e:
                    log(f"chunk {i} failed: {e}")
            chunk_q.put(None)

        threading.Thread(target=producer, daemon=True).start()

        # 3. First chunk: stream it so sound starts after the first few KB rather
        #    than after a whole file downloads. Runs on the main thread and blocks
        #    until it has finished playing, while the producer above renders the
        #    rest.
        try:
            if already_russian:
                first_text = chunks[0]
            else:
                t0 = time.time()
                first_text = translate_to_russian(chunks[0], api_key)
                log(f"chunk 0 translate {time.time()-t0:.2f}s")
            log(f"streaming chunk 0 ({len(first_text)} chars)")
            if stream_to_player(first_text, api_key):
                log(f"TIME TO FIRST AUDIO: ~{time.time()-started:.2f}s (streamed)")
            else:
                # No pcm_play binary — fall back to the download-then-play path.
                path = os.path.join(CHUNK_DIR, f"chunk_0.{AUDIO_EXT}")
                synthesize_to_file(first_text, api_key, path)
                log(f"TIME TO FIRST AUDIO: {time.time()-started:.2f}s (buffered)")
                subprocess.run(["/usr/bin/afplay", path], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try: os.remove(path)
                except Exception: pass
        except Exception as e:
            log(f"chunk 0 failed: {e}")

        # 4. Remaining chunks: already rendered to files, play them in order.
        while True:
            chunk_path = chunk_q.get()
            if chunk_path is None:
                break
            log(f"playing {os.path.basename(chunk_path)}")
            try:
                subprocess.run(
                    ["/usr/bin/afplay", chunk_path],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception as e:
                log(f"afplay error: {e}")
            try: os.remove(chunk_path)
            except Exception: pass

        log("done")

    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200]
        log(f"HTTP {e.code}: {body}")
        show_error(f"API error {e.code}:\n{body}")
    except Exception as e:
        log(f"error: {e}")
        show_error(f"Error: {str(e)[:200]}")
    finally:
        try: os.remove(PID_PATH)
        except Exception: pass


if __name__ == "__main__":
    main()
