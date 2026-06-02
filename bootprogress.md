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
- **ROOT CAUSE of no-video, CONFIRMED but NOT yet fixed:** VRAM (`$F40000-$FBFFFF`) is wrongly
  routed onto the 6800 **VPA** synchronous-peripheral path instead of async **DTACK** —
  present in BOTH `verilator/sim.v` AND the real FPGA top `MacLC.sv`. The boot ROM's VRAM
  presence-probe reads back stale data, mis-sizes the video bank, corrupts the RAM-config
  descriptor table, and never initialises video.
- No working VRAM fix landed: attempts either failed a clean build or hit a
  TG68-kernel-internal paradox (section 5). All experimental changes reverted; tree clean.

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
5. **PARADOX (unresolved):** despite `tg68_din_r` = `$5368/$656C` (correct) for both words,
   the `cmp.l` still reports unequal — `$A467F4 beq` not taken, `$A467F6` runs, the `$4E754F00`
   march persists. The data is correct at EVERY observable point including the TG68 wrapper's
   data register. So the remaining discrepancy is INSIDE the TG68 kernel
   (`rtl/tg68k/TG68KdotC_Kernel.v`, generated VHDL->Verilog) — how/when it consumes `data_in`
   to assemble the 32-bit operand and compare, or whether `D0` itself differs at the ALU. The
   wrapper samples `din` at `s_state==6` on phi2 (`rtl/tg68k/tg68k.v:104-118`).

## Where to go next (recommended order)
1. **Trace the TG68 KERNEL internals** (the actual blocker). FST waveform (`--trace`) of
   `TG68KdotC_Kernel` `data_in` / operand latches / the two `cmp` operands across `$A467F2`,
   and compare against a WORKING RAM longword read (RAM longword reads succeed, VRAM ones
   don't — the diff is the answer). This resolves the paradox in section 5.
2. Once understood, fix VRAM->DTACK properly: route VRAM off VPA onto DTACK with the right
   read-settle / write-commit timing (the `vram_slot` two-slot idea + combinational/settled
   read got the data correct at the bus & wrapper; the kernel-consume timing is the last gap).
   Apply the SAME change to BOTH `sim.v` and `MacLC.sv` (sim==FPGA parity).
3. Verify any fix, in a CLEAN build: `$A467F6` count -> 0 (probe passes), `$4E754F00` gone,
   framebuffer writes to `$F40000` appear in the trace, and the screenshot goes black ->
   grey/Happy-Mac. Cross-check the V8 video registers the ROM programs vs `monitor_id` /
   `video_mode` defaults (default monitor_id=2 / 512x384, video_mode=2 / 4bpp).
4. Separately confirm (or rule out) that the post-fix march which walks `$4F62xxxx` (the masked
   2-8MB gap) is the legit HMMU-truncation test vs another decode divergence — MAME never
   reads that gap.

## Key references
- Disasm: `docs/MacLC_ROM_disasm.txt` (VMA 0x40800000; runtime `$A0xxxx` <-> disasm
  `$4080xxxx`, low 20 bits match). Probe `$A467E6-$A467F6`; RAM-sizing `$A467CC`; march
  `$A468C4-$A46908`; bank-scan driver `$A4A600-$A4A6xx`.
- VRAM map: CPU `$F40000-$FBFFFF` -> SDRAM word `$580000` (`addrController_top.v:170-176`).
- CPU bus/VPA/DTACK: `sim.v:249-263`, `MacLC.sv:832-846`; TG68 din sample `tg68k.v:104-118`.
- MAME ground-truth how-to + fuller notes: auto-memory `video-march-investigation-2026-06-01`
  and `mame-ground-truth-maclc`.
