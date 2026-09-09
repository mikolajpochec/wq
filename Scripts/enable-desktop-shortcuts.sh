#!/bin/bash
# Registers macOS's own "Switch to Desktop N" shortcuts (⌃5 … ⌃9).
#
# macOS only ships entries for desktops 1-4; anything beyond that has no shortcut, so WindowQueue
# has nothing to fall back on for a workspace that holds no windows. Symbolic hotkey ids 118-121 are
# desktops 1-4, and 122 onwards continue the series.
#
# Undo in System Settings › Keyboard › Keyboard Shortcuts › Mission Control.
set -euo pipefail

CONTROL=262144   # ⌃ modifier mask used by AppleSymbolicHotKeys
# desktop:id:keycode  — keycodes are the ANSI virtual key codes for 5,6,7,8,9
ENTRIES="5:122:23 6:123:22 7:124:26 8:125:28 9:126:25"

for entry in $ENTRIES; do
    desktop="${entry%%:*}"
    rest="${entry#*:}"
    id="${rest%%:*}"
    keycode="${rest##*:}"
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$id" \
        "{enabled=1;value={parameters=(65535,$keycode,$CONTROL);type=standard;};}"
    echo "desktop $desktop -> ⌃$desktop (id $id)"
done

/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
echo "settings reloaded"
