#!/usr/bin/env bash
# setup.sh — automates everything that doesn't require GUI clicks.
# Run from the repo root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Long-running .app bundles are installed here rather than run from the repo.
# If the clone lives in an iCloud-synced folder (~/Documents and ~/Desktop are
# synced by default), the file provider stamps com.apple.FinderInfo onto the
# bundle. That invalidates its code signature, and the kernel then kills the
# running daemon with OS_REASON_CODESIGNING — repeatedly, because KeepAlive
# restarts it. ~/Library is never file-provider managed, so a bundle installed
# there keeps a valid signature. The repo stays source-only.
BIN_DIR="$HOME/Library/Application Support/Echo/bin"
mkdir -p "$BIN_DIR"

# Build a .app bundle at $BIN_DIR/<name>.app from <name>.swift. Builds straight
# into the destination on purpose: swiftc ad-hoc signs the binary it writes, and
# copying it afterwards is what leaves the signature stale.
build_app() {
    local name="$1" plist="$2"
    local app="$BIN_DIR/$name.app"
    mkdir -p "$app/Contents/MacOS"
    printf '%s' "$plist" > "$app/Contents/Info.plist"
    swiftc -O -module-name "$name" "$name.swift" -o "$app/Contents/MacOS/$name"
    xattr -cr "$app" 2>/dev/null || true
    codesign --force --deep --sign - "$app" 2>/dev/null || true
    if ! codesign -v --strict "$app" 2>/dev/null; then
        echo "  WARNING: $name.app is not validly signed; it may be killed at launch"
    fi
}

# ── 1. Prereqs ───────────────────────────────────────────────────────────────
if ! command -v swiftc >/dev/null 2>&1; then
    echo "ERROR: swiftc not found. Run: xcode-select --install"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found."
    exit 1
fi

# ── 2. .env ──────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    if [ -t 0 ]; then
        echo ""
        read -r -p "OPENAI_API_KEY (press Enter to skip and add manually later): " key
        if [ -n "$key" ]; then
            echo "OPENAI_API_KEY=$key" > .env
            chmod 600 .env
            echo "Wrote .env (chmod 600)"
        else
            echo "Skipped — create .env manually before using any tool: echo 'OPENAI_API_KEY=sk-...' > .env && chmod 600 .env"
        fi
    else
        echo "WARNING: .env missing and stdin is not a TTY. Create it manually:"
        echo "  echo 'OPENAI_API_KEY=sk-...' > $SCRIPT_DIR/.env && chmod 600 $SCRIPT_DIR/.env"
    fi
fi

# ── 3. Build record_realtime.app ─────────────────────────────────────────────
# This is the recorder AI Dictate actually uses. It streams mic audio to the
# OpenAI realtime endpoint during the hold, so the transcript is ready almost as
# soon as you let go, and it draws the live caption while you speak.
echo "Building record_realtime.app…"
build_app record_realtime '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.echo.context-helper.record-realtime</string>
    <key>CFBundleExecutable</key><string>record_realtime</string>
    <key>CFBundleName</key><string>Echo Realtime Recorder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Streaming your voice for realtime AI dictation.</string>
    <key>NSAppSleepDisabled</key><true/>
</dict>
</plist>'

# ── 3b. Build record.app ─────────────────────────────────────────────────────
# The legacy recorder: writes an m4a, which dictate.py then uploads. Superseded
# by record_realtime.app above and NOT auto-started, but still built so the old
# path stays one step away — set REALTIME_MODE = False in dictate.py and point
# the LaunchAgent at this bundle instead.
echo "Building record.app (legacy m4a recorder, kept for revert)…"
build_app record '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.echo.context-helper.record</string>
    <key>CFBundleExecutable</key><string>record</string>
    <key>CFBundleName</key><string>Echo Recorder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Recording your voice for AI dictation.</string>
    <key>NSAppSleepDisabled</key><true/>
</dict>
</plist>'

# ── 4. Build history_menubar.app ─────────────────────────────────────────────
# Menubar app: recent dictations, a stop control while AI Speak is talking, and
# the Microphone picker.
echo "Building history_menubar.app…"
build_app history_menubar '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.echo.context-helper.history-menubar</string>
    <key>CFBundleExecutable</key><string>history_menubar</string>
    <key>CFBundleName</key><string>Echo History</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>'

# ── 5. Build standalone helpers ──────────────────────────────────────────────
echo "Building helper binaries…"
swiftc -O hud.swift -o hud
swiftc -O dialog_buttons.swift -o dialog_buttons
# paste_helper sends Cmd+V via CGEvent (no System Events), keeping AI Dictate's
# paste fast and load-immune. Ad-hoc sign so it can hold an Accessibility grant.
swiftc -O paste_helper.swift -o paste_helper
codesign -s - -f paste_helper 2>/dev/null || true
# lang_toggle flips the dictation language and shows a HUD saying which way it
# went. It lives in $BIN_DIR because Karabiner runs it by absolute path.
swiftc -O lang_toggle.swift -o "$BIN_DIR/lang_toggle"
codesign --force --sign - "$BIN_DIR/lang_toggle" 2>/dev/null || true
# pcm_play streams raw PCM from stdin so AI Speak can start talking before the
# whole TTS response has downloaded (afplay needs a complete file).
swiftc -O pcm_play.swift -o pcm_play

# ── 6. Make scripts executable ───────────────────────────────────────────────
chmod +x rewrite_selection.sh rewrite.py dictate.py speak.py install.sh

