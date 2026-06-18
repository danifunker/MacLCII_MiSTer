# LC II post-MMU wedge — ROOT CAUSE & FIX: PMMU long-format early-term validity bug

**Date:** 2026-06-18  **Branch:** `030_LCii_rebased`
**Supersedes** the "bsr.w-family CPU address-datapath" framing in
`findings_1ff35a_mmuswitch_2026-06-18.md` and `handoff_lcii_postpmmu_2026-06-18.md`.
That framing was **WRONG**. The actual bug is in the **PMMU table walker**.

## TL;DR
`rtl/tg68k/TG68K_PMMU_030.vhd`, state `W_PAGE` (~line 3592), validated the page
descriptor with `desc_valid(walk_desc)`. For a **long-format (8-byte) descriptor**,
`walk_desc` holds the **LOW word** — the page's *physical base address*, which is
always ≥256-byte aligned, so its bits[1:0] are `"00"`. `desc_valid` returns
`desc(1:0) /= "00"`, so it flagged **every long-format early-termination page
descriptor as invalid (DT=00)** and raised a bus error.

The 68030's DT (descriptor type) for a long descriptor lives in the **HIGH word**.
The fix checks the DT in the correct word per format.

## Why it surfaced on the LC II boot (not before)
After the `_SwapMMUMode` 24↔32-bit handler runs `pmove (8,A0),TC` at `$A03F12`, the
live MMU is the **24-bit config**: `TC=$80F84500` (IS=8, 32KB pages), CRP aptr
`$3FE820`. That page table's root entries are **DT=01 long early-termination page
descriptors** (verified against MAME `maclc2`, `verilator/mame/pt_root10.lua`):

```
root[ 0] @003FE820 = 7FFFFC19 00000000  DT=1   -> phys $000000 (RAM 0-1MB)
root[ 1..3]                              DT=1   -> RAM 1-4MB
root[ 4..7] = 7FFFFC18 00000000          DT=0   -> INVALID (the 4-8MB RAM gap)
root[ 8] @003FE860 = 7FFFFC19 00800000  DT=1   -> phys $800000
root[ 9]                                  DT=1
root[10] @003FE870 = 7FFFFC19 00A00000  DT=1   -> phys $00A00000  (ROM!)
root[11]                                  DT=1
```

The instruction right after the `pmove TC` — `move.b d1,$cb2.w` at `$40A03F18` —
must be **fetched**. IS=8 strips `$40` → `$A03F18` → root index 10 → the DT=01
early-term descriptor above. Our walker read it correctly but the `W_PAGE` check
faulted on the LOW word → bus error → the `$1FF35A` derail the old docs chased.

(The old docs extrapolated "root[10] invalid" from root[4..7]; that was never
verified and is FALSE. ROM is fully mapped.)

## Evidence (decisive)
1. **MAME ground truth** (`/tmp/mame_pt10.txt`, trigger = `TC==$80F84500`): root[10]
   = `$7FFFFC19/$00A00000`, DT=01 VALID. MAME runs sustained at `$40Axxxxx`
   (root[10]) for hundreds of frames — so ROM IS mapped (refutes the i-cache theory
   too: a 256-byte cache can't cover that span).
2. **Our walker read the SAME valid descriptor then faulted** (`/tmp/pmmu3.log`):
   ```
   PMMU REQ #57 addr=003fe870 ... ws=1 -> ACK data=7ffffc19   (root[10] HIGH, DT=01)
   PMMU REQ #58 addr=003fe874 ... ws=2 -> ACK data=00a00000   (root[10] LOW = phys base)
   PMMU trap_berr addr=40a03f18
   ```
3. **Fault-class probe** (`tg68k.v` `PMMU FAULT` line, PMMU_TRACE): the fault is
   ```
   PMMU FAULT saddr=40a03f18 fstat=0400 (I=1) descaddr=003fe870 descdata=00a00000
   ```
   `fstat=$0400` = MMUSR **I-bit** (Invalid descriptor) — i.e. the `desc_valid`
   check. `descdata=$00a00000` = the LOW word it (wrongly) tested. root[1]
   (`$1FF35A`, base `$00100000`, RAM) faults identically — the old "frame push
   succeeds" note was a misread; it's just suppressed because `trap_berr` was
   already pending.

## The fix (`TG68K_PMMU_030.vhd`, `W_PAGE`)
```vhdl
-- BEFORE
if not desc_valid(walk_desc) then            -- walk_desc = LOW word for long descr!
-- AFTER (validate DT in the correct word per format)
if (walk_desc_is_long = '1' and not desc_valid(walk_desc_high)) or
   (walk_desc_is_long = '0' and not desc_valid(walk_desc)) then
```
`walk_desc_high` carries the long descriptor's DT (set at each level's HIGH read);
`walk_desc` IS the short-format descriptor. Reaching `W_PAGE` already implies
`desc_is_page` was true on the correct word, so this check is essentially a
belt-and-suspenders that must look at the right word. Regenerate the `.v`:
`rtl/tg68k/convert_to_verilog.sh` (ghdl 6.0.0), then rebuild Verilator.

## Verification
- **F200 boot trace** (`/tmp/verify200.log`, PMMU_TRACE build): `PMMU FAULT
  saddr=40a03f18` count = **0**; zero PMMU FAULT lines total. The only `trap_berr`
  are the 15 expected FC=7 MOVES hardware probes (`$00a03a94`). HB advanced past the
  old `$1FF35A` wedge to **`$A07A5A`** — the *same* post-mode-switch PC MAME shows at
  F260 (`pc=40A07A5A`). `$A07A4E..$A07A5E` is a calibrated `dbf` delay loop
  (`muluw #500,[$0D00]`), i.e. legitimate code, not a derail.
- **F400 run** (`/tmp/verify400.log`): still 0 PMMU faults. Boot ran the FULL
  post-MMU path — distinct HB PCs march through `$A3C1xx`/`$A3C232` (MAME's F300
  region), `$A05A3E`, `$A09Bxx`, the `$A14xxx` jump-table dispatcher, `$A0A8Ex`,
  `$A15194`, `$A0DB78`, `$A16D06`, `$A2E80A`, `$A4B9xx`, `$A06ED0..$A06F0E`. By
  F376-400 it sits in the `$A06EF4..$A06F0E` linked-list-walk-with-callback loop
  (`movel (a1),d0; jsr (a0); tstw d0; beq` — normal OS init dispatch, not a derail).
  `screenshot_frame_0399.png` = uniform grey + live mouse cursor (the documented
  pre-desktop-fill state; MAME shows the same grey here). Video path fine.
- **Status:** the CPU/PMMU bug is FIXED. A possible NEXT divergence: at F340-420
  MAME bounces in `$A0A8Ex`/`$A148EC` while ours settles in the `$A06F08` list walk
  — investigate separately (likely a peripheral/event, not a CPU fault).

## Tooling (PMMU_TRACE, `tg68k.v`)
Added `PMMU FAULT` log on the `pmmu_fault` rising edge: fault-status class
(B/L/S/W/I), faulting logical addr, walk state, last descriptor addr/data. Wired
`debug_pmmu_fault_status`/`debug_pmmu_fault`/`debug_pmmu_walk_desc_addr/data`.
New MAME oracle: `verilator/mame/pt_root10.lua` (dumps root[0..15] + decodes
root[10], triggered when `TC==$80F84500`). **Re-comment `PMMU_TRACE` in
`verilator/Makefile` before any FPGA/normal build.**
