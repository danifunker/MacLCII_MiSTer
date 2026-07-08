# RESUME — 68030 I-cache ENABLED, HW boots 7.1 to Finder (2026-07-08)

Read cold to continue. Branch `video-performance`. The H2 instruction-cache
lever from the 07-08 morning resume is DONE through HW boot validation: the
parked-since-June TG68K cache subsystem is enabled (I-side), four wrapper bugs
that made cache-ON corrupt the boot are fixed, sim boots 22% faster, and the
build is ON THE BOX booting System 7.1 to a stable Finder. **Speedometer + a
disk-integrity session are the remaining validation** (user-run or next
session); the sim 7.1 disk-boot gate may still be running (see below).

## CURRENT HW STATE
- **On the box now:** `_Unstable/MacLCii.rbf` md5 `2e3552a9ada3057227df75febad3a59f`
  = the I-cache build (commit `f9d4994` tree). Deployed 17:31, boots 7.1 →
  clean Finder (screenshots 17:34 + stability recheck), lock RELEASED.
- **Fallbacks:** the 4/4-slot build (38f8a3d, md5 e6f25bdb) can be rebuilt from
  git; `releases/MacLCii_flineFix_v9_20260703.rbf` (143d902b) is the deep
  fallback. If the cache build misbehaves: redeploy either, and/or set
  `USE_68030_CACHE = 1'b0` (tg68k.v:~99) and rebuild — the flag-off design is
  provably identical to the uncached core.
- Fit: **89% ALM** (was 86), TNS 0.000 on all core clocks (one −0.008 ns on the
  framework HDMI scaler PLL — 8 ps, accepted; revisit only if HDMI artifacts).

## WHAT SHIPPED (commits)
- `b1fb014` tg68k: enable the 68030 I-cache — fix the four cache-ON corruption
  mechanisms (FC=5 override during fills; same-edge fill launch
  `fill_launch_now`; borrowed-cycle berr isolation `berr_kernel_cycle`; fill
  abort-on-berr). D-side answer path stays tied off (`d_req=0` — the ROM sets
  CACR.DE late; write-through keeps an inert D-cache correctness-neutral).
- `f9d4994` sim: PERF2/PERF3 counters (access mix, walk tax, shadow I-cache hit
  rates) + `[BERRFRAME] EDGE` per-dispatch prints + verilator-public `cpuFC`.

## SIM VALIDATION LEDGER (all PASS, no-disk boot, F451 runs)
| Gate | uncached baseline | I-cache build |
|---|---|---|
| Idle loop (blinking-?) | F396–410 | **F310 (−22%)** |
| March milestones | F90 / F327 | F76 / F233 (fetch-free: 2 bus fetches per 60-frame window) |
| Extra berr dispatches | 14 | **14 — identical** (ROM device probes, see gotcha) |
| VIDDBG | healthy | healthy; b/w CLUT rendering by F449 |

**In-flight gate:** a 7.1 **disk-boot sim** (cache-ON, `simDiskRun/`,
`--scsi0 boot_copy.vhd` = a COPY of HD20SC-With-Benchmarking, screenshots at
F1400/2000/2400, stop F2500, ~3.5–4 h) was launched ~17:15 to exercise PMMU
page tables + the SCSI driver cache-ON. Check `simDiskRun/diskboot.log`
([HB] advancing, `EDGE berr` count, screenshots = desktop). If it derailed,
that's the repro to debug IN SIM before further HW reliance.

## NEXT STEPS (in order)
1. **Speedometer 3.23 Color Benchmarks** on the box (user-run; input injection
   into the Mac is not established). Baseline to beat: **0.677 ×MacII avg**
   (38f8a3d). Real LC II ≈ 1.3–1.4. Expect a large jump in all four tests;
   mono is the one MacLC's (different, DTACK-join) cache regressed — watch it.
2. **Disk-integrity session** (the MacLC fetch-cache corrupted its Speedometer
   app): run benchmarks, copy some files, restart via OSD (warm — NEVER hard
   power off mid-write, see [[maclcii-disk-corruption-from-hard-restarts]]),
   verify apps still launch + Disk First Aid clean. Backups exist per memory.
3. Check the sim disk-boot gate result (above).
4. If Speedometer still lags parity: next levers = grow I-cache 256B→1–2KB
   (constants in TG68K_Cache_030.vhd + ghdl re-convert + BRAM restructure for
   fit — 27 free M10Ks; register-array style won't fit past ~512B at 89% ALM)
   and/or enable the D-side answer path after its own validation pass.
5. Housekeeping: `perf_run_*_20260708.log` files in `verilator/` are throwaway
   (gitignored); `simDiskRun/` likewise.

## HARD-WON GOTCHAS THIS SESSION (also in memory `maclcii-cache-fill-fc7-berr-race`)
- **The ROM bus-errors ~14×/boot BY DESIGN** — the device-table walk re-invokes
  the FC=7 `moves.w $22000` probe (code A03A82–A03A94, scanner A02F18) once per
  entry; the ROM's berr handler absorbs them (A5/A6 unwind). The
  `[BERRFRAME] DISP` frame_pc dedupe HID these in every historical run — the
  old "3 berrs = healthy" mental baseline was an artifact. Compare EDGE counts,
  measured ON and OFF with the same instrumentation.
- **`live_pc`/`frame_pc` debug taps lag one fault behind**; the cpu_trace `@`
  column is the DATA address, not a PC. `[BERRIN]` (tg68k.v, SIMULATION) prints
  the true pin-level context (addr/fc/busstate/walk/fill) at each berr edge.
- **`make 2>&1 | tail` masks build failures** (pipe status = tail's): one
  "baseline" run silently reused the stale cache-ON binary. `set -o pipefail`.
- `cpuFC` in sim.v needs `/* verilator public_flat_rd */` — with the cache
  generate-arm off it optimizes into an alias and sim_main.cpp breaks.
- v1's FILL_ARM double-sample launch was SAFE but STARVED fills (1-phi idle
  windows in hot loops → cache inert, march at uncached pace). The same-edge
  `fill_launch_now` clkena suppression is the correct shape. Don't reintroduce.
- launch_unstable_core.py needs `--host 192.168.99.143 --ssh-key ~/.ssh/mister_only`
  when scripts/local.env isn't sourced (defaults to MiSTer.local + default keys,
  fails with getaddrinfo/lost-connection).

## CONTEXT: why the cache (and not "missing MacLC ports")
The user suspected un-ported MacLC fixes. Audited file-by-file: video RTL
byte-identical (maclc_v8_video/ariel_ramdac/v8_clocks/vram_bram/pll.v); LCII
AHEAD on addrController (4/4 slots vs 3/4) + sdram.v (walk-read fixes); tick
fix/VPA read/pixel clock all ported. MacLC-only leftovers: floppy work,
BlueSCSI Toolbox, JTAG meters — nothing video/perf. The 0.677-vs-0.932 ×MacII
gap vs MacLC is 030-side; sim measured fetches = 65–86% of bus accesses at the
5-clk floor with 92%/97% shadow-cacheability @256B/1K → the I-cache was the
lever. MacLC's own fetch-cache disk corruption (their i-cache branch, comb-
DTACK join suspect) is a DIFFERENT design — ours never touches DTACK.

## RELEVANT MEMORY
[[maclcii-cache-fill-fc7-berr-race]] (the four fixes + gotchas) ·
[[maclcii-video-performance-roadmap]] (perf ladder, updated) ·
[[maclcii-mister-hardware-access]] · [[mister-sharing-lock-protocol]] ·
[[maclcii-disk-corruption-from-hard-restarts]]
