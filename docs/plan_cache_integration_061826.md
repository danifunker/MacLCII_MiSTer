# Plan — Enable the 68030 on-chip I-cache + D-cache (MacLC, the 030_mmu2 design)

**Date:** 2026-06-18 · **Branch:** `kernel-sync-030mmu2` · Supersedes Phase F2 of
`docs/handoff_phaseF_cache_2026-06-18.md`. Goal: bring up the real 68030 instruction +
data caches (`TG68K_Cache_030`) the same way Minimig `apolkosnik/030_mmu2` does, wired into
the Mac `tg68k.v` bus — **except** the non-architectural board-level SDRAM cache
(`cpu_cache_new.v`), which we are deliberately NOT porting.

---

## Answers to the three framing questions (these shape the whole plan)

### Q1 — Instantiate in Verilator via `.v` (ghdl). YES, and the pattern already exists.
The CPU core already follows "VHDL is source-of-truth, ghdl emits `.v` for Verilator, Quartus
compiles the VHDL" (`convert_to_verilog.sh`, `TG68K.qip`). We extend it to the cache:
- Add one line to `rtl/tg68k/convert_to_verilog.sh`:
  `ghdl synth $GHDL_FLAGS --latches --out=verilog TG68K_Cache_030 > TG68K_Cache_030.v`
  (the cache analyzes clean standalone with `TG68K_Pack.vhd` — confirmed in the handoff).
- Verilator compiles the generated `TG68K_Cache_030.v`; Quartus keeps compiling
  `TG68K_Cache_030.vhd` (already in `TG68K.qip:13`). A Verilog wrapper instantiating a VHDL
  entity is fine for Quartus (mixed-language) and for Verilator it resolves to the generated
  `.v` — identical handling to the kernel today.
- **Risk to verify early:** ghdl-synth of the cache's `16 × 128-bit` arrays (×2) must emit
  Verilog that Verilator accepts. This is the first checkpoint (Phase 1), before any wiring.

### Q2 — Is the cache already wired into the CPU core? NO — but the kernel side is fully ready.
The **kernel already produces every signal the cache needs**, all currently left unconnected
in `tg68k.v:400-403`:
- `busstate` (00=ifetch, 10=dread, 11=dwrite, 01=idle) — demuxes I vs D access
- `pmmu_addr_log` (logical → cache index/tag) and `pmmu_addr_phys` (physical → line fill) —
  `TG68KdotC_Kernel.vhd:950-951`
- `pmmu_cache_inhibit`, `pmmu_busy`, `pmmu_fault` — fill/lookup gating
- `fc`, `data_write`, `nUDS`/`nLDS` — FC tag, write-through data, byte enables
- `cacr_ie/de/ifreeze/dfreeze/wa`, `cache_inv_req`, `cache_op_scope/cache/addr` — full CACR/CAAR
  decode is **already done in the kernel** (`TG68KdotC_Kernel.vhd:1058-1091`)

What is **missing** = the consumer side, all in the Verilog wrapper:
1. the cache module instantiation + a Mac cache **controller** (req derivation, addr/data
   demux to the 16-bit bus, byte enables, fill accumulator),
2. a **line-fill engine** on the Mac 68K bus (8 word reads/line), and
3. the **read-hit bypass** + **write-through** hooks into the `s_state`/`clkena` FSM.

Confirmed enabler: `addr_out = pmmu_addr_phys` when the MMU is on (`TG68KdotC_Kernel.vhd:9162`),
so the Mac bus already runs physical addresses — the fill engine drives `pmmu_addr_phys`
line-aligned, same address space the walker already uses successfully.

### Q3 — Wire up CACR/CAAR. Mostly "connect", not "implement".
The kernel already decodes CACR (enable/freeze/WA bits) and CACR-self-clearing /
CAAR-line-invalidate into `cacr_*` + `cache_inv_req` + `cache_op_{scope,cache,addr}`
(`TG68KdotC_Kernel.vhd:1058-1091`). The work is to route those existing outputs into the
cache's `cacr_*` / `inv_req` / `cache_op_*` ports (the cache module already implements the
invalidate/clear semantics internally). No new register logic.

