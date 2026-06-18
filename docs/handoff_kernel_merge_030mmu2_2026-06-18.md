# Handoff — converge the TG68K kernel/CPU: MacLC LC II ⇄ upstream Minimig `030_mmu2`

**Date:** 2026-06-18  **Start a fresh session with this doc.**
**Goal:** make MacLC gain the upstream Minimig-AGA `030_mmu2` CPU advances **without regressing the
LC II boot** (which currently reaches the desktop). Then optionally upstream MacLC's generic fixes.
The user's preferred approach: **"pull in Minimig's entire kernel and add back what MacLC is missing,"**
but also evaluate "keep MacLC's kernel, port only Minimig's generic improvements on top."

---

## 1. Repos (absolute paths — they are sibling dirs)
- **MacLC** (this repo): `/Users/dani/repos/MacLC_MiSTer`, branch `030_LCii_rebased`, HEAD **`3194397`**
  = the WORKING baseline (boots LC II to the desktop checkerboard). Do NOT regress below it.
  Shared CPU core: `rtl/tg68k/{TG68K_Pack.vhd, TG68K_ALU.vhd, TG68K_Cache_030.vhd,
  TG68K_PMMU_030.vhd, TG68KdotC_Kernel.vhd}` + generated `TG68KdotC_Kernel.v` + sim wrapper `tg68k.v`.
