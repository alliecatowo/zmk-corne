# Touchpad: Debug Chronology + Roadmap

**Status as of 2026-04-16: WORKING.** Cursor movement, tap-click, press-and-hold, two-finger scroll all confirmed functional on the right-half Azoteq TPS43 (IQS572) touchpad over BLE split to the left-half central. Released as `v2026.04.16-tps43-working`.

---

## Final Working Config

**Driver**: `github.com/AYM1607/zmk-driver-azoteq-iqs5xx` @ `main` (compatible = `azoteq,iqs5xx`).

**Pins** (factory-extracted from `firmware/original-backup/RIGHT.UF2`):
- RDY = P1.02 `GPIO_ACTIVE_HIGH`
- NRST = P1.01 (factory declares as `GPIO_INPUT`; we omit `reset-gpios` and rely on POR)
- SDA = P0.17, SCL = P0.20 (pro_micro_i2c defaults)
- I2C = 100 kHz (I2C_BITRATE_STANDARD)
- I2C address = 0x74

**Layout**:
- `config/corne.keymap` — shared keymap, kscan pin overrides
- `config/corne.conf` — shared Kconfig (ZMK_POINTING, CONFIG_I2C, debug logs)
- `config/corne_right.overlay` — right-half overlay: I2C bus + tps43 device + `zmk,input-split@0` source with `device = <&tps43>`
- `config/corne_left.overlay` — left-half overlay: `zmk,input-split@0` proxy (same reg) + `zmk,input-listener` bound to proxy + `zmk,input-processor-transform` with `INPUT_TRANSFORM_X_INVERT` (X-axis correction)

---

## How we got here — four stacked root causes

All four had to be right simultaneously. Each "cause" in isolation looked like a plausible diagnosis but didn't fix the problem alone.

### Cause 1: Pin swap guess (commit `4212e32`)

An earlier debug session swapped RDY/NRST pin assignments relative to factory based on a guess. Byte-level analysis of factory `RIGHT.UF2` (`iqs5xx_config` struct at flash offset 0x60ae8) gave definitive pins: RDY=P1.02, NRST=P1.01. Restored (commit `83542bf`).

### Cause 2: AYM1607 driver post-reset race

AYM1607's `iqs5xx_init` does: pulse reset 1 ms → `k_msleep(10)` → configure RDY → `k_msleep(100)` → `iqs5xx_setup_device`. Total ~111 ms post-reset. IQS572 datasheet specifies ≥150 ms for ATI, up to 500 ms in practice. When `reset-gpios` is wired, setup writes fire into a still-closed comm window — all NACK, init returns `-EIO`.

Workaround: **omit `reset-gpios`**. The chip uses its natural POR (completed long before Zephyr driver init). 100 ms blind sleep is plenty when the chip has been powered for seconds already. Committed at `83542bf`.

### Cause 3: Missing `zmk,input-split` forwarding

ZMK split keyboards isolate input devices to the physical half they're wired to. Touchpad lives on the peripheral (right); HID reports must come out of the central's (left) USB. Without `zmk,input-split` source + proxy bridging the two over BLE, peripheral touchpad events never reach the host. The shared-keymap `zmk,input-listener` pattern alone is insufficient for split. Added `split_inputs/tps43_split@0` on both halves (commit `5b4ea5d`). Confirmed against ZMK source `app/src/pointing/input_split.c` and `EyalYe/zmk-config`'s Corne+TPS43 config.

### Cause 4: Shield overlays in wrong directory (THE actual blocker)

Our repo's `zephyr/module.yml` sets `board_root: .`, so Zephyr *should* scan `./boards/shields/` at repo root. In practice — even after moving overlays there — Zephyr's shield lookup only found upstream ZMK's shield dir. Zero references to our workspace path appeared in CI build logs. The driver was never compiled; evidence: no `iqs5xx`/`azoteq` strings anywhere in the build log across every prior build attempt.

**Fix:** move overlays to `config/<shield>.overlay` (commit `89c31ff`). This uses ZMK's documented `$ZMK_CONFIG` auto-load mechanism — Zephyr picks them up as a proper shield extension, no module registration needed. After this change, the CI log grep for `iqs5xx` went from 0 → 26 occurrences.

### Cause 5: X-axis inversion (final tweak)

