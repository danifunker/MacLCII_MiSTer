# MAME handoff: confirm + characterize the TG68 PMMU mistranslation at $A416xx (2026-06-22)

**Run this on the MacBook (MAME lives there).** Goal: get 68030 ground truth for the bug that
HW JTAG confirmed but can't fully inspect. Full root-cause writeup: `docs/findings_berr_hw_pctrace_2026-06-22.md`.
MAME process + gotchas: `docs/mame_compare.md` (heed them — macOS no `timeout`, debugger default CPU is the
Egret HC05 not maincpu, PCs are 8-digit `00Axxxxx`, install Lua taps on `register_frame_done`).

## The bug in one paragraph (HW-confirmed)
On real hardware the LC II boot reaches a low-level **MMU reconfiguration routine at ROM `$A416xx`**
(`$A4168E` link a5,#-124; … `$A41716 pmove (fp),crp`; `$A4171E pmove (a3),tc`). At `$A416B8`
(`bsr.w $A41B8E`) the CPU is **logically in ROM** (`exe_pc=$A416B6`) but the next program fetch lands
on **physical high-RAM `$9FEE40`** (garbage) → derail → Sad Mac `0000000F`. The MMU is already ON
(earlier `pmove tc` at `$A0006E`/`$A03EB2`). The `$A416` page translates 1:1, but the `bsr` target
page `$A41B` mistranslates to `$9FExxx` (target wobbles per boot: `$9FE876`,`$9FEE40`). TG68's PMMU is
producing a wrong physical for a ROM-logical page. (The FC7 `moves.w $22000` faults are a red herring —
they recover; the Format-$B continue-past fix is a no-op here.)

## Config to match HW
- **ROM:** HW runs `releases/boot0-nomemcheck.rom`. MAME's goodrom is `350eacf0.rom` (== stock
  `boot0.rom`). The nomemcheck patch should only touch the RAM test, not the MMU routine — but VERIFY:
  disasm both at `$A416xx` and confirm `$A4168E..$A4171E` is byte-identical. If not, run MAME with
  `boot0-nomemcheck.rom` (custom rompath / `-ignore_crc` style override). The `$A416xx` addresses in
  this doc are from `boot0-nomemcheck.rom` (runtime = ROMdoc `$40800000`+off; off = runtime&0x7FFFF).
- **RAM size:** the derail lands at `$9FExxx` (~10 MB), and the MMU table depends on RAM size, so run
  `-ramsize 10M` (also try `2M`). Confirm the HW core's active RAM config (OSD) and match it.

## Q1 (decisive) — does MAME execute $A416xx correctly, or derail too?
```bash
cd <repo>/verilator/mame
RAMSIZE=10M ./run_mame.sh -debug -debugscript trace.dbg -seconds_to_run 15   # -> /tmp/maincpu.tr
grep -nE "^00A416(8E|A0|B0|B2|B6|B8|BA|BC):" /tmp/maincpu.tr | head -40
```
- If MAME steps `…00A416B8: bsr … -> 00A41B8E: …` and **boots on** (reaches the desktop / never
  fetches high-RAM `$009Fxxxx`), the mapping is 1:1 and **TG68 is wrong** ⇒ it's a TG68 PMMU bug. Proceed to Q2/Q3.
- If MAME ALSO ends up executing physical `$9Fxxxx` (logical PC stays `$A41Bxx` but it's a ROM→RAM
  shadow that MAME populated and TG68 didn't), then the bug is a **missing ROM-to-RAM shadow copy**
  in our core, not the PMMU walk. (Check: does MAME ever `move`-copy ROM `$A4xxxx` to RAM `$9Fxxxx`
  before `$A416xx`? grep the trace for writes into `$009Fxxxx`.)

## Q2 — what is the CORRECT translation of logical $A41B8E?
In the MAME debugger (target **maincpu**), at/near `$A416B8`:
```
# break when we reach the routine (data watchpoint is more reliable than a PC bp on 68020/030):
wpset <addr_of_a_global_this_routine_writes>,4,w     # or: bpset 0x00A416B8 ; g
# then read the 68030 MMU regs + translate:
print pmmu_tc ; print pmmu_crp ; print pmmu_srp      # exact cmd names per MAME 0.287 68030 dbg
translate 0x00A41B8E,p                                # logical->physical (program space)
# dump the page-table descriptors the walk uses (CRP root -> level tables in RAM):
dump /tmp/crp.bin,<crp_base>,0x40
```
Capture: **TC** (E bit, page size, TIA/TIB/TIC/TID), **CRP/SRP root**, and the **descriptor at each
walk level** for `$A41B8E`, plus the **resulting physical** (expected ≈ `$00A41B8E` if 1:1). This is
the oracle to compare against TG68's walk.

## Q3 — capture the descriptor bytes so the TG68 walk can be hand-checked
Tap the maincpu reads of the page-table region during the `$A416xx` window (the descriptors live in
high RAM — our HW saw a sDAT read at `$9FFFAC` that may be a descriptor):
```bash
TAP_LO=0x009FF000 TAP_HI=0x009FFFFF TAP_MODE=r TAP_OUT=/tmp/ptes.txt ./run_mame.sh -autoboot_script tap.lua -seconds_to_run 15
```
(Adjust the window once CRP base is known from Q2.)

## What I need back here (to fix TG68 on the Windows box)
1. Q1 verdict: TG68-bug vs missing-shadow-copy.
2. TC value, CRP/SRP root, and the per-level descriptors for `$A41B8E` (the correct walk).
3. The correct physical for `$A41B8E`.
With (2)+(3) I can compare against TG68's PMMU table-walk (`rtl/tg68k/TG68KdotC_Kernel.vhd`, the
`pmmu_*` ATC/walk state machine) and pinpoint the divergent step, then fix + rebuild + re-validate on HW.

## State of the working tree (this branch, uncommitted)
- `rtl/tg68k/TG68KdotC_Kernel.vhd`: the (no-op-for-this-bug) Format-$B `berr_setup_*` continue-past
  fix + the `debug_TG68_PC` reroute (`kernel_tg68_pc`).
- `rtl/dbg_probes.sv` + `scripts/cpu_state.tcl`: PFR0-3 are the bus-txn / logical-vs-physical derail
  trace (NOT the original first-fault recorder). `rtl/tg68k/tg68k.v` + `MacLC.sv`: `dbg_tg68_pc` tap.
- These are DEBUG; revert or keep per the eventual fix.
