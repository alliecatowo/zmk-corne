# Touchpad Debugging Handoff

Status pinned to the Phase A attempt (this commit). Touchpad NACKed on every
prior attempt; this iteration addresses a **stacked cause** that earlier debug
sessions missed.

## TL;DR

Right half has an Azoteq TPS43 (IQS572) touchpad on I2C `0x74`. Driver loads, but
I2C transactions NACKed across every previous config — including the
originally-correct pin assignment. This iteration lands a compound fix that
addresses both root causes at once.

**Next step:** flash `corne_right_debug` UF2, capture USB serial logs, follow the
decision-gate tree below.

## Definitive Factory Pin Extraction

Byte-level analysis of the committed factory firmware (`firmware/original-backup/RIGHT.UF2`)
located the compiled `iqs5xx_config` struct at flash offset `0x60ae8`:

| Role | Pin | Polarity | Evidence |
|---|---|---|---|
| RDY | **P1.02** | `GPIO_ACTIVE_HIGH` | gpio_dt_spec at `0x60b40`, `{port=P1, pin=2}` |
| NRST | **P1.01** | `GPIO_ACTIVE_LOW` | gpio_dt_spec at `0x60b48`, `{port=P1, pin=1}` |
| SCL | **P0.17** | — | `NRF_PSEL(TWIM_SCL)=0x000c0011` at `0x60b18` |
| SDA | **P0.20** | — | `NRF_PSEL(TWIM_SDA)=0x000b0014` at `0x60b1c` |
| I2C freq | 100 kHz | — | `nrf_twim_frequency=0x01980000` at `0x60af8` |
| I2C addr | 0x74 | — | node name `iqs5xx@74` |

P1.01 and P1.02 appear only in RIGHT.UF2, not LEFT.UF2 — confirming they are
right-half touchpad pins.

## Stacked Root Cause

Previous debug focused only on cause #1. All three had to be fixed together.

**Cause 1 — Pins were inverted by commit `4212e32`.**
That commit was a well-intentioned guess that happened to be wrong. Restoring
RDY → P1.02 is mandatory.

**Cause 2 — AYM1607 driver's post-reset race.**
`drivers/input/iqs5xx.c` in the AYM1607 module does, when `reset-gpios` is
wired: pulse reset 1ms → release → `k_msleep(10)` → configure RDY interrupt →
`k_msleep(100)` → call `iqs5xx_setup_device()`. Total post-reset wait is ~111ms.
IQS572 datasheet specifies ≥150ms for ATI, and real chips can take up to 500ms.
Setup register writes hit a still-closed communication window, all NACK, init
returns `-EIO`. This is why commit `61bd27b` — which had the correct pins —
*still* failed.

For comparison, the stelmakhdigital TPS43-specific driver waits 610ms after
reset release. AYM1607 is too aggressive.

**Cause 3 — Missing `zmk,input-split` forwarding (central/peripheral bridge).**
ZMK split keyboards isolate input devices to the half they're physically wired to.
Our touchpad is on the peripheral (right), but HID reports come out of the
central's (left) USB. Without a pair of `zmk,input-split` nodes — a source on
the peripheral that forwards events over BLE, and a proxy on the central that
re-emits them — the touchpad could be working perfectly and the host would
never see a single event. The `zmk,input-listener` alone (our previous config)
is NOT enough for split setups. This is confirmed from `app/src/pointing/input_split.c`
in the ZMK source and cross-validated in `EyalYe/zmk-config` (a working Corne
+ TPS43 build). Pattern applied:
- `corne_right.overlay`: `zmk,input-split` with `device = <&tps43>`, `reg = <0>`.
- `corne_left.overlay`: `zmk,input-split` proxy with matching `reg = <0>`, no
  `device`, plus the `zmk,input-listener` bound to the proxy.

## Current State (Phase A + split-input fix)

Split-shield layout:

- `config/boards/shields/corne/corne_right.overlay` — I2C bus, TPS43 device,
  `zmk,input-split` source (forwards events to central over BLE).
- `config/boards/shields/corne/corne_left.overlay` — `zmk,input-split` proxy +
  `zmk,input-listener` (consumes forwarded events, emits HID mouse).
- `config/corne.keymap` — only kscan wiring + keymap. No touchpad nodes.
- `config/boards/shields/corne/boards/nice_nano_v2.overlay` — empty (I2C now
  lives on right-only).
