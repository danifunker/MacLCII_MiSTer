# Resume — Phase F: TG68K_Cache_030 (the last core-file divergence)

**Date:** 2026-06-18 · **Branch:** `kernel-sync-030mmu2` (off `030_LCii_rebased`). **Start a fresh session here.**
**Context:** The TG68K core convergence (MacLC ⇄ upstream Minimig `apolkosnik/030_mmu2`) is done except this
file. After Phases A/C/D/E/G: `TG68K_Pack`, `TG68K_ALU`, `TG68K_PMMU_030`, `TG68K.vhd` are **byte-identical**
to upstream; `TG68KdotC_Kernel.vhd` = upstream + a 127-line delta (grace + bsr.w, both in the upstream PR
`tg68k-030mmu2-lcii-fixes`). **`TG68K_Cache_030.vhd` is the only remaining divergent core file** (225-line
delta vs upstream). Full story: `docs/plan_061826.md`, `docs/findings_kernel_merge_030mmu2_2026-06-18.md`,
memory `kernel-sync-030mmu2`.

---

## ⚠️ The critical fact that reframes Phase F (the prior plan got this wrong)

**MacLC runs the CPU UNCACHED on BOTH sim and FPGA.** `TG68K_Cache_030` is compiled (listed in
`rtl/tg68k/TG68K.qip`) but **instantiated by NOTHING in the compiled design**:
- `rtl/tg68k/tg68k.v` (the real Mac wrapper, used for **both** sim and FPGA) explicitly does **not** instantiate
  the cache — see its own comment at `tg68k.v:401-403` ("The on-chip caches (TG68K_Cache_030) are not
  instantiated; the kernel runs uncached").
- The kernel (`TG68KdotC_Kernel.vhd`/`.v`) does **not** instantiate it (0 refs).
- Only the **reference-only** `TG68K.vhd` instantiates it (`TG68K.vhd:724`), and `TG68K.qip:5` says TG68K.vhd
  is compiled by neither sim nor FPGA. On Quartus the cache is an unconnected module → optimized away.

So the earlier "Phase F = adopt logical cache, FPGA-only, needs HW" framing **conflated two separate things**.
Split them:

### F1 — Cache file *convergence* (byte-identity). TRIVIAL, risk-free, no hardware.
Because nothing instantiates the cache, adopting upstream's file has **zero functional effect** on MacLC.
```bash
cp /tmp/minimig_tg68k/TG68K_Cache_030.vhd rtl/tg68k/TG68K_Cache_030.vhd   # (re-extract if /tmp gone, see below)
diff -q rtl/tg68k/TG68K_Cache_030.vhd /tmp/minimig_tg68k/TG68K_Cache_030.vhd   # IDENTICAL
```
Validate (no boot needed — it's dead code):
- ghdl analyze clean (already confirmed standalone): `ghdl -a -fsynopsys -fexplicit --workdir=$(mktemp -d) rtl/tg68k/TG68K_Pack.vhd rtl/tg68k/TG68K_Cache_030.vhd` → exit 0.
- Optional: a Verilator build still succeeds (the cache isn't compiled into the sim anyway).
- **Bonus:** it RESOLVES a latent inconsistency — the already-synced `TG68K.vhd` (byte-identical to upstream)
  instantiates the cache *with* `i_fc`/`d_fc`, but MacLC's current cache lacks those ports. Upstream's cache
  has them → reference + cache become self-consistent.
- Then sync the same file to MacIIvi (`/Users/dani/repos/MacIIvi_MiSTer`, branch `kernel-sync-030mmu2`).
- **Result: 5/5 core files byte-identical to upstream** (modulo the kernel's heading-upstream delta).

**Recommendation:** just do F1 — it completes byte-identity at zero risk. The only reason it's listed as
"deferred" was the (incorrect) assumption that the cache is live on FPGA.

### F2 — Actually *enable* the cache (instantiate it for performance). The real work — HW-gated, risky. OPTIONAL.
MacLC currently runs uncached, which is part of why it's slow (see memory `core-runs-slow-cpu-busslots`).
Enabling the 68030 caches is a genuine **performance feature**, separate from convergence:
- Instantiate `TG68K_Cache_030` in `tg68k.v` (and `sim.v`/the sim wrapper for sim coverage): wire
  `i_addr`/`i_addr_phys`/`i_req`/`i_fc`, `d_addr`/`d_addr_phys`/`d_req`/`d_fc`/`d_we`/`d_wdata`, `cacr_*`,
  cache-inhibit, and the line-fill bus path; route the PMMU **physical** address to `*_addr_phys` for fills.
  Use upstream `cpu_wrapper.v` (`apolkosnik/030_mmu2`) as the integration reference (but it's Amiga-shaped —
  don't import `TG68K_CacheCtrl_030.vhd`/`cpu_wrapper.v`; wire into Mac `tg68k.v` instead).
- **THE RISK LIVES HERE:** upstream's cache is **logically** indexed/tagged with **FC-qualified tags**; MacLC's
  (now-dead) cache was **physically** indexed/tagged. Physical tags sidestep PMMU logical-address aliasing —
  exactly the hazard class just stabilized for the LC II post-MMU boot (`f605e44`, the early-term fix). A
  logical cache can return stale lines across an address-space/translation change if coherency isn't handled.
- **Validation (both needed):**
  1. **Sim** — once the cache is instantiated in the sim wrapper, the existing boot test DOES exercise it:
     `./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom ../releases/boot0-fastmem.rom --screenshot 399
     --stop-at-frame 400` → must still reach the desktop checkerboard. Also diff the framebuffer/PC stream vs
     MAME `maclc2` (`docs/mame_compare.md`, `verilator/mame/run_mame_maclc2.sh`) to catch cache coherency bugs.
  2. **FPGA** — Quartus build → DE10-Nano → LC II boots with caches enabled; check perf (Speedometer / the
     perf notes in `docs/handoff_performance_2026-06-08.md`) and visual correctness vs MAME.
- Keep a clean revert. If logical caching destabilizes the LC II post-MMU on HW, fall back to uncached (today's
  behaviour) or propose MacLC's physical-tag cache upstream as a config option.

---

## Upstream cache design being adopted (what changed, for reference)
One coherent design decision + fallout (~15 blocks, all generic 68030 — no Mac/Amiga gating):
- **physical → logical indexing/tagging**, with **FC bits folded into the tag** (new `i_fc`/`d_fc` ports;
  `I_TAG_BITS=25`, `D_TAG_BITS=27`). Physical address now used only for external fill.
- **write-allocate removed** (write miss → `null`, no line fill) — avoids the fill competing with the
  write-through cycle.
- **cache-inhibit relaxed** — CI blocks new *allocation*, not hits on existing lines (dropped from `i_hit`/
  `d_hit` and the D-cache outer gate).
- **CACR line-invalidate (entry "00") unconditional** — clears the CAAR-indexed slot without a tag compare.

## Re-extract upstream pristine cache if `/tmp` is gone
```bash
M=/Users/dani/repos/Minimig-AGA_MiSTer-danifunker; mkdir -p /tmp/minimig_tg68k
git -C $M show apolkosnik/030_mmu2:rtl/tg68k/TG68K_Cache_030.vhd > /tmp/minimig_tg68k/TG68K_Cache_030.vhd
```

## Build / boot recipes (for F2 only; F1 needs no boot)
```bash
# regen .v after any .vhd edit (only needed if you change the kernel; the cache isn't in the generated .v):
rtl/tg68k/convert_to_verilog.sh
# build (-Os ~8 min; plain make is 15x slow, `make fast` crashes clang):
cd verilator && make obj_dir/Vemu.cpp && (cd obj_dir && rm -f *.o *.gch && make OPT_FAST=-Os OPT_SLOW=-Os -f Vemu.mk)
# boot test (~15-20 min; cap <=400 frames; run ONCE, analyze the log):
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom ../releases/boot0-fastmem.rom \
  --screenshot 399 --stop-at-frame 400 > /tmp/boot.log 2>&1
grep '\[HB\]' /tmp/boot.log | tail   # PASS: PCs climb A45Exx->A07A5A->A3C188->A06F0E; screenshot = desktop checkerboard
```
Note: the sim wrapper `tg68k.v` and FPGA both use `tg68k.v`; any cache instantiation must go there (and the sim
wrapper) — see `docs/verilator_differences.md`. The boot binary at handoff time is stale; rebuild before testing.

## Deliverables for the Phase F session
- [ ] F1: cache byte-identical to upstream + synced to MacIIvi + committed (completes 5/5 byte-identity).
- [ ] F2 (optional): cache instantiated + boot-validated (sim + FPGA) + MAME-oracle-clean, OR documented as
      deferred/declined with the reason (physical-vs-logical PMMU-aliasing risk on HW).
