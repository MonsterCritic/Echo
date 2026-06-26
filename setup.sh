#!/usr/bin/env bash
# setup.sh — automates everything that doesn't require GUI clicks.
# Run from the repo root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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

# ── 3. Build record.app ──────────────────────────────────────────────────────
echo "Building record.app…"
mkdir -p record.app/Contents/MacOS
cat > record.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
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
</plist>
PLIST
swiftc -O record.swift -o record.app/Contents/MacOS/record

# ── 4. Build history_menubar.app ─────────────────────────────────────────────
echo "Building history_menubar.app…"
mkdir -p history_menubar.app/Contents/MacOS
cat > history_menubar.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
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
</plist>
PLIST
swiftc -O history_menubar.swift -o history_menubar.app/Contents/MacOS/history_menubar

# ── 5. Build standalone helpers ──────────────────────────────────────────────
echo "Building helper binaries…"
swiftc -O hud.swift -o hud
swiftc -O dialog_buttons.swift -o dialog_buttons
# paste_helper sends Cmd+V via CGEvent (no System Events), keeping AI Dictate's
# paste fast and load-immune. Ad-hoc sign so it can hold an Accessibility grant.
swiftc -O paste_helper.swift -o paste_helper
codesign -s - -f paste_helper 2>/dev/null || true

# ── 6. Make scripts executable ───────────────────────────────────────────────
chmod +x rewrite_selection.sh rewrite.py dictate.py speak.py install.sh

# ── 7. Install AI Rewrite Quick Action ───────────────────────────────────────
echo "Installing AI Rewrite Quick Action…"
./install.sh < /dev/null

# ── 8. LaunchAgent for the recorder daemon ───────────────────────────────────
echo "Installing LaunchAgent (auto-starts the recorder at login)…"
mkdir -p "$HOME/Library/LaunchAgents"
PLIST_PATH="$HOME/Library/LaunchAgents/com.echo.context-helper.record.plist"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.echo.context-helper.record</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_DIR/record.app/Contents/MacOS/record</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/record.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/record.err.log</string>
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

Verify with:
   • tap Globe with text selected → it gets rewritten
   • hold Globe, speak, release   → transcript pasted at cursor
   • Cmd+Globe with text selected → Russian audio plays

Logs: ~/Documents/context-helper/rewrite.log
==============================================================
DONE
