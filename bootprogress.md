  Boot progression (4.3M instructions total):

  ┌──────────┬──────────┬──────────────────────────────────────────────────────────────────────────────┐
  │   Line   │ PC Range │                                 Description                                  │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1        │ $000000  │ Reset vector                                                                 │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 568      │ $A02Exx  │ Early ROM init                                                               │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 2190     │ $A463xx  │ Main ROM startup                                                             │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 4195     │ $A14Cxx  │ Hardware init routines                                                       │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 31909    │ $A464DE  │ RAM test/sizing (the $A46AF0 checksum loop runs from here until line ~1.34M) │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1342662  │ $A02Fxx  │ Post-RAM-test                                                                │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1350043  │ Various  │ ROM initialization continues ($A465xx, $A4A5xx)                              │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1352294  │ $A466DA  │ Enters memory clear/init region                                              │
  ├──────────┼──────────┼──────────────────────────────────────────────────────────────────────────────┤
  │ 1352353+ │ $A4685E  │ Memory init loop with MOVEM/EOR pattern (part of the RAM march)              │
  └──────────┴──────────┴──────────────────────────────────────────────────────────────────────────────┘

  The CPU advances through reset, early init, RAM testing, and into memory initialization.
  The $A4685E-$A46880 MOVEM loop above is part of the legitimate RAM march, not the real
  blocker. See the investigation log below for where the boot actually stalls and why video
  never initialises.

---

# Boot Investigation Log — Video / Black Screen (2026-06-01 -> 2026-06-02)

Goal: boot now runs but the screen stays black. Used MAME (`maclc`, same ROM) as ground
truth alongside the Verilator sim.

## TL;DR — current state
- **FIXED & committed (`2206dfb`):** address-decoder motherboard-RAM mapping. Made the RAM
  march terminate and advanced boot to the bank-scan region (the same region MAME reaches).
- **VRAM→DTACK done (uncommitted, tree change):** VRAM (`$F40000-$FBFFFF`) was on the 6800
  **VPA** path; now routed to async **DTACK** like RAM, in BOTH `verilator/sim.v` AND `MacLC.sv`.
  This is architecturally correct (matches MAME and the lbmactwo NuBus-on-DTACK core) and makes
  the VRAM data path bit-identical to RAM — but it is **NOT the lever**: screen still black,
  probe still fails at the same point. Keep it; it's a prerequisite, not the fix.
- **ACTUAL ROOT CAUSE (2026-06-02 — CONFIRMED via execOPC/Flags probe; corrects the earlier
  "stale operand" wording in section 6):** a **TG68K flag-commit-vs-branch pipeline race**. The
  bank probe does two consecutive `cmp.l` longword reads — alias `cmp.l (A0,D2)` @ `$A467EC` then
  real `cmp.l (A0)` @ `$A467F2`. At the real cmp's `execOPC` commit BOTH ALU operands are correct
  (`OP1=D0=5368656C`, `OP2=mem=5368656C`) so it computes EQUAL and latches `Z=1` — but ONE CYCLE
  LATE. The following `beq $A467F4` already evaluated its condition using the stale `Z=0` from the
  alias cmp → falls through to `$A467F6` (bank absent) → probe fails. `cmp.l (An)` uses the tight
  `get_ea_now` immediate-read path (2-cycle longword read delays the flag commit); the working
  `cmp.l (d16,An)` defers via `ld_dAn1`, whose extra cycle aligns the commit ahead of the branch.
  NOT VRAM-specific (reproduces on VPA and DTACK); the data path is 100% clean. Fix = give the
  `(An)` longword op the same one-cycle alignment (mirror `ld_dAn1`), or stall the Bcc on a
  pending flag commit. (VHDL is now the source of truth — see the consolidation commit.)

## Critical methodology note
This sim has **clean-vs-incremental build nondeterminism**. Several "it works!" results were
incremental builds with stale objects = FALSE POSITIVES. **ALWAYS `make clean && make`
before trusting any result.** (Also bit us at session start: an incremental build hung at
`$A14E60`; the clean build ran fine.)

## ROM ruled out
- 68k ROM `releases/boot0.rom` is byte-identical to MAME `350eacf0.rom` (SHA1 `6bef5853...`).
- The Egret HC05 firmware the sim actually loads (`rtl/egret/egret_rom.hex`, SHA1 `8b0dae3...`)
  == MAME's default BIOS `341s0851`.
