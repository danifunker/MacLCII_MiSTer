# LC II post-MMU derail — DEFINITIVE root cause: bsr.w push corrupted by a PMMU-stall address race

**Date:** 2026-06-17 (evening)  **Branch:** `030_LCii_rebased`
**Supersedes** every earlier root-cause framing in `findings_postpmmu_divergence_2026-06-17.md`
and `handoff_lcii_resume_2026-06-17.md`. Those were ALL wrong:
- ❌ "CPU drops the `$40` alias bit (A30) from PC/EA" — it does NOT. The CPU jmps to
  `$40A0010E` correctly and runs the whole continuation in the `$40A` alias (verified:
  `debug_TG68_PC=$40a0010e`, `reg_QA=$40a0010e`; A2/A3/A6 all carry `$40`).
- ❌ "SP overlaps `$c04/$c08` / low stack pointer" — A7 is `$001FF3C8`/`$1FF3C4` at the
  continuation/rts, which **matches MAME** (`$1FF3xx`). The "SP=$000C06" reading came from
  the lagged cpu_trace `@data_addr` (it was the `move.l $c04,$c08` operand, not SP).

## The actual bug (cycle-level, verified by fresh sim instrumentation)

The LC II boot, after MMU-enable, relocates A7 to a **freshly-mapped** stack page (`$1FF3xx`,
set at `$00A4178C movea.l D0,A7`) and runs the continuation at the **`$40A` alias**. At
`$40A0012C bsr.w $a00910` it must push the return `$40A00130` to `-(A7) = $1FF3C4`.

What actually happens (from the `A30[STK]`/`A30[UST]` probes, fastmem ROM, ~cyc 12 359 310):

1. `bsr.w` is handled by the **`bsr2`** microstate, which asserts `setstate="11"` (the push
   write) **and** `TG68_PC_brw` (the branch) in the same state.
2. The push write to `$1FF3C4` **misses the ATC** (first touch of the relocated page) →
   PMMU table walk → `pmmu_busy=1` → `busstate="01"` for ~8 cycles (cyc 12 359 310–318).
3. During that stall `micro_state` **correctly freezes** at `nopnop` — because
   `clkena_lw` (which gates `micro_state <= next_micro_state`, kernel line ~6002) is
   `clkena_in AND memmaskmux(3) AND pmmu_busy='0'` (line 1451), so it's held.
4. **BUT the address datapath is NOT held.** `addr`, `memaddr_reg`, `memaddr_delta`,
   `pmmu_addr_log_int` are *combinational* off `memaddr_delta_rega`/`use_base`, which are
   *registered on `clkena_in`* (kernel line 2502) — and `clkena_in` **keeps firing during
   `pmmu_busy`** (the walker needs it). `nopnop`'s default `setstate="00"` re-latches
   `memaddr_delta_rega <= TG68_PC_add` (line 2712). Because `bsr2` set `TG68_PC_brw`,
   `TG68_PC_add` = the **branch target `$40A00910`**. So mid-stall the write address flips
   `$1FF3C4 → $1FF3C6 → $40A00910` and freezes at `$40A00910`.
5. When the walk completes the write commits to **`$00A00910`** (`$40A00910` translated —
   the jump target, in ROM-alias space) instead of `$1FF3C4`. Proof:
   `A30[STK] WR addr=00a00910 data=0130` and **no write to `$1FF3C4` anywhere**.
6. The real stack slot `$1FF3C4` stays `$0`. The routine's `rts` at `$a00948` reads SP
   (`A7=$1FF3C4`, correct) and pops **`$0`** → `PC=$0` → runs zeroed low memory →
   `$FFFFxx` wander (HB F154+). That is the "no desktop checkerboard."

MAME, on the same ROM, sustains the `$40A` alias (396 HB samples post-F303, never bare
`$00A0xxxx`) and reaches the `?` floppy screen — i.e. its `bsr.w` push lands correctly.

