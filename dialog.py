#!/usr/bin/env python3
"""
Preset picker dialog for AI Rewrite.
Uses SwiftDialog if available, falls back to AppleScript.
"""
from __future__ import annotations
import json
import os
import subprocess
import tempfile

DIALOG_BIN    = "/usr/local/bin/dialog"
BUTTONS_BIN   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dialog_buttons")


def show_preset_dialog(presets: list[str], preview: str) -> str | None:
    if os.path.exists(BUTTONS_BIN):
        return _buttons_picker(presets, preview)
    if os.path.exists(DIALOG_BIN):
        return _swiftdialog_picker(presets, preview)
    return _applescript_dialog(presets, preview)


# ── Native button window (compiled Swift) ────────────────────────────────────

_loading_proc: "subprocess.Popen[str] | None" = None


def dismiss_loading():
    """Signal the loading dialog to close. Call after paste is complete."""
    global _loading_proc
    if _loading_proc is not None:
        try:
            _loading_proc.stdin.close()
            _loading_proc.wait(timeout=2)
        except Exception:
            try:
                _loading_proc.terminate()
                _loading_proc.wait(timeout=1)
            except Exception:
                pass
        _loading_proc = None


def _buttons_picker(presets: list[str], preview: str) -> str | None:
    import time
    global _loading_proc
    all_options = presets + ["✏️ Custom…"]
    short = preview[:120] + ("…" if len(preview) > 120 else "")
    cmd = [BUTTONS_BIN, short] + all_options
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    choice = proc.stdout.readline().strip()
    _log(f"swift binary choice={repr(choice)}")
    if not choice:
        proc.wait()
        return None
    if "Custom" in choice:
        proc.stdin.close()
        proc.wait()
        return _applescript_custom()
    # Dialog is now showing loading state — caller must call dismiss_loading() when done
    _loading_proc = proc
    time.sleep(0.2)
    return choice


def _log(msg: str):
    import os
    from datetime import datetime
    log_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rewrite.log")
    with open(log_path, "a") as f:
        f.write(f"[{datetime.now().isoformat()}] [DLG] {msg}\n")


# ── SwiftDialog (fallback) ────────────────────────────────────────────────────

def _swiftdialog_picker(presets: list[str], preview: str) -> str | None:
    all_options = presets + ["✏️ Custom…"]
    select_values = ",".join(all_options)

    short = preview[:150] + ("…" if len(preview) > 150 else "")

    cmd = [
        DIALOG_BIN,
        "--title", "AI Rewrite",
        "--message", short,
        "--selecttitle", "Action,radio",
        "--selectvalues", select_values,
        "--selectdefault", presets[0],
        "--button1text", "Rewrite",
        "--button2text", "Cancel",
        "--buttonsize", "large",
        "--width", "540",
        "--height", "600",
        "--messagefont", "size=13",
        "--hideicon",
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        return None

    try:
        data = json.loads(result.stdout)
        choice = data.get("Action", "").strip()
        if not choice:
            return None
        if "Custom" in choice:
            return _swiftdialog_custom()
        return choice
    except Exception:
        return None


def _applescript_custom() -> str | None:
    script = '''
tell application "Finder" to activate
delay 0.2
set r to display dialog "Enter your instruction:" ¬
    default answer "" ¬
    with title "AI Rewrite" ¬
    buttons {"Cancel", "Rewrite"} ¬
    default button "Rewrite"
if button returned of r is "Cancel" then error number -128
return text returned of r
'''
    code, out, _ = _run_applescript(script)
    return out.strip() if code == 0 and out.strip() else None


def _swiftdialog_custom() -> str | None:
    cmd = [
        DIALOG_BIN,
        "--title", "AI Rewrite",
        "--message", "Enter your instruction:",
        "--textfield", "Instruction,required",
        "--button1text", "Rewrite",
        "--button2text", "Cancel",
        "--icon", "wand.and.stars",
        "--width", "520",
        "--hideicon",
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        return None

    try:
        data = json.loads(result.stdout)
        return data.get("Instruction", "").strip() or None
    except Exception:
        return None


# ── AppleScript fallback ──────────────────────────────────────────────────────

def _run_applescript(script: str) -> tuple[int, str, str]:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".applescript", delete=False) as f:
        f.write(script)
        tmp = f.name
    try:
        r = subprocess.run(["osascript", tmp], capture_output=True, text=True)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    finally:
        os.unlink(tmp)


def _applescript_dialog(presets: list[str], preview: str) -> str | None:
    safe = preview[:80].replace("\\", "\\\\").replace('"', '\\"')
    if len(preview) > 80:
        safe += "…"
    all_presets = presets + ["Custom…"]
    as_list = "{" + ", ".join(f'"{p}"' for p in all_presets) + "}"
    script = f'''
tell application "Finder" to activate
delay 0.3
set presets to {as_list}
set chosen to choose from list presets \u00ac
    with title "AI Rewrite" \u00ac
    with prompt "{safe}" \u00ac
    default items {{"{all_presets[0]}"}}
if chosen is false then error number -128
set choice to item 1 of chosen
if choice is "Custom\u2026" then
    set r to display dialog "Enter your instruction:" \u00ac
        default answer "" \u00ac
        with title "AI Rewrite" \u00ac
        buttons {{"Cancel", "Rewrite"}} \u00ac
        default button "Rewrite"
    if button returned of r is "Cancel" then error number -128
    return text returned of r
else
    return choice
end if
'''
    code, out, _ = _run_applescript(script)
    return out if code == 0 and out else None