- Cleanup nit: the unused `rtl/egret_rom.bin` / `rtl/egret_rom.hex` in the REPO ROOT are the
  older `341s0850` — harmless but worth deleting to avoid confusion.

## MAME ground truth
Identical ROM + 2 MB boots to video (grey desktop, mouse, blinking "?" disk). Its RAM march
runs ~2 passes then exits and **never reads the `$200000-$7FFFFF` gap** (debugger
watchpoints: 0 hits). Source: `~/repos/mame/src/mame/apple/{maclc,v8}.cpp`. Romset:
`/private/tmp/goodroms/maclc`. Debugger gotcha: breakpoints/trace default to the Egret
HC05 — target `maincpu` explicitly (`trace file,maincpu`). 68k ROM runs at `$00A4xxxx`;
address mask is `global_mask(0x80ffffff)`.

## Fix #1 (COMMITTED, `2206dfb`) — addrDecoder motherboard RAM at $000000
`rtl/addrDecoder.v` only asserted `selectRAM` for the motherboard mirror at `$800000-$9FFFFF`.
With no SIMM (`ram_config=0x24`), `$000000-$1FFFFF` fell through to `selectUnmapped` (returns
`$FFFF`). MAME's `v8.cpp ram_size()` ALWAYS installs the motherboard RAM at `mb_location`
(= SIMM size = 0 when no SIMM) plus the `$800000` mirror. Added `in_motherboard_low`. Result:
the RAM march terminates instead of grinding forever, and boot reaches the post-march
bank-scan (`$A4A6xx`). (The unmapped-read VALUE, `$FFFF` vs MAME's `$0000`, was tested and is
NOT the lever — leave it `$FFFF`.)

## Fix #2 (ROOT CAUSE, NOT fixed) — VRAM on VPA instead of DTACK
Found by PC-stream diffing our trace vs a MAME `maincpu` trace, anchored at RAM-sizing entry
`$A467CC`. First divergence is the bank-presence probe:
```
A467E6  move.l D0,(A0)        ; write pattern $5368656C to bank base A0
A467EC  cmp.l  (A0,D2.l),D0   ; D2=$40000 -> read $F80000 (alias check)
A467F0  beq    $a46804        ; if aliased
A467F2  cmp.l  (A0),D0        ; read back $F40000
A467F4  beq    $a467fe        ; MAME: TAKEN (readback OK)   OURS: NOT taken (readback wrong)
A467F6  bclr   #0,(A2)        ; ours-only: bank marked "not present"
```
`A0 = $50F40000` = the VRAM aperture. The ROM probe table at ROM offset `$3B00` holds the
I/O/video bank bases (`$50F40000`=VRAM, `$50F26000`=PseudoVIA, `$50F0xxxx`=VIA...). MAME reads
the pattern back; we do not -> the video bank is mis-marked -> that corrupts the RAM-config
descriptor table -> the later march gets a garbage base (`$4E754F00`, in the unmapped gap) and
wanders. **This is the black-screen root cause and it is on the video memory path.**

Why VPA: `$F40000` has `cpuAddr[23:21]==3'b111`, which the CPU bus logic treats as a 6800
E-clock VPA peripheral:
```
sim.v:262-263 / MacLC.sv:845-846
  _cpuVPA   = (cpuFC==3'b111) ? 0 : ~(!_cpuAS && cpuAddr[23:21]==3'b111);
  _cpuDTACK = ~(!_cpuAS && cpuAddr[23:21]!=3'b111) | !dtack_en;
```
VRAM is SDRAM-backed and must use async DTACK like RAM. On the VPA path the CPU samples the
read on a fixed E-clock phase that catches the SDRAM read BEFORE it settles -> stale data.