## Why it masqueraded as so many other bugs
- The cpu_trace `@data_addr` is pipeline-lagged → the rts looked like it read `$000C06`.
- The `--heartbeat` reads regfile A7 only at frame boundaries → it sampled the *correct*
  high A7 and missed nothing (A7 really is fine); the bug is the *write address*, not SP.
- The CPU genuinely runs the `$40A` alias, so "A30 is dropped" looked plausible from the
  bus-fetch address (`last_fetch_pc` shows the translated bare `$00A`, not the `$40A`
  logical PC) — but `debug_TG68_PC` proved the register holds `$40A`.

## The general latent defect
The CPU's logical-address datapath (`memaddr_*` → `addr`/`pmmu_addr_log_int`) is clocked by
`clkena_in`, which fires during `pmmu_busy` so the table walker can run. That also lets the
**in-flight access address recompute during a translation stall.** Any CPU access that
(a) stalls on an ATC-miss walk **and** (b) has its address datapath redirected during the
stall commits to the wrong address. `bsr.w`/`bsr.l` hit it because `bsr2` raises
`TG68_PC_brw` (→ `memaddr_delta_rega = TG68_PC_add = branch target`) in the same window as
the push write. `bsr.s`/`jsr` normally escape (their push doesn't coincide with a
fresh-page ATC miss + branch-redirect), so the SingleStepTests bench — which runs single
instructions with no PMMU walks — would NOT catch this.

## Fix options (the real fix is NOT a localized microcode tweak)
1. **Hold the CPU access address during a PMMU stall (recommended).** Gate
   `memaddr_delta_rega` / `use_base` / `memaddr_delta_regb` (hence `addr`/`pmmu_addr_log_int`)
   so they don't recompute while `pmmu_busy='1'` and a CPU access is pending (`state(1)='1'`).
   Complication: longword accesses legitimately step base→base+2 mid-transfer, so the hold
   must preserve longword progression while blocking the spurious `TG68_PC_add` redirect.
   This is the principled fix and also hardens every other access against the same race.
2. Restructure `bsr2` so the push write fully completes before `TG68_PC_brw` redirects the
   address (separate write/branch states) — narrower, but still races a slow (PMMU) write.
3. Latch+hold the bus address across the PMMU park in the bus glue (`tg68k.v` **and**
   `MacLC.sv`) — but `s_state` resets to 0 during the `busstate="01"` park, so the address
   is already flipped by the time `s_state` re-asserts; this alone does not work.

Whatever the fix: it lives in the **shared `rtl/tg68k`** core. After fixing, regenerate via
`rtl/tg68k/convert_to_verilog.sh` (ghdl 6.0.0), re-copy the 8 tg68k files to
`../MacIIvi_MiSTer`, `diff -q` clean, and gate on the MacIIvi SingleStepTests bench
(baseline 714/719, 5 known PRM-CCR diffs) PLUS the boot trace.

## UPDATE (2026-06-17 late) — option-1 address-hold IMPLEMENTED & VALIDATED (partial)

Applied option 1: in `TG68KdotC_Kernel.vhd` (MEM_IO process, after the `memaddr_delta_rega`
ELSIF chain) added, inside `IF clkena_in='1'`:
```
IF pmmu_busy='1' AND state(1)='1' THEN
    use_base           <= use_base;
    memaddr_delta_rega <= memaddr_delta_rega;
    memaddr_delta_regb <= memaddr_delta_regb;
END IF;
```
(kept the `set(presub)`-in-`bsr2` microcode change too). Regenerated `.v`, rebuilt, ran
fastmem to F175.

**RESULT — big, validated step forward:**
- The `A30[UST]` trace shows the address now **HELD at `$1ff3c4`** (`memreg=A7,
  memdelta=-4, use_base=1`) for the entire 9-cycle PMMU stall (cyc 12 359 301–309) — it no
  longer flips to `$40a00910`. The hold works exactly as designed.