# ── 7. Install AI Rewrite Quick Action ───────────────────────────────────────
echo "Installing AI Rewrite Quick Action…"
./install.sh < /dev/null

# ── 8. LaunchAgent for the realtime recorder daemon ──────────────────────────
echo "Installing LaunchAgent (auto-starts the realtime recorder at login)…"
mkdir -p "$HOME/Library/LaunchAgents"

# Retire the legacy recorder's agent if an earlier install left it loaded. Both
# daemons poll the same /tmp flags, and the legacy one creates the ready flag as
# soon as it stops recording — so dictate.py hands off before the realtime
# transcript exists and the dictation is silently lost. Exactly one may be loaded.
OLD_PLIST="$HOME/Library/LaunchAgents/com.echo.context-helper.record.plist"
if [ -f "$OLD_PLIST" ]; then
    launchctl unload "$OLD_PLIST" 2>/dev/null || true
    mv -f "$OLD_PLIST" "$OLD_PLIST.disabled"
    echo "  retired the legacy recorder agent (renamed to .disabled)"
fi

PLIST_PATH="$HOME/Library/LaunchAgents/com.echo.context-helper.record-realtime.plist"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.echo.context-helper.record-realtime</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/record_realtime.app/Contents/MacOS/record_realtime</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/tmp/record_realtime.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/record_realtime.err.log</string>
</dict>
</plist>
EOF
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

# ── 9. Karabiner rule (file dropped into place; user must enable in GUI) ─────
echo "Dropping Karabiner rule into ~/.config/karabiner/assets/complex_modifications/echo.json …"
KARABINER_DIR="$HOME/.config/karabiner/assets/complex_modifications"
mkdir -p "$KARABINER_DIR"
cat > "$KARABINER_DIR/echo.json" <<EOF
{
    "title": "Echo (AI Rewrite / Dictate / Speak)",
    "rules": [
        {
            "description": "Globe key: tap = rewrite selection, hold = dictate, Cmd+Globe = speak selection",
            "manipulators": [
                {
                    "type": "basic",
                    "from": { "key_code": "fn", "modifiers": { "optional": ["any"] } },
                    "to": [
                        { "shell_command": "/usr/bin/touch /tmp/rewrite_record_start && /usr/bin/osascript -e 'tell application \"System Events\" to name of first process whose frontmost is true' > /tmp/rewrite_record_app.txt" }
                    ],
                    "to_if_alone": [
                        { "shell_command": "/bin/bash $SCRIPT_DIR/rewrite_selection.sh" }
                    ],
                    "to_after_key_up": [
                        { "shell_command": "/bin/rm -f /tmp/rewrite_record_start && /usr/bin/python3 $SCRIPT_DIR/dictate.py" }
                    ]
                },
                {
                    "type": "basic",
                    "from": { "key_code": "fn", "modifiers": { "mandatory": ["command"] } },
                    "to": [
                        { "shell_command": "/usr/bin/python3 $SCRIPT_DIR/speak.py" }
                    ]
                },
                {
                    "type": "basic",
                    "from": {
                        "key_code": "spacebar",
                        "modifiers": { "mandatory": ["fn"], "optional": ["any"] }
                    },
                    "to": [
                        { "shell_command": "'$BIN_DIR/lang_toggle' &" }
                    ]
                }
            ]
        }
    ]
}
EOF

# ── Done ─────────────────────────────────────────────────────────────────────
cat <<'DONE'

==============================================================
Automated install complete.

THESE THREE STEPS REQUIRE GUI CLICKS — they cannot be scripted:

1. Install Karabiner-Elements (if you don't have it):
   https://karabiner-elements.pqrs.org/

2. Open Karabiner-Elements → Complex Modifications →
   "Add predefined rule" → enable
   "Echo (AI Rewrite / Dictate / Speak)".

3. The first time you tap or hold Globe, macOS will prompt for:
   • Microphone        (the recorder daemon)
   • Accessibility     (Karabiner-Elements, osascript, AND paste_helper —
                        paste_helper needs it to send Cmd+V; until granted,
                        Dictate falls back to a slower osascript paste)
   • Automation        (allow your shell to control "System Events")
   Approve all of them.

RECOMMENDED — pin one microphone, so dictation always records from the
same input instead of following whatever macOS has selected. Easiest way
is the menubar icon → Microphone. From a shell, list the inputs with:

   "$HOME/Library/Application Support/Echo/bin/record_realtime.app/Contents/MacOS/record_realtime" --list-inputs

Then write the one you want into the config and restart the recorder:

   mkdir -p "$HOME/Library/Application Support/Echo"
   echo 'MacBook Pro Microphone' > "$HOME/Library/Application Support/Echo/input_device"
   launchctl kickstart -k "gui/$(id -u)/com.echo.context-helper.record-realtime"

Pick this Mac's built-in mic, or a wired display/interface mic — NOT
Bluetooth headphones. Opening a headset's microphone drops it from stereo
to mono call mode, which costs 1.5–2s before recording starts and audibly
degrades whatever you're listening to.

Verify with:
   • tap Globe with text selected → it gets rewritten
   • hold Globe, speak, release   → caption appears, transcript pasted
   • Cmd+Globe with text selected → Russian audio plays

Logs: ~/Documents/context-helper/rewrite.log   (all three tools)
      /tmp/record_realtime.log                 (the recorder daemon)
==============================================================
DONE