- **Minimig** (upstream `030_mmu2` line, danifunker's fork): `/Users/dani/repos/Minimig-AGA_MiSTer-danifunker`,
  branch `030_mmu2_fixes`. Pristine upstream kernel: `git -C /Users/dani/repos/Minimig-AGA_MiSTer-danifunker
  show apolkosnik/030_mmu2:rtl/tg68k/<file>` (the `apolkosnik` remote is added + fetched). Extra files we
  lack: `TG68K_CacheCtrl_030.vhd` (logical-tag cache controller, wired in its `rtl/cpu_wrapper.v`, NOT in the
  shared core) and `cpu_wrapper.v` (its Amiga integration layer; we use `tg68k.v` for sim).
- **MacIIvi** (sibling Mac core): `/Users/dani/repos/MacIIvi_MiSTer`. Currently byte-identical to MacLC for all
  8 tg68k files. Keep them in sync at the end (copy + commit), but do the work in MacLC first.

## 2. What is ALREADY done (do not redo)
- **PMMU `TG68K_PMMU_030.vhd` is byte-identical across MacLC / MacIIvi / Minimig** — fully shared, leave it.
  (The LC II "early-termination validity" fix lives here and is in all three.)
- The **bsr.w/bsr.l PMMU-stall fix** is in ALL kernels (MacLC `c8895d8`; Minimig `d21cd6c`; PR
  **apolkosnik/Minimig-AGA_MiSTer#3** open, `danifunker:030_mmu2_fixes → apolkosnik:030_mmu2`).
- So the remaining divergence is the kernel + ALU + Cache + Pack + TG68K.vhd (NOT the PMMU, NOT bsr.w).

## 3. The divergence (real-logic lines, excluding comments/blanks/`debug_`/`report`)
| File | MacLC-only logic | Minimig-only logic |
|---|---|---|
| TG68K_PMMU_030.vhd | 0 | 0  ✅ shared |
| TG68K_Pack.vhd | 1 | 1 |
| TG68K_ALU.vhd | 6 | 5 |
| TG68K_Cache_030.vhd | 80 | 71 |
| TG68K.vhd (FPGA wrapper; NOT compiled by the sim) | 21 | 27 |
| **TG68KdotC_Kernel.vhd** | **~290** | **~576** |

Kernel **entity** interfaces differ ONLY in `debug_*` ports: MacLC has `debug_OP1out`/`debug_OP2out`;
Minimig has ~17 (`debug_rte_mmu_fix_*`, `debug_pmmu_fault_dispatched`/`_was_cleared`, `debug_USP/ISP/MSP`,
`debug_pmmu_pending_flags`, …). All NON-debug CPU ports are the same.

Known **MacLC-only** kernel logic (candidates that may be load-bearing for the Mac):
`mmu_fetch_grace`/`mmu_grace_page`/`mmu_grace_suppress` (MMU-enable transition handling — possibly an
obsolete workaround now that the PMMU early-term bug is fixed; verify!), `pmove_dn_data`/`pmove_dn_regnum`/
`pmove_dn_mode` (PMOVE with a Dn register operand), `pmmu_ptest_a` (PTEST/PLOAD A-bit writeback), plus the
sim debug ports `tg68k.v`'s PMMU_TRACE/A30_TRACE probes connect.

Known **Minimig-only** kernel logic worth pulling: RTE format-$B MMU-frame fixup (the `debug_rte_mmu_fix_*`
family), `pmmu_fault_dispatched`/`pmmu_fault_was_cleared` (double-bus-fault detection), and ~576 lines total.

## 4. CRITICAL prior finding — do NOT just overwrite
A **wholesale swap** of Minimig's kernel+ALU+Cache+Pack into MacLC **regressed the boot**: it hung in the
**pre-MMU power-on self-test at PC `$A45Exx`** (heartbeat looping there F157→F400, **flat-grey screenshot**,
never reached MMU-enable). So MacLC's ~290 kernel-only lines are (at least partly) Mac-essential. The
"adopt their kernel" path MUST re-add MacLC's essential logic and re-validate the boot.

## 5. Recommended plan
**Phase 1 — classify (no builds).** Diff each shared file MacLC vs Minimig. Tag every block:
(G) generic 68030 correctness, (M) Mac/LC-II-specific, (S) sim-only/debug, (A) Amiga-specific; note which
side has it. Decide if `mmu_fetch_grace` is still needed (try the boot without it once the PMMU fix is in).

**Phase 2 — merge + validate.** Attempt the user's approach: start from Minimig's kernel, re-add MacLC's
Mac-essential blocks (mmu_fetch_grace if needed, pmove_dn, pmmu_ptest_a) + the debug ports `tg68k.v` needs;
bring ALU/Cache/Pack as required. Regenerate the `.v`, build (traces OFF), boot-test to F400. Bound to ~3
iterations; if it won't reach the desktop, document exactly what's missing and keep the baseline.
Also weigh the alternative (keep MacLC's kernel, port only Minimig's generic fixes). Pick the one that boots
with the most upstream parity.

## 6. Build / regen / boot-test recipes
```bash
# After ANY .vhd edit — regenerate the Verilog (ghdl 6.0.0; ~30s; runs ghdl -a + --synth):
rtl/tg68k/convert_to_verilog.sh
# Manual syntax/elaboration gate (note: --latches is REQUIRED; the design infers latches intentionally):
W=$(mktemp -d); for f in TG68K_Pack TG68K_ALU TG68K_PMMU_030 TG68K_Cache_030 TG68KdotC_Kernel; do \
  ghdl -a -fsynopsys -fexplicit --workdir=$W rtl/tg68k/$f.vhd; done
ghdl --synth -fsynopsys -fexplicit --latches --workdir=$W TG68KdotC_Kernel   # exit 0 = clean

# Build (plain `make` is -O0 = 15x slow / looks hung; `make fast` crashes clang). Use -Os (~8 min):
cd verilator
make obj_dir/Vemu.cpp && (cd obj_dir && rm -f *.o *.gch && make OPT_FAST=-Os OPT_SLOW=-Os -f Vemu.mk)

# Boot-test (cap <=700 frames; macOS has no `timeout`; ~15-20 min). Run ONCE, analyze the log:
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom ../releases/boot0-fastmem.rom \
  --screenshot 399 --stop-at-frame 400 > /tmp/boot.log 2>&1
grep '\[HB\]' /tmp/boot.log | tail        # PASS: PCs climb $A45Exx -> $A07A5A -> $A3Cxxx -> $A14xxx -> $A06F08
                                            # FAIL: stuck looping in $A45Exx
# Then inspect verilator/screenshot_frame_0399.png:
#   PASS = desktop CHECKERBOARD ("dots", a fine 1px checker that reads as textured grey)
#   FAIL = FLAT uniform grey (hung in pre-MMU POST)
```
Keep `verilator/Makefile`'s `PMMU_TRACE`/`A30_TRACE` defines COMMENTED for normal builds. (Enabling them
makes `tg68k.v` connect MacLC-only kernel `debug_*` ports — if the merged kernel lacks them the build fails;
that's a signal, not a goal. `tg68k.v` connects only `debug_make_berr`/`debug_trap_berr` unconditionally.)

## 7. Validation gates (must all hold to claim success)
1. `ghdl --synth --latches` clean on the merged core.
2. Verilator build succeeds with traces OFF.
3. LC II boot reaches the **desktop checkerboard at F399** (HB progression + screenshot). Baseline `3194397`
   meets this; do not regress.

## 8. Deliverables
- Commit to a **NEW branch** (e.g. `kernel-merge-030mmu2`), not `030_LCii_rebased`. If it boots: commit the
  merged core + regenerated `.v`. If not: revert VHDL, keep the baseline, commit only the findings doc.
- Write `docs/findings_kernel_merge_030mmu2_2026-06-18.md`: per-file/per-block classified comparison
  (G/M/S/A + direction), verdict on "adopt-their-kernel + re-add ours" (booted? what was re-added? residual
  delta?), the alternative's assessment, and a recommendation.
- If the merge lands and boots, sync the 8 tg68k files to MacIIvi (`/Users/dani/repos/MacIIvi_MiSTer`) and commit.

## 9. Background / gotchas
- Full LC II PMMU/bsr.w story: `docs/findings_pmmu_earlyterm_2026-06-18.md`, memory `lcii-postpmmu-divergence`.
- The Verilator sim compiles `tg68k.v` (NOT `TG68K.vhd`) — so `TG68K.vhd` divergence does NOT affect the sim
  boot test (it's the FPGA wrapper). The sim runs the kernel UNCACHED (the cache isn't instantiated in `tg68k.v`).
- The PMMU is inlined into the generated `TG68KdotC_Kernel.v` by `convert_to_verilog.sh` (it analyzes
  Pack→ALU→PMMU_030→Cache_030→Kernel and synths the kernel). Minimig's `cpu_wrapper.v`/`TG68K_CacheCtrl_030.vhd`
  are NOT part of MacLC's regen and are not needed for the sim.
- MAME ground truth (if needed): `verilator/mame/run_mame_maclc2.sh` + the `mmu_*.lua`/`pt_root10.lua` probes;
  68030 program-space taps see the LOGICAL `$40A` alias; code taps don't fire post-i-cache (tap DATA).