---

## Reference design (what we're cloning, minus the Amiga parts)
Minimig live path: `cpu_wrapper.v → TG68K_CacheCtrl_030 → TG68K_Cache_030`, gated by
`USE_68030_CACHE=1` (`Minimig.sv:579`). The cache hit feeds `cpu_din`
(`cpu_wrapper.v:249`) and releases the CPU wait-state (`cpu_wrapper.v:2004`).

`TG68K_CacheCtrl_030.vhd` is ~90% Mac-reusable. **Reusable verbatim (logic, re-expressed in
Verilog):** req derivation from busstate, `i_addr/d_addr ← pmmu_addr_log`,
`*_addr_phys ← pmmu_addr_phys`, the 16-bit `cache_data_out_16` demux on `addr[1:0]`+busstate,
`d_be`/`d_data_in` byte-lane build from uds/lds, and the 8-beat line-fill accumulator.
**Amiga-specific, REPLACE:** `phys_z3ram*/phys_z2ram/phys_fast_cacheable/fill_zram` cacheable
decode and the `cache_req/cache_ramaddr/cache_ack` external-fill bus (that's the
`cpu_cache_new.v` SDRAM-cache bus we are NOT porting). For the Mac these become: a RAM/ROM
cacheable-range check + the existing `s_state` Mac-bus fill engine.

**Cacheable rule (Mac):** `cacheable = ~pmmu_cache_inhibit AND (phys ∈ RAM or ROM)`. Must
**never** cache I/O / VRAM / frame buffer. Honor `pmmu_cache_inhibit` (OS marks I/O CI via
TTR/descriptors) AND hard-gate to known RAM/ROM physical ranges (belt-and-suspenders, exactly
as Minimig restricts caching to z2/z3 RAM). Confirm the exact ROM/RAM physical bases against
the V8 map before enabling.

---

## Phased implementation (each phase independently testable; cache stays OFF until Phase 5)

### Phase 0 — Adopt the upstream cache file (the handoff's F1). Prereq, zero functional effect.
- `cp /tmp/minimig_tg68k/TG68K_Cache_030.vhd rtl/tg68k/TG68K_Cache_030.vhd` (re-extract per
  handoff if `/tmp` gone). This is the **logical+FC-tagged** version (`i_fc`/`d_fc`,
  `I_TAG_BITS=25`, `D_TAG_BITS=27`) the controller wires — our current file is physical-tagged
  with no fc ports and won't match.
- ghdl-analyze clean; sync the same file to MacIIvi. Still uninstantiated → boot unchanged.

### Phase 1 — Generate `TG68K_Cache_030.v`; prove it compiles in Verilator. Still uninstantiated.
- Extend `convert_to_verilog.sh` (the `ghdl synth … TG68K_Cache_030` line above).
- Add `TG68K_Cache_030.v` to the Verilator file list; add a `VERILOG_FILE` entry (sim) while
  Quartus keeps the `.vhd`.
- **Checkpoint:** `make clean && make` in `verilator/` succeeds; boot screenshot frame 350
  identical to today (nothing instantiates it yet).

### Phase 2 — Cache controller + READ-HIT bypass (the heart). Behind `USE_68030_CACHE` (default 0).
- New Verilog (a `tg68k_cache.v` controller, or a block in `tg68k.v`): instantiate
  `TG68K_Cache_030`; derive `i_req`(busstate==00 ∧ cacr_ie ∧ xlate_ready),
  `d_req`(busstate∈{10,11} ∧ cacr_de ∧ xlate_ready), `d_we`(busstate==11);
  `xlate_ready = ~pmmu_busy ∧ ~pmmu_fault`. Wire `i_addr/d_addr←pmmu_addr_log`,
  `*_addr_phys←pmmu_addr_phys`, `fc`, byte enables, `cacr_*`. Port the 16-bit data demux.
