#!/usr/bin/env python3
"""Extract GPIO pin assignments from a ZMK/Zephyr UF2 firmware file.

Zephyr compiles devicetree to C structs (no DTB blob). This script finds
gpio_dt_spec arrays in the binary by locating GPIO port device structs
and tracing references to them.

Usage:
    python3 extract_pins.py firmware.uf2
"""

import struct
import sys


GPIO_TO_PROMICRO = {
    ('P0', 8): 0, ('P0', 6): 1, ('P0', 17): 2, ('P0', 20): 3,
    ('P0', 22): 4, ('P0', 24): 5, ('P1', 0): 6, ('P0', 11): 7,
    ('P1', 4): 8, ('P0', 12): 9,
    ('P1', 11): 14, ('P1', 13): 15, ('P0', 10): 16,
    ('P1', 15): 18, ('P0', 2): 19, ('P0', 29): 20, ('P0', 31): 21,
}


def uf2_to_flat(path):
    """Convert UF2 file to flat binary, returning (data, base_address)."""
    regions = {}
    with open(path, 'rb') as f:
        while True:
            block = f.read(512)
            if len(block) < 512:
                break
            magic1 = struct.unpack('<I', block[0:4])[0]
            if magic1 != 0x0A324655:
                continue
            addr = struct.unpack('<I', block[12:16])[0]
            datalen = struct.unpack('<I', block[16:20])[0]
            regions[addr] = block[32:32 + datalen]

    if not regions:
        return b'', 0

    min_addr = min(regions.keys())
    max_addr = max(k + len(v) for k, v in regions.items())
    flat = bytearray(max_addr - min_addr)
    for addr, data in regions.items():
        offset = addr - min_addr
        flat[offset:offset + len(data)] = data
    return bytes(flat), min_addr


def extract_pins(data, base):
    """Extract GPIO pin assignments from firmware binary."""
    p0_str_off = data.find(b"gpio@50000000")
    p1_str_off = data.find(b"gpio@50000300")
    if p0_str_off < 0 or p1_str_off < 0:
        print("  GPIO port strings not found in binary!")
        return

    p0_str_addr = base + p0_str_off
    p1_str_addr = base + p1_str_off

    p0_ptr = struct.pack('<I', p0_str_addr)
    p1_ptr = struct.pack('<I', p1_str_addr)

    # Find __device struct addresses (first pointer to name string)
    p0_dev = p1_dev = None
    for i in range(0, len(data) - 4, 4):
        if data[i:i + 4] == p0_ptr and p0_dev is None:
            p0_dev = base + i
        elif data[i:i + 4] == p1_ptr and p1_dev is None:
            p1_dev = base + i

    if not p0_dev or not p1_dev:
        print("  GPIO device structs not found!")
        return

    p0_dev_bytes = struct.pack('<I', p0_dev)
    p1_dev_bytes = struct.pack('<I', p1_dev)

    print(f"  GPIO P0 device @ 0x{p0_dev:08x}")
    print(f"  GPIO P1 device @ 0x{p1_dev:08x}")

    cols = []
    rows = []
    other = []
    for i in range(0, len(data) - 12, 4):
        val = data[i:i + 4]
        if val == p0_dev_bytes or val == p1_dev_bytes:
            port = "P0" if val == p0_dev_bytes else "P1"
            pin_word = struct.unpack('<I', data[i + 4:i + 8])[0]
            pin = pin_word & 0x3F
            flags = (pin_word >> 8) & 0xFFFF
            if pin > 31:
                continue  # invalid pin, false positive
            entry = (base + i, port, pin, flags)
            if flags & 0x2000:
                rows.append(entry)
            elif flags == 0:
                cols.append(entry)
            else:
                other.append(entry)

    print(f"\n  COLUMNS ({len(cols)} pins, output, no pull):")
    for addr, port, pin, flags in cols:
        pm = GPIO_TO_PROMICRO.get((port, pin), '??')
        print(f"    @0x{addr:08x}: {port}.{pin:02d} (pro_micro {pm})")

    print(f"\n  ROWS ({len(rows)} pins, input, pull-down):")
    for addr, port, pin, flags in rows:
        pm = GPIO_TO_PROMICRO.get((port, pin), '??')
        print(f"    @0x{addr:08x}: {port}.{pin:02d} (pro_micro {pm})")

    if other:
        print(f"\n  OTHER ({len(other)} pins):")
        for addr, port, pin, flags in other:
            pm = GPIO_TO_PROMICRO.get((port, pin), '??')
            print(f"    @0x{addr:08x}: {port}.{pin:02d} flags=0x{flags:04x} (pro_micro {pm})")


def extract_strings(data, min_len=4):
    """Extract DT node names and other relevant strings."""
    strings = []
    current = b''
    for i, b in enumerate(data):
        if 32 <= b < 127:
            current += bytes([b])
        else:
            if len(current) >= min_len:
                s = current.decode()
                if any(k in s.lower() for k in [
                    'kscan', 'matrix', 'gpio@', 'i2c@', 'spi@', 'tps43',
                    'cirque', 'procyon', 'maxtouch', 'sensor', 'touch',
                    'mouse', 'pointing', 'encoder', 'split', 'sofle',
                    'corne', 'eyelash'
                ]):
                    strings.append((i - len(current), s))
            current = b''
    return strings


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <firmware.uf2> [firmware2.uf2 ...]")
        sys.exit(1)

    for path in sys.argv[1:]:
        print(f"\n{'=' * 60}")
        print(f"  {path}")
        print(f"{'=' * 60}")
        data, base = uf2_to_flat(path)
        print(f"  Size: {len(data)} bytes, base address: 0x{base:08x}\n")

        extract_pins(data, base)

        print(f"\n  RELEVANT STRINGS:")
        for pos, s in extract_strings(data):
            print(f"    @{base + pos}: {s}")
