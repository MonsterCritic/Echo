# Echo — AI Rewrite, Dictate & Speak

A small set of macOS tools wired up to the Globe (🌐 / Fn) key:

- **AI Rewrite** — tap Globe with text selected → Claude rewrites it in place (translates non-English to English, prettifies tone, replaces the selection).
- **AI Dictate** — hold Globe → speak → release → OpenAI Whisper transcribes, Claude prettifies, and the result is pasted at the cursor.
- **AI Speak** — Cmd+Globe with text selected → translates to Russian (if not already Cyrillic) and streams TTS playback sentence-by-sentence.

All actions run locally; only the Anthropic and OpenAI APIs are called over the network.

---

## Requirements

- macOS 13+ (Ventura or newer)
- Python 3 (preinstalled on macOS)
- Swift toolchain (`xcode-select --install` if `swiftc` isn't found)
- An [Anthropic API key](https://console.anthropic.com/) — needed for Rewrite
- An [OpenAI API key](https://platform.openai.com/api-keys) — needed for Dictate and Speak
- [Karabiner-Elements](https://karabiner-elements.pods.tools/) — used to bind the Globe key

---

## Step-by-step install

### 1. Clone the repo

```sh
git clone git@github.com:MonsterCritic/Echo.git ~/Documents/context-helper
cd ~/Documents/context-helper
```

### 2. Add your API keys

Create a `.env` file in the repo root:

```sh
cp .env.example .env
chmod 600 .env
```

Open `.env` and fill in:

```
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
```

### 3. Install the AI Rewrite Quick Action

```sh
./install.sh
```

This creates `~/Library/Services/AI Rewrite.workflow` and reloads the Services menu.

### 4. Build the recorder daemon and helper binaries

```sh
swiftc -O record.swift -o record.app/Contents/MacOS/record
swiftc -O history_menubar.swift -o history_menubar.app/Contents/MacOS/history_menubar
swiftc -O dialog_buttons.swift -o dialog_buttons
swiftc -O hud.swift -o hud
```

(The `.app` bundle directories already exist in the repo — only the inner binaries need to be rebuilt.)

### 5. Auto-start the recorder daemon at login

Create a LaunchAgent so the recorder is always running and the first Globe-hold has zero cold-start lag:

```sh
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.sergeyshmidt.context-helper.record.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sergeyshmidt.context-helper.record</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/Documents/context-helper/record.app/Contents/MacOS/record</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/record.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/record.err.log</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.sergeyshmidt.context-helper.record.plist
```

### 6. Grant macOS permissions

The first time each tool runs, macOS will prompt for permissions. Approve them in **System Settings → Privacy & Security**:

- **Microphone** — for the recorder (`record`).
- **Accessibility** — for Karabiner-Elements and `osascript` (used to send Cmd+V and re-focus the original app).
- **Automation** — allow Terminal/iTerm/your shell to control "System Events" and "Finder".

If a tool seems to do nothing, check Console.app for permission denials.

### 7. Configure Karabiner-Elements

Install Karabiner-Elements from the link above, then add a Complex Modification rule that binds the Globe key:

- **Tap Globe** → run `~/Documents/context-helper/rewrite.py` as a shell command (or invoke the "AI Rewrite" service via a keyboard shortcut you assign in System Settings → Keyboard → Keyboard Shortcuts → Services).
- **Hold Globe** → on press: `touch /tmp/rewrite_record_start && echo "<frontmost-app-name>" > /tmp/rewrite_record_app.txt`. On release: `rm /tmp/rewrite_record_start && python3 ~/Documents/context-helper/dictate.py`.
- **Cmd+Globe** → `python3 ~/Documents/context-helper/speak.py`.

A minimal Karabiner rule looks like this (paste into `~/.config/karabiner/assets/complex_modifications/echo.json` and import via Karabiner's GUI):

```json
{
  "title": "Echo (AI Rewrite / Dictate / Speak)",
  "rules": [
    {
      "description": "Hold Globe → dictate, tap Globe → rewrite, Cmd+Globe → speak",
      "manipulators": [
        {
          "type": "basic",
          "from": { "key_code": "fn", "modifiers": { "optional": ["any"] } },
          "to": [
            { "shell_command": "/usr/bin/touch /tmp/rewrite_record_start && /bin/bash -c 'osascript -e \"tell application \\\"System Events\\\" to name of first process whose frontmost is true\" > /tmp/rewrite_record_app.txt'" }
          ],
          "to_if_alone": [
            { "shell_command": "pbpaste | /usr/bin/python3 $HOME/Documents/context-helper/rewrite.py" }
          ],
          "to_after_key_up": [
            { "shell_command": "/bin/rm -f /tmp/rewrite_record_start && /usr/bin/python3 $HOME/Documents/context-helper/dictate.py" }
          ]
        }
      ]
    }
  ]
}
```

> The "tap Globe" path here pipes `pbpaste` for testing. If you want the tap to read the *current selection* (not the clipboard), assign a keyboard shortcut to the "AI Rewrite" service in **System Settings → Keyboard → Keyboard Shortcuts → Services**, then have Karabiner trigger that shortcut instead.

### 8. (Optional) Run the menubar history app

`history_menubar.app` displays the last few dictation results so you can recover anything that didn't land in the right window:

```sh
open ~/Documents/context-helper/history_menubar.app
```

Add it to **System Settings → General → Login Items** if you want it to auto-start.

---

## Verify it works

1. **Rewrite** — select some text in any app, tap Globe. It should be replaced with a rewritten version within ~1s.
2. **Dictate** — focus a text input, hold Globe, speak a sentence, release. The transcript should be pasted at the cursor.
3. **Speak** — select an English sentence, press Cmd+Globe. You should hear the Russian translation read aloud.

If something misfires, check `~/Documents/context-helper/rewrite.log` — every action logs its inputs, outputs, and timing.

---

## Files

| File | Purpose |
|---|---|
| `rewrite.py` | AI Rewrite — Claude-powered selection rewrite |
| `dictate.py` | AI Dictate — Whisper transcription + Claude prettify |
| `speak.py` | AI Speak — translate-to-Russian + streaming TTS |
| `record.swift` | Persistent voice-recording daemon (auto-started at login) |
| `history_menubar.swift` | Menubar app showing recent dictation history |
| `hud.swift`, `dialog_buttons.swift` | Small UI helpers |
| `install.sh` | Installs the AI Rewrite Automator Quick Action |
| `.env.example` | Template for API keys |

---

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.sergeyshmidt.context-helper.record.plist
rm ~/Library/LaunchAgents/com.sergeyshmidt.context-helper.record.plist
rm -rf "$HOME/Library/Services/AI Rewrite.workflow"
```

Then remove the Karabiner rule from Karabiner-Elements' Complex Modifications panel.