Once the driver was compiling and the split forwarding was wired, cursor worked but X was inverted (finger left → cursor right). Y was correct. `flip-x;` at driver level did not produce the expected inversion despite:
- Property name confirmed in `AYM1607/.../azoteq,iqs5xx-common.yaml` binding
- Driver code maps DT prop → `IQS5XX_FLIP_X = BIT(0)` → register `0x0669 XY_CONFIG_0`
- Same register + bit layout confirmed in stelmakhdigital driver + Linux kernel driver

Unclear why the driver write doesn't land (possibly `setup_device` fails on a preceding register write due to the I2C comm-window timing quirk — would take runtime debug to confirm). Moved inversion to ZMK's listener-level `zmk,input-processor-transform` with `INPUT_TRANSFORM_X_INVERT` — post-driver, authoritative, matches urob's and other known-working community configs. Fixed in commit `13fae34`.

---

## CRITICAL — power-cycle after flashing the right half

**Every firmware flash, the right half MUST be physically unplugged from USB
and replugged before testing the touchpad.** Learned the hard way over
multiple misdiagnosed "regressions":

- Symptom if skipped: touchpad appears rotated (90°-ish), laggy, or dead.
  Feels like the new firmware broke something. It didn't — the IQS572
  chip's internal state machine is wedged.
- Root cause: DFU flash reboots the MCU but the IQS572 stays powered from
  the same 3V3 rail. If it was mid-I2C-transaction when the MCU rebooted
  (highly likely given how often the driver polls), its state latches in a
  broken state. The new firmware talks to it, gets garbage, reports back
  to ZMK.
- Fix: unplug USB from the right half → wait ~2s → replug. That power-
  cycles the IQS572 properly; POR runs cleanly; driver init succeeds.

Applies to DFU-serial flashes AND UF2 drag-drop flashes — both reboot the
MCU only, not the touchpad chip.

Does NOT apply to the left half — no touchpad, no wedged chip state,
just flash and go.

## Open / cosmetic: `Failed to read system info 0: -5`

Every ~1 s while idle, the debug serial log shows:
```
<err> i2c_nrfx_twi: Error 0x0BAE0001 occurred for message 0
<err> iqs5xx: Failed to read system info 0: -5
```

**Decoded** (`0x0BAE0001` = `NRFX_ERROR_DRV_TWI_ERR_ANACK`, address NACK). IQS5xx protocol opens a comm window triggered by RDY, NACKs any I2C address byte outside that window. AYM1607's `iqs5xx_work_handler` fires on RDY rising edge and immediately reads `SYSTEM_INFO_0` (`0x000F`). If work-queue scheduling misses the window, the read NACKs. The Linux kernel iqs5xx driver handles this with a 10-retry loop + 200–300 µs between attempts — AYM1607 has no retry logic; it logs and drops the work item, waiting for the next RDY.

**Impact**: purely cosmetic. Touch works because most windows are caught, and the failed reads don't corrupt state.

**Fix**: either patch AYM1607 to add retry logic, or migrate to stelmakhdigital's driver (which has proper retry + I2C window handling). Covered in Roadmap below.

---

## Roadmap — planned improvements

### R1. Migrate to `stelmakhdigital/zmk_driver_azoteq` (HIGH value)