- `A30[STK] WR addr=001ff3c4` — the push now targets the **real stack** (was `$00a00910`).
- The boot **clears the old F154 `$FFFFxx` derail** and runs the `$40A` alias for the first
  time: HB F157+ = `fullpc=40A46240`, A7=`$1FF3A8` (high/valid) — same alias execution MAME
  uses. Huge leap from "immediately wanders zeroed memory".

**REMAINING (next layer): longword write × PMMU-stall.** The `bsr.w` push is a *longword*
(`$40A00130`), which on the 16-bit Mac bus is two word transfers (`$40A0`→`$1ff3c4`,
`$0130`→`$1ff3c6`). Freezing the address for the whole stall **collapsed the longword to a
single word** — only `$0130` (low word) committed, to `$1ff3c4`; `$1ff3c6` never written.
So the rts still can't read back a valid return; the boot diverges (much later) to the POST
error-reporter `$40A46240` (`btst #27,D7` → `ori.w #code,D7; bra $a462c0` jump table — MAME
never hits it; MAME runs `$40A148D2`/`$40A0CB0E`… and settles at `$40A07A5A`).

Root of the remaining issue: a longword write whose **first word** misses the ATC stalls,
but the kernel/bus run the address ahead of the stalled bus (word0→word1→…), so freezing
the address pins the wrong word and the two words don't commit to `$1ff3c4` **and**
`$1ff3c6` across the walk. The proper fix must coordinate the kernel's per-word address
advance with the bus's actual per-word commit under `pmmu_busy` — i.e. don't advance to
word1 until word0 commits, and let word1 (ATC hit, no stall) commit to `$1ff3c6`. This is a
longword-write/PMMU-stall handshake issue (kernel address datapath ↔ tg68k.v/MacLC.sv bus
state machine), deeper than the single-word address hold.

Current working tree carries: `set(presub)` in bsr2 + the `pmmu_busy/state(1)` address-hold
(both in TG68KdotC_Kernel.vhd, .v regenerated). These fix the single-word case and advance
the boot dramatically but are NOT the complete fix; keep iterating on the longword handshake
(and validate the whole thing on the SST bench before committing to the shared core).

## UPDATE 2 (2026-06-17 latest) — longword word-counter hold ADDED → bsr.w FULLY FIXED, boot runs the whole $40A alias

Added part 2 of the fix (TG68KdotC_Kernel.vhd, line ~3041): freeze the longword word
counter during a PMMU stall of ANY access, not just fetches —
```
IF NOT ((state = "00" OR state(1) = '1') AND pmmu_busy = '1') THEN
    memmask <= memmask(3 downto 0)&"11";
    memread <= memread(1 downto 0)&memmaskmux(5 downto 4);
END IF;
```
Regenerated `.v`, rebuilt, ran fastmem to F200.

