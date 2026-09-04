#!/usr/bin/env python3
"""Paste the last dictation again — Cmd+Option+Shift+V.

For the case where a dictation was transcribed and translated correctly but never
landed in the input: focus had moved, the field wasn't a text field, or the paste
was refused. The text is never lost — it goes into the history file before the
paste is attempted — but recovering it meant opening the menubar or the file.

Cmd+Shift+V would be the obvious binding and is not free: it is "paste without
formatting" in Chrome, Slack, Notion and most editors, and a Karabiner rule would
shadow it everywhere. Cmd+Option+Shift+V it is.

Reads the newest Dictate entry rather than simply the newest entry, because a
Rewrite in between should not become what this pastes — "the last thing I
dictated" is the promise.
"""

from __future__ import annotations
import json
import os
import re
import subprocess
import sys
import time

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
HISTORY_PATH = os.path.join(SCRIPT_DIR, "dictate_history.md")
PASTE_HELPER = os.path.join(SCRIPT_DIR, "paste_helper")
LOG_PATH     = os.path.join(SCRIPT_DIR, "rewrite.log")


def log(msg: str):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] [LAST] {msg}\n")
    except OSError:
        pass


def notify(title: str, message: str):
    try:
        subprocess.run(
            ["osascript", "-e",
             f"display notification {json.dumps(message)} with title {json.dumps(title)}"],
            capture_output=True, timeout=3)
    except Exception:
        pass


def last_dictation() -> str | None:
    """The output text of the newest Dictate entry, or None.

    History is prepended, so file order is newest-first. Entries are separated by
    a `---` rule; each begins with `## <time> · <kind>`. The output sits under a
    marker that differs by tool, so they are tried in order of specificity: a
    Dictate entry carries both a raw transcript and a final, and the final is the
    one that was meant to be pasted.
    """
    try:
        with open(HISTORY_PATH, encoding="utf-8") as f:
            content = f.read()
    except OSError as e:
        log(f"cannot read history: {e}")
        return None

    for block in content.split("\n---"):
        m = re.search(r"##\s*(.+)", block)
        if not m or "Dictate" not in m.group(1):
            continue
        for marker in ("**Final:**", "**Raw transcript:**"):
            i = block.find(marker)
            if i == -1:
                continue
            text = block[i + len(marker):].strip()
            # A Dictate block holds the raw transcript first, then the final; if
            # this is the raw one, stop at the next marker.
            nxt = text.find("**")
            if nxt != -1:
                text = text[:nxt].strip()
            if text:
                return text
    return None


def read_clipboard() -> str:
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def write_clipboard(text: str):
    subprocess.run(["pbcopy"], input=text, text=True)


def paste() -> bool:
    """Send Cmd+V through the helper, reporting whether it actually went."""
    if not os.path.exists(PASTE_HELPER):
        return False
    try:
        r = subprocess.run([PASTE_HELPER], capture_output=True, text=True, timeout=10)
    except Exception as e:
        log(f"helper error: {e}")
        return False
    if r.returncode != 0:
        log(f"helper refused: {r.stderr.strip()[:120]}")
        return False
    return True


def main():
    text = last_dictation()
    if not text:
        log("no dictation in history")
        notify("Nothing to paste", "No dictation found in the history.")
        return

    saved = read_clipboard()
    write_clipboard(text)

    if paste():
        log(f"re-pasted {len(text)} chars")
        # Give the app a moment to take it, then hand the clipboard back — the
        # same courtesy dictation itself observes.
        time.sleep(0.5)
        if read_clipboard() == text:
            write_clipboard(saved)
        return

    # The keystroke could not be sent — usually the helper's Accessibility grant.
    # Leave the text on the clipboard rather than restoring over it, so the
    # shortcut still saves the retyping even when it cannot finish the job.
    log(f"could not paste; left {len(text)} chars on the clipboard")
    notify("Last dictation copied", "Couldn't paste — press Cmd+V to insert it.")


if __name__ == "__main__":
    main()
