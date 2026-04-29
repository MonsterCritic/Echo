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
TTS_MODEL       = "tts-1"      # gpt-4o-mini-tts is nicer but slower
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
        "response_format": "mp3",
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type":  "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        with open(output_path, "wb") as f:
            f.write(resp.read())


# ── Sentence chunking ────────────────────────────────────────────────────────

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
        # 1. Translate (skipped if selection is already Russian).
        if is_already_russian(selection):
            log("already Russian — skipping translate")
            russian = selection
        else:
            t0 = time.time()
            russian = translate_to_russian(selection, api_key)
            log(f"translated in {time.time()-t0:.2f}s")

        # 2. Split into sentences for pipelined TTS.
        sentences = split_sentences(russian)
        log(f"{len(sentences)} sentence(s)")

        os.makedirs(CHUNK_DIR, exist_ok=True)

        # 3. Producer thread: synthesizes each sentence into its own MP3,
        #    feeds paths into the queue. Sentinel `None` marks completion.
        chunk_q: queue.Queue[str | None] = queue.Queue(maxsize=4)
        stop = threading.Event()

        def producer():
            for i, sent in enumerate(sentences):
                if stop.is_set():
                    break
                chunk_path = os.path.join(CHUNK_DIR, f"chunk_{i}.mp3")
                try:
                    t0 = time.time()
                    synthesize_to_file(sent, api_key, chunk_path)
                    log(f"chunk {i} synth {time.time()-t0:.2f}s ({len(sent)} chars)")
                    chunk_q.put(chunk_path)
                except Exception as e:
                    log(f"chunk {i} failed: {e}")
            chunk_q.put(None)

        threading.Thread(target=producer, daemon=True).start()

        # 4. Consumer (main thread): plays each chunk in order via afplay.
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