**RESULT — bsr.w push/rts now FULLY correct, boot runs essentially the entire $40A alias
post-MMU boot (matches MAME's path):**
- The push now commits BOTH longword words: `WR $1ff3c4=40a0`, `WR $1ff3c6=0130`; and the
  rts reads them back: `RD $1ff3c4=40a0`, `RD $1ff3c6=0130` → returns to `$40A00130`. ✓
- HB trajectory now mirrors MAME: F154 `$00A008A0` (continuation, == MAME's `$40A0089E`
  region) → F155 `$00A1491E` (the jump-table dispatcher MAME runs at `$40A148xx`) → F156+
  loops at `$001FF35A` (high RAM). A7/a2 all valid (`$1FF302` / `$40A001F4` alias).

**THE THREE-PART FIX (all in shared `rtl/tg68k`, TG68KdotC_Kernel.vhd):**
1. `set(presub)` moved from the common bsr-idle into the `bsr.s` branch AND `bsr2` (push EA
   starts as `-(A7)`).
2. Address-datapath hold during a PMMU stall of a CPU access (`pmmu_busy='1' AND
   state(1)='1'` → hold `use_base`/`memaddr_delta_rega`/`memaddr_delta_regb`).
3. Word-counter hold (`memmask`/`memread`) during a PMMU stall of any access (extend the
   `state="00"` guard to `state="00" OR state(1)='1'`).

**REMAINING (NEW, deeper blocker): the `$1FF35A` wedge.** The jump-table dispatcher
(`$00A1491E`, `jmp ($2,PC,D5.w)`) jumps to `$001FF35A` (a high-RAM/stack-region address) and
the CPU spins there (F156–200, fetching `$1ff35a`=`f380` every frame). MAME's equivalent
dispatch goes to `$40A07A5A` (ROM alias) and settles there showing the checkerboard `?`.
Screenshot @F200 = uniform luma-127 grey (the correct PRE-desktop state — same as MAME
before the fill), so we wedge BEFORE the desktop-fill. `$1FF35A` is in the stack region, so
the dispatch target looks CORRUPTED (jumped into the stack) — possibly another address
corruption (a jmp/branch EA mangled, maybe the same PMMU-stall class on a different access,
or an unrelated bug). NEXT: trace the `$00A1491E` dispatch — is D5 / the computed target
correct vs MAME, and does the target fetch/EA stall on a PMMU walk? Compare to MAME's
`$40A07A5A` dispatch. Likely the next focused task (deep, but the boot is now ~all the way
through the alias POST).

Validation still owed before committing to the shared core: MacIIvi SingleStepTests bench
(714/719 baseline) — none of the three changes should regress single-instruction ISA tests
(no PMMU walks in the bench), but confirm. Then re-copy 8 files to ../MacIIvi_MiSTer.

## Working-tree state (UNCOMMITTED, experimental — decide before committing)
- `TG68KdotC_Kernel.vhd`: `set(presub)` moved out of the common bsr-idle block into the
  `bsr.s` branch and into `bsr2`. This makes the bsr.w push EA *start* as `A7-4` (correct),
  but is **NOT sufficient** — the PMMU stall still recomputes it to the branch target. It is
  behaviour-neutral on the LC II boot (bit-identical cyc trace) but is UNVALIDATED against
  the SST bench; consider reverting unless kept as part of the full fix.
- `TG68KdotC_Kernel.v`: regenerated to match (carries the presub change).
- `verilator/tg68k.v`: `A30_TRACE` debug block (ifdef-guarded; ports
  `debug_TG68_PC/reg_QA/memaddr_reg/memaddr_delta/data_read/exec_directPC/regfile_*/
  micro_state/use_base/setstate/state`). Logs `A30[ENTER-A0]`, `A30[RTS]`, `A30[STK]`,
  `A30[UST]`. Harmless when `A30_TRACE` is undefined.
- `verilator/Makefile`: `V_DEFINE += +define+A30_TRACE=1` (revert for normal builds).

## Repro / probes
```
cd verilator && make obj_dir/Vemu.cpp && \
  (cd obj_dir && rm -f *.o *.gch && make OPT_FAST=-Os OPT_SLOW=-Os -f Vemu.mk)   # ~Os build
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat \
  --rom ../releases/boot0-fastmem.rom --stop-at-frame 156 > /tmp/x.log 2>&1
grep 'A30\[STK\]' /tmp/x.log      # push WR goes to $00a00910, no WR to $1ff3c4
grep 'A30\[UST\]' /tmp/x.log      # addr flips $1ff3c4 -> $40a00910 mid-stall (ust=24 nopnop)
grep '\[HB\]'     /tmp/x.log      # F154+ wanders $FFFFxx (was: desktop on MAME)
```
Enum: idle=0, bra1=21, bsr1=22, bsr2=23, nopnop=24. `debug_micro_state = micro_states'pos`.
MAME oracle: `/tmp/mame_hb.txt` (pc_sp_hb.lua) — `$40A` alias from F303, A7=`$1FF3xx`.
