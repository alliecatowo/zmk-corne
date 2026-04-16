# zmk-corne

ZMK firmware for Allie's AliExpress Corne keyboard (Nice!Nano v2 × 2, non-standard PCB pinout, right-half Azoteq TPS43 touchpad).

## Status

**Working as of April 2026.** Both keys and touchpad (movement, tap-click, press-and-hold, two-finger scroll) confirmed functional.

## Hardware

- AliExpress Corne PCB (mislabeled "Sofle_RGB" in stock firmware) — custom pin mapping: `cols=20,8,7,6,5,4 rows=19,18,15,14`.
- Nice!Nano v2 on each half (nRF52840, Adafruit UF2 bootloader).
- **Touchpad** (right half only): Azoteq TPS43 module (IQS572 die) on I2C 0x74 at 100 kHz.
  - SDA: P0.17, SCL: P0.20 (pro_micro_i2c defaults, matches factory wiring)
  - RDY: P1.02 (`GPIO_ACTIVE_HIGH`)
  - NRST: P1.01 (factory declares as GPIO_INPUT; we don't actively drive reset — relies on POR)
- Factory firmware backups at `firmware/original-backup/{LEFT,RIGHT}.UF2` for rollback.

## Build targets

Defined in `build.yaml`:

| Target | Purpose |
|---|---|
| `corne_left_studio` | Left half (central). ZMK Studio enabled. Flash this for normal use. |
| `corne_right` | Right half (peripheral). Production build, no serial logs. |
| `corne_right_debug` | Right half + `zmk-usb-logging` snippet. Flash this for touchpad/I2C debugging. |
| `settings_reset` | Wipes BT pairings + NVS. Only flash if halves can't re-pair. |

## ⚠️ After every flash: power-cycle BOTH halves

**Unplug both halves' USB → wait 2s → replug.** DFU reboots the MCU but not
the touchpad chip (whose state machine wedges) and not the BT pairing state
(which can end up half-torn). Symptoms of skipping: touchpad appears
rotated/laggy/dead. See [`TOUCHPAD_HANDOFF.md`](TOUCHPAD_HANDOFF.md#critical--power-cycle-both-halves-after-flashing).

## Flashing

Standard UF2 drag-drop works if macOS allows removable-storage mounts (`Privacy & Security → Allow accessories to connect → Always Allow`). MDM-managed Macs typically block this.

**DFU-serial path** (bypasses mass storage entirely — works on MDM Macs):

```bash
pip install --user adafruit-nrfutil        # one-time
# Double-tap reset on target half, then:
cd firmware/latest
./dfu-flash.sh left      # flash corne_left_studio.uf2
./dfu-flash.sh right     # flash corne_right_debug.uf2 (debug build with logs)
./dfu-flash.sh right-prod  # corne_right.uf2 (production, no logs)
./dfu-flash.sh reset     # wipe pairings
```

## Debugging the right half

With the debug build flashed, USB CDC emits ZMK logs. Identify the port (the one that emits `[time] <lvl>` lines):

```bash
python3 -c "import serial,time; s=serial.Serial('/dev/cu.usbmodemXXX',115200,timeout=5); print(s.read(4096).decode(errors='replace'))"
```

The `iqs5xx: Failed to read system info 0: -5` errors every ~1s are protocol-mandated NACKs outside the chip's comm window. Harmless. AYM1607 driver lacks retry logic the Linux kernel has; cosmetic only.

## Layout

```
config/
  corne.keymap           keymap + kscan override (applies to both halves)
  corne.conf             shared Kconfig
  corne_left.overlay     central-side: split input proxy + listener + X-axis flip transform
  corne_right.overlay    peripheral-side: I2C bus + tps43 device + input-split source
  west.yml               zmk + AYM1607 driver module
build.yaml               CI build matrix
firmware/
  original-backup/       factory UF2s (rollback)
  latest/                CI artifacts + DFU flash helpers
tools/extract_pins.py    UF2 pin-extraction utility
TOUCHPAD_HANDOFF.md      full debug chronology + stacked-cause analysis
```

## Deep touchpad debugging reference

See [`TOUCHPAD_HANDOFF.md`](TOUCHPAD_HANDOFF.md) for the full stacked-cause analysis. TL;DR:
1. Pin swap confusion (previously inverted vs. factory UF2 extraction).
2. AYM1607 driver's 10ms post-reset race vs. IQS572's ~150ms ATI (fixed by omitting `reset-gpios`).
3. Missing `zmk,input-split` peripheral-to-central forwarding.
4. **Shield overlays were in `config/boards/shields/corne/` — silently ignored.** ZMK auto-loads `<shield>.overlay` from `config/` directly. This was the real blocker for every prior build attempt.

## Roadmap

- [ ] Migrate to `stelmakhdigital/zmk_driver_azoteq` (TPS43-specific driver, proper suspend/resume, 3–8× idle battery-life improvement)
- [ ] Input-processors: sensitivity scaler, precision-mode layer, scroll-mode layer
- [ ] Deep sleep (`CONFIG_ZMK_SLEEP=y`) + `BT_BAS=n` to stop macOS waking from battery notifications
- [ ] Peripheral battery reporting (`CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING`)
- [ ] Mouse-layer keybindings (`&mkp`, `&msc`, precision/scroll layer toggles)