- `config/corne.conf` — unchanged (`CONFIG_ZMK_POINTING=y`, `CONFIG_I2C=y`,
  debug log vars).

## Testing Procedure

1. Wait for GitHub Actions to build. Download `corne_right_debug.uf2`:
   ```
   gh run list --workflow build.yml --limit 1
   gh run download <run-id> -n firmware
   ```
2. Plug right half via USB. Double-tap reset → `NICENANO` volume mounts.
3. Copy UF2 to `/Volumes/NICENANO/`. Board reboots automatically.
4. Identify the serial port: only the debug build emits text.
   ```
   # Two /dev/cu.usbmodem* ports will exist. Debug half emits [time] <lvl> lines.
   cat /dev/cu.usbmodem2143101    # Ctrl-C after a second
   cat /dev/cu.usbmodem2143201
   ```
5. Tail the debug port:
   ```
   screen /dev/cu.usbmodemXXXX 115200   # Ctrl-A K to exit
   ```
6. Touch the pad. Interpret per decision gates below.

## Decision Gates

### ✅ Success signature
- `iqs5xx: initialized` (or similar probe-success message) during boot
- `input: ... rel_x=... rel_y=...` events when touching the pad
- Cursor moves on macOS during touch

### 🟡 "0xEEEE" close-NACK only
If logs show NACKs *only* on the `0xEEEE` write, that's the IQS5xx protocol's
mandated communication-window-close. Normal. Ignore those specific NACKs.

### 🔴 Phase B1 — Patch AYM1607 driver timing
If logs show sustained NACK loops on early setup register writes (e.g. at
register `0x058F`, system config):
- Fork `AYM1607/zmk-driver-azoteq-iqs5xx` into alliecatowo's GitHub.
- Pin `config/west.yml` to the fork's branch.
- In `drivers/input/iqs5xx.c` `iqs5xx_init`: replace `k_msleep(100)` with a poll
  loop that waits up to 500ms for `gpio_pin_get_dt(&config->rdy_gpio) == 1`.
- If you later want to add `reset-gpios` back, bump the `k_msleep(10)` after
  reset release to `k_msleep(200)` as well.

### 🔴 Phase B2 — Swap to stelmakhdigital driver
If Phase B1 doesn't land cleanly, switch drivers:
- `config/west.yml`: add project `zmk_driver_azoteq` from `stelmakhdigital` remote.
- Keymap: `compatible = "azoteq,tps43"`, rename `reset-gpios` → `rst-gpios` (note
  the different property name!), re-add NRST on P1.01 `GPIO_ACTIVE_LOW`.
- Kconfig: enable `CONFIG_INPUT_AZOTEQ_IQS5XX=y` (symbol name differs from
  AYM1607's).

### 🔴 Phase C — Hardware sanity (only if B1+B2 both fail)
- Multimeter the P2 header pinout (we assumed VCC/GND/SDA/SCL/RDY).
- Scope SDA/SCL idle: should sit at 3.3V. Floating → pullups missing.
- Re-flash `firmware/original-backup/RIGHT.UF2` to confirm hardware still works.

## Reference: Files You'll Touch

- `config/corne.keymap` — touchpad devicetree node.
- `config/boards/shields/corne/boards/nice_nano_v2.overlay` — I2C bus config.
- `config/corne.conf` — Kconfig (I2C, pointing, logging).
- `config/west.yml` — driver module pin (only for Phase B).
- `build.yaml` — build variants (`corne_right_debug` is what we flash).
- `tools/extract_pins.py` — UF2 pin extractor. Reusable.
- `firmware/original-backup/{LEFT,RIGHT}.UF2` — factory ground truth / rollback.

## Reference: Driver Behavior Notes

- AYM1607 `azoteq,iqs5xx`: configures `GPIO_INT_EDGE_RISING` on RDY, reads registers
  in work handler triggered by RDY rising edge. Setup/init path is synchronous,
  does NOT go through the work handler.
- The `0xEEEE` close-window write is expected to NACK per IQS5xx protocol — don't
  mistake for a real failure.
- `reset-gpios` absent means driver skips its reset block entirely; clock relies on
  natural power-on reset (fine, since board boot takes ≫150ms).
