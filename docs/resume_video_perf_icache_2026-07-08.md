# RESUME — video performance: instruction cache is the next lever (2026-07-08)

Read cold to continue. Branch `video-performance`. Two HW-validated wins shipped
this session (black-screen fix + a +33% memory-bandwidth win); the core now boots
7.1 to a stable Finder with true-59.94 Hz VGA and runs Speedometer at **0.677×
Mac II** on the Color Benchmarks. The remaining gap to a real LC II (~1.3–1.4×
Mac II, i.e. we're ~half its video speed) is the **missing 68030 instruction
cache** — that is the next and probably final big lever.

## CURRENT HW-GOOD STATE — do not lose this
- **On the box now:** `_Unstable/MacLCii.rbf` md5 `e6f25bdb` = the 4/4-slot perf
  build (commit `38f8a3d`). Boots 7.1 → Finder, video works (fixed 25.175 MHz
  VGA, 59.94 Hz), Speedometer Color avg **0.677× Mac II**.
- **Committed on `video-performance` (both HW-validated):**
  - `f3f2c2d` — video: fixed-PLL + gate debug probes. Fixed the pixel-clock
    black-screen (root cause was 97% ALM fit density; dropped the pll_video
    reconfig core → plain General altera_pll @ 25.175, and gated the JTAG probe
    deck behind `` `ifdef USE_DEBUG_PROBES `` → 86–87% ALM).
  - `38f8a3d` — perf: reclaim the 4th SDRAM slot for the CPU when idle. +33%.

## THE PERF PICTURE (what's done, what's left)
Grounded in `docs/handoff_performance_2026-06-08.md` (H1–H4) and
`docs/clock_analysis.md`. **It is NOT a clock problem — the clocks are correct**
(CPU 16.25 MHz vs the real 15.67, +3.7%).

| Lever | Status |
|---|---|
| H1 — reclaim video's dead SDRAM slot (video → BRAM) → CPU 3/4 slots | DONE (pre-session, addrController_top.v:119) |
| H1-stretch — lend the idle 4th slot to the CPU → 4/4 slots | **DONE `38f8a3d`, +33% HW** |
| H3 — real pixel clock (38.7 → 59.94 Hz) | DONE `f3f2c2d` (+ Tick fix `9375c9f`) |
| **H2 — instruction cache** | **NEXT — the big remaining lever** |
| H4 — CPU overclock | cheaper alt; overshoots authenticity; timing risk |

**Speedometer 3.23 Color Benchmarks (10MB LC II, ×Mac II = 1.0):**

| Test | 3/4 slots | 4/4 slots (now) |
|---|---|---|
| Monochrome | 70.417 / 0.463 | 52.933 / 0.616 |
| Two Bit | 78.550 / 0.496 | 58.783 / 0.663 |
| Four Bit | 86.183 / 0.533 | 65.017 / 0.706 |
| Eight Bit | 104.633 / 0.541 | 78.067 / 0.725 |
| **Average** | **0.508** | **0.677** |

## THE TASK — add an instruction cache (H2)
**Why:** the sim's PERF counter shows the CPU is **42–58% memory-stalled**
(stderr: `[Fn] PERF: clk=.. as=.. stall=X% of as commits=..`). The real 68030
has a 256-byte I-cache that hides the 16-bit memory bus in tight graphics loops;
the TG68K has **none** (`grep -i cache rtl/tg68k/*` → nothing). More bus slots
raised the ceiling (H1/H1-stretch); the cache *reduces the number of accesses*,
which is what's left.

**Design sketch (validate assumptions before building):**
- Add a small I-cache in front of the CPU instruction-fetch path. Two routes:
  (a) inside the TG68K VHDL fetch path then re-convert via GHDL
  (`how-to-convert-cpu.txt`, `rtl/tg68k/convert_to_verilog.sh`) — deep; or
  (b) a cache module wrapping the fetch bus (intercept code fetches FC=2/6, serve
  hits 0-wait, fill on miss) — cleaner, no CPU-core surgery. Prefer (b) first.
- Size: start 256 B–4 KB, direct-mapped or 2-way. Resources are fine: **~27 free
  M10Ks** (RAM 526/553 = 95%) and 86% ALM.
- **Coherency is the trap.** Code space can be written (relocation, some ROM/OS
  paths) and the 68030 exposes cache control via CACR (enable/flush) + the CINV/
  CPUSH ops. Decide: snoop writes to cached lines and invalidate, and/or honor a
  modeled CACR flush. If the OS toggles CACR and we ignore it, stale-instruction
  bugs will look like random crashes. Check what the 7.1 ROM/OS does with CACR
  early (MAME `maclc2` oracle can help — see `docs/mame_compare.md`).
- Only cache cacheable space (RAM/ROM); never cache I/O ($Fxxxxx), VRAM, or the
  overlay-mirror region.

**Where the code goes:** the fetch path is top-level glue → changes likely land
in **both** `MacLC.sv` and `verilator/sim.v` (they have separate CPU
instantiations — see `docs/verilator_differences.md`), OR in a shared tg68k
wrapper. `addrController_top.v` is shared, so bus-side changes are sim-visible.

## VALIDATION LOOP (perf is sim + Speedometer measurable — no JTAG needed)
1. **Sim (WSL, Verilator 5.020):** `cd verilator && make`, then
   `SDL_VIDEODRIVER=dummy ./obj_dir/Vemu --headless --heartbeat
   --stop-at-frame N`. Watch the **PERF counter** stall% drop and `commits` rise;
   confirm healthy boot (heartbeat PC advances, `a2` RAM-march, no BERR/EXC) and
   `[VIDDBG]` renders (de_px=307200, gray CLUT). Sim is slow (~5–6 s/frame;
   no-disk boot is uniform gray through ~F360 BY DESIGN).
2. **HW build:** `QUARTUS_BIN=/c/intelFPGA_lite/17.0/quartus/bin64 bash
   scripts/build.sh` from **Git Bash** (not wsl.exe bash — CRLF). Clean fit:
   `rm -rf db incremental_db` first. ~20 min. Watch ALM % + timing (keep TNS 0).
3. **Deploy:** claim the lock (below), then `python
   tools/misterdeploy/launch_unstable_core.py --push ./output_files/MacLCii.rbf
   --core MacLCii.rbf --delay 0.12`; confirm `coreRunning='MacLCii'` + the md5.
4. **Measure:** run Speedometer 3.23 Color Benchmarks on the desktop; compare to
   the **0.677 baseline** above. (Screenshot API: POST
   `http://<host>:8182/api/screenshots`, pull newest under
   `/media/fat/screenshots/MacLCii/` — filter by that core dir; the sibling MACLC
   dir has stale images.)

## GOTCHAS
- **Sharing lock:** the MiSTer may be shared. Before any deploy/reboot:
  check/claim `/tmp/claude_mister.lock` (`docs`/memory `mister-sharing-lock`).
  It's WIPED by the launcher's reboot — re-claim after. I released it at the end
  of this session.
- **JTAG probes are gated off** (`USE_DEBUG_PROBES`, default undefined). Release
  builds have no `read_probes.sh` deck. Perf work doesn't need JTAG — use the sim
  PERF counter + Speedometer. If you truly need probes, rebuild with the macro,
  but that re-inflates ALM density (it was the black-screen root cause).
- `check_boot.sh` has CRLF and won't exec under WSL bash directly; use the Vemu
  heartbeat/VIDDBG output instead, or `dos2unix` it.
- Fixed altera_pll must use `pll_type("General")` not `("Cyclone V")` — already
  done in `rtl/pll_video.v`; mirror `rtl/pll/pll_0002.v` if you touch it.
- **OPEN (minor):** HTTP-API screenshots of *early* no-disk frames render magenta
  vs the expected gray. On the live monitor it looked correct + boots fine, so
  likely a screenshot-path quirk, not a real palette bug. Verify if it recurs.

## RELEVANT FILES / MEMORY
- `docs/handoff_performance_2026-06-08.md` (H1–H4 analysis), `docs/clock_analysis.md`
  (clocks correct), `docs/mame_compare.md` (68030 oracle for CACR behavior).
- `rtl/addrController_top.v` (bus slots + `extra_busy` gate), `MacLC.sv` +
  `verilator/sim.v` (CPU glue, DTACK), `rtl/tg68k/` (CPU core, no cache).
- Memory: `maclcii-video-performance-roadmap`, `maclcii-video-pixelclock-hw-blackscreen`,
  `maclcii-mister-hardware-access`, `mister-sharing-lock-protocol`.
