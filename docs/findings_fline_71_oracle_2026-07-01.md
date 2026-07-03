# 7.1 "bad F-Line instruction" — MAME-oracle analysis (2026-07-01 late)

## Symptom (re-confirmed on HW today, build a389971a)
System 7.1 @10MB: Welcome → startup (extension phase) → bomb
**"bad F-Line instruction"** (`scratch/hw71_bomb_check.png`). 7.5.5 wedges later
(MemMgr free-walk); 6.0.8 fine. MAME boots both 7.x fine.

## THE ORACLE GAP (key insight of this session)
**MAME maclc2's 68030 models a phantom FPU** — `fsave/frestore/fmove` execute
natively in MAME (verified in trace: `fsave -(A7)` at $CB0C falls straight
through to `move.w (A7),D0`). A real LC II (and our core) has NO FPU: every FPU
op must trap to vector 11 with a correct format-$0 frame. **The entire no-FPU
F-line trap surface is invisible to MAME comparison** — it is exactly where our
core can diverge from real hardware without the oracle noticing.

## What 7.1 executes that is F-line (from full-boot maincpu trace, 48.5M lines)
Extracts persisted in `scratch/m71_analysis/` (pmmu_sites.txt, fpu_sites.txt,
firsts.txt). Trace itself was in WSL /tmp (evaporates on WSL idle-exit — rerun
`verilator/mame/fline_trace.dbg` if needed, ~7 min).

1. **ROM FPU-sizing probe** (runs EVERY boot, trace line ~12.0M):
   - `$A47C56-$A47C9C`: copies vector table to a stack buffer, installs
     handler **$A48252** at vector 7 + FPU vectors ($C0-$D8), handler
     **$A48284** at vectors 11/13/14 ($2C/$34/$38), swaps VBR to the copy.
   - `$A47CA2`: `lea $A47CAC,A0` (resume addr), `moveq #$B,D7` (expected vec),
     then probe #1: **`$A47CA8: fmove.l D0,FP0`** ($F200 $4000).
   - No-FPU: traps v11 → $A48284. **Handler contract** (disassembled):
     `move.w ($6,A7),D0; lsr.w #2,D0; cmp.b D0,D7` — vector byte from the
     format/vector word at SP+6 must equal $B; `lsr.w #10` more → format
     nibble must be 0; then **`move.l A0,($2,A7)` — REPLACES the stacked PC —
     and `rte`**. Flags D5=1 → `$A47CAC: tst.b D5; bne $A481CC` (no-FPU path:
     restores VBR, returns FPU-type "none" in D0).
   - **The ROM probe handler never READS the stacked PC (it overwrites it).**
     ⟹ 6.0.8 booting does NOT validate our stacked F-line PC — only the
     format/vector word. A wrong stacked PC sails through the ROM probe and
     only kills the first 7.x consumer that decodes the faulting instruction.
   - On MAME the probe does NOT trap (FPU present) → D6 escalates through the
     full ROM FPU test suite $A47CB2-$A481CA (fmove.l/w/b/s/d/x/p + frem with
     per-op handler arming) — none of that runs on a no-FPU machine.

2. **System 7.1 fsave probe** `$CB0C: fsave -(A7)` (RAM, trace line ~14.8M),
   guarded by `btst #$4,$b22.w` (**HWCfgFlags bit 4 = FPU present**) and
   CPUFlag $12F. On a correct no-FPU boot this is SKIPPED. If it executes and
   traps unhandled → bomb. (If our ROM probe mis-signals "FPU present" into
   HWCfgFlags, this is the first landmine.)

3. **`$76600/$76610: frestore (A7)+ / fsave -(A7)` + fmovem** (RAM, line
   ~21.0M) — FPU context save/restore, presumably also gated on FPU presence.

4. **PMMU ops** (all-boot corpus, pmmu_sites.txt): hot SwapMMUMode sequence at
   `$40A03EFC-$40A03F12` (1209×): `pload #0,(a0)$8; pmove srp; pmove crp;
   pmovefd crp; pmove tc`. Plus one-time ROM MMU init at `$A41664-$A416B6`:
   `$F000 $2400` = **PFLUSHA** (MAME disasm mislabels it "pflushr"), PMOVEs
   with ext $0800/$0C00 (TT0/TT1 in 030 encoding; MAME names them srp/crp per
   68851 convention) and 030-encoded CRP ($4C00)/TC ($4000). All these forms
   are accepted by our pmove_decode — verified against the kernel decode.

## Hypotheses (unchanged, sharpened)
- **(b2) F-line frame/stacked-PC bug**: stacked PC (or SR) subtly wrong for
  $F2xx decode-traps; masked by the ROM probe (PC overwritten), fatal to 7.x
  consumers that parse the faulting instruction. 6.0.8 split explained.
- **(b1) PMMU decode strictness**: some 7.x-era PMOVE/PTEST/PFLUSH form hits
  one of our WinUAE-style reserved-bit traps (`pmmu_brief(7:0)/=0`, FD+read,
  MMUSR+FD, FC=11xx, PTEST level-0+A) that real silicon accepts. Would appear
  as ctx=1 capture with $F0xx opcode.
- False-FPU-detect variant of (b2): ROM probe concludes "FPU present" on our
  core (e.g., trap never fires, or D5 path broken) → HWCfgFlags bit4=1 → 7.1
  executes fsave at $CB0C → unhandled trap → bomb. 6.0.8 never consults the
  flag at boot.

