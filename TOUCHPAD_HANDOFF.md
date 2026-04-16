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
| SDA | **P0.17** | — | `NRF_PSEL(TWIM_SDA, 0, 17) = 0x000c0011` at `0x60b18` (fun=12=SDA) |
| SCL | **P0.20** | — | `NRF_PSEL(TWIM_SCL, 0, 20) = 0x000b0014` at `0x60b1c` (fun=11=SCL) |
| I2C freq | 100 kHz | — | `nrf_twim_frequency=0x01980000` at `0x60af8` |
| I2C addr | 0x74 | — | node name `iqs5xx@74` |

P1.01 and P1.02 appear only in RIGHT.UF2, not LEFT.UF2 — confirming they are
right-half touchpad pins.

## Stacked Root Cause

Previous debug focused only on cause #1. FOUR causes had to be fixed together.

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

**Cause 4 — Shield overlay files in wrong directory (silently ignored).**
Our `zephyr/module.yml` sets `board_root: .`, so Zephyr looks for shield
overlays at `./boards/shields/<shield>/` at the repo root — NOT at
`./config/boards/shields/<shield>/`. Overlays placed under `config/boards/`
are silently dropped by the build. Every prior build never compiled the
AYM1607 driver (zero mentions of `iqs5xx`/`azoteq` in CI build logs). Only
the `corne.keymap` changes took effect because keymap auto-loads from
`$ZMK_CONFIG` (`config/`), which is why the keyboard matrix kept working
even though the touchpad silently did nothing. Fix: `git mv config/boards/
shields/corne/ boards/shields/corne/`. ZMK user-config template confirms
this layout.

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

### 🔴 Phase B2 — Swap to stelmakhdigital driver (RECIPE)

Purpose-built for TPS43. Datasheet-correct timing (10ms reset + 610ms ATI wait
+ poll-until-SHOW_RESET before configure). `reg ` and bus unchanged; `zmk,input-split`
unchanged.

**1. `config/west.yml`** — replace the driver project:
```yaml
manifest:
  defaults:
    revision: v0.3
  remotes:
    - name: zmkfirmware
      url-base: https://github.com/zmkfirmware
    - name: stelmakhdigital
      url-base: https://github.com/stelmakhdigital
  projects:
    - name: zmk
      remote: zmkfirmware
      import: app/west.yml
    - name: zmk-driver-azoteq
      remote: stelmakhdigital
      revision: main
  self:
    path: config
```

**2. `config/boards/shields/corne/corne_right.overlay`** — swap compatible + property names,
add NRST back (safe here — driver waits 610ms post-reset):
```dts
&pro_micro_i2c {
    status = "okay";
    clock-frequency = <I2C_BITRATE_STANDARD>;   /* or I2C_BITRATE_FAST; factory used STANDARD */

    tps43: trackpad@74 {
        compatible = "azoteq,tps43";             /* was azoteq,iqs5xx */
        reg = <0x74>;
        rdy-gpios = <&gpio1 2 GPIO_ACTIVE_HIGH>;
        rst-gpios = <&gpio1 1 GPIO_ACTIVE_LOW>;  /* add back — property name is rst not reset */
        single-tap;                              /* was one-finger-tap */
        two-finger-tap;
        press-and-hold;
        scroll;
        invert-scroll-y;                         /* was natural-scroll-y */
    };
};

/* split_inputs block unchanged */
```

**3. `config/corne.conf`** — add driver Kconfig:
```
CONFIG_INPUT_TPS43=y
```

**Property renames** (common gotcha):
| AYM1607 | stelmakhdigital |
|---|---|
| `reset-gpios` | `rst-gpios` |
| `one-finger-tap` | `single-tap` |
| `natural-scroll-y` | `invert-scroll-y` |

Emit codes (identical): `INPUT_REL_X/Y/WHEEL/HWHEEL`, `INPUT_BTN_0/1`. Our central
`zmk,input-listener` consumes these unchanged.

### 🟠 Phase B3 — Check P1.29 (possible touchpad power gate)

Deep factory UF2 extract found a GPIO at **P1.29 with complex flags `0x0539`**
(active-low + pull-up + additional config bits) that appears in the RIGHT half
only. The researcher flagged it as "possibly EXT_POWER enable" — i.e. a 3V3 gate
controlling power to the TPS43. ZMK's default `nice_nano_v2` EXT_POWER node
targets **P0.13** (`ext_power: control-gpios = <&gpio0 13 GPIO_OPEN_DRAIN>`),
which is Nice!Nano's on-board rail. But the AliExpress Corne PCB may have
rerouted the touchpad's 3V3 to a separate, independently-switched rail on P1.29.

If that's the case, we never enable P1.29 in our build → the chip is
**unpowered** → every I2C transaction NACKs, regardless of any other fix.

**Symptoms that point to this:**
- Flashed Phase A + split-input build, still every transaction NACKs
- Logs show "device not found" or "no ACK" on `iqs5xx_setup_device`'s first
  register write at `0x058F`, not partway through the sequence

**Fix to try:**
Add a shield-level GPIO output that drives P1.29 active on boot. Simplest way —
add to `config/boards/shields/corne/corne_right.overlay`:
```dts
/ {
    tp_power: tp-power {
        compatible = "zmk,ext-power-generic";
        control-gpios = <&gpio1 29 GPIO_OPEN_DRAIN>;
        init-delay-ms = <50>;
    };

    chosen {
        zmk,ext-power = &tp_power;
    };
};
```
And enable in `config/corne.conf`:
```
CONFIG_ZMK_EXT_POWER=y
```

This overrides nice_nano_v2's default ext-power node to point at P1.29.

**Caveat:** the flags `0x0539` are complex (not clean ACTIVE_HIGH/LOW), so
polarity is not certain. If the touchpad still doesn't respond, try
`GPIO_ACTIVE_LOW` as well. Worst case, short experimentally with
`gpio-keys` / fixed-regulator bindings.

### 🔴 Phase C — Hardware sanity (only if B1+B2+B3 all fail)
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
