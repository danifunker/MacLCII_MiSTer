# Results: BERRFRAME continue-past ground-truth on the MacBook (Verilator) — 2026-06-20

> **STATUS: ROOT-CAUSED AND FIXED.** The bug (TG68 stacks the prefetch PC, not the
> next-instruction PC, in the Format-$B frame) is fixed in
> `rtl/tg68k/TG68KdotC_Kernel.vhd` (`instr_boundary_pc` latch + external-data-fault
> frame build) and validated: all OS-probe forms land on the true next instruction
> (`verilator/test_berrframe`), and the boot is unchanged (nomemcheck reaches OS
> init `A1B718@F100`, no BERR storm). See "ROOT CAUSE" and "the fix" below.

Answers the handoff in `docs/handoff_sim_berrframe_2026-06-20.md`. Ran the
instrumented Verilator sim natively on macOS (Apple Silicon, Verilator 5.048).
Companion: `docs/resume_lcii_berr_frame_2026-06-20.md`, `docs/findings_berr_probe_replay_2026-06-20.md`.

## TL;DR

- **The sim boots fine on macOS** — it is *slow*, not hung. Frame 0 alone burns
  ~5–8M clk cycles (the RAM-size probe loop) ≈ ~20 s wall-clock at ~350–400k
  cyc/s, so short runs look "stuck at frame 0." The `[HB]` heartbeat is gated to
  start at **F9**, which compounded the illusion. **No macOS boot regression.**
- **`--public-flat-rw` is unnecessary here.** Plain `make` compiles clean on
  Verilator 5.048 (the deep-flat `[SR]`/Egret/SCC taps that the handoff said
  break the build do NOT break it on this toolchain). The plain build is the one
  to use — `--public-flat-rw` only bloats the model. Build: `make clean && make`.
- **Decisive Q1 — does `fix_write=1` ever appear? → NO.** Zero `fix_write=1`,
  zero `[BERRFRAME] RTE` lines across every run (diskless, floppy, SCSI, and the
  F9 cpu-trace). Confirmed structurally: the gate at
  `TG68KdotC_Kernel.vhd:1574` requires stacked **SSW bit 9 = 1**, which no Mac OS
  handler sets.
- **Decisive Q3 — frame-field sanity → CONFIRMED (build side).** The one Format-$B
  fault reachable in sim (the F9 RAM-size probe) is `long=1, DF=1, b9=0, RW=1,
  faddr=0x22000, opc=0E79`.
- **Decisive Q2 — does a DF-cleared continue-past `RTE` land wrong? → YES,
  CONFIRMED via a focused unit test (see "ROOT CAUSE" below).** TG68 stacks the
  **prefetch pointer (~faulting-addr + 3 words), not the true next-instruction
  PC**, in the Format-$B frame. For faulting instructions shorter than 3 words —
  exactly the Mac OS probe forms — the continue-past `RTE` resumes **too far,
  skipping 1–2 instructions**, and the destination register is left corrupted.
  (The OS boot path itself is unreachable in the full-system sim — it wedges in
  the Egret/ADB idle loop `$A06F0E` before disk/Memory-Manager activity — so the
  bug was isolated with a hand-built test ROM instead.)

## ROOT CAUSE (Q2) — TG68 stacks the prefetch PC, not the next-instruction PC

A focused unit test (`verilator/test_berrframe/`) reproduces the OS probe in
isolation: a tiny ROM installs a BERR handler, faults via `MOVES` (SFC=7, the
sim's only BERR source), and the handler clears DF (`andi.w #$feff,$a(a7)`) +
DIB (`clr.l $2c(a7)`) then `RTE`s — the exact Mac OS "continue-past" pattern. The
`[BERRFRAME]` `landed_pc` and the cpu-trace show where the `RTE` resumes.

Result, varying only the faulting instruction's length (probe always at $A0003C,
correct resume is the instruction right after it):

| probe | length | true next instr | stacked / landed PC | error |
|---|---|---|---|---|
| `moves.w $22000.l` (the real boot F9 probe) | 8 B | $3A92 | $3A92 | **0 (correct)** |
| `moves.l $38(a1),d0`  (= OS `(d16,An)` form) | 6 B | $A00042 | $A00042 | **0 (correct)** |
| `moves.l (a1),d0`     (= OS `(An)` form)     | 4 B | $A00040 | $A00042 | **+2 (skips 1 instr)** |
| `moves.w (a1),d0`                            | 4 B | $A00040 | $A00042 | **+2 (skips 1 instr)** |

The stacked PC is always `faulting_addr + max(6, instr_len)` → **TG68 freezes the
*prefetch pointer* (3 words / 6 bytes ahead of the instruction start — its
prefetch depth) as the Format-$B continuation PC, instead of the true
end-of-instruction PC.** For instructions ≥ 3 words it coincides with the next
instruction (correct); for shorter ones it overshoots by `6 - instr_len`.

