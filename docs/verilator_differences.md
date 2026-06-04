# Verilator sim vs. FPGA core — known differences

Living record of where the Verilator simulator (`verilator/sim.v` + the
`verilator/sim_main.cpp` C++ harness) differs from the synthesised FPGA core
(`MacLC.sv` + `sys/`). Keep this updated when you add a top-level signal, change
CPU/bus glue, or hardwire a config in one place.

**Why this matters:** `verilator/sim.v` is the Verilator top (`module emu`), NOT
`MacLC.sv`. It has its **own** CPU instantiation and bus glue (VPA / DTACK / BERR
/ overlay). All peripheral RTL is shared through `dataController_top`, but any
CPU-glue or top-level wiring fix must be made in **both** files or sim and FPGA
silently diverge. (This has bitten us before — e.g. sim once hardwired
`.berr(1'b0)`, masking the MOVES bus-error fix.)

Last audited: 2026-06-04 (commit `2f96afa`).

---

## ✅ Shared / verified identical

These must stay identical; they were checked and match today.

- **All peripheral RTL** — instantiated once in `dataController_top` (used by both
  tops): VIA, pseudovia, V8 video, Ariel DAC, IWM/SWIM, SCC, NCR5380/SCSI, ASC,
  the Egret HC05 wrapper, and **`adb_device` (ADB kbd+mouse) + the ADB
  open-collector loopback + the SCSI upper-byte write fix**.
- **CPU bus glue (both tops, byte-identical):**
  - `cpu_berr = fc7_berr && !_cpuAS`
  - `_cpuVPA  = fc7_iack ? 0 : (fc7_berr ? 1 : ~(!_cpuAS && cpuAddr[23:21]==3'b111 && !selectVRAM))`
  - `_cpuDTACK= fc7_berr ? 1 : (~(!_cpuAS && (cpuAddr[23:21]!=3'b111 || selectVRAM)) | !dtack_en)`
  - `dtack_en` always-block, `fc7_berr`, `fc7_iack`, `overlay_trigger`,
    `memoryOverlayOn`.
- `ram_config_phys` wiring; pseudovia address `.addr({cpuAddr[12:1], tg68_a[0]})`
  (the old sim-only A0 fix is now matched).
- `CE_PIXEL = v8_ce_pix` (the old "hardwired 1" pixel-doubling bug is fixed in both).
- `ps2_key` / `ps2_mouse` are wired into `dataController_top` in both → the ADB
  device gets real input on sim **and** FPGA.

## ⚠️ Intentional differences (reduced sim coverage, not bugs)

| Thing | Sim (`sim.v`) | FPGA (`MacLC.sv`) | Consequence |
|---|---|---|---|
| RAM size | `configRAMSize = 8'h24` (2 MB, hardwired) | `status[4] ? 8'hE4 : 8'h24` (2 MB / 10 MB) | **10 MB / SIMM path never exercised in sim** |
| Monitor ID | `v8_monitor_id = 4'h6` (640×480, hardwired) | `status[11:10]`-selected | **Other resolutions are FPGA-only** |
| `clk_sys` | 32 MHz from the testbench | PLL `outclk_1` | same frequency; no functional diff |
| Debug HUD / ports | absent | Row-M overlay, `*_dbg_*`, `selectUnmapped`, `synthesis keep` taps | FPGA-only observability; harmless |
| Framework | bespoke C++ harness (`sim_main.cpp`) | `sys/` (HPS I/O, HDMI/scaler, OSD, audio out) | sim has no HPS/HDMI/scaler |

## 🔴 Inherent gap — keep in mind

- **Memory model:** sim uses `sim_ram` (ideal, zero-latency block RAM); the FPGA
  uses the real `sdram` controller with bus-slot latency. **A design that boots
  in Verilator can still fail on hardware for SDRAM timing/latency reasons.**
  Historically real here (stale-read / DTACK-before-cpu-slot issues). "Boots in
  sim" ≠ "boots on FPGA" for anything timing-sensitive on the memory bus.

## Host-input harness (sim only)

`sim_main.cpp` drives `ps2_key`/`ps2_mouse` from the host (SDL):
- Keyboard: host keys → `ps2_key` (Scan-Code-Set-2; the ADB device translates).
- Mouse: click the VGA image to capture (SDL relative mode; Esc/F1 to release);
  motion/left-click → `ps2_mouse` with X/Y sign bits set. Arrow keys + A/B are a
  fallback when not captured. On FPGA these come from the HPS (USB) instead.

## Maintenance checklist (when editing the core)

1. Touching CPU/bus glue (BERR/VPA/DTACK/overlay/IPL)? Edit **both** `sim.v` and
   `MacLC.sv`, then re-diff the assignments.
2. Adding a top-level config (RAM size, monitor, CPU speed)? Decide the sim's
   fixed value and note it here.
3. Adding a `dataController_top` port? It propagates to both tops automatically —
   only the connections in each top differ.
4. Re-run the audit (compare instantiations + the glue assignments) and update
   the "Last audited" date above. See `docs/mame_compare.md` for ground-truth checks.
