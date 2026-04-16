# Hardware Notes — AliExpress Corne with TPS43 Touchpad

## Board Details
- **Source**: AliExpress (unknown seller, listing 3256810072110707)
- **MCU**: Nice!Nano v2 (nRF52840)
- **Layout**: 3x6 + 3 thumb cluster per side (standard Corne physical layout)
- **Touchpad**: Azoteq TPS43 (IQS572 chipset) at I2C address 0x74
- **Touchpad connector**: 5-pin header labeled "P2" on PCB
- **Batteries**: NOT included (2-pin JST header present, needs 301230 LiPo)
- **Power switch**: Custom horizontal slide switch on bottom of PCB (not the Nice!Nano's reset button)
- **Case**: 3D printed

## NON-STANDARD PIN MAPPING

**This board is NOT compatible with the standard foostan Corne ZMK shield.**

The PCB swaps the row/column GPIO assignments compared to a standard Corne,
and uses pro_micro pin 8 (nRF P1.04) instead of pin 21 (nRF P0.31).

### Pin Comparison

| Function | Standard Corne (pro_micro pins) | This Board (pro_micro pins) |
|----------|--------------------------------|----------------------------|
| Columns  | 21, 20, 19, 18, 15, 14        | 20, 8, 7, 6, 5, 4         |
| Rows     | 4, 5, 6, 7                     | 19, 18, 15, 14             |

### GPIO Mapping (nRF52840)

**Columns (output, GPIO_ACTIVE_HIGH):**
| Pro Micro | nRF52840 | Standard Corne Role |
|-----------|----------|-------------------|
| 20        | P0.29    | Column            |
| 8         | P1.04    | (not used)        |
| 7         | P0.11    | Row               |
| 6         | P1.00    | Row               |
| 5         | P0.24    | Row               |
| 4         | P0.22    | Row               |

**Rows (input, GPIO_ACTIVE_HIGH | GPIO_PULL_DOWN):**
| Pro Micro | nRF52840 | Standard Corne Role |
|-----------|----------|-------------------|
| 19        | P0.02    | Column            |
| 18        | P1.15    | Column            |
| 15        | P1.13    | Column            |
| 14        | P1.11    | Column            |

### Other Notable Pins
- **P0.13**: LED (present in both backup and standard firmware)
- **P1.02**: Present in right half backup only (likely encoder or touchpad interrupt)

### Diode Direction
- col2row (same as standard Corne)

## Touchpad (TPS43)

- **Chipset**: Azoteq IQS572 (part of IQS5xx family)
- **Interface**: I2C at address 0x74
- **Connector**: 6-pin ZIF (0.5mm pitch) on touchpad, wired to P2 5-pin header on PCB
- **ZMK Driver**: [AYM1607/zmk-driver-azoteq-iqs5xx](https://github.com/AYM1607/zmk-driver-azoteq-iqs5xx)
- **Capabilities**: 2-finger multitouch, tap, swipe, scroll
- **Firmware reference**: Backup firmware identifies it as `tps43_split@74`

## Firmware Extraction Method

The pin mapping was extracted from the seller's backup UF2 firmware by:

1. Converting UF2 to flat binary (UF2 blocks are 512 bytes: 32-byte header + 256-byte payload)
2. Locating GPIO port device strings (`gpio@50000000` for P0, `gpio@50000300` for P1)
3. Finding `__device` struct pointers that reference these strings
4. Scanning for `gpio_dt_spec` arrays (12-byte structs: `{device_ptr, pin|flags, index}`)
5. Interpreting flags: `0x2000` = GPIO_PULL_DOWN (input/row pins), `0x0000` = no pull (output/col pins)

Zephyr does NOT embed a DTB blob — devicetree is compiled to C structs at build time.
The `gpio_dt_spec` structs survive in the binary and can be identified by their device pointers.

### Extraction Script

See `tools/extract_pins.py` for the automated extraction script.
