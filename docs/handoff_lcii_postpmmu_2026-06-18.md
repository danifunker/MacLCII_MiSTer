# LC II post-MMU boot — handoff (2026-06-18)

**Branch:** `030_LCii_rebased`  **Goal:** stabilize the shared `rtl/tg68k` CPU/PMMU core so the
Mac LC II boots past the post-MMU POST (toward the desktop checkerboard), THEN copy the 8 tg68k
files to `../MacIIvi_MiSTer`. (User's stated order: fix the CPU here first; MacIIvi later.)

This doc is self-contained. Full cycle-level detail: **`docs/findings_1ff35a_mmuswitch_2026-06-18.md`**
(read it). Memory: **`lcii-postpmmu-divergence`**. Prior bsr.w fix: `docs/findings_postpmmu_bsrw_2026-06-17.md`.

---

## 1. Where the boot is now

- **Committed & load-bearing:** `c8895d8` — the bsr.w/bsr.l push fix (3 parts in
  `TG68KdotC_Kernel.vhd`: `set(presub)` into `bsr.s`/`bsr2`; address-datapath hold during a
  PMMU stall of a CPU access; longword word-counter hold). This cleared the old F154 `$FFFFxx`
  derail and lets the boot run the whole `$40A` alias post-MMU POST. **Do not regress it.**
- **Current blocker (the "`$1FF35A` wedge"):** the boot wedges around frame **F156** at
  `move.b d1,$cb2.w` (`$40A03F18`), right after a `pmove (8,A0),TC` MMU reconfig. A bus-error
  exception fires and the boot derails (HB samples it as a spin reading `$001FF35A`).
- Screenshot @F200 = uniform grey (correct PRE-desktop state — same as MAME before the desktop
  fill). So we wedge BEFORE the fill; video path is fine.

## 2. THE ROOT CAUSE (confirmed, cycle-level) — it's a CPU bug, NOT the PMMU

The resume's framing (a `jmp ($2,PC,D5.w)` to `$1FF35A`) was a **misaligned disassembly**.
The real chain, traced against MAME `maclc2`:

1. Post-MMU, the boot takes an **A-line trap** → A-line dispatcher `$A099B0`
   (`jsr ([$400,d2.w*4])`, the low-mem trap-vector table) → the **24↔32-bit address-mode-switch
   handler `$A03ED8`** (`_SwapMMUMode`-class).
2. The handler branches on the mode flag **`[$0CB2]`**: ours = **`$01`** (set by the setup
   `$A03E14 move.b #$1,$cb2.w`), MAME = **`0`**. With `$01` we run the `pmove` reconfig
   (`$A03EFC pload`; `$A03F02/08 pmove TT0/TT1`; `$A03F0E pmovefd CRP`; **`$A03F12 pmove (8,A0),TC`**);
   MAME (flag=0) **skips it** (`beq $a03f2a`) and reaches the desktop.
3. Right after `pmove TC`, the `move.b d1,$cb2.w` (`$40A03F18`) **never decodes**: its
   instruction fetch stalls on a PMMU walk (the ATC was just flushed by the `pmove TC`), and a
   **bus-error exception preempts it** (`opcode` forced `$f028`→`$4E71` NOP, never `$11C1`) →
   straight to `berr_fill`. The recorded fault address / first frame write is a **wild
   `$fffffff2`** (`use_base=0`); subsequent frame pushes correctly hit the stack (`$1FF35A`).

So the fault is an **earlier access** (a `pmove`-TC operand read / a descriptor walk / the
fetch) that bus-errored, and the **exception entry itself is partly corrupted**. Same FAMILY as
the bsr.w bug (a PMMU stall corrupting the CPU address datapath), but a different, **pipeline-
race-sensitive** manifestation (fetch-stall × multi-word `pmove` × exception entry interact).

**MMU config is CORRECT** (so the PMMU is fine): loaded `CRP=$7FFF0003:$003FE820`,
`TC=$80F84500` (IS=8 → 24-bit mode), `TT0=TT1=0` — all match MAME. MAME's page table at CRP
aptr `$3FE820` = four DT=01 early-termination descriptors identity-mapping the 4 MB RAM
(`root[0]@$3FE820 = $7FFFFC19/$00000000`), so `$0CB2`→physical `$0CB2`. The bug is the CPU's
address datapath under the `pmove`-TC → next-access → exception sequence, not the walk.

## 3. Ruled out (do NOT re-derive — each cost a build/run cycle)

| Hypothesis | Why it's WRONG |
|---|---|
| `jmp ($2,PC,D5.w)` → `$1FF35A` | misaligned disasm; real path is the A-trap mode-switch handler |
| PMMU walk / stale-ATC bug | ATC **is** flushed on `pmove TC` (FD=0, kernel L1128 + 4004-4006); loaded CRP/TC match MAME |
| byte-lane bug on `move.b #1,$cb2.w` | `A30[CB]` watchpoint: write is correct (UDS asserted, even-byte high lane, `$0CB2=$01`) |
| bsr.w-fix HOLD over-holding the EA | `A30[MOVB]`: `pmmu_busy=0` during the EA cycle → the hold (`pmmu_busy AND state(1)`) doesn't engage |
| `move.b` absolute-EA simply skipped | incomplete — the `move.b` **never decodes**; a bus error preempts it (`opcode`→NOP) |
| earlier "`$46`" at `$0CB2`, "`$fffffff2`" as the EA, "non-determinism" | misreads of the lagged `dbg_data_read` register and the berr-frame fill |

## 4. NEXT STEP — pin the faulting access (then fix)

The exact source of the wild `$fffffff2` / the faulting access is **not yet pinned** (it's not
the obvious candidates). The next diagnostic, BEFORE any fix:

- **Instrument the bus-error source.** At the rising edge of `kernel_make_berr` /
  `kernel_trap_berr` / the PMMU walker fault (`walker_fault`/`mem_berr`), log: the faulting
  **logical AND physical address**, the **SSW / fault-status (MMUSR)**, `micro_state`, and which
  access was in flight (instruction fetch vs operand read vs descriptor walk). The kernel already
  exposes most of this (`debug_pmmu_fault_status`, `pmmu_fault_addr_out`, `debug_pmmu_saved_addr`,
  `debug_pmmu_wstate`) — wire what's missing into `tg68k.v` (a `tg68k.v`-only change, no ghdl
  regen, like the probes already there).