Why this is the bomb:
- The Mac OS BERR-probe instructions are short: `movea.l (a1),a0` = **1 word**
  (overshoot +4 → skips ~2 instructions), `move.l $38(a6),d0` = **2 words**
  (overshoot +2 → skips 1). On the handler's DF-cleared `RTE`, the CPU resumes
  **past** the instruction that checks the probe result, derails into garbage,
  and storms vector-2 → Sad Mac on boot / "bus error" bomb in apps.
- The boot's RAM-size probe is `moves.w $22000.l` = **4 words** → stacks the
  correct PC → survives. That is exactly why the RAM test passes but the OS
  handle-validation probes bomb.
- `fix_write` is **0** throughout (Q1), and the destination register is left
  **corrupted** (not the protected sentinel, not the cleared DIB — a partial
  faulted-read value), so even the data the probe reads back is garbage.

Corroboration: `sim.v:390` disables unmapped-address BERR with the comment
*"TG68 berr is not handler-recoverable"* — the sim authors hit this same bug and
worked around it by removing the only other BERR source, leaving FC7/`moves` as
the lone path (which is why the full-system sim never bombs but the FPGA does).

**Fix locus:** the Format-$B frame build must stack the *retire* PC
(faulting-instruction address + its decoded length), not the live prefetch-
advanced `TG68_PC`. In `rtl/tg68k/TG68KdotC_Kernel.vhd` that is the
`berr_frame_pc <= TG68_PC` capture (~3605 / ~3668) feeding the stacked PC; it
needs the end-of-instruction PC instead of the prefetch pointer. Cross-check the
resulting frame against MAME `maclc2`. (The `rte_mmu_fix` replay / bit-9 gate is a
*separate* concern and is NOT the lever here — Q1 shows it never fires for OS
probes anyway.)

## What was run (all headless, stock + nomemcheck ROMs)

