# Resume: TG68 Format-$B continue-past bug — HW diagnostic in flight (2026-06-21)

Read cold to continue. The MacBook's sim-validated fix does **not** work on hardware; I'm mid-way
through a hardware kernel-signal diagnostic to get ground truth, then build the real fix.
Companion docs: `docs/handoff_berr_fix_2026-06-21.md` (the MacBook fix), `docs/results_berrframe_sim_2026-06-20.md`
(sim writeup — has the KEY `exe_opcode` note), `docs/resume_lcii_berr_frame_2026-06-20.md`,
`docs/findings_berr_probe_replay_2026-06-20.md`.

## TL;DR — current state
- Branch `fix/tg68-format-b-continue-past` (checked out). **Working tree has UNCOMMITTED changes**
  (a candidate register-writeback fix + the kernel-signal diagnostic probes — see "Uncommitted" below).
- Bug: TG68 mishandles the 68030 **Format-$B "continue-past" RTE**. Mac OS does BERR-protected probes
  everywhere (install temp BERR handler → touch maybe-bad addr → on fault clear DF + set DIB + `RTE`
  to *continue past*). TG68 derails → vector-2 storm → **Sad Mac `0000000F`/`00007FFF` on boot**, app bombs.
- MacBook fix (commit `280f671`: stack `instr_boundary_pc`, not the prefetch PC) is on origin but
  **FAILS on hardware** — identical Sad Mac, `PEXC` BUSERR at `$A0DBFC`, derail to `$A09B8A` (JTAG + screenshot confirmed).
- I then broadened the `rte_mmu_fix` register-writeback — **also failed** (byte-identical signature).
- **Root difficulty (the crux):** at frame-build time (`make_berr`) TG68's prefetch has already moved
  past the faulting instruction. The MacBook's own note (results doc): *"exe_opcode is NOT reliable there —
  it shows the prefetched next opcode (e.g. `4E71`)."* So: (a) the register-writeback gate decodes the
  WRONG opcode (the *next* instr, not the probe's `move.l`) → never fires; (b) `instr_boundary_pc`
  overshoots for the real short MOVE forms — 2-byte `(An)`, 4-byte `(d16,An)` — which the MacBook never
  tested (it validated only longer `MOVES`: 4B/6B).

## IMMEDIATE next step: the in-flight diagnostic build
A clean-fit FPGA build of a **kernel-signal first-fault recorder** was running when this session ended
(~20 min; synthesis had passed). It routes the CPU kernel's own fault signals to the JTAG deck (reusing
PFR0–3), latched on the FIRST `make_berr` (clean, before any derail).

1. Check whether it finished:
   ```bash
   cd /c/Temp/mistercore/MacLCII_MiSTer
   ls -la output_files/MacLCii.rbf
   grep "Compile exit" output_files/auto_compile_*.log | tail -1     # want exit=0
   ```
   If not finished / failed (the fit is marginal; the added routing may cause congestion or a Fitter
   ACCESS-VIOLATION crash on stale db/), rebuild clean:
   ```bash
   rm -rf db incremental_db && bash scripts/build.sh                 # ~20 min
   ```
   Timing need not close for the diagnostic — it just has to run and capture.

2. Deploy + cold-boot (auto-mounts `MacLC_6-0-8-POP.hda` = System 6.0.8 + Prince of Persia → reaches the OS probes):
   ```bash
   source scripts/local.env
   python tools/misterdeploy/launch_unstable_core.py --push output_files/MacLCii.rbf   # ~4 min
   ```

3. Read the first-fault capture:
   ```bash
   bash scripts/read_probes.sh 2>&1 | grep -A4 "PFR first-fault"
   ```
   Decode (cpu_state.tcl already updated):
   - **PFR0 = berr_frame_pc** = stacked PC = where the handler's `RTE` resumes.
   - **PFR1 = exe_pc** = faulting instruction's START.
   - **PFR2 = {exe_opcode[31:16], opcode[15:0]}** = the two opcode taps (which one holds the faulting
     `move.l` = `0x202E` vs the prefetched-next).
   - **PFR3 = {make_berr_count[31:24], …, frozen[0]}** = count>1 ⇒ that first fault derailed into a storm.

## Interpret → pick the fix
Disasm at `exe_pc` (capstone `CS_ARCH_M68K`/`CS_MODE_M68K_030`; ROM offset = runtime & 0x7FFFF; SD ROM =
`releases/boot0-nomemcheck.rom`; see `scratch/disasm_probes.py`). Expect `exe_pc` ≈ `$A0DC1A`
`move.l $38(a6),d0` (4B `(d16,An)`, correct next `$A0DC1E`) or `$A0DB92 movea.l (a1),a0` (2B `(An)`, next +2). Then:
- **`berr_frame_pc` ≠ `exe_pc` + instr_len** → stacked PC overshoots → fix the PC: stack
  `exe_pc + length` (length from the FAULTING instr's EA mode: `(An)`→+2, `(d16,An)`→+4), computed at `make_berr`.
- **Which opcode tap = the faulting `move.l` (0x202E)?** If `opcode` (the decode register) holds it but
  `exe_opcode` is the prefetched-next, then the frame's `berr_opcode_saved <= exe_opcode` (and thus the
  `rte_mmu_fix` gate) uses the wrong opcode → switch to `opcode` (or capture the faulting opcode at fault).
- Most likely **both** the PC and the gate-opcode are wrong → fix both.

