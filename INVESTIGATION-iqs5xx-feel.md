# IQS5xx Driver Feel Investigation — Synthesis

Date: 2026-04-28
Branch: `investigation/world-class-iqs5xx`
Trigger: Allie's Lily58 with same TPS43 (IQS572 die) on holykeebs QMK feels world-class. Our Corne with AYM1607-fork ZMK feels jumpy on slow drags. Five parallel research agents launched to determine why.

## TL;DR

Our driver writes the chip's filter configuration register (`0x0632`) into a half-configured **dynamic IIR mode**, but never sets register `0x0633` which is **the max-filtering beta at low speeds** of that dynamic filter. With `0x0633` at chip POR (likely zero), the chip applies **no filtering at slow speeds** — directly causing the jitter Allie reports on slow drag.

Linux, holykeebs QMK, and QMK upstream all **never write** `0x0632` at all. They trust the chip's NVD-baked defaults from Azoteq's GUI tool. Our driver's well-intentioned filter write breaks the factory tuning. The fix is small, surgical, and converges with three reference drivers.

## Reference drivers compared

| Driver | Status | What it does to filter regs |
|---|---|---|
| Linux `drivers/input/touchscreen/iqs5xx.c` | Mainline kernel, Jeff LaBundy maintainer | Writes nothing to `0x0632`, `0x0633`, `0x0637`, `0x0638`, `0x0639`, `0x0672` |
| Holykeebs `qmk_firmware` `hk-master` | Active commercial keyboard vendor | Same — writes none of the filter regs |
| QMK upstream | Mainline pointing-device driver | Same — writes none of the filter regs |
| AYM1607 ZMK (our fork's parent) | Active community ZMK driver | **Writes 3 of them** with hardcoded values |
| stelmakhdigital ZMK | Active independent ZMK driver | Writes `0x0632` configurable, default `0x0F` |
| fcoury fork of AYM1607 | One commit, 2025-11-22 | Adds REATI, palm-reject, idle timeout, report rates as DT props |
| Rino1122 fork of AYM1607 | Active, datasheet-aligned init order | Same as AYM1607 for filter |

## Root-cause hypothesis (datasheet-validated)

Per Azoteq IQS5xx-B000 Datasheet Rev 2.1 §5.9, the dynamic IIR filter (when `IIR_SELECT=0` in `0x0632`) operates as:

```
beta(speed) = static_beta_0x0633          if speed < LOWER_SPEED
            = bottom_beta_0x0637          if speed >= UPPER_SPEED
            = linear_interp(...)          between

filtered_pos[n] = filtered_pos[n-1] + (raw[n] - filtered_pos[n-1]) * beta/256
```

Our `setup_device` writes:
- `0x0632 = 0x0B` → IIR_FILTER + MAV_FILTER + ALP_COUNT_FILTER + dynamic IIR (IIR_SELECT=0)
- `0x0637 = config->bottom_beta` (DT default 5) → bottom_beta = MIN beta at high speed
- `0x0633` = **NEVER WRITTEN** → static_beta = MAX beta at low speed = chip POR
- `0x0638` LOWER_SPEED = NEVER WRITTEN → POR
- `0x0639-0x063A` UPPER_SPEED = NEVER WRITTEN → POR

If chip POR for `0x0633` is 0 (which is plausible — datasheet doesn't publish defaults), then at low speeds the chip applies `beta = 0/256 = 0` = no filter. Slow drag of a finger jitters across the unfiltered raw centroid signal, producing the symptom Allie reports.

This also explains the second symptom (fast motion straight-line gaps): if LOWER_SPEED == UPPER_SPEED == 0 at POR, the dynamic filter has zero transition window. Datasheet doesn't document this edge case, but the most likely behaviors are:
- Filter snaps from full-on (at exactly speed=0) to full-off (any motion) → chunky transitions
- Filter is permanently in one extreme regardless of speed → uneven feel

Either way the chip is being driven into an undefined / degenerate dynamic-IIR state because we set the mode bit but didn't configure its parameters.

## Concrete patch plan

### Tier 0 — surgical fix (recommended first)

Match the three reference drivers: trust the chip's NVD-baked tuning. Plus add the three things QMK enables that we don't.

**`modules/zmk-driver-azoteq-iqs5xx/drivers/input/iqs5xx.c` `iqs5xx_setup_device`:**

1. **DELETE** `iqs5xx_write_reg8(dev, IQS5XX_FILTER_SETTINGS, IQS5XX_IIR_FILTER | IQS5XX_MAV_FILTER | IQS5XX_ALP_COUNT_FILTER)` (line ~387)
2. **DELETE** `iqs5xx_write_reg8(dev, IQS5XX_BOTTOM_BETA, config->bottom_beta)` (line ~369)
3. **DELETE** `iqs5xx_write_reg8(dev, IQS5XX_STATIONARY_THRESH, config->stationary_threshold)` (line ~375)
4. **ADD** `iqs5xx_write_reg8(dev, IQS5XX_IDLE_MODE_TIMEOUT, 0xFF)` — pin idle timeout to "never" per AZD087 §4.2
5. **ADD** `iqs5xx_write_reg16(dev, IQS5XX_REPORT_RATE_IDLE_TOUCH, 10)` — match holykeebs (chip default behavior preserved across mode transitions)
6. **ADD** `iqs5xx_write_reg16(dev, IQS5XX_REPORT_RATE_IDLE, 10)` — same
7. **MODIFY** XY_CONFIG_0 write — OR in `IQS5XX_PALM_REJECT` (BIT(3))
8. **MODIFY** final SYSTEM_CONFIG_0 write — OR in `IQS5XX_REATI | IQS5XX_ALP_REATI` (BIT(2) | BIT(3))

Net change: 3 deletes, 3 adds, 2 modifies. About 30 lines of C.

### Tier 0 header changes

**`iqs5xx.h`:**
```c
#define IQS5XX_PALM_REJECT BIT(3)              // bit 3 of XY_CONFIG_0 (0x0669)
#define IQS5XX_IDLE_MODE_TIMEOUT 0x0586        // single byte, 0xFF = never
#define IQS5XX_REPORT_RATE_IDLE_TOUCH 0x057C   // 16-bit ms
#define IQS5XX_REPORT_RATE_IDLE 0x057E         // 16-bit ms
```

### Tier 0 DT bindings

**`dts/bindings/input/azoteq,iqs5xx-common.yaml`:**
- Mark `bottom-beta` and `stationary-threshold` deprecated (or remove — they have no effect after Tier 0)
- Add boolean `palm-reject` (default true)
- Add boolean `reati` (default true)
- Add boolean `disable-idle-timeout` (default true)

### Tier 1 — only if Tier 0 isn't enough

If after Tier 0 the slow-drag jitter is still present, the chip's NVD default for `0x0633` (max beta) is too low. Then we move into tuning the filter explicitly per the datasheet's recommended dynamic-IIR setup. This requires writing all four registers as a coherent set:

- `0x0632 = 0x03` (IIR + MAV, dynamic IIR, no ALP_COUNT) per AZD087 recommendation
- `0x0633` static_beta = ~128 (mid-range; MAX filtering at low speed) — datasheet recommends mid-range to leave headroom
- `0x0637` bottom_beta = ~5 (preserve current default; MIN filtering at high speed)
- `0x0638` LOWER_SPEED = ~5 (pixels/cycle; below this = full filter)
- `0x0639-0x063A` UPPER_SPEED = ~50 (pixels/cycle; above this = bottom_beta)

Expose all four as DT properties for iteration, since "feel" is subjective and we'll want to tune.

### Tier 2 — architectural exploration (low priority, big effort)

If even Tier 1 doesn't satisfy:

A. **Switch to ABS coordinates** like Linux. Read `0x0016`/`0x0018` (16-bit absolute centroids) instead of `0x0012`/`0x0014` (chip-pre-computed deltas). Compute deltas in software. Bypasses any chip-side quantization on REL output. Significant refactor — work handler maintains prev-pos state.

B. **Multi-touch slot tracking.** Linux tracks 5 simultaneous contacts via Linux MT-protocol slots. We track only `NUM_FINGERS` and emit single-finger deltas. Slot-aware tracking gives cleaner finger-lift/finger-down handling, prevents phantom motion on multi-finger gestures.

C. **Switch to polling mode** (`EVENT_MODE = false`) like holykeebs. Periodic 10ms timer, no RDY interrupt. Chip behaves slightly differently in polling mode. Significant work in ZMK — no native poller infrastructure for this kind of driver.

These are 1-2 week refactors each. Not warranted unless Tier 0 + Tier 1 leave real gaps.

## What we should NOT change

These were earlier suspicions that turned out to be fine:

- **`stationary-threshold` default 5** — it's in output-resolution pixels. 5/2048 = 0.24% of pad width = sensible noise floor, not aggressive.
- **REL coordinates** — holykeebs uses REL (same as us) and feels great. ABS migration not required.
- **Interrupt mode (EVENT_MODE=1)** — not the cause; just architecturally different from holykeebs.
- **SETUP_COMPLETE clear-on-init** — our chip-wedge fix is orthogonal and correct.
- **ACK_RESET sequence** — we have a more robust path than the reference drivers; don't touch.
- **Burst read at 0x000D** — works fine, our optimization is on top of holykeebs/Linux.
- **I2C 400kHz** — fine, gives us headroom.

## Cherry-pick path (fast track)

`fcoury/zmk-driver-azoteq-iqs5xx` already implemented Tier 0 in a single commit dated 2025-11-22. We could rebase our `fix/clear-setup-complete-on-init` branch onto fcoury's work, then:
1. Merge our chip-wedge fix on top
2. Add palm-reject DT prop default-true (fcoury defaults false)
3. Drop our `0x0632`/`0x0637`/`0x0672` writes (fcoury keeps them; we go further)

Rough effort: 2-3 hours including build + flash + test.

## Open questions

1. **Chip POR default for `0x0633`** — datasheet doesn't publish. We'd need to read it back via I2C on a fresh-flashed chip to know. Easy diagnostic: dump that register at boot in a debug build.
2. **Whether SETUP_COMPLETE is required** — holykeebs/QMK upstream don't write it; we do. Our chip-wedge fix path requires the bit-clear; whether the bit needs to be re-set later is unclear from the datasheet.
3. **`AUTO_ATI` trigger** (BIT(5) of `0x0431`) — none of the reference drivers explicitly trigger ATI. Chip's NVD has factory-tuned ATI compensation from TPS43 module manufacturing. Probably leave alone.
4. **LP1/LP2 timeouts** (`0x0587`, `0x0588`) — AZD087 example values exist but no driver writes them. With `0x0586 = 0xFF` (idle never expires), LP1/LP2 are unreachable, so these are moot.

## Sources

- IQS5xx-B000 Datasheet Rev 2.1 (Sept 2019): https://www.azoteq.com/images/stories/pdf/iqs5xx-b000_trackpad_datasheet.pdf
- AZD087 Setup and User Guide Rev 1.0 (Nov 2015): https://www.azoteq.com/images/stories/pdf/AZD087%20-%20IQS5xx-B000%20Setup%20and%20User%20Guide.pdf
- TPS43/TPS65 Module Datasheet v1.02
- Linux: https://github.com/torvalds/linux/blob/master/drivers/input/touchscreen/iqs5xx.c
- Holykeebs QMK: https://github.com/holykeebs/qmk_firmware/blob/hk-master/drivers/sensors/azoteq_iqs5xx.c
- QMK upstream: https://github.com/qmk/qmk_firmware/blob/master/drivers/sensors/azoteq_iqs5xx.c
- AYM1607 ZMK: https://github.com/AYM1607/zmk-driver-azoteq-iqs5xx
- fcoury fork: https://github.com/fcoury/zmk-driver-azoteq-iqs5xx
- Rino1122 fork: https://github.com/Rino1122/zmk-driver-azoteq-iqs915x
- stelmakhdigital: https://github.com/stelmakhdigital/zmk_driver_azoteq

## Recommended next action

When the board is back: implement Tier 0, build, flash. ~30 lines of C, ~3 DT prop additions, one west.yml edit if we want fcoury's bindings. Test feel against the de5139b baseline (currently flashed) and against the Lily58 holykeebs baseline.

If feel matches Lily58 = ship Tier 0 to main, close investigation, the world is good.
If feel still has slow-drag jitter = move to Tier 1 with explicit dynamic-IIR tuning.
If even Tier 1 doesn't satisfy = consider Tier 2 architectural changes, but probably not worth it for marginal gains.

---

## Implementation log — 2026-04-28 evening session

### Tier 0 flashed and tested

Driver fork `3b7448c` + parent `c5778b9` — branch `feat/world-class-feel-tier0`.

**Allie's verdict after flash + replug:**
- Slow-drag jitter mostly resolved.
- BUT: *"feels like it just doesn't have the smooth subpixel movement down to a T... not really like jitter, like DPI in a way, like the minutest of movements isn't picking up. It's like it's just a little not sensitive, so once it moves it moves in blocks."*
- Lily58 (holykeebs) is *"more sensitive AND smoother simultaneously."*

That combined "more sensitive AND smoother" rules out filter as the remaining cause. Points to **chip output resolution** — `X_RESOLUTION` (`0x066E`) / `Y_RESOLUTION` (`0x0670`). Lower resolution = chunkier integer REL deltas after the chip rounds its internal 256-points-between-electrodes precision before emit. Higher resolution preserves more sub-electrode precision.

**Holykeebs writes these at init** via `azoteq_iqs5xx_setup_resolution()` to chip max (2048×1792 for TPS43). Linux reads them but doesn't override. **Our driver wrote nothing.** Chip used whatever NVD had — given the symptom, plausibly less than max.

### Tier 1 — X/Y resolution explicit write

Driver fork `b8e9702` (parent `5529482`).

Adds `IQS5XX_X_RESOLUTION = 0x066E`, `IQS5XX_Y_RESOLUTION = 0x0670`. `setup_device` writes both when DT props non-zero. New DT properties `x-resolution` (default 2048) and `y-resolution` (default 1792). Setting either to 0 leaves chip at NVD default.

### Tier 1 read-back diagnostic

Driver fork `a06b2d4` (parent `769bcb7`).

`LOG_INF` reads `0x066E` + `0x0670` immediately before driver overwrites them. Logs as `Chip NVD resolution: X=<n> Y=<n>`. Visible in USB serial debug build only.

Confirms or refutes the hypothesis empirically:
- NVD < 2048×1792 → our resolution write was the cause of any feel improvement.
- NVD = 2048×1792 already → resolution wasn't the bottleneck, look elsewhere.

### What's still open

- **Runtime resolution change** — plumbing exists, no UX. Out of scope this session.
- **Dynamic IIR speed thresholds** (`0x0638` LOWER_SPEED, `0x0639-0x063A` UPPER_SPEED) — datasheet says these are in pixels-per-cycle of the *configured* resolution, so only tunable cleanly after resolution is locked. Tier 2 territory.
- **REL → ABS coordinate migration** like Linux — read absolute centroids, compute deltas in software at higher precision than chip-side integer rounding. Significant refactor. Tier 3.
