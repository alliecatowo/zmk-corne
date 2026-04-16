#!/usr/bin/env bash
# Flash a UF2 to nice!nano via DFU serial — bypasses USB mass storage entirely.
# Useful on macs where MDM blocks mass-storage writes (the NICENANO volume
# never mounts via digihub but the bootloader's CDC ACM port still works).
#
# Usage:
#   ./dfu-flash.sh <side> [port]
#
#   side = right | right-prod | left | reset
#   port = /dev/cu.usbmodem* (optional — auto-detects if only one bootloader is present)
#
# Prereq: adafruit-nrfutil installed (`pip install --user adafruit-nrfutil`).
# Prereq: target half double-tapped into bootloader mode.

set -euo pipefail

cd "$(dirname "$0")"

side="${1:-}"
case "$side" in
    right)      uf2="corne_right_debug.uf2" ;;
    right-prod) uf2="corne_right.uf2" ;;
    left)       uf2="corne_left_studio.uf2" ;;
    reset)      uf2="settings_reset.uf2" ;;
    *)
        echo "Usage: $0 <right|right-prod|left|reset> [port]"
        echo "  right      -> corne_right_debug.uf2 (with USB serial logs)"
        echo "  right-prod -> corne_right.uf2 (no serial logs)"
        echo "  left       -> corne_left_studio.uf2"
        echo "  reset      -> settings_reset.uf2 (wipes BT pairings/NVS)"
        exit 1
        ;;
esac

NRFUTIL="${HOME}/.local/bin/adafruit-nrfutil"
if [[ ! -x "$NRFUTIL" ]]; then
    echo "adafruit-nrfutil not found at $NRFUTIL"
    echo "Install with: pip install --user adafruit-nrfutil"
    exit 1
fi

# Auto-detect port if not given.
# Bootloader enumerates a CDC ACM serial port distinct from running firmware.
# Simplest heuristic: if user passed it, use it; else pick the single new
# /dev/cu.usbmodem* that appeared after last boot (caller needs to know which).
port="${2:-}"
if [[ -z "$port" ]]; then
    # List all usbmodem ports. User has to pick if multiple.
    mapfile -t ports < <(ls /dev/cu.usbmodem* 2>/dev/null || true)
    if (( ${#ports[@]} == 0 )); then
        echo "No /dev/cu.usbmodem* found. Double-tap reset on the target half."
        exit 1
    fi
    if (( ${#ports[@]} == 1 )); then
        port="${ports[0]}"
    else
        echo "Multiple serial ports found:"
        for i in "${!ports[@]}"; do echo "  [$i] ${ports[$i]}"; done
        read -p "Pick which index is the bootloader (target in DFU mode): " idx
        port="${ports[$idx]}"
    fi
fi

echo "Flashing $uf2 via DFU serial on $port"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Convert UF2 -> hex
python3 - <<PY
import struct, sys
src = '$uf2'
dst_hex = '$WORK/fw.hex'
with open(src, 'rb') as f: data = f.read()
blocks = len(data) // 512
regions = []
for i in range(blocks):
    b = data[i*512:(i+1)*512]
    m0, m1, _, addr, psize, _, _, _ = struct.unpack_from('<IIIIIIII', b, 0)
    assert m0 == 0x0A324655 and m1 == 0x9E5D5157
    regions.append((addr, b[32:32+psize]))
regions.sort()
def cs(bb): return ((-sum(bb)) & 0xFF)
def rec(t, a, p):
    rb = bytes([len(p), (a>>8)&0xff, a&0xff, t]) + p
    return ':' + rb.hex().upper() + f"{cs(rb):02X}"
lines = []; cur = None
for addr, payload in regions:
    p = 0
    while p < len(payload):
        ca = addr + p
        upper = (ca >> 16) & 0xFFFF
        if upper != cur:
            lines.append(rec(0x04, 0, bytes([(upper>>8)&0xff, upper&0xff])))
            cur = upper
        chunk = payload[p:p+16]
        lines.append(rec(0x00, ca & 0xFFFF, chunk))
        p += 16
lines.append(':00000001FF')
open(dst_hex, 'w').write('\n'.join(lines) + '\n')
PY

# Build DFU zip
"$NRFUTIL" dfu genpkg \
    --dev-type 0x0052 \
    --application "$WORK/fw.hex" \
    --application-version 1 \
    --sd-req 0xCA,0xB6,0x00B6,0xFFFE \
    "$WORK/fw.zip" >/dev/null

# Flash
"$NRFUTIL" dfu serial \
    --package "$WORK/fw.zip" \
    --port "$port" \
    -b 115200 \
    --singlebank

echo "Done. Board should reboot into new firmware."
