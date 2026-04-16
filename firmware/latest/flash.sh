#!/usr/bin/env bash
# Flash a UF2 to a nice!nano bootloader volume.
# Usage: ./flash.sh <side>   where <side> is "right" or "left"
#
# Expects the relevant half to already be in bootloader mode (double-tap reset)
# and its NICENANO volume to be mounted at /Volumes/NICENANO or /Volumes/NICENANO\ 1.
#
# If macOS refused to mount with "SUIS premount dissented", open System Settings
# -> Privacy & Security -> "Allow accessories to connect" and set to
# "Ask For New Accessories", then replug and approve.

set -euo pipefail

cd "$(dirname "$0")"

side="${1:-}"
case "$side" in
    right) uf2="corne_right_debug.uf2" ;;
    right-prod) uf2="corne_right.uf2" ;;
    left)  uf2="corne_left_studio.uf2" ;;
    reset) uf2="settings_reset.uf2" ;;
    *)
        echo "Usage: $0 <right|right-prod|left|reset>"
        echo ""
        echo "Available UF2s:"
        ls -1 *.uf2 2>/dev/null | sed 's/^/  /'
        exit 1
        ;;
esac

if [[ ! -f "$uf2" ]]; then
    echo "error: $uf2 not found in $(pwd)"
    exit 1
fi

# Find NICENANO volumes
mapfile -t vols < <(ls -d "/Volumes/NICENANO"* 2>/dev/null || true)
if (( ${#vols[@]} == 0 )); then
    echo "No NICENANO volume mounted. Double-tap RESET on the target half."
    echo "If macOS is silently refusing, see SUIS note in README.md."
    exit 1
fi

if (( ${#vols[@]} == 1 )); then
    target="${vols[0]}"
else
    echo "Multiple NICENANO volumes found:"
    for i in "${!vols[@]}"; do echo "  [$i] ${vols[$i]}"; done
    read -p "Pick which index to flash $uf2 to: " idx
    target="${vols[$idx]}"
fi

echo "Flashing $uf2 -> $target/"
cp "$uf2" "$target/"
echo "Done. Board will reboot."
