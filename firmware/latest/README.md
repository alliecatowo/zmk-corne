# Flashable Firmware — current build

Generated from `main` at the time of build. See the commit SHA in each UF2's INFO line.

## Files

| File | Flash to | When to use |
|---|---|---|
| `corne_right_debug.uf2` | **right half** | Touchpad debug — emits USB serial logs |
| `corne_right.uf2` | right half | Production (no serial logs) |
| `corne_left_studio.uf2` | **left half** | Left half with ZMK Studio + HID — **needed for touchpad forwarding** |
| `settings_reset.uf2` | either half | Only if BT pairing is wedged; wipes NVS |

## Flash procedures (two paths)

### Option A — DFU serial (works on MDM'd Macs)

Nice!Nano bootloader exposes a CDC ACM serial port. On corporate/MDM machines
where mass-storage writes are blocked, this path bypasses digihub entirely.

Prereq (once): `pip install --user adafruit-nrfutil`

```bash
# Double-tap reset on target half, then:
./dfu-flash.sh right         # flash corne_right_debug.uf2
./dfu-flash.sh left          # flash corne_left_studio.uf2
./dfu-flash.sh right-prod    # flash corne_right.uf2 (no USB logs)
./dfu-flash.sh reset         # flash settings_reset.uf2 (wipe pairings)
```

Script auto-converts UF2 → Intel HEX → Nordic DFU zip, then uploads over
`/dev/cu.usbmodem*`. Takes ~15 seconds per flash.

### Option B — UF2 drag-drop

1. **Put halves in bootloader:** double-tap the RESET button on each half. macOS will show a `NICENANO` USB mass storage volume per half.

2. **First time on this Mac:** macOS may block the accessory with `SUIS premount dissented`. Fix:
   - System Settings → Privacy & Security → scroll to "Allow accessories to connect"
   - Set to "Ask For New Accessories" (or "Automatically When Unlocked")
   - Unplug → replug the half → approve the prompt

3. **Flash the right half** (debug build is recommended during troubleshooting):
   ```bash
   cp corne_right_debug.uf2 /Volumes/NICENANO/
   ```
   If both halves show as `NICENANO` / `NICENANO 1`: the one you put in bootloader FIRST will usually be the lower-suffix (`NICENANO`). If in doubt, do one at a time.
   The board auto-reboots after copy.

4. **Flash the left half** (required — contains split input proxy for touchpad):
   ```bash
   cp corne_left_studio.uf2 /Volumes/NICENANO/
   ```

5. **Tail serial logs** from the right half:
   ```bash
   # After reboot, the debug half enumerates as "Generic CDC"
   # Figure out which /dev/cu.usbmodem* is which:
   cat /dev/cu.usbmodem2143101    # Ctrl-C quickly
   cat /dev/cu.usbmodem2143201
   # The one that emits [00:00:00.xxx] <inf> lines is the debug right half.

   # Then tail with screen:
   screen /dev/cu.usbmodemXXXX 115200
   # Exit: Ctrl-A K
   ```

## What to look for in the logs

- `iqs5xx: initialized` or similar probe-success message → I2C + driver good
- `input: ... rel_x=... rel_y=...` when you touch the pad → forwarding works
- Cursor should move on macOS when you touch the pad

## If it still doesn't work

See `TOUCHPAD_HANDOFF.md` at the repo root for Phase B / C escalation.