| Run | ROM | Disk | Result |
|---|---|---|---|
| Heartbeat / rate | stock | none | ~0.3–0.5 fps; reached F25 in 70 s (`-v`) |
| Exp-A cpu-trace | stock | none | frames 8–11 traced; F9 fault flow captured |
| Exp-B deep | stock | none | RAM test to F315 (slow); killed |
| Exp-B nomemcheck | nomemcheck | none | OS init by F100; idle loop `$A06F0E` by F278 |
| Exp-B floppy | nomemcheck | Disk605.dsk | same idle loop by F283 (6.0.5 doesn't boot LC II) |
| Exp-B SCSI | nomemcheck | HD20SC…vhd | SCSI img *mounted* (target 6) but never read; same idle wedge |

Disk605.dsk = System 6.0.5 (predates the LC II → not bootable). The SCSI
HD20SC image mounts but the ROM never issues a SCSI read — the boot is consumed
by the Egret/ADB handshake (196k `EGRET[` + 20k `ADBLINE[` log lines by F307) and
never reaches the boot-device scan.

## Experiment A — the F9 RAM-size fault is abort-recover, NOT an RTE

cpu-trace (`--trace-frames 8,11`), runtime `$A0xxxx` = ROM `& 0x7FFFF`:

```
00003A82: move.b #$7,D1
00003A86: movec  D1,SFC            ; SFC = 7  (alternate address space)
00003A8A: 0E79 moves.w $22000.l,D1 ; <-- the probe. FAULTS (read of $22000)
00003A92: cmp.b  D1,D1             ; stacked berr_frame_pc = 0x3A92 = NEXT instr
00003A94: jmp    (A6)              ; <-- RECOVERY via jmp (A6), a pre-armed vector
```

- **No `RTE` ($4E73) anywhere** in the fault→recovery path. The handler discards
  the Format-$B frame and continues through a register continuation (`jmp (A6)`).
- Hence: no `[BERRFRAME] RTE`, and `rte_mmu_fix`/`fix_write` never arm for this
  fault. The boot survives the F9 fault independently of TG68's $B-frame RTE.
- The probe is **`moves.w`** (privileged alternate-space move, FC=7) — a
  deliberate RAM-presence probe, not the OS Memory-Manager handle probe.

## Refinements to the handoff hypothesis (important)

The handoff/findings assumed: *"plain Format-$B RTE resumes at the stacked =
faulting-instruction PC → re-runs the faulted access → derail."* The reachable
sim evidence **does not support the "re-run" part**:

1. For the F9 fault, TG68 stacks `berr_frame_pc = 0x3A92` = the instruction
   **after** the 8-byte `moves` — the **correct continue-past PC**. A plain RTE
   here would resume at the *next* instruction (continue past), not re-run.
2. `TG68KdotC_Kernel.vhd:3307-3315`: with `rte_mmu_fix_commit=0` (the non-bit9
   case), RTE takes `TG68_PC <= data_read` = the stacked PC. So *where* it lands
   is entirely determined by *what PC was stacked* — and the reachable case
   stacks the correct continue-past PC.
3. What the plain RTE does **not** do is the destination-register write from the
   stacked DIB (that is the gated `rte_mmu_fix` replay). So the live failure mode
   is more likely **"continue-past with a stale/garbage destination register"**
   (→ the OS validity check reads the wrong value → cascade) than **"wrong PC."**

This matters for the fix: if the OS (d16,An) probes also stack the next-instr PC,
the lever is the **missing register writeback** (extend `rte_mmu_fix` to fire on a
DF-cleared $B frame regardless of bit 9, and to handle `(d16,An)` not just `(An)`),
**not** a PC-restore change. If instead those probes stack a mid-instruction PC
(plausible for a complex EA), then PC *is* the issue. **This is the open question
and it needs the OS probe path, which the Egret/ADB wedge currently blocks.**

The hardware JTAG symptom ("RTE landed at A09B8A then 000000") is a *garbage PC*,
which argues for the mid-instruction-PC variant — but that path was not
reproducible in sim, so it stays a hypothesis, not ground truth.

## The blocker: Egret/ADB idle wedge at `$A06F0E`

All three boot configs converge to the *identical* state by ~F280 (`pc≈A06F0E,
a7=0x20FB46, a2=0x20FBDC`). Disassembly shows `$A06F0E` is the **OS task-dispatch
/ idle loop**:

```
A06EF4: move.l (a1),d0      ; walk the installed-task list
A06EFC: movea.l $8(a1),a0   ; a0 = node->handler
A06F04: jsr    (a0)         ; call each task (cursor/VBL/disk-poll/Egret)
A06F08: tst.w  d0 ; beq A06EF4
```

The system is alive and cycling tasks, but it never advances to the boot-device
scan — the Egret/ADB handshake dominates (per `CLAUDE.md`'s VIA-SR warnings). The
OS handle-validation continue-past probes (`$A0DBF8`/`$A08D14`, handler `$A0DB50`:
`andi.w #$feff,$a(a7); clr.l $2c(a7); rte`) fire from *inside* the heavy
Memory-Manager work that only happens once a disk boots — so they are unreachable
until the boot gets past Egret/ADB and actually loads a System.

## Recommended next steps (the fix)

1. **Fix the Format-$B stacked PC** in `rtl/tg68k/TG68KdotC_Kernel.vhd`: stack the
   retire PC (faulting-instruction address + decoded instruction length), not the
   live prefetch-advanced `TG68_PC`, at the `berr_frame_pc <= TG68_PC` capture
   (~3605 / ~3668). Re-run the unit test (`test_berrframe/`): all four probe forms
   should then land on their true next instruction. Then cross-check a real
   Format-$B frame against MAME `maclc2`.
2. **Regenerate `TG68KdotC_Kernel.v`** from the `.vhd` (GHDL is installed on this
   MacBook now) so the Verilator `.v` doesn't go stale after the kernel edit:
   `rtl/tg68k/convert_to_verilog.sh`.
3. **Re-validate** with the unit test + a boot smoke test, then on FPGA confirm
   the game "bus error" bomb is gone (the FPGA enables unmapped-BERR, so it hits
   the real OS probes). Consider whether the destination-register corruption also
   needs handling (likely moot once the PC is correct, since the probe's own
   result-check then runs).
4. *(Optional, separate)* the Egret/ADB boot wedge at `$A06F0E` still blocks a
   full-system sim boot-to-desktop; fixing it would let the SCSI boot reproduce
   the bomb end-to-end in sim. Respect the VIA-SR caveats in `CLAUDE.md`.

## Reproduce

```bash
cd verilator && make clean && make          # plain fast build (no --public-flat-rw)
# Exp-A (F9 Format-$B fault flow):
./obj_dir/Vemu --headless --trace-frames 8,11 --stop-at-frame 14 --rom ../releases/boot0.rom 2>err.log
grep -aE 'BERRFRAME' err.log ; sed -n '393,420p' cpu_trace.log
# Exp-B deep boot (will idle at $A06F0E ~F280; nomemcheck reaches OS init fastest):
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --stop-at-frame 800 \
  --rom ../releases/boot0-nomemcheck.rom --scsi0 /Users/dani/HD20SC-With-Benchmarking-and-CDROM.vhd 2>&1 | grep -aE 'BERRFRAME|HB\] F'
```
Note: `--no-cpu-trace`, `--trace-frames`, `--scsi0`/`--floppy0`, `--rom` are all
implemented though absent from `--help`.

# Focused Format-$B RTE unit test (answers Q2 in isolation):
cd verilator/test_berrframe && bash build_rom.sh          # needs m68k-elf-as/ld (brew)
cd .. && ./obj_dir/Vemu --headless --trace-frames 0,20 --stop-at-frame 20 \
  --rom test_berrframe/berr_rte_test.rom 2>&1 | grep -aE 'BERRFRAME'
#   -> DISP/RTE/landed_pc=A00042 ; probe (moves at $A0003C) should resume at $A00040
#      but lands at $A00042 (+2). Edit the `moves.l (%a1)` line to vary the probe form.
```
Run the test ONLY past ~frame 12 — the CPU's `debug_pc` tap reads 0 for the first
~10M cycles even though execution has started (true for the stock ROM too); a
short stop makes a working ROM look wedged.
