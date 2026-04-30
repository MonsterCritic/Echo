#!/usr/bin/env bash
# Capture the current selection via Cmd+C and pipe it to rewrite.py.
# This lets Karabiner trigger the rewrite directly without needing a
# Services keyboard-shortcut assignment in System Settings.
#
# If nothing is selected (clipboard didn't change after Cmd+C), do nothing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

original=$(pbpaste)
/usr/bin/osascript -e 'tell application "System Events" to keystroke "c" using command down'
/bin/sleep 0.15
selection=$(pbpaste)

if [ -z "$selection" ] || [ "$selection" = "$original" ]; then
    # Nothing selected — restore the original clipboard and exit.
    printf '%s' "$original" | /usr/bin/pbcopy
    exit 0
fi

# Restore the user's clipboard before running rewrite.py. The script
# does its own save/clobber/restore around the paste, so handing it
# back the original now keeps that flow clean.
printf '%s' "$original" | /usr/bin/pbcopy
printf '%s' "$selection" | /usr/bin/python3 "$SCRIPT_DIR/rewrite.py"