## Build the real fix, then validate
Correct continue-past needs: resume PC = next instruction (`exe_pc + faulting-instr length`) AND dest
register = DIB. Machinery in play: `rte_mmu_fix` (register writeback, ~`TG68KdotC_Kernel.vhd:1572`) + the
Format-$B frame PC (`berr_frame_pc`, ~`3709`). Build the fix in `TG68KdotC_Kernel.vhd`, then:
- `rm -rf db incremental_db && bash scripts/build.sh`; deploy; **validate**: screenshot reaches the
  System 6 Finder (NOT Sad Mac) AND `read_probes.sh` shows no BUSERR storm (PFR `make_berr_count` low,
  `PEXC` not maxed). Then check the game (POP) doesn't bomb.
- When it works: close timing if regressed; regen `TG68KdotC_Kernel.v` (GHDL — **not on this box**; on the
  MacBook via `rtl/tg68k/convert_to_verilog.sh`); commit; push; write a results doc.

## Uncommitted working-tree changes (what's there now)
- **`rtl/tg68k/TG68KdotC_Kernel.vhd`** — (a) register-writeback CANDIDATE fix (grep `CONTINUE-PAST FIX`):
  removed `rte_mmu_fix_ssw(9)='1'` gate (~1577), added `(d16,An)` EA mode "101" (~1583), gated `TG68_PC+2`
  on `rte_mmu_fix_ssw(9)='1'` (~3322). (b) diagnostic taps: new out ports `debug_berr_frame_pc`,
  `debug_exe_opcode`, `debug_berr_opcode` + assigns (~9268); reuses existing `debug_exe_PC` (VHDL is
  case-insensitive — `debug_exe_pc` clashes with it; that's why the diag uses the existing port).
- **`rtl/tg68k/tg68k.v`** — 5 new module outputs (`dbg_make_berr`/`dbg_berr_frame_pc`/`dbg_exe_pc`/
  `dbg_exe_opcode`/`dbg_berr_opcode`), `assign dbg_make_berr = kernel_make_berr;`, + 4 always-connected
  taps in the `TG68KdotC_Kernel` instantiation (note `.debug_exe_PC(dbg_exe_pc)` — existing port).
- **`MacLC.sv`** — 5 wires (`cpu_make_berr`,`cpu_berr_frame_pc`,`cpu_exe_pc`,`cpu_exe_opcode`,`cpu_berr_opcode`)
  + tg68k taps + dbg_probes taps.
- **`rtl/dbg_probes.sv`** — 5 inputs + the PFR0–3 recorder rewritten to latch the kernel signals on the
  first `make_berr` (search `kernel-signal first-fault capture`).
- **`scripts/cpu_state.tcl`** — PFR decode updated for the new layout.
The register-writeback fix is a CANDIDATE (didn't work alone; may be part of the final fix). The probes
are DEBUG (keep until fixed, then optionally revert).

## Dead-ends — do NOT repeat
1. MacBook `instr_boundary_pc` PC-latch alone → fails on HW (overshoots short MOVE forms).
2. Broadening the `rte_mmu_fix` register-writeback alone → fails (gate sees the prefetched-NEXT opcode → never fires).
3. External-bus PFR recorder (vec-fetch / `$4E73` RTE-landing) → only catches post-derail garbage
   (`fr_pc0=$8`); that's why I switched to kernel-signal capture.
4. Keeping `db/` for an incremental build → Fitter ACCESS-VIOLATION crash; always `rm -rf db incremental_db`.
5. The sim **cannot** reproduce this bug (unmapped-BERR disabled in `sim.v` + Egret/ADB boot wedge); HW-only.
   (User chose to keep grinding on HW rather than extend the sim unit test.)

## Hardware / build / toolchain
- SSH `ssh -i ~/.ssh/mister_only root@192.168.99.143`. `scripts/local.env`: MISTER_HOST=192.168.99.143,
  MISTER_SSH_KEY, MISTER_HTTP_PORT=8182, RBF_NAME=MacLCii.rbf, QUARTUS_BIN=/c/intelFPGA_lite/17.0/quartus/bin64.
- JTAG: `bash scripts/read_probes.sh` (USB-Blaster; decodes `scripts/cpu_state.tcl`). Fine to run during a
  Quartus compile (cable only used by program ops).
- Screenshot: `bash scripts/grab.sh scratch/x.png` then `Read` the PNG (HTTP; works after a fresh boot;
  an idle core returns stale/black).
- Deploy+boot: `python tools/misterdeploy/launch_unstable_core.py --push output_files/MacLCii.rbf`
  (full reboot + OSD select; ~4 min; preserves the POP-HD mount in `config/MacLCii.s0`).
- FPGA build: `rm -rf db incremental_db && bash scripts/build.sh` (Quartus 17.0.2; ~20 min; compiles the
  `.vhd` directly via `TG68K.qip` — no GHDL needed for FPGA). The latest CLEAN fit closed at +0.079 setup.
- GHDL/Verilator NOT native here; WSL has Verilator 5.020 (slow over 9p); `.v` regen needs GHDL (MacBook).

## Key addresses (offset = runtime & 0x7FFFF; SD ROM = releases/boot0-nomemcheck.rom)
- Sad Mac: `0000000F` / `00007FFF`. PEXC fatal: `$A0DBFC`. Storm derail landing: `$A09B8A`.
- Handle-validation probe `$A0DBF8…`: `$A0DC1A move.l $38(a6),d0` (4B `(d16,An)`, next `$A0DC1E`);
  handler `$A0DB50` (`andi.w #$feff,$a(a7); clr.l $2c(a7); rte`, DIB:=0). Also `$A0DB92 movea.l (a1),a0`
  (2B `(An)`); handler `$A0DB5C` (DIB:=$FFFFFFFF). Dispatch probe at `$A08D14…`.
