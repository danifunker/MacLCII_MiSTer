# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Macintosh LC emulation core for the MiSTer FPGA platform. It's based on the MacPlus core by Sorgelig, which originated from the Plus Too project. The core emulates the Motorola 68000 CPU and various Macintosh peripherals.

## Build Commands

### FPGA Build (Quartus)
The project uses Intel Quartus 17.0.2 Lite Edition:
- Open `MacLCii.qpf` in Quartus
- Compile to generate RBF output in `output_files/`
- Deploy RBF to MiSTer SD card root

### Verilator Simulation
```bash
cd verilator
make        # Build simulator
make clean  # Clean build artifacts
./obj_dir/Vemu  # Run interactive simulator (requires SDL2, OpenGL)
```

#### Simulator Command Line Options
```bash
./obj_dir/Vemu --help                    # Show all options
./obj_dir/Vemu --screenshot 360          # Take screenshot at frame 360
./obj_dir/Vemu --stop-at-frame 400       # Exit after frame 400
./obj_dir/Vemu --screenshot 360 --stop-at-frame 361  # screenshot
```

Key options:
- `--screenshot <frames>` - Save PNG screenshots (comma-separated frame list); PNGs land in the CWD
- `--stop-at-frame <frame>` - Exit simulation after reaching frame count
- `--scsi0 <image>` - Mount a SCSI hard-drive image and boot from it. The sim WRITES to the image — always boot a copy, never a master
- `--headless` - No SDL/ImGui window (use for all long runs)
- `--heartbeat` - One `[HB] F<n> pc=... a7=...` line per video frame on stderr (progress/wedge diagnosis on long runs)
- `--no-cpu-trace` - Skip cpu_trace.log entirely (fast scouting runs)
- `--trace-frames A,B` - Only write cpu_trace.log lines for frames A..B (bounded forensic capture)

Note: `--help` is stale — the disk/heartbeat/trace-window flags above exist but are not all listed there.
Note: With no disk, boot reaches the blinking-? desktop in ~360 frames. A full System 7.1 boot from `--scsi0` reaches Finder well past frame 2000; the sim runs ~5.4 s/frame (~90 min per 1000 frames) on an Apple M1.
Note: FST wave tracing is NOT wired up (there is no `--trace` CLI flag; nothing instantiates a tracer). The build deliberately omits Verilator's `--trace-fst`/`--timing` for a ~1.5x sim speedup (see `verilator/Makefile`). Because of this, any internal signal `sim_main.cpp` reads via `rootp->` MUST be listed as `public_flat_rd` in `verilator/tg68k_debug.vlt` or Verilator will optimize it away and the C++ build breaks.

#### CWD requirement / running sims in parallel
`$readmemh` paths in the RTL are CWD-relative (`../rtl/egret/egret_rom.hex`, `../rtl/egret/egret.pram` under `SIMULATION`), and `cpu_trace.log` + screenshots are written to the CWD. Consequences:
- The CWD must be a **direct child of a repo-root-shaped directory** (i.e. `<cwd>/../rtl/egret/` must exist). `verilator/` qualifies; a fresh `<repo>/simfooRun/` directory also works. A missing egret.pram/rom does NOT abort the run — the Egret plays dead and the 68k bus-errors at the reset vector (log shows `[BERRFRAME] ... live_pc=00000004` and no `[HB]` lines ever).
- To run several sims concurrently, give each its own child-dir CWD (separates trace/screenshot outputs) and its own **copy** of the disk image.

#### Boot Verification
```bash
cd verilator
./check_boot.sh              # Analyze existing cpu_trace.log
./check_boot.sh --run        # Run 30 frames + analyze
./check_boot.sh --run 100    # Run N frames + analyze
```
Exit codes: 0=PASS, 1=FAIL, 2=missing log. Suitable for pre-commit hooks.

#### Simulation Logs
- **CPU trace log:** `verilator/cpu_trace.log` - Contains 68K CPU instruction trace
- **Console output (stderr):** Contains HC05 (Egret) traces, VIA/peripheral debug messages
- **Important:** Do NOT re-run the simulator multiple times when diagnosing. Run once, then analyze the log files.

#### Comparing against MAME (ground truth)
When the core misbehaves, diff it against MAME's `maclc` running the same ROM.
Tooling: `verilator/mame/` (`run_mame.sh`, `tap.lua`, `snap.lua`, `trace.dbg`).
Full process + gotchas: **`docs/mame_compare.md`** (memory tap, maincpu trace,
PC-stream divergence diff; macOS has no `timeout`, debugger defaults to the Egret
HC05 not the 68020, MAME PCs are 8-digit `00Axxxxx`, etc.).

## Architecture

### Top-Level Module
- `MacLC.sv` - Main system module (module name: `emu`)
- Entry point for the MiSTer framework via `sys/sys_top.v`

### RTL Structure (`/rtl`)

**CPU Core:**
- `tg68k/` - TG68K CPU core (68000)

**Memory & Storage:**
- `sdram.v` - SDRAM controller
- `scsi.v`, `ncr5380.sv` - SCSI hard drive interface
- `floppy.v`, `floppy_track_encoder.v` - Floppy drive emulation

