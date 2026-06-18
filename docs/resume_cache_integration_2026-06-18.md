# Resume — Enable the 68030 I/D cache (Phase 5 only; Phases 0–4 landed)

**Date parked:** 2026-06-18 · **Branch:** `kernel-sync-030mmu2` · **HEAD:** `5426733`
("tg68k: add 68030 I/D cache subsystem (disabled by default)")

The 68030 on-chip Instruction + Data cache (`TG68K_Cache_030`) is **implemented, wired, and
committed — but DISABLED** (`localparam USE_68030_CACHE = 1'b0` at `rtl/tg68k/tg68k.v:52`).
With the flag off the design is **bit-identical** to the uncached core (validated). All that
remains is to flip it on and validate. Full design rationale: `docs/plan_cache_integration_061826.md`.

---

## ⚠️ Validation gotchas discovered the hard way (read before testing!)
These cost a lot of confusion this session — don't repeat them:
1. **Screenshot at frame ~450+, NOT 350.** Video does **not** turn on until ~frame 426–450
   with the default ROM. Every frame before that is a uniform `0xAA` grey blank
   (`md5 b1cfa61ff9c873f35b636cfde286aa91`) — that is the **uninitialized framebuffer**
   (`output_ptr` memset, `sim/sim_video.cpp:272`), **not** a healthy "memory-test pattern".
   The healthy desktop checkerboard appears at **frame 450**, PC at **`A07A5A`** (the idle
   loop — the documented PASS state).
2. **`check_boot.sh` is CPU-only.** It checks PC milestones (ROM init → RAM test → memory
   clear) and says **nothing** about video/desktop/mouse. A `check_boot` PASS + a grey
   screenshot is NOT a validated boot. Always also eyeball a frame-450 screenshot.
3. **ROM choice dominates boot time.** Default `releases/boot0.rom` runs the full destructive
   RAM march → video on ~frame 450. `releases/boot0-fastmem.rom` skips it → **video content by
   frame 300** (measured this session: fastmem has content at 300/340/380, PC `A06F08`).
   "Video is slow to appear" was purely the default ROM, **not a regression.**
4. **Headless is fine** for screenshots — `video.Clock()` (`sim_main.cpp:919`) fills
   `output_ptr` regardless of `--headless`; the grey was the early-frame issue above, not headless.

Baseline (cache OFF) healthy reference saved to `/tmp/baseline_cacheoff_frame0450.png`
(`md5 81ab40cf`); `/tmp` may be wiped — regenerate with the baseline run below.

---

## What's done (committed in `5426733`)
- **Phase 0** — `rtl/tg68k/TG68K_Cache_030.vhd` replaced with upstream Minimig `030_mmu2`
  version (logical+FC tags, `i_fc`/`d_fc`, byte-identical). Also synced to MacIIvi
  (`/Users/dani/repos/MacIIvi_MiSTer`, **uncommitted there** — only the `.vhd`).
- **Phase 1** — `convert_to_verilog.sh` now also emits `TG68K_Cache_030.v` via `ghdl synth`;
  added to `verilator/Makefile` `V_SRC`. (`.vhd`→Quartus via `TG68K.qip:13`, `.v`→Verilator.)
- **Phase 2** — cache controller + **read-hit bypass** in `tg68k.v` (`generate if
  (USE_68030_CACHE)` at `:482`). Kernel taps wired (`pmmu_addr_log/phys`, `pmmu_cache_inhibit`,
  `cacr_ie/de/ifreeze/dfreeze/wa`, `cache_inv_req`, `cache_op_*`). On a cacheable read-hit,
  `cache_read_hit` holds `s_state` at 0 and pulses `clkena` → data from cache, no bus cycle.
- **Phase 3** — **line-fill engine** (`fill_st` FSM `FILL_IDLE/READ/DONE` at `:507+`): on a
  cacheable read miss the CPU stalls and the engine borrows the bus (like the PMMU walker) for
  8×16-bit reads at the line-aligned physical addr, accumulates `fill_buf`, pulses
  `i/d_fill_valid`; the resulting hit then delivers. `eff_*`/`clkena`/`s_state` gated by
  `fill_active`/`fill_hold` (tied 0 in the `no_cache` arm).
- **Phase 4** — write-through + CACR/CAAR invalidate need **no extra RTL**: the cache module
  updates lines on `d_we` write-hits and self-invalidates aliases; Phase 2 already drives
  `d_req`/`d_we`/`d_data_in`/`d_be` + `cache_inv_req`/`cache_op_*`. Memory writes go through
  the normal bus cycle (writes never bypass).

Cacheable region decode: `pmmu_addr_phys[23:20] <= 4'hA` (RAM `$0–$9` + ROM `$A`), excludes
unmapped `$B–$E` and I/O+VRAM `$F`; plus `~pmmu_cache_inhibit`.

## What remains — Phase 5 (enable + validate)
1. **Enable:** set `localparam USE_68030_CACHE = 1'b1;` (`rtl/tg68k/tg68k.v:52`).
2. **Rebuild** (~8 min; codegen first as a fast sanity check):
   ```
   make -C verilator obj_dir/Vemu.cpp
   cd verilator && rm -f obj_dir/*.o obj_dir/*.gch && make -C obj_dir OPT_FAST=-Os OPT_SLOW=-Os -f Vemu.mk
   ```
   (The cache-ON codegen already passed this session; only the compile was interrupted.)
3. **Sim validate at the RIGHT frame** (note frame 450, fastmem ROM for speed):
   ```
   cd verilator
   ./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom ../releases/boot0-fastmem.rom \
     --screenshot 450 --stop-at-frame 451 > /tmp/cacheon.log 2>&1
   ```
   PASS = desktop checkerboard at frame 450 (compare to the cache-OFF baseline) **and** the
   heartbeat PC reaches `A07A5A`. Also re-run `./check_boot.sh` (needs a traced run).
4. **MAME coherency compare** — diff PC-stream/framebuffer vs MAME `maclc2`
   (`docs/mame_compare.md`, `verilator/mame/run_mame_maclc2.sh`). This is the real test for the
   **logical-cache aliasing risk** (the `f605e44` hazard class) — a logical cache can return
   stale lines across a translation/context change.
5. **FPGA** — Quartus build → DE10-Nano → LC II boots with caches; perf via Speedometer
   (`docs/handoff_performance_2026-06-08.md`). Keep the flag as a one-line revert.

## Baseline reproduction (cache OFF, for A/B compare)
```
cd verilator
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --screenshot 450 --stop-at-frame 451   # default ROM, desktop @450
```

## Risks / notes
- Logical+FC cache → software-managed coherency (CACR flushes). The MAME compare in step 4 is
  the gate for stale-line bugs; keep the revert clean.
- Miss penalty ≈ 8 line reads (CPU stalled) vs a ~6-cycle hit saving — net win needs decent
  hit rate (good for hot code/loops; the whole point given `core-runs-slow-cpu-busslots`).
- The cache is a leaf VHDL module ghdl-synthed to `.v`; if you edit the `.vhd`, re-run
  `rtl/tg68k/convert_to_verilog.sh` before rebuilding Verilator.
