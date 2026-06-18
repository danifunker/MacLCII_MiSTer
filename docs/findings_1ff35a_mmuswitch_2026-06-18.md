# LC II `$1FF35A` wedge — root cause: spurious 24↔32-bit MMU-mode-switch `pmove` (NOT a jmp)

**Date:** 2026-06-18  **Branch:** `030_LCii_rebased`
**Follows** `findings_postpmmu_bsrw_2026-06-17.md` (the bsr.w/PMMU-stall fix `c8895d8`, which
cleared the F154 `$FFFFxx` derail and let the boot run the whole `$40A` alias POST).

## TL;DR
The resume's framing of this blocker was wrong. There is **no `jmp ($2,PC,D5.w)` to
`$1FF35A`** — that disassembly was **misaligned**. The real wedge:

1. The boot takes an **A-line trap** → A-line dispatcher `$A099B0`
   (`jsr ([$400,d2.w*4])`, the low-mem trap-vector table) → handler **`$A03ED8`**, the
   **24↔32-bit address-mode-switch routine** (`_SwapMMUMode`-class).
2. `$A03ED8` branches on the mode flag **`[$0CB2]`**. In our core `[$0CB2]` is **nonzero**
   (`$46`); in MAME it is **`0`**. With a nonzero flag we run the `pmove` reconfig
   (`$A03EFC..$A03F12`: `pload`/`pmove TT0`/`TT1`/`CRP`/**`pmove (8,A0),TC`**); MAME (flag=0)
   **skips it** (`beq $a03f2a`).
3. Right after our `pmove (8,A0),TC` re-enables/reprograms the MMU, the next data write
   (`move.b d1,$cb2.w`, logical `$0CB2`) mistranslates to garbage **`$fffffff2`** → **bus
   error** → 92-byte format-$B berr frame (A7 `$1FF35E`→`$1FF302`) → berr recovery loads PC
   from inside the just-pushed frame → PC = **`$fffff380`**. The per-frame `[HB]` then samples
   this derail as the "`$1FF35A` spin" (it actually reads `$001FF35A` for data while
   PC=`$fffff380`).

So the wedge is a **downstream symptom of taking a path MAME never takes**, gated by one wrong
low-memory byte (`$0CB2`).

## Evidence
- Cycle trace (`/tmp/disp.log`, A30[DISP] probe): the derailing instruction is `pmove`-family
  (micro-states `pmove_decode`=85, `pmmu_ld_dAn1`=98, `berr_fill`=113), EA → `$fffffff2`,
  then PC ← `$fffff380` read from `$001FF35A`.
- ROM disasm (capstone mis-renders cpid-0 MMU ops as FPU; objdump `-m68030` shows the truth):
  `$A03EFC ploadr #5,(8,A0)` · `$A03F02 pmove (12,A0),TT0` · `$A03F08 pmove (16,A0),TT1` ·
  `$A03F0E pmovefd (A0),CRP` · `$A03F12 pmove (8,A0),TC` · `$A03F18 move.b d1,$cb2.w`.
- MAME oracle (`verilator/mame/mmu_state.lua`, per-frame, reads bypass d-cache): after MMU
  enable (TC `$000046FC`→`$80F84500`, ~F260) MAME has **`[$0CB2]=00`**, `[$0CB4]=$003FFFBE`,
  `[$0CB8]=$003FFFAA`. Our `[$0CB4]/[$0CB8]` **match** (= `A1-$2E`/`A1-$42`, A1=`[$0DDC]`=
  `$3FFFEC`); only `[$0CB2]` differs.
- The handler family (`$A03E84..$A03F62`) is the mode switch: paired `beq`/`bne` on `$0CB2`
  install (set) and remove (clear) the 32-bit MMU config around a critical section; the setup
  `$A03E0C` writes `clr.b $cb0.w` + `move.b #$1,$cb2.w` + `move.l a0,$cb4/$cb8.w` and stages a
  continuation vector at `$0DBC`.

## RESOLVED by the `$0CB0-$0CBF` watchpoint: byte-write is FINE; `$0CB2` is just never cleared
The `A30[CB]` watchpoint (logs every `$0CB0-$0CBF` bus access with UDS/LDS + data + PC, no
filter) shows:
```
WR addr=00000cb2 uds=0 lds=1 data=0101(hi=0001) cyc=12374689   # move.b #1,$cb2.w  -> $0CB2=$01 (UDS, correct!)
RD addr=00000cb2 uds=0 lds=1 data=010d(hi=0001) cyc=12462725   # fatal read: $0CB2 = $01
```
- **The byte write is CORRECT** — even-byte → UDS asserted, `$01` to the high lane; the fatal
  read confirms `[$0CB2]=$01`. **Byte-lane bug RULED OUT.** (The earlier "`$46`" came from the
  DISP probe's `dbg_data_read` — a lagged/pipelined register, NOT the bus data; same
  data_read-lag artifact that misled earlier root causes. The CB watchpoint reads `din`.)
- **`$0CB2` is written exactly ONCE** (the setup `$01`) and **never cleared** — no
  `move.b d1,$cb2.w` clear ever fires. MAME's `$0CB2` reaches `0` because its mode switch
  *completes* and clears the flag; ours stays `$01`.

So our 24↔32-bit switch never completes the clear — because the install step (`pmove TC`
reconfig) **bus-errors in our PMMU**, so we never reach the remove/clear stage. The chain is:
`$0CB2=$01` (correct) → handler runs `pmove TC` reconfig → **our PMMU page-table walk for the
next access (`$0CB2`) returns garbage `$fffffff2`** → bus error → derail. (`$fffffff2` is the
faulting PHYSICAL address = our broken translation of logical `$00000CB2`.)

## CONFIRMED ROOT CAUSE: PMMU page-table-walk bug on the 24-bit reconfig
MAME's two mode configs (read via `verilator/mame/mmu_descr.lua`, descriptor blocks the
pmoves load):
- `[$0CB4]`→`$3FFFBE` = **24-bit** mode: CRP=`$7FFF0003:$003FE820`, **TC=`$80F84500`** (IS=8),
  TT0=TT1=`0`, +14=`$04000000`.
- `[$0CB8]`→`$3FFFAA` = **32-bit** mode: CRP=`$7FFF0003:$003FEE00`, TC=`$80F05750` (IS=0),
  TT0=TT1=`0`, +14=`$7FFF0003`.

MAME's **live** MMU = the 24-bit config (TC=`$80F84500`, CRP aptr=`$3FE820`, TT0=TT1=`0`,
PSR=`0`). The `$A03ED8`/`$cb4` handler loads exactly this 24-bit config. So after the pmove,
ALL translation (incl. the `$40A` alias and low mem) goes through the page-table walk from
CRP (TT is OFF). MAME walks `$0CB2`→physical `$0CB2` fine; **our walk produces `$fffffff2`**.

CRP HIGH `$7FFF0003`: DT=`11` (long table descriptor), Limit=`$7FFF` (none), aptr=`$3FE820`.
TC=`$80F84500` decodes to IS=8, PS=15 (32KB pages), TIA=4, TIB=5, TIC=TID=0 (sum=32 ✓).
For `$0CB2` the index math is trivially 0 at both levels, so the failure is NOT the index
extraction (`get_table_index` checks out). **Fix lives in `rtl/tg68k/TG68K_PMMU_030.vhd`.**

MAME's live 24-bit page table (`mame_pagetable.lua`): CRP aptr=`$3FE820`, root descriptors are
DT=01 **early-termination page descriptors**, one per 1MB, identity-mapping the 4MB RAM:
`root[0]@$3FE820 = HIGH $7FFFFC19 / LOW $00000000` → `$0CB2`→physical `$0CB2`. root[4+] invalid.

`PMMU_TRACE` capture (gated to `$A03xxx`):
- **Fatal: `PMMU trap_berr addr=40a03f18`** — confirmed the `move.b d1,$cb2.w` (logical `$0CB2`)
  bus-errors at PMMU level, exactly as predicted (`$0CB2`→`$fffffff2` unmapped).
- The 15 `make_berr addr=00a03a92` are the handled `movec #7,sfc; moves.w $22000` FC=7
  hardware probes (deliberate, NOT the wedge).
- **ZERO `PMMU REQ`/`PMMU ACK` (no page-table walk) anywhere** — though the REQ/ACK gate keys on
  `tg68_addr`=PC so a `$0CB2` data-access walk (PC≠`$A03`) could be missed. Still, combined with
  the reconfig disabling TT (TT0=TT1=0) and using `pmovefd`(FD)/`pload` (no full flush), the
  leading hypothesis is **a STALE/WRONG ATC entry for `$0CB2`** surviving the reconfig (or our
  PLOAD / post-reconfig translation path), NOT a fresh walk bug.

## FINAL ROOT CAUSE (2026-06-18, decisive): NOT a PMMU bug — the `move.b` EA = its PC
The ATC IS flushed on `pmove TC` (FD=0 → `atc_flush_req<='1'`, lines 1128 + 4004-4006), and the
loaded config is CORRECT (`crp=$3fe820`, `tc=$80f84500`, matching MAME). The walk capture
(`tg68k.v` now wires `debug_pmmu_saved_addr/crp_lo/tc/wstate` into `PMMU REQ`) shows:
```
PMMU REQ #57 addr=003fe870 log=40a03f18 crp=003fe820 tc=80f84500 ws=1  ... we=0
PMMU trap_berr addr=40a03f18
```
**`log=` (the logical address the PMMU is asked to translate for `move.b d1,$cb2.w`) is
`$40A03F18` — the instruction's OWN PC — not `$0CB2`.** IS=8 strips `$40` → `$00A03F18` →
root[10] → physical ROM `$00A03F18`; the WRITE to ROM faults → `trap_berr addr=40a03f18` →
derail. Cross-checked in the A30 trace (cyc 12462820): `memreg=0 memdelta=40a03f1a
addr=40a03f18` — the absolute-short EA is the PC, the fetched `$0CB2` extension word never
reaches `memaddr_delta`. (`pmmu_addr_log_int <= memaddr_reg + memaddr_delta`, kernel L2785.)
The earlier "`$fffffff2`"/"run-to-run non-determinism" was a misread of the lagged
`dbg_data_read` and of the berr-frame fill — the real, consistent mechanism is EA=PC→ROM write.

**So the bug is a CPU address-datapath bug (kernel `TG68KdotC_Kernel.vhd`), bsr.w-family —
NOT the PMMU.** Prime suspect: the committed bsr.w-fix HOLD (lines 2764-2768,
`IF pmmu_busy='1' AND state(1)='1' THEN hold use_base/memaddr_delta_rega/regb`) **over-holds
during the `move.b`'s absolute-short operand fetch** (which is also `state(1)='1'` + a PMMU
stall), freezing `memaddr_delta` at the PC so `$0CB2` is never latched. The hold must protect an
*in-flight, already-addressed* access (the bsr.w push) WITHOUT blocking the *next* instruction's
EA build. Needs careful microcode work — the hold is load-bearing for the bsr.w push.

**Next (to fix):** narrow the hold so it doesn't freeze the EA datapath while an operand/
extension-word fetch is establishing the next access's address (distinguish "access issued &
stalled" from "EA still building"). Then re-validate: (1) the bsr.w push still commits both
words / boot still clears the F154 derail; (2) the `move.b` now writes `$0CB2` and the mode
switch completes (`$0CB2`→0, boot past F156 toward the desktop); (3) MacIIvi SST CPU bench
(714/719) + 40-test PMMU corpus — no regression. The committed bsr.w fix `c8895d8` is the thing
being refined, NOT discarded.

## UPDATE (confirm-step REFUTED the over-hold; the real trigger is a fetch-stall)
The `A30[MOVB]` per-cycle EA-build trace (tg68k.v wires `debug_pmmu_busy`/`debug_memaddr_delta_rega`)
shows the over-hold is NOT the cause:
```
cyc 12462814-18  ust=0 pc=40a03f18 st=00(FETCH) pbusy=1 drega=40a03f18   # move.b INSTR FETCH stalls on a walk (ATC flushed by pmove TC)
cyc 12462819     ust=0 pc=40a03f18 st=00 pbusy=0 drega=40a03f18 dread=11c1
cyc 12462820     ust=0 pc=40a03f1a st=00 pbusy=0 drega=40a03f1a          # fetch the $0CB2 word; EA STILL = PC
cyc 12462821     ust=113(berr_fill) ss=11(WRITE) addr=fffffff2            # data write faults
```
- During the EA cycle (12462819-20) **`pbusy=0`** → the bsr.w hold (`pmmu_busy AND state(1)`)
  does NOT engage. **Over-hold REFUTED.**
- The `move.b` **never enters `ld_nn`/`st_nn` (ust=2/3)** — the absolute-short EA setup is
  **SKIPPED**, so `memaddr_delta` keeps the PC and the byte write targets `~$40A03F18` (its own
  PC → ROM → write fault → berr). (`$fffffff2` at cyc 12462821 is the berr-frame fill, not the EA.)
- ROOT TRIGGER: the `move.b`'s **instruction fetch STALLS on a PMMU walk** (cyc 12462814-18,
  5 cycles — the ATC was just flushed by `pmove TC`, so the fetch of `$40A03F18` and the
  `$0CB2` extension word must walk). That fetch-stall **disrupts the decode so the absolute-EA
  micro-sequence (`ld_nn`) is never entered.** Same FAMILY as bsr.w (PMMU stall corrupting the
  address datapath) but a DIFFERENT manifestation: a stalled *instruction/extension fetch*
  derailing the *next EA's* setup, not a data-write redirect.

**Revised fix direction:** ensure an instruction/extension-word fetch that stalls on a PMMU
walk does NOT skip the following EA micro-sequence — i.e. the decode/micro-sequencer must
resume the absolute-EA path (`set(addrlong)`/`ld_nn`) after the fetch-stall, instead of
falling through to the default PC-based EA. NEXT diagnostic to pinpoint the RTL: log
`set(addrlong)` / the EA-mode decode signals + `micro_state`/`next_micro_state` across the
`move.b` decode (cyc 12462814-12462821) to see exactly where the `ld_nn` transition is lost.
This is deeper microcode work in `clkena_lw`/micro_state sequencing under `pmmu_busy` (kernel
line ~1451/6002), NOT the bsr.w hold. The hold + the committed `c8895d8` fix are unaffected.

## UPDATE 2 (decode-sequence trace — the move.b NEVER decodes; a bus error preempts it)
Wiring `debug_next_micro_state/opcode/last_opc_read/set_addrlong/decodeOPC/clkena_lw` into the
`A30[MOVB]` trace shows the EA-skip framing is incomplete. The actual sequence:
```
cyc 12462814-18  ust=0 opc=f028(pmove) pbusy=1 clw=0 drega=40a03f18   # move.b INSTR FETCH stalls on a walk
cyc 12462819     ust=0 opc=f028 pbusy=0 clw=1 addr=40a03f18           # fetch completes (returns $11C1)
cyc 12462820     ust=0 opc=4e71(NOP-FORCED) lopc=11c1 nxt=113(berr_fill) addr=40a03f18
cyc 12462821     ust=113(berr_fill) ss=11 ubase=0 drega=fffffff2 addr=fffffff2   # corrupted 1st frame write
cyc 12462822     ust=113 ss=11 ubase=1 drega=fffffffc(-4) memreg=1ff35e addr=1ff35a  # proper stack pushes
```
- `opcode` goes `$f028` → **`$4E71` (NOP, forced by `setinterrupt`)** — it **never becomes
  `$11C1`**. The `move.b` is fetched (it's in `lopc=11c1`) but **never decodes**: a **bus-error
  exception preempts it** at the instruction boundary → straight to `berr_fill`.
- So the fault is NOT the `move.b`'s data write — it's an **earlier access** (during the
  `pmove TC` operand reads / a descriptor walk / the fetch) that bus-errored and set the pending
  exception. The recorded fault address / first frame write is the **wild `$fffffff2`**
  (`use_base=0`); subsequent frame pushes correctly target the stack (`$1FF35A`).
- Same bsr.w address-datapath FAMILY, **pipeline-race-sensitive** (fetch-stall + multi-word
  `pmove` + exception entry interact). MMU config loaded is correct (`crp=$3fe820`,`tc=$80f84500`,
  =MAME); MAME skips the whole path (`$0CB2=0`).

**NEXT diagnostic (to pin the faulting access before any fix):** instrument the `make_berr`
trigger — log, at `kernel_make_berr`'s rising edge, the faulting logical+physical address, the
SSW/fault-status, `micro_state`, and which access (fetch vs operand-read vs walk) was in flight.
Only then is the fix targetable. The fix is a delicate microcode change in the
`pmove`-TC → next-access → exception path (bsr.w family); the committed `c8895d8` + the hold are
unaffected and must not regress. Probes added this session (all `ifdef`-guarded): `A30[MOVB]`
decode-sequence trace + the wired `debug_pmmu_*`/`debug_next_micro_state`/`debug_set_addrlong`
etc. in `tg68k.v`.

## Tooling added this session (all under `A30_TRACE`, ifdef-guarded; Makefile has the define)
- `A30[DISP]` (tg68k.v): instruction-boundary trace of the continuation→dispatcher→wedge path.
- `A30[CB]` (tg68k.v): `$0CB0-$0CBF` byte-lane watchpoint.
- `verilator/mame/mmu_state.lua`, `mmu_reconfig.lua`, `isr_probe.lua`: MAME maclc2 probes
  (per-frame `[$0CB2]`/`[$0CB4]`/`[$0CB8]`/`TC`; data taps; note CODE read-taps DON'T fire
  post-cache — the boot enables the i-cache, so tap DATA, and MAME 68030 program-space taps
  see the LOGICAL `$40A` alias, not bare `$00A`).

## NOT the bsr.w bug
The committed `c8895d8` 3-part fix is good and still needed (push commits both words, rts
returns to `$40A00130`). This is a **separate, later** divergence.
