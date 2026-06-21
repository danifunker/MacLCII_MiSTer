# Findings: LC II bus-error bomb — `rte_mmu_fix` replay mis-fires on Mac OS BERR probes (2026-06-20)

**Status (CORRECTED 2026-06-20, later):** Pass-1 (disable the replay) was **WRONG — REVERTED.**
The replay is **opt-in via SSW bit 9** ("software-fix request"): the build sets a data-fault
SSW with bit 9 = 0 / bit 8 (DF) = 1, and the gate requires bit 9 = **1** and bit 8 = **0** — so
the replay only fires when a handler explicitly sets bit 9. The **boot's** MMU/page-fault handler
sets it (so disabling the replay broke the boot — black-screen hang), but the OS probe handler at
`$A0DB50` only clears bit 8 (`andi #$feff`) and does **not** set bit 9, so the replay **never fired
for the probe** and was **never the bomb's cause.** The original analysis below (and the subagent's)
missed the bit-9 gate. **Real cause is still open** — most likely TG68's Format-$B RTE handling of
the OS "continue-past" probe (it resumes at the stacked = faulting-instruction PC with no
mid-instruction continue, so the access likely re-faults). **Needs ground-truth instrumentation
before any further code change** — no more static guesses. The analysis below is retained for the
mechanism/evidence, but its pass-1/pass-2 conclusions are superseded by this note.

Running a game on the `MacLCii` build (commit `3230bea`) bombs with *"Sorry, a system
error occurred. bus error."* Root-caused via JTAG probes + ROM disassembly to a CPU-core
defect: the 030 `rte_mmu_fix` replay fires on Mac OS's bus-error-probe `RTE` and corrupts
the return PC.

## Evidence — JTAG ISSP probes (`scripts/cpu_state.tcl`, captured at the bomb)

```
PEXC last fatal : faulting IF=A0DBFC vec=2 (BUSERR) fires=11
PFR recorder    : frozen=1 cause=BERR-NEAR-DEATH  berr_trigs=255   <- storm/maxed
  faulting IF=A08D18 (prev A08D16)
  handler RTE landed at: A09B8A then A0E150   <-- garbage = TG68 frame bug
PSDT dma timeout: berr_fires=0    <- NOT a SCSI-DMA-stall BERR
PSDS stall-snap : CAPTURED phase=DATA_IN(wr) ~16.08 ms  <- the game's disk load (incidental)
PEX3 1st ILLEGAL: A0C9E6 (BlockMove loop run with corrupted pointers — cascade)
```

## Mechanism — ROM disasm (`boot0.rom`, $350EACF0; runtime `$A0xxxx` = ROM `addr & 0x7FFFF`)

Mac OS uses **BERR-protected probes** everywhere — save the BERR vector, install a temp
handler, touch a maybe-bad address, catch the fault, recover. Both fault sites are this:

- `$A0DBF8 movea.l $8.w,a2` / `$A0DBFC lea $a0db50(pc),a3` / `$A0DC00 move.l a3,$8.w`
  — Memory Manager **handle validation** (touches `$38(a6)` under BERR protection).
- `$A08D14` — same pattern around a dispatch call.

Recovery handler at **`$A0DB50`**:
```
andi.w #$feff, $a(a7)   ; clear bit 8 of the SSW at exception-frame +$0A
clr.l   $2c(a7)         ; clear the data-input-buffer field at +$2C
rte                     ; CONTINUE past the faulted access (do not re-run it)
```
Offsets `+$0A` (SSW) and `+$2C` are the **68030 long bus-error frame (format $B)**. The
handler clears the SSW rerun bit and `RTE`s to continue. TG68 *does* build a correct
format-$B frame — the defect is on the `RTE` consume side.

## Root cause — `rtl/tg68k/TG68KdotC_Kernel.vhd`

The `030_mmu2` kernel merge pulled in a WinUAE-derived **"software-fixed MMU data-fault
replay"** (`rte_mmu_fix_*`). On `RTE` of *any* format-$B frame it re-reads the stacked
SSW/opcode/data-buffer and, if gated, injects a register write + `TG68_PC+2`:

- **Gate** `rte_mmu_fix_write` (lines **1569–1590**) requires `rte_mmu_fix_ssw(8)='0'`
  (line **1575**), plus `ssw(9)=1, ssw(7)=0, ssw(6)=1` and a `MOVE/MOVEA (An)` opcode.
- The OS handler's `andi.w #$feff,$0A(a7)` **clears SSW bit 8** → **satisfies the gate.**
- **Arming** (lines **1767–1773**) is *unconditional* for any `$B` frame at `rte4`,
  defeating the `trap_mmu_berr`-origin intent at lines 1751–1760.
- **Commit** (line **1591**) → `TG68_PC+2` (lines **3307–3308**) + register writeback
  (lines **1964–1990**) — the register is written from the data-input-buffer the handler
  *just cleared to 0*.

So the OS's normal "continue past the probe" `RTE` gets a phantom register write + a +2 PC
bump → returns one instruction word off → garbage execution → vector-2 storm → bomb. It
was never caught because the merge was validated only against boot + the single-instruction
SingleStepTests bench, neither of which exercises the OS BERR-probe `RTE` path.

## Pass 1 — this build (pending hardware test)

`TG68KdotC_Kernel.vhd:1569` — flip the replay enable from `'1' when` to `'0' when` (gate
kept intact + commented). Mac OS does its own recovery; it does not need the replay.

**Test:** boots to desktop cleanly **and** the game no longer bombs **and** `PFR berr_trigs`
no longer storms. If so → diagnosis confirmed.

## Pass 2 — narrow fix (if pass 1 confirms)

Re-arm `rte_mmu_fix` only for TG68's **own** MMU-origin faults (gate the `rte4` arm at
1767–1773 on `trap_mmu_berr` / the captured fault origin, not merely `rte_format_word="1011"`),
so genuine 030 MMU software-fix replay still works for the boot path that needs it.

## Secondary (watch)

`berr_frame_pc` consistency: the PMMU-fault path freezes `TG68_PC` at the faulting
instruction (lines 3185–3199, 3668); an external `make_berr` is registered (one cycle late).
TG68's format-$B `RTE` has no rerun engine — it resumes at the stacked PC. Confirm both
paths stack the continuation PC the OS expects (cross-check MAME `maclc2`).

## Toolchain note

Quartus compiles the **`.vhd` directly** (`TG68K.qip`), so this fix builds without GHDL.
The Verilator `.v` (`TG68KdotC_Kernel.v`) is regenerated from the `.vhd` via
`convert_to_verilog.sh` (needs GHDL 6.0.0) — **not installed on the current build box**, so
the `.v` is stale after this edit (sim only; FPGA unaffected). **Regenerate the `.v` before
committing** or sim and FPGA desync.