**I/O Peripherals:**
- `via6522.sv` - Versatile Interface Adapter (parallel I/O, timers)
- `pseudovia.sv` - VIA emulation for LC models
- `iwm.v` - Integrated Woz Machine (floppy controller)
- `scc.v` - Serial Communication Controller
- `adb.sv` - Apple Desktop Bus
- `ps2_kbd.sv`, `ps2_mouse.v` - Keyboard/mouse input
- `rtc.v` - Real-Time Clock
- `uart/` - UART TX/RX modules

**Video Subsystem:**
- `maclc_v8_video.sv` - Mac LC Video Engine (V8)
- `ariel_ramdac.sv` - Video DAC
- `addrController_top.v`, `addrDecoder.v` - Address generation
- `dataController_top.sv` - Data control

### System Framework (`/sys`)
Standard MiSTer framework files (video scaling, HPS I/O, audio output). Generally should not need modification for core-specific work.

## Key Technical Details

- **Target FPGA:** Cyclone V (MiSTer DE10-Nano)
- **System clock:** Generated via `rtl/pll.v`
- **Memory:** 1MB/4MB RAM configurations, DDR3 SDRAM interface
- **Video modes:** 1/2/4/8/16 bpp
- **CPU speeds:** 8 MHz (original) or 16 MHz

## File Locations

- `files.qip` - Lists all RTL source files for Quartus
- `MacLCii.qsf` - Quartus project settings
- `releases/` - Pre-built RBF files and ROM images

## CPU Conversion Notes

When working with CPU cores, see `how-to-convert-cpu.txt` for GHDL-based VHDL to Verilog conversion process using:
```bash
ghdl synth -fsynopsys -fexplicit --latches --out=verilog
```

## Verilator vs Quartus Compatibility

**Critical:** Verilator allows multiple `always` blocks to drive the same `reg`, but Quartus does not (Error 10028: "Can't resolve multiple constant drivers"). When writing or modifying RTL:

- Each `reg` must be driven from exactly **one** `always` block for Quartus synthesis
- If timer logic, PRAM loading, or other hardware needs to write the same register as a CPU write path, **merge them into a single `always` block**
- Use `if/else if` priority within the block to handle the different write sources
- Verilator builds (`make` in `verilator/`) will succeed even with multiple drivers — always verify the design is Quartus-clean before targeting FPGA

**Conditional compilation:** `USE_EGRET_CPU` and `SIMULATION` are defined in `verilator/Makefile` for simulation. For FPGA, `USE_EGRET_CPU` is set in `MacLCii.qsf`. Guard simulation-only code (`$display`, debug counters) with `` `ifdef SIMULATION ``.

**Top-level split:** the Verilator top is `verilator/sim.v` (`module emu`), NOT `MacLC.sv`. It has its **own** CPU instantiation and bus glue (VPA/DTACK/BERR/overlay); peripheral RTL is shared via `dataController_top`. CPU-glue/top-level fixes must go in **both** files or sim and FPGA silently diverge. Tracked differences (and a maintenance checklist) live in **`docs/verilator_differences.md`** — update it when you add a top-level signal or hardwire a sim config.

## VIA Shift Register — Simulation Sensitivity

**Critical:** Changes to the VIA SR logic in `rtl/via6522.sv` can break Egret communication and stall the boot. After any SR change, verify simulation still boots:

```bash
cd verilator && make clean && make
./check_boot.sh --run 30    # PASS + "ADVANCING" required
```

A broken Egret handshake stalls the CPU polling IFR, which check_boot reports
as FAIL or LOOP. **STALE-GATE WARNING (cost a 5-hour false regression hunt on
2026-07-07): the old check here — "screenshot at F350 must show grey/black
alternating lines; uniform grey = broken" — NO LONGER HOLDS.** The ROM
programs the Ariel CLUT all-grey (every entry $7F7F7F) early in boot, so a
no-disk boot renders a UNIFORM GREY screen at least through F360 even on a
known-good build (verified against the HW-validated v9 tree, 2026-07-07).
Real palette content only arrives during System-disk video init — the visual
gate is a `--scsi0` 7.1 boot reaching the desktop (screenshots ~F1400-2000),
not any no-disk frame.

**SR edge-detection patterns (history + FPGA caveat):**
- `cb2_latched` (shift-in: capturing CB2 at the CB1 rising edge) — **removed; do not re-introduce.** Shift-in uses live `cb2_i`. Re-introducing it hung the 4th Egret SR transfer in Verilator (CPU stuck polling IFR bit 2 at `0xA14E5E`).
- `ext_fall_edge_pending` (shift-out: latching CB1 falling edges in external-clock mode) — **currently IN USE in `via6522.sv`.** It was reverted in `a8f9f33`, then deliberately re-added in `e067857` ("switching to fake egret"). It boots in Verilator only because the behavioral Egret drives CB1 slowly, so edges never coalesce. It is the **suspected cause of the FPGA overlay-stuck bug**: the real HC05 toggles CB1 far faster than the VIA's E-rate (only one pending edge is consumed per E-falling phase), so edges coalesce, SR bytes corrupt, the boot ROM's Egret handshake never completes, and the ROM overlay never clears. Do NOT assume it is FPGA-safe — prefer rate-limiting CB1 in `egret_wrapper` over re-touching this SR path.

Re-verify boot (the screenshot check above) after ANY SR change.

## Known Limitations

- Floppy disks are read-only
- SCSI writes work but are experimental
- Floppy won't read at 16 MHz CPU speed
- Bus retry via HALT signal not implemented
