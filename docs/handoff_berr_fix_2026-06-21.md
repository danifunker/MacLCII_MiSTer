# Handoff: TG68 Format-$B continue-past bug — FIXED, pushed (2026-06-21)

Self-contained. Picks up from `docs/handoff_sim_berrframe_2026-06-20.md` (the
"ground-truth the bug" task). That task is **done**: the bug is root-caused,
fixed, validated in sim, and pushed. This doc says exactly what landed and what's
left.

## Status: DONE in sim, awaiting hardware validation

- **Branch `fix/tg68-format-b-continue-past`, commit `280f671`, PUSHED to origin.**
  PR not opened yet: https://github.com/danifunker/MacLCII_MiSTer/pull/new/fix/tg68-format-b-continue-past
- Full writeup: `docs/results_berrframe_sim_2026-06-20.md` (root cause, the
  per-instruction-length stacked-PC table, the fix, and the macOS-sim findings).

## The bug (one line)

TG68 stacked the **prefetch pointer** (~faulting_addr + 3 words), **not the
next-instruction PC**, in the 68030 Format-$B bus-fault frame. Mac OS
BERR-protected probes (`movea.l (a1),a0`, `move.l $38(a6),d0` — short, 1–2 word
instructions) clear DF and `RTE` to "continue past"; with the overshot PC the
RTE resumes 1–2 instructions too far → derail → vector-2 storm → Sad Mac on boot
/ "bus error" bomb in apps. The 8-byte `moves.w $22000.l` RAM-size probe happens
to stack the correct PC, which is why the RAM test passes but OS probes bomb.

## The fix

`rtl/tg68k/TG68KdotC_Kernel.vhd` (source of truth; `.v` regenerated):
- New `signal instr_boundary_pc`.
- Latch during operand setup: `IF setstate="01" THEN instr_boundary_pc <= TG68_PC`.
- Frame build (~line 3680): for an **external (non-PMMU) data fault**, stack
  `instr_boundary_pc` instead of `TG68_PC`. PMMU faults keep `TG68_PC` (their
  `rte_mmu_fix` replay advances the PC itself).

## Validation done

- **Unit test** `verilator/test_berrframe/` (faults via MOVES/SFC=7, the sim's
  only BERR source). All OS-probe addressing modes now resume on the true next
  instruction: `(An).l`/`(An).w` fixed `A00042→A00040`; `(d16,An)` stays `A00042`.
- **Boot unchanged**: nomemcheck reaches OS init `A1B718@F100`, no BERR storm
  (DISP count identical to pre-fix). The only early-boot external data fault is
  the RAM probe, which recovers via `jmp (A6)`, never an RTE of this frame.
- **Toolchain trusted**: a no-op GHDL regen (6.0.0) of the *unedited* VHDL is
  byte-identical to the committed `.v`, so the large `.v` diff is just
  wire-renumbering churn around the one logical change.

## Open items / next steps (priority order)

1. **Hardware validation (the real proof).** The FPGA enables unmapped-BERR
   (sim disables it — that's why the bomb never reproduced in the full-system
   sim), so the FPGA hits the *actual* OS probes. Rebuild the `.rbf` (Quartus
   compiles the `.vhd` directly via `TG68K.qip`; no GHDL needed) and confirm the
   game "bus error" bomb is gone and boot is reliable.
   Build: `QUARTUS_BIN=/c/intelFPGA_lite/17.0/quartus/bin64 bash scripts/build.sh`
   (~15–22 min; remove `db/ incremental_db/` for a clean fit). Deploy to
   `/media/fat/_Unstable/MacLCii.rbf`.
2. **Open the PR** (link above) if desired.
3. **(Optional) make the fix universal for absolute-EA faults.** Current fix is
   exact for register-indirect `(An)/(An)+/-(An)` and `(d16,An)` (the OS probe
   modes). Absolute-EA data faults stack `-2` (their last EA word is read in the
   access cycle) — **harmless** today (only the RAM probe uses abs, and it
   recovers via `jmp`, never RTE). A universal fix would need the faulting
   instruction's length/EA-mode at frame-build time; `exe_opcode` is NOT reliable
   there (it shows the prefetched next opcode, e.g. `4E71`), so this needs more
   than a one-liner. Low priority unless an abs-EA continue-past probe ever shows
   up.
4. **(Separate) Egret/ADB boot wedge.** The full-system sim boot wedges in the OS
   task-dispatch/idle loop `$A06F0E` before disk load (all of diskless/floppy/SCSI
   converge there), so it never reaches the live OS probes — that's why the unit
   test was needed. Fixing it would let the SCSI boot reproduce the bomb
   end-to-end in sim. Respect the VIA-SR caveats in `CLAUDE.md` (prefer
   rate-limiting `cuda_cb1` over touching the SR path).

## Reproduce / re-validate (macOS, native Verilator 5.048)

```bash
# Build the sim (plain make — --public-flat-rw is NOT needed; berrframe_build.sh's
# claim it's required is false on 5.048, and it just bloats/slows the model):
cd verilator && make clean && make

# Unit test (the fix's oracle):
cd test_berrframe && bash build_rom.sh && cd ..
./obj_dir/Vemu --headless --trace-frames 0,20 --stop-at-frame 20 \
  --rom test_berrframe/berr_rte_test.rom 2>&1 | grep -aE 'BERRFRAME'
#   -> landed_pc=A00040 (probe moves at $A0003C resumes at its true next instr).
#   Edit the `moves.l (%a1), %d0` line in berr_rte_test.s to vary the probe form.

# Boot smoke test (no regression): heartbeat must reach A1B718@F100, no storm.
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --stop-at-frame 120 \
  --rom ../releases/boot0-nomemcheck.rom 2>&1 | grep -aE 'HB\] F100|BERRFRAME'

# After ANY further .vhd edit, regen the .v so sim/FPGA stay in sync:
cd ../rtl/tg68k && bash convert_to_verilog.sh && cd ../../verilator && make
```

Gotchas worth knowing (cost me time):
- The sim is **slow, not hung**, on macOS (~0.3–0.5 fps; frame 0 alone ~20 s).
  `[HB]` heartbeat only starts at **F9**, and `debug_pc` reads 0 for the first
  ~10M cycles even while executing — a short run makes a working ROM look wedged.
- The sim's only BERR source is **FC7/`moves`** (sim.v `fc7_berr`); unmapped-BERR
  is disabled there (it broke the boot via early high-bit addresses), so you can't
  fault a plain `move` in sim — hence the MOVES-based unit test.
- A from-scratch test ROM must enter at a **low PC** (overlay mirror) and jump to
  `$A`-space to disable the overlay before using a stack (`$800000-$9FFFFF` RAM).
- Bootable disk images live under `/Users/dani/` (e.g.
  `HD20SC-With-Benchmarking-and-CDROM.vhd`); `releases/Disk605.dsk` (System 6.0.5)
  is too old to boot the LC II.