**Why**: AYM1607 has zero power management. IQS572 idle current at ~227 µA vs `<1 µA` in suspend via `SYSTEM_CONTROL_1 (0x0432) bit 0`. stelmakhdigital's driver:
- Full `ZMK_LISTENER` on `zmk_activity_state_changed` → calls `tps43_set_sleep(dev, true)` on IDLE/SLEEP, `false` on ACTIVE
- `k_sem`-guarded I2C (no race between RDY handler and suspend)
- First-transaction-after-suspend NACK handled correctly (dummy read + 200 ms settle)
- 610 ms post-reset wait (datasheet-correct, no race like AYM1607's 10 ms)
- Proper `0xEEEE` close-window handling

**Expected uplift**: 3–8× peripheral-half idle battery life. Right-half standby time goes from ~3 days to ~2–3 weeks assuming typical usage.

**Migration diff**:
- `config/west.yml`: swap project `zmk-driver-azoteq-iqs5xx` → `zmk_driver_azoteq` @ stelmakhdigital
- `config/corne_right.overlay`:
  - `compatible = "azoteq,iqs5xx"` → `compatible = "azoteq,tps43"`
  - Rename: `reset-gpios` → `rst-gpios` (we'll add NRST back on P1.01 `GPIO_ACTIVE_LOW` since the driver handles reset timing correctly)
  - Rename: `one-finger-tap` → `single-tap`
  - Rename: `natural-scroll-y` → `invert-scroll-y`
  - Add: `enable-power-management;`
- `config/corne_right.conf` (new file): `CONFIG_INPUT_TPS43=y`
- Keep split_inputs / zmk,input-split unchanged — same wiring works across drivers
- Keep listener-level X-invert unchanged — still works post-driver

**UX gotcha to solve during migration**: stelmakhdigital disables the RDY interrupt during suspend. First touch after idle doesn't wake the driver — user must press a key first. Mitigations:
1. Leave RDY interrupt enabled in idle and have work handler check suspend flag
2. Add a `zmk,gpio-key-wakeup-trigger` on RDY for system-off deep wakeup

### R2. Input-processors for pointing quality-of-life

Attaches to `tps43_listener` on the central. All applied post-driver.

- **Sensitivity scaler**: `&zip_xy_scaler <1 2>` on base = 0.5× speed globally (TPS43 raw is usually too fast). Add `&zip_scroll_scaler <1 2>` for scroll speed.
- **Precision layer**: layer-override on listener with `&zip_xy_scaler <1 2>` + `process-next` — net 0.25× when held. For fine cursor work.
- **Scroll-mode layer**: layer-override with `&zip_xy_to_scroll_mapper` — finger movement becomes scroll wheel.
- **Natural-scroll toggle**: two layers with/without `INPUT_TRANSFORM_Y_INVERT` on a `zip_scroll_transform` node.

Gotcha: ZMK issue #2967 — layer-0 overrides can bleed. Keep overrides on non-zero layer indices. See input-processors research for full recipe.

### R3. Mouse-layer keybindings

Add a `mouse_layer` (layer 4) with:
- `&mkp LCLK` / `&mkp MCLK` / `&mkp RCLK` on home row
- `&msc SCRL_UP` / `&msc SCRL_DOWN` for keyboard-driven scroll
- `&mo 5` → scroll-mode layer momentary
- `&mo 6` → precision-mode layer momentary
- Toggles (`&tog 4`, `&tog 5`, `&tog 6`) added to `bt_layer`

### R4. Sleep + battery config (small, high-leverage)

In `config/corne.conf`:
- `CONFIG_ZMK_SLEEP=y` — enables 15-min deep sleep. ~20 µA vs ~1.5 mA awake-idle. **Single highest-impact battery config**.
- `CONFIG_BT_BAS=n` — suppresses BAS notifications that wake macOS from display sleep (known ZMK issue #1273). Trade-off: macOS stops displaying the battery percentage.
- `CONFIG_ZMK_BATTERY_REPORT_INTERVAL=120` — cut ADC polling in half.

In new `config/corne_left.conf` (central only):
- `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=y` — central polls peripheral battery and fires ZMK events.

### R5. Back to driver-level X-axis (curiosity)

Allie's hypothesis: `flip-x` at driver level might have been working but the test on the pre-fix build only flashed the right half — even though that's architecturally sufficient for a driver-level invert. Worth an A/B test after migrating to stelmakhdigital (which has proper I2C retry so the `setup_device` path is more reliable). If driver-level flip-x works on stelmakhdigital's driver, the listener-level transform becomes redundant and can be dropped for cleanliness.

---

## Reference — files touched

- `config/corne.keymap` — keymap + kscan only
- `config/corne.conf` — shared Kconfig
- `config/corne_right.overlay` — I2C + tps43 device + input-split source
- `config/corne_left.overlay` — input-split proxy + listener + X-invert transform
- `config/west.yml` — AYM1607 driver module
- `build.yaml` — CI build matrix (4 targets)
- `firmware/original-backup/{LEFT,RIGHT}.UF2` — factory firmware (ground-truth rollback)
- `firmware/latest/dfu-flash.sh` — DFU-serial flash helper (MDM-friendly)
- `tools/extract_pins.py` — UF2 pin-extraction utility

## Reference — external

- AYM1607 driver source + binding: github.com/AYM1607/zmk-driver-azoteq-iqs5xx @ main
- stelmakhdigital driver source: github.com/stelmakhdigital/zmk_driver_azoteq @ main (migration target)
- Linux kernel iqs5xx driver (reference for retry logic): `drivers/input/touchscreen/iqs5xx.c`
- IQS5xx-B000 Setup and User Guide (Azoteq AZD087)
- IQS572EV02 datasheet (power numbers)
- ZMK user-config template: github.com/zmkfirmware/unified-zmk-config-template
- ZMK input-split source: `app/src/pointing/input_split.c` @ v0.3
- ZMK input-processors docs: zmk.dev/docs/keymaps/input-processors