## Instrumentation added (this session)
- `rtl/tg68k/tg68k.v`: F-line trap capture — latches first+last
  {op, pmmu_brief, pc, ctx} + 16-bit count on every `trap_1111 && trapmake`
  rising edge; `$display("FLINE[...]")` under `ifdef SIMULATION`; new
  `dbg_fline_*` output ports. op/pc select `fline_opcode_latch/_pc` when
  `fline_context_valid` (PMMU sub-decode traps) else live `opcode`/`exe_pc`.
- `MacLC.sv`: probes **PFLA** (first pc), **PFLB** (first {op,ext}), **PFLC**
  (last pc), **PFLD** (last {op,ext}), **PFLE** {count[15:0],ctx flags}.
- `scripts/cpu_state.tcl`: PFLx decode section.
- `verilator/mame/fline_trace.dbg`, `dasm_fpuprobe.dbg`, `dasm_mmuprobe.dbg`.

## ★★★ ROOT CAUSE FOUND (HW capture + berr_bench, same session)
**HW capture (PFLx, build f5ccc524):** exactly ONE F-line trap in the fatal
boot: **op=$FFFF executed at PC=$00000100** (low-mem globals) — a WILD JUMP
into data, then the $FFFF F-line bomb. The OS handler is fine; the jump is the
bug. (The ROM FPU probe trap doesn't appear in the count because a CPU reset
occurs between it and System startup; the sim independently proved the ROM
probe traps + recovers: `FLINE[0] op=f200 pc=00a47ca8`.)

**Mechanism (proved in `verilator/berr_bench/`, new this session):** the
MC68030 **Format-$B continue-past contract is broken**. Byte-exact repro of the
ROM validator handler ($A0DB50: `andi.w #$feff,($a,A7); clr.l ($2c,A7); rte`)
against the kernel:
- Stacked frame PC = **one instruction SHORT** (points at the `moveq` before
  the probing `move.l ($3c,A6),D0`) → the DF-cleared RTE re-runs the probe →
  **infinite vector-2 storm** (bench: 1009 faults; HW PEXC wrap16 ambiguity
  masked this).
- Frame `+$14` opcode stash = stale (`lea` from 2 instrs back) → the
  `rte_mmu_fix` register-writeback gate never decodes the real MOVE → the
  probed destination register never receives the handler's DIB value → the
  validator's verdict is computed on a stale register.
- Cause of both: the **v2 (2026-06-21) `setstate="01"` capture heuristic**
  (`berr_setup_opcode/_exe_pc`) goes stale when the instructions before the
  probe are register-only (moveq/lea never pass `setstate="01"`); and
  `opcode` is clobbered to 4E71 at trap dispatch, so frame-build-time reads
  are too late. Depending on surrounding code, the stale resume PC can land
  mid-instruction → garbage decode → wild jump (→ the $100 F-line bomb on
  7.1; plausibly the 7.5.5 free-walk heap garbage too — 7.5.5 validators
  "continue past" with stale registers and corrupt state downstream).

**Fix v3 (superseded by v4):** captured `opcode`+`opcode_pc` at the external-
BERR first-fire cycle and stacked `berr_capture_pc + EA-mode-length`. berr_bench
proved v3 fixes the MOVE `(An)`/`(d16,An)` forms — BUT it deployed to HW and
7.1 **still bombed** (PEXC byte-identical). Root of the residual: **EA-mode
length reconstruction is wrong for two-word opcodes.** The `$A0DB6A` validator
family also probes with **`btst #$6,(A0)` = `$0810 $0006` (4 bytes, EA mode
010)**; v3 read mode 010 → stacked +2 → RTE resumed on the `$0006` immediate
word → decoded as garbage → wild jump into the vector table → the `$100`
F-line bomb. berr_bench probe #4 (btst) reproduced it exactly (BERR#5 on the
mis-executed marker).

**Fix v4 (current, TG68KdotC_Kernel.vhd):** stop reconstructing length. Capture
the **prefetch pointer `TG68_PC` at external-BERR first-fire** into
`berr_capture_nextpc`; resume = `berr_capture_nextpc - 2`. Measured across all
validator read forms (move.l(d16,An)/movea.l(An)/tst.b(An)/btst #imm,(An)/
abs.L), `TG68_PC` at first-fire is EXACTLY `next_instruction_pc + 2` (one
prefetched word) regardless of the faulting instruction's own length — so a
single `-2` is correct where per-EA length decode was fragile. `berr_capture_opcode`
still feeds the `rte_mmu_fix` register writeback (unchanged). Validation:
`verilator/berr_bench/` now exercises FIVE probe forms; PASS gate = all five
markers + D0←DIB + no derail + exactly 5 faults. MAME remains blind to ALL of
this (phantom FPU ⟹ no F-line traps; healthy boot never calls the validators).

## Gotchas learned
- WSL2 idle-terminates ~60s after the last wsl.exe client exits — kills
  nohup'd background jobs and wipes /tmp. Run long WSL jobs as TRACKED
  background Bash commands (wsl.exe stays attached); persist artifacts to
  /mnt/c, not /tmp.
- Verilator sim under WSLg needs `SDL_VIDEODRIVER=dummy` when the X pipeline
  is broken (BadDrawable crash even with --headless).
- MAME `-debug -video none -debugscript` works headless; a `quit` at the end
  of a debugscript can segfault — end with `go` + `-seconds_to_run` instead.
- MAME m68k disasm uses 68851 register naming for PMOVE group-000 ext words
  and renders PFLUSHA as "pflushr 0,0,D0" — always check raw ext words.