- **Read-hit bypass:** on a cacheable read with `cache_hit`, latch `cache_data_out_16` into
  `tg68_din_r` and pulse `tg68_clkena` on the next phi1 **without** running the `s_state`
  AS/DS cycle (keep `s_state==0`) — this is the perf win (skips the SDRAM round-trip). Model
  it as a `cache_hit_cycle` flag analogous to `walk_cycle` (`tg68k.v:45`,113).
- Implement the Mac cacheable decode (replaces `phys_fast_cacheable`).
- **Checkpoint:** with `USE_68030_CACHE=0`, bit-identical boot (proves zero regression when off).

### Phase 3 — Line-fill engine on the Mac bus.
- Add a fill FSM modeled on the walker FSM (`tg68k.v:413-454`): on a cacheable read **miss**,
  borrow the bus for **8 line-aligned 16-bit reads** at `pmmu_addr_phys & ~15` (+offset),
  accumulate the 128-bit line, pulse `i_fill_valid`/`d_fill_valid` with `*_fill_data`, then
  deliver the requested word + `clkena`. Reuse the `eff_addr`/`s_state` overrides the walker
  uses. Non-cacheable / inhibited reads fall through to today's single-word `s_state` cycle.
- Watch the `s_state` phi1/phi2 parity invariant (`tg68k.v:159-173`) — the same deadlock class
  the walker hit (`docs/findings_pmmu_walk_stall_2026-06-15.md`); fills must start on phi1.
- **Checkpoint:** sim boot to desktop checkerboard frame 350/400 with cache ON.

### Phase 4 — Write-through + CACR/CAAR cache ops.
- On `busstate==11`: run the normal bus write (write-through) AND present `d_we`/`d_be`/
  `d_data_in` to the cache so a present line updates (no write-allocate — upstream removed it).
- Route `cache_inv_req`/`cache_op_scope`/`cache_op_cache`/`cache_op_addr` (existing kernel
  outputs) to the cache for CACR clear + CAAR line-invalidate.
- **Checkpoint:** OS depth/PRAM writes + Restart still behave; no stale-data corruption in sim.

### Phase 5 — Enable + validate (sim, then FPGA).
- Flip `USE_68030_CACHE=1`.
- **Sim correctness:** boot screenshot frame 350/400 = desktop checkerboard; then diff the
  PC-stream + framebuffer vs MAME `maclc2` (`docs/mame_compare.md`,
  `verilator/mame/run_mame_maclc2.sh`) to catch **logical-cache coherency** bugs (stale lines
  across translation/context changes — the hazard class stabilized by `f605e44`).
- **FPGA:** Quartus build → DE10-Nano → LC II boots; check perf
  (`docs/handoff_performance_2026-06-08.md` / Speedometer) and visual correctness vs MAME.

### Phase 6 — Land.
- Sync MacIIvi; commit; note in the kernel-sync upstream thread. Keep `USE_68030_CACHE` as a
  one-flag revert to today's uncached behavior.

---

## Risks & mitigations
- **Logical-cache coherency** (the real risk): upstream caches are logical+FC-tagged; stale
  lines can survive a translation/address-space change unless flushes/inhibit are honored.
  Mitigate: hard cacheable-range gate (no I/O/VRAM), honor `pmmu_cache_inhibit`, wire the CACR
  clear/CAAR invalidate path (Phase 4), and MAME PC-stream diff in Phase 5. Clean revert flag.
- **`s_state` parity / fill timing** — fills must respect the phi1-start invariant (Phase 3).
- **VIA-SR-style boot fragility** — re-verify the frame-350 screenshot after each phase, per
  CLAUDE.md.
- **ghdl-synth of the cache arrays** — verify Verilog output compiles (Phase 1) before wiring.

## Out of scope (explicit)
- `cpu_cache_new.v` (board-level SDRAM cache) — not an architectural 68030 structure; skipped.
- `TG68K_CacheCtrl_030.vhd` / `cpu_wrapper.v` imported verbatim — Amiga-shaped; we port the
  reusable logic into Mac Verilog instead.
