# Touchpad Debugging Handoff

Status as of commit `d78143e` (2026-04-16). Pick this up in a fresh session and keep going.

## TL;DR

Right half has an Azoteq TPS43 (IQS572) touchpad on I2C `0x74`. Driver loads, but I2C transactions NACK. We're guessing RDY/NRST pins because nothing documents this PCB. Current build has **swapped** RDY/NRST vs. the initial guess + verbose I2C logging — not yet flashed and tested.

**Next step:** flash `corne_right_debug` UF2 to right half, capture USB serial logs, decide if the swap worked.

## Hardware Recap

See `HARDWARE.md` for full details. Key facts:

- **AliExpress Corne**, Nice!Nano v2, non-standard pin mapping (already working for keys).
- **Touchpad**: Azoteq TPS43 / IQS572 chipset, I2C addr `0x74`, 5-pin header "P2" on PCB.
- **Known-good pins** (extracted from backup firmware UF2):
  - Present in right-half backup but not left: `P1.02` — assumed to be a touchpad control pin (RDY or NRST).
  - `P1.01` is the other prime suspect but wasn't directly observed in the extraction; we're probing it as the other half of the pair.
- **Backup firmwares** committed at `firmware/original-backup/{LEFT,RIGHT}.UF2` — these are the seller-flashed (mislabeled "Sofle_RGB") factory firmware. Use them to re-extract or to flash as a rollback.

## Driver

- Module: `github.com/AYM1607/zmk-driver-azoteq-iqs5xx` (pulled via `config/west.yml`).
- Compatible string: `azoteq,iqs5xx`.
- Driver **requires** `rdy-gpios` at compile time (discovered the hard way — see commit `fd077a4`). Polling-only mode is not an option without a driver change.
- `reset-gpios` is optional.

## What's Been Tried (chronological)

| Commit | Change | Result |
|--------|--------|--------|
| `61bd27b` | Initial TPS43 setup. `rdy-gpios = P1.02`, `reset-gpios = P1.01`. | Boots, driver binds, but **I2C NACK at 0x74** — touchpad doesn't ACK any transaction. |
| `b481b7c` | Added `corne_right_debug` build target with `zmk-usb-logging` snippet. | Can now read logs over USB. |
| `4222285` | Removed **both** RDY/NRST pins to try polling mode. | **Build failed** — driver requires `rdy-gpios`. |
| `fd077a4` | Re-added `rdy-gpios = P1.02`, kept `reset-gpios` removed. Theory: wrong NRST pin was holding touchpad in reset. | Build ok; still NACKs (need to re-verify with logs). |
| `4212e32` | **Swapped** the pins: `rdy-gpios = P1.01`, `reset-gpios = P1.02`. Enabled `CONFIG_I2C_LOG_LEVEL_DBG` + `CONFIG_LOG_MODE_IMMEDIATE`. | **Current state — not yet flashed/tested.** |

## Current Config State

`config/corne.keymap`:
```dts
tps43: iqs5xx@74 {
    compatible = "azoteq,iqs5xx";
    reg = <0x74>;
    rdy-gpios   = <&gpio1 1 GPIO_ACTIVE_HIGH>;   /* P1.01 */
    reset-gpios = <&gpio1 2 GPIO_ACTIVE_LOW>;    /* P1.02 */
    one-finger-tap;
    two-finger-tap;
    press-and-hold;
    scroll;
    natural-scroll-y;
};
```

`config/corne.conf` (relevant):
```
CONFIG_ZMK_POINTING=y
CONFIG_ZMK_POINTING_SMOOTH_SCROLLING=y
CONFIG_I2C=y
CONFIG_I2C_LOG_LEVEL_DBG=y
CONFIG_LOG_MODE_IMMEDIATE=y
```

I2C bus uses default Nice!Nano pins (`&pro_micro_i2c` → SDA=P0.17, SCL=P0.20).

## Build Targets (`build.yaml`)

- `corne_left_studio` — left half, ZMK Studio enabled (central).
- `corne_right` — right half, production build.
- `corne_right_debug` — **use this for touchpad debugging**, emits USB serial logs.
- `settings_reset` — flash to wipe pairings.

## How To Test

1. Push the current commit (CI is GitHub Actions). Download `corne_right_debug.uf2` from the workflow artifacts.
2. Plug **right half** into USB (double-tap reset to enter bootloader if needed) and flash.
3. After it reboots, grab logs:
   ```
   sudo screen /dev/ttyACM0 115200
   ```
   (Exit with `Ctrl-A K`.)
4. Look for:
   - `i2c_nrfx_twim: Error ...` or NACK messages → addressing/wiring problem.
   - Driver probe success from the `iqs5xx` / `azoteq` tag → RDY/NRST are correct.
   - Touch events on the input subsystem.

## Live Theories (most → least likely)

1. **RDY/NRST still swapped wrong, or one of them isn't a GPIO line at all.** The backup firmware extraction only positively identified `P1.02`. `P1.01` is a guess for the other pin. It might actually be something else (nothing, or a different function). If the swap doesn't work, try `rdy-gpios = P1.02` + no `reset-gpios` again and *really* confirm the NACK from logs.
2. **Wrong I2C address.** `0x74` comes from the backup firmware's devicetree label (`tps43_split@74`). Worth scanning the bus (enable an I2C scanner or check logs at boot — Zephyr logs attempted addresses at DBG level).
3. **NRST polarity / idle level wrong.** We currently have `GPIO_ACTIVE_LOW` on reset. If the trace is actually an active-high enable, we're holding the chip disabled. Try inverting, or leave reset-gpios out entirely.
4. **Missing I2C pull-ups.** Azoteq parts generally expect external pull-ups. If the PCB doesn't have them, SDA/SCL float and every transaction NACKs. A multimeter check of SDA/SCL idle voltage (should sit at 3.3V) would rule this out.
5. **Power not reaching the touchpad.** The 5-pin "P2" header pinout isn't documented — we assumed 3V3/GND/SDA/SCL/RDY (or NRST). If VCC is on the wrong pin, the chip is unpowered and will NACK everything.
6. **IQS572 vs IQS5xx driver mismatch.** The AYM1607 driver is written for the IQS5xx family generically; TPS43 / IQS572 should be in that family but the init register sequence might differ. Low probability — save for when the electrical layer is confirmed healthy.

## Open Questions / Things To Verify Next

- [ ] Read the **backup UF2 again** with `tools/extract_pins.py` and grep for any `gpio_dt_spec` near I2C port structs — the RDY pin should pair with the `iqs5xx` device, giving us a definitive answer.
- [ ] Probe the 5-pin P2 header with a multimeter to identify VCC/GND/SDA/SCL.
- [ ] Scope or logic-analyze SDA/SCL during boot to see if the host is even talking, and if the target responds at all (distinguish "no ACK" from "no signal").
- [ ] Try `reset-gpios` inverted (`GPIO_ACTIVE_HIGH`) as a cheap experiment.
- [ ] If all else fails: re-flash the **backup firmware** (`firmware/original-backup/RIGHT.UF2`) and confirm the touchpad physically works — rules out hardware failure.

## Reference: Files You'll Touch

- `config/corne.keymap` — touchpad devicetree node (lines ~29–49).
- `config/corne.conf` — I2C/pointing kconfig.
- `config/boards/shields/corne/boards/nice_nano_v2.overlay` — I2C bus enable.
- `config/west.yml` — driver module pin.
- `build.yaml` — add/remove build variants.
- `tools/extract_pins.py` — firmware binary analyzer.
- `firmware/original-backup/{LEFT,RIGHT}.UF2` — factory firmware, our ground truth.
