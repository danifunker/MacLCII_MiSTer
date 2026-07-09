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

## SPEEDOMETER RESULT (user-run, evening 2026-07-08) — +25%, not parity yet
Color Benchmarks on the I-cache build (screenshot 20260708_220257):
Mono 43.650s/**0.747** · 2-bit 47.200/**0.825** · 4-bit 51.533/**0.891** ·
8-bit 61.367/**0.922** · **Average 0.846 ×MacII** (was 0.677; slots-only era
0.508). Mono IMPROVED 21% (MacLC's DTACK-join cache regressed mono — ours
does not). Now within 9% of the MacLC 68020 core (0.932) despite the PMMU
tax. User verdict: "much faster but still not at the level I expect" — real
LC II ≈ 1.3–1.4, we're ~62% of real.

## NEXT STEPS (re-ranked after the 0.846 measurement)
1. **Wrapper phi-cadence compression (the big lever, ~+25–35%).** The 5-clk
   bus floor (8 phis/cycle in the tg68k.v s_state walk) vs the real 030's
   3-clock bus. MacLC reached the same conclusion ("next lever is the
   wrapper/kernel phi cadence — NOT DTACK"). RISKS: E-clock (eCntr) + VIA/IWM
   timing ride the same phis; the floppy already can't read at 16 MHz. Mono
   (the worst test, VRAM RMW-bound, cache-immune) is mostly THIS floor.
2. **I-cache 256B→1–2KB** (+8–15%): residual-miss data shows 92%→97-98% hit at
   1KB+. Constants in TG68K_Cache_030.vhd + ghdl re-convert + **BRAM
   restructure** (register arrays won't fit past ~512B at 89% ALM; 27 M10Ks
   free; hit lookup must become sync-read — the phi cadence has slack for a
   1-clk registered lookup, hit decision needed by the NEXT phi1).
3. **Enable the D-side answer path** (+5–15%): un-tie d_req; needs its own
   corruption-watch pass (write-through + snoop already in the module; the OS
   sets CACR.DE ~F148 so it activates immediately).
4. **VRAM-write fast-ack** (+2–5%, contained): BRAM-backed VRAM writes still
   wait for slot-aligned DTACK they don't need (MacLC.sv/sim.v dtack glue).
5. **Disk-integrity session** still owed (benchmarks ran fine; do the
   copy/restart/DFA check per [[maclcii-disk-corruption-from-hard-restarts]]).
6. Housekeeping: `perf_run_*_20260708.log` + `simDiskRun/` are gitignored
   throwaways.

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