- Once the faulting access + the corruption cycle are pinned, the fix is a **delicate microcode
  change** in the `pmove`-TC → next-access → exception path (kernel `TG68KdotC_Kernel.vhd`,
  near the `clkena_lw`/`micro_state` sequencing under `pmmu_busy`, ~L1451/L6030, and the
  `memaddr_delta_rega`/`use_base` datapath ~L2764). It must NOT regress `c8895d8` (the bsr.w push).

## 5. Validation gates (before committing any tg68k change)

1. **Boot trace** (this repo): the `move.b` must write `$0CB2`, the mode switch must complete
   (`$0CB2`→0), and the boot must run past F156 toward the desktop checkerboard. Repro below.
2. **MacIIvi SST CPU bench** — `cd ../MacIIvi_MiSTer/SingleStepTests/tg68k; make; ./obj_dir/Vtg68k_tests ../results/cpu/mame_baseline_2026-06-12.json`.
   Baseline ≈ **193 passed** today, but **~520 of the "fails" are a KNOWN harness USP-injection
   gap** (`sim_main.cpp` says so: USP poke doesn't take effect; all other state matches). The
   real census is the **non-USP** pass count (the docs cite ~711-714/718-719). Compare the
   non-USP failure SET before/after your change — it must not grow. (The bench links
   `../../rtl/tg68k/TG68KdotC_Kernel.v`, so copy your fixed kernel in first, or diff the two
   kernels' results.)
3. **MacIIvi PMMU corpus** — `../MacIIvi_MiSTer/SingleStepTests/pmmu/` (40 tests; the PMMU is a
   known-weak area). Run if your change touches `TG68K_PMMU_030.vhd` (this one probably won't —
   it's a CPU datapath fix).

After validating: regenerate `.v` via `rtl/tg68k/convert_to_verilog.sh` (ghdl 6.0.0), re-copy
the **8** tg68k files to `../MacIIvi_MiSTer/rtl/tg68k/` (`TG68K_ALU.vhd`, `TG68K_Cache_030.vhd`,
`TG68K_Pack.vhd`, `TG68K_PMMU_030.vhd`, `TG68K.vhd`, `tg68k.v`, `TG68KdotC_Kernel.v`,
`TG68KdotC_Kernel.vhd`), `diff -q` clean.

## 6. Build / run / repro

```bash
# Build (plain `make` is -O0 = 15× slow / looks hung; `make fast` crashes clang). Use -Os:
cd verilator
make obj_dir/Vemu.cpp && (cd obj_dir && rm -f *.o *.gch && make OPT_FAST=-Os OPT_SLOW=-Os -f Vemu.mk)

# Repro the wedge (~8 min to F157; cap sims <=700 frames, no `timeout` on macOS):
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom ../releases/boot0-fastmem.rom --stop-at-frame 157 > /tmp/x.log 2>&1
grep '\[HB\]' /tmp/x.log | tail   # F154 $00A008A0 -> ... -> wedge ~F156

# After ANY .vhd edit: rtl/tg68k/convert_to_verilog.sh  (ghdl 6.0.0), then rebuild.
```

The wedge instructions/accesses live at **cyc ~12462808-12462822** (frame ~156); the bsr.w push
(prior fix, for reference) is at **cyc ~12359300-12359320**.

## 7. Tooling left in place (all `ifdef`-guarded; Makefile defines are COMMENTED = off)

**`rtl/tg68k/tg68k.v`** (sim wrapper; the Verilator top is `verilator/sim.v` but it instantiates
this) — under `` `ifdef A30_TRACE ``:
- `A30[DISP]` — instruction-boundary trace of the continuation→dispatcher→wedge path.
- `A30[CB]` — `$0CB0-$0CBF` byte-lane watchpoint (UDS/LDS + both data bytes + PC).
- `A30[MOVB]` — per-cycle decode/EA-build trace over cyc 12462795-12462830, logs
  `micro_state/next_micro_state/opcode/last_opc_read/set_addrlong/decodeOPC/get_2ndopc/clkena_lw/pmmu_busy/use_base/state/memaddr_delta_rega/memaddr_delta/addr`.
- Wired kernel debug output ports (already in the generated `.v`): `debug_pmmu_busy`,
  `debug_memaddr_delta_rega`, `debug_next_micro_state`, `debug_opcode`, `debug_last_opc_read`,
  `debug_set_addrlong`, `debug_decodeOPC`, `debug_get_2ndopc`, `debug_clkena_lw`.

Under `` `ifdef PMMU_TRACE ``: `PMMU REQ`/`PMMU ACK` walk capture (gated on descriptor addr
`$3F0000-$3FFFFF`), augmented with `log=`(saved_addr) `crp=`(crp_lo) `tc=` `ws=`(walk_state).
Plus `PMMU make_berr`/`trap_berr` (ungated). Wires `debug_pmmu_saved_addr/crp_lo/tc/wstate`.

Enable a trace by uncommenting its `V_DEFINE += +define+...` in `verilator/Makefile` (both
defines currently commented). **Re-comment before any FPGA/normal build.**

**MAME oracle** (`verilator/mame/`, run via `run_mame_maclc2.sh`; binary `/opt/homebrew/bin/mame`
0.288 — the one that knows `maclc2`; ROMs at `/private/tmp/goodroms/{maclc2,egret}`):
- `mmu_state.lua` — per-frame `[$0CB2]`/`[$0CB4]`/`[$0CB8]`/`TC` (showed MAME `$0CB2=0`).
- `mmu_descr.lua` — final MMU regs + the two mode-config descriptor blocks (`$3FFFBE` 24-bit /
  `$3FFFAA` 32-bit).
- `mame_pagetable.lua` — dumps the live CRP page table (`$3FE820`: 4× DT=01 early-term, identity).
- `mmu_reconfig.lua`, `isr_probe.lua` — earlier probes (data taps / ISR snapshots).
- `pc_sp_hb.lua` — per-frame PC+A7 heartbeat → `/tmp/mame_hb.txt` (the canonical oracle).
- **MAME gotchas:** 68030 program-space taps see the **LOGICAL `$40A` alias** (not bare `$00A`);
  CODE read-taps DON'T fire post-i-cache (the boot enables the cache) → **tap DATA**; lua
  `space:read_*` bypasses the d-cache (true memory). `-skip_gameinfo` required.

## 8. Key facts / constants (don't re-derive)

- `$0CB2` = the 24↔32-bit mode-switch flag (`_SwapMMUMode`-class). `$0CB4`/`$0CB8` = pointers to
  the 24-bit / 32-bit descriptor config blocks (`$3FFFBE`/`$3FFFAA` = `A1-$2E`/`A1-$42`,
  `A1=[$0DDC]=$3FFFEC`). Our `$0CB4`/`$0CB8` match MAME; only `$0CB2` differs (1 vs 0), and that
  difference is downstream of the bus-error wedge (the mode switch never completes the clear).
- micro_states enum (in `TG68K_Pack.vhd`, 0-indexed): `idle`=0, `ld_nn`=2, `st_nn`=3, `bra1`=21,
  `bsr1`=22, `bsr2`=23, `nopnop`=24, `pmove_decode`=85, `pmmu_ld_dAn1`=98, `berr_fill`=113.
- `state`/`setstate` encoding: `"00"`=FETCH, `"10"`=read, `"11"`=write, `"01"`=internal/idle.
  `clkena_lw = clkena_in AND memmaskmux(3) AND pmmu_busy='0'` (L1451) gates `micro_state <=
  next_micro_state` (L6030); `nUDS=memmaskmux(5)`, `nLDS=memmaskmux(4)` (L1449); for even byte
  `memmaskmux = memmask(4:0)&'1'` (L1445). `pmmu_addr_log_int <= memaddr_reg + memaddr_delta`
  (L2785). The bsr.w-fix hold is L2764-2768.
- ROM: `releases/boot0-fastmem.rom` (512 KB at `$A00000`; `$40A` is the 32-bit alias). Disassemble
  with capstone `CS_MODE_M68K_030` (NOTE: capstone renders cpid-0 MMU ops as bogus FPU; use
  `m68k-elf-objdump -m m68k:68030` for `pmove`/`pload`).
- Open task list (this session): #3 "Pin the post-pmove-TC bus error that preempts the move.b"
  (next), #4 "Validate fix: boot + MacIIvi SST CPU + PMMU corpus".

## 9. Working-tree state (uncommitted)
- `rtl/tg68k/tg68k.v` — ifdef-guarded probes + the wired `debug_*` ports (no hardware-logic
  change; harmless when defines off).
- `verilator/Makefile` — trace defines present but COMMENTED (clean for normal builds).
- New: this doc, `docs/findings_1ff35a_mmuswitch_2026-06-18.md`, and `verilator/mame/*.lua`.
- Kernel/PMMU RTL logic UNTOUCHED; `c8895d8` intact. Decide whether to commit the probes (they're
  useful, ifdef-guarded) or keep them in the working tree.