## Cycle-accurate evidence (the deep dive) and the paradox
Instrumented `sim_ram.v` + `sim.v` with an armed cycle-by-cycle `$display` of
busCycle/videoBusControl/memoryLatch/selectVRAM/memoryAddr/ram_do/dataControllerDataOut/
AS/DTACK/cpuAddr/busstate, plus clk16-enable sampling and the TG68 wrapper's internal
`tg68k.tg68_din_r` / `s_state`. Findings (all CLEAN-build):
1. The data path is fine: `dataControllerDataOut` settles to the correct word at the first
   cpu-slot `memoryLatch` and is rock-stable for 40+ clocks (cpu_data only latches in cpu
   slots, so interleaved video fetches don't corrupt it).
2. `sim_ram` has a 1-clock REGISTERED-READ lag (`dout<=mem[addr]`): when `memoryLatch`
   samples the cycle right after `memoryAddr` switches, `ram_do` is still the prior address.
3. The longword WRITE was being TRUNCATED: with VRAM on DTACK, `mem[$580001]` was written 0
   times — DTACK acked before the 2nd word's cpu write slot, so `$656C` was LOST and the
   readback legitimately returned 0.
4. Sub-fixes that DID work in a clean build: (a) combinational `sim_ram` read removes the lag;
   (b) a `vram_slot` counter giving each VRAM access TWO cpu slots (1st settles read / commits
   write, 2nd asserts DTACK). After these: `mem[$580001]` IS written, and the dump shows the
   TG68's OWN input register `tg68_din_r` latch `$5368` (word1) then `$656C` (word2) at state
   6/7 — i.e. the CPU input register holds exactly `$5368656C` = `D0`.
5. **The old "paradox" — NOW RESOLVED (2026-06-02), see section 6.** `tg68_din_r` is correct
   for both words yet `cmp.l` reports unequal. The discrepancy is inside the TG68 kernel, exactly
   as suspected — a back-to-back-longword-read operand bug, NOT a VRAM/bus issue.

## 6. ROOT CAUSE — TG68K back-to-back longword-read stale operand (2026-06-02)
Method: re-ran (VRAM on DTACK) with three `ifdef SIMULATION` probes — `sim_ram` VRAM-range
read/write log, the wrapper's `tg68_din_r` latch + per-`clkena` (`s_state`/`busstate`/`din_r`)
log, and an in-kernel dump of `tg68_pc`/`data_in`/`data_read`/`last_data_in`/`last_data_read`/
`memmask`/`state` (the readable net aliases exist in the generated `.v`). All probes removed
afterward; tree holds only the DTACK change.

The probe code at `$A467E6` is a write-then-read-back bank presence test:
```
A467E6  move.l D0,(A0)        ; D0=$5368656C -> write to $50F40000 (VRAM base)
A467EC  cmp.l  (A0,D2.l),D0   ; D2=$40000 -> read $50F80000 (alias) = $00000000; not-equal (correct)
A467F0  beq    $a46804        ; not taken (alias != D0, good)
A467F2  cmp.l  (A0),D0        ; read $50F40000 = $5368656C; SHOULD be equal to D0=$5368656C
A467F4  beq    $a467fe        ; SHOULD take, but does NOT -> bank wrongly marked absent
```
What the kernel dump proves — operand assembly is CORRECT for BOTH the failing and a known-good
`cmp.l`, so the assembly is not the bug:
```
FAILING cmp.l (A0) @A467F2:   reads 5368 then 656c -> data_read=5368656c, last_data_in=5368656c  OK
WORKING cmp.l ($24,A1) @A02F90: reads 5600 then 0000 -> data_read=56000000, last_data_in=56000000 OK (bne falls through = equal)
```
Both deliver the right 32-bit operand into `last_data_in`. The distinguishing factor: the FAILING
`cmp.l (A0)` is the **second of two back-to-back longword reads** — preceded immediately by the
alias `cmp.l (A0,D2)` @ `$A467EC` whose operand is `$00000000`. The working one is a lone read.
`D0` is provably correct (`$5368656C`): the alias cmp @ `$A467EC` returned not-equal, which it
could only do if `D0 != $00000000`. So with operand=`$5368656C` AND `D0`=`$5368656C` both correct,
the second cmp still reporting not-equal means **the ALU received a STALE operand — the alias's
`$00000000` carried over from `$A467EC`** instead of the freshly-read `$5368656C`. The kernel does
not flush/advance the compare operand between two consecutive longword reads to the same base reg.
- This is **addressing-mode / instruction-sequence general, NOT VRAM-specific.** It reproduces on
  VPA and on DTACK; memory/sim_ram/wrapper/kernel `data_read` are all correct. The DTACK change is
  correct but irrelevant to this bug.
- `last_data_read` is a red herring: it tracks opcode fetches (b090/6708/08aa...), not the data
  operand, in BOTH the working and failing cases — so it is NOT the ALU operand source.

(superseded scratch note below; kept for the cycle timestamps)
The kernel latches `last_data_read` only when `state="00" OR exec(update_ld)`
(`TG68KdotC_Kernel.vhd:495`). For this read the assembled longword is valid at `state="10"`
(`@760`); by the time `state="00"` comes (`@768`) an interleaved **opcode prefetch has already
overwritten `data_read`**. So `cmp.l` compares `D0` against `$00006708` (stale) → not equal →
`$A467F4 beq` not taken → `$A467F6` marks the bank "not present" → descriptor table corrupts →
`$4E754F00`/`$4F..` gap-march → no video.
- The alias probe `cmp.l (A0,D2),D0` @ `$A467EC` hits the SAME mis-capture, but its operand is
  `$00000000`, so "not equal" is coincidentally correct → the bug is masked there.
- **Not a kernel-version issue:** lbmactwo's NEWER kernel has the IDENTICAL capture condition
  (`TG68KdotC_Kernel.vhd:537`) and the IDENTICAL longword-assembly process, yet boots to video.
  So the difference is in **bus/wrapper TIMING** (when the prefetch interleaves vs the operand
  read), not the kernel's capture logic. The MacLC `tg68k.v` wrapper differs from lbmactwo's.
- **Not VPA/DTACK and not the data path:** memory, sim_ram, `cpu_data`, `tg68_din_r`, and the
  kernel's own `data_read` are all correct. The previous "VPA stale data" theory is wrong;
  the DTACK change is correct but insufficient.

## Where to go next (recommended order)
1. **Compare the failing operand read against a WORKING longword cmp/read on RAM**, capturing
   the kernel `state`/`data_read`/`last_data_read`/`exec(update_ld)` sequence for both. The
   question to answer: in the working case does `exec(update_ld)` fire at `state="10"` (capturing
   the operand before the prefetch), or does the prefetch simply not interleave there? That tells
   you whether the fix belongs in (a) decode (`update_ld` for `cmp.l (An)`), or (b) the wrapper's
   fetch/read sequencing (`skipFetch`/busstate handling).
2. **Most promising fix: port the lbmactwo `tg68k.v` wrapper (and its matching kernel).** lbmactwo
   is a working core that does longword reads from DTACK video memory with the same kernel logic;
   its wrapper sequences fetch-vs-read differently. This needs the newer kernel's extra ports
   (`longword`, `VBR_out`, `cpu_halted`, `berr_inhibit`, `berr_data`, `IPL_autovector=1`). Big,
   risky change (CLAUDE.md warns on CPU edits) — do it in a worktree and gate on the frame-350
   screenshot + the verification below. Bonus: would also bring real BERR-on-unmapped support.
3. Verify any fix, in a CLEAN build: `$A467F6` count -> 0 (probe passes), `$4E754F00`/`$4F..`
   march gone, framebuffer writes to `$F40000` appear, screenshot goes black -> grey/Happy-Mac.
   Cross-check V8 video registers vs `monitor_id`/`video_mode` defaults (monitor_id=2 / 512x384,
   video_mode=2 / 4bpp).
4. Separately confirm (or rule out) the post-fix `$4F62xxxx` gap-march as legit HMMU-truncation
   vs another decode divergence — MAME never reads that gap.

## Key references
- Disasm: `docs/MacLC_ROM_disasm.txt` (VMA 0x40800000; runtime `$A0xxxx` <-> disasm
  `$4080xxxx`, low 20 bits match). Probe `$A467E6-$A467F6`; RAM-sizing `$A467CC`; march
  `$A468C4-$A46908`; bank-scan driver `$A4A600-$A4A6xx`.
- VRAM map: CPU `$F40000-$FBFFFF` -> SDRAM word `$580000` (`addrController_top.v:170-176`).
- CPU bus/VPA/DTACK: `sim.v:249-263`, `MacLC.sv:832-846`; TG68 din sample `tg68k.v:104-118`.
- MAME ground-truth how-to + fuller notes: auto-memory `video-march-investigation-2026-06-01`
  and `mame-ground-truth-maclc`.
