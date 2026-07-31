#!/usr/bin/env bash
# Capture the current selection via Cmd+C and pipe it to rewrite.py.
# Karabiner runs this directly on a Globe tap — no Automator Quick Action in
# the path, which removes that layer's multi-second launch overhead.
#
# The copy goes through the CGEvent paste_helper (--copy) so it doesn't pay the
# System Events cold-start; it falls back to osascript if the helper is missing
# or not yet Accessibility-trusted. If nothing is selected (clipboard unchanged
# after the copy), do nothing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

original=$(pbpaste)

if ! ( [ -x "$SCRIPT_DIR/paste_helper" ] && "$SCRIPT_DIR/paste_helper" --copy >/dev/null 2>&1 ); then
    /usr/bin/osascript -e 'tell application "System Events" to keystroke "c" using command down'
fi
/bin/sleep 0.12
selection=$(pbpaste)

if [ -z "$selection" ] || [ "$selection" = "$original" ]; then
    # Nothing selected — restore the original clipboard and exit.
    printf '%s' "$original" | /usr/bin/pbcopy
    exit 0
fi

# Restore the user's clipboard before running rewrite.py. The script does its
# own save/clobber/restore around the paste, so handing it back the original
# now keeps that flow clean.
printf '%s' "$original" | /usr/bin/pbcopy
printf '%s' "$selection" | /usr/bin/python3 "$SCRIPT_DIR/rewrite.py"
