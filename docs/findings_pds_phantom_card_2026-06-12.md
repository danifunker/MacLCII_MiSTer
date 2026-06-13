# ROOT CAUSE: phantom PDS card from 24-bit-aliased slot probes (7.x boot Sad Macs)

*2026-06-12 overnight session, branch `scsi-fixes-from-lbmactwo`. Continues
docs/handoff_warmboot_loop_2026-06-11.md — most of that document's SCSI framing
is now OBSOLETE (see "exonerations" below).*

## The mechanism

The LC boot ROM probes for a PDS card with this sequence at ROM `$A4BEB0`
(disassembled from `releases/boot0.rom`, confirmed live via the PEXC/PEX2
JTAG exception-latch probes):

```
A4BEB0: movem.l d0-d2/a2-a5,-(a7)
A4BEB4: moveq   #1,d0
A4BEB6: A05D                      ; _SwapMMUMode → 32-BIT addressing
A4BEBC: ori.w   #$0700,sr         ; interrupts off
A4BEC0: movea.l $8.w,a4           ; save bus-error vector
A4BEC8: lea     (handler,pc),a5
A4BECC: move.l  a5,$8.w           ; install temp BERR handler
A4BED0: movea.l #$FE000000,a3     ; PDS pseudo-slot $E base
A4BEDA: move.w  $1c(a3),d1        ; probe reads
A4BEDE: move.w  $10(a3),d0
A4BEE2: addq.w  #1,d1             ; ← PEX3 latched here (prefetch skew)
A4BEE4: cmp.w   $1c(a3),d1
        ...                       ; restore vector, _SwapMMUMode back, rts
```

On a real cardless LC the `$FE00001C` read **bus-errors**; the temp handler
catches it → "no card". Our glue ignored `cpuAddr[31:24]`, so `$FE00001C`
aliased to **`$00001C`** — the exception vector table in RAM. The read
"succeeded", returning vector garbage → the ROM recorded a **phantom PDS
card in slot $E**. System 7.x's Slot Manager later initializes the phantom
card through garbage descriptors → illegal-instruction-class Sad Macs
(`0000000F/00000003`, `/00007FFF`) at a fixed boot phase (~1 s after Happy
Mac / during 7.5.5's progress bar). System 6.0.8 exercises almost none of
that machinery → boots fine. Both cores shared the symptom because both
truncate (check lbmactwo!).

## The fix (this branch, both tops)

`MacLC.sv` + `verilator/sim.v`: `slot_space = cpuAddrFullHi inside [$F1..$FE]`
→ assert BERR, suppress DTACK/VPA. Window rationale:
- `$F1-$FE` = NuBus/PDS standard slot space the ROM/Slot Manager probes.
- EXCLUDED: `$50` (32-bit I/O alias — works via truncation), `$40-$4F` (ROM),
  `$00`, `$FF`, and `$20-$E0` (24-bit Memory Manager handle FLAG bytes —
  those must keep aliasing to RAM exactly like a V8 ignoring A31-A24).
- docs/plan_040526.md step 2 tried a BLANKET high-bit BERR and regressed
  boot ("$50xxxxxx etc. early in ROM execution") — this is the targeted form.

## Exonerations (all measured, do not re-litigate)

- **SCSI write path / "write stall"**: downstream of the crash, not a cause.
- **Post-reset "deaf disk"**: NOT deafness. Live `at_sel_data` histogram over
  30 s of the rescan shows the ROM selecting IDs 0-5 only — **ID 6 ($C0) is
  never put on the bus**. The mounted, healthy target is simply never asked
  (ROM skips the failed boot device; blinking-`?` = scanning for an
  ALTERNATIVE boot disk). PSC2 at-sel: out_en=1, A_DATA=1, MOUNTED=01,
  tbsy=00 — initiator and target both healthy.
- **Memory size**: crashes at 2MB and 10MB alike (2MB run had pristine SCSI).
- **Video/SDRAM contention**: video scanout is BRAM-only (Phase 2); 1bpp test
  (user-run) crashed identically. The legacy SDRAM/DDR3 video-fetch plumbing
  was REMOVED this session (user request) from addrController/maclc_v8_video/
  dataController/both tops.
- **Heat (separate, real, hardware-level)**: warm board adds fuzzy video,
  JTAG ISSP flakiness/hangs, one double-bus-fault halt inside the Sad Mac
  handler (its SCC poll loop at $F04002), and one full SoC freeze requiring
  a power cycle. Cold board: none of it. STA: core clocks ~2 ns slack, but
  pll_hdmi only +0.2 ns → likely the fuzz. Check the DE10 heatsink.

## Instrumentation added this session (rtl/dbg_probes.sv)

- PSC2 v2: `{at_sel_data, at-sel flags, live scsi_dbg}` — the data byte on
  the bus at the last SEL assertion.
- PEXC: rolling last fatal vector (2-9; line-A/F excluded — the OS dispatches
  every syscall via line-A). PEX2/PEX3: STICKY first-ILLEGAL {addr16,opcode}
  + {faulting IF, count}. All qualified by `cpuAddrHi == 0` (else 32-bit
  device probes alias into the vector window — that false positive is
  exactly what exposed the root cause).
- boot_watch.tcl: side-channel live log (Quartus 4KB-buffers stdout), allff
  reattach fixed (missing probes can no longer veto), PEXC/PEX3 sampled.
- cpu_state.tcl: PEXC/PEX2/PEX3 decode; NOTE Tcl `scan %x` is SIGNED — guard
  probe prints with `[info exists idx(NAME)]`, never `>= 0`.

## Overnight fix iterations (rounds 2-4)

**Round 2 — immediate BERR for $F1-$FE: REGRESSION.** Boot dies at T+2 s.
PEXC: 13 bus errors, last at ROM `$A05E8A` — the ROM's 14-slot SCAN loop
(`$A05E78`: `move.b (a1),d0` at $xEFFFFFF per slot, temp handler resumes at
`$A05E8C`). Zero illegals (phantom card IS gone), but the boot lands in the
Sad-Mac handler (its SCC-poll loop at `$F04002` / PC `$A49Fxx`).

**Round 3 — LBMacTwo-style delayed (~8 µs) + held-until-AS BERR: identical
failure.** Same 13 faults, same death. Conclusion: **TG68KdotC's bus-error
exception for normal bus cycles is not handler-recoverable** (the ROM's
resume-at-different-PC frame surgery fails — likely wrong/short stack frame).
This is a real TG68 deficiency worth fixing someday, but not load-bearing:

**Round 4 — the actual LBMacTwo mechanism, re-read: empty slots are NOT
bus-errored there either.** `LBMacTwo.sv` `nubus_no_card`: after a 4-tick
timeout the cycle is **ACKED with $FFFF** (NuBus open-bus convention), and
the Mac II ROM accepts all-ones as "no card" — that's how it boots 7.x
without ever exercising TG68 berr. Ported to MacLC: `slot_space` cycles get
DTACK + `din` forced to `$FFFF` (both tops); no berr. Cannot regress vs the
pre-fix build: the only delta is slot reads returning $FFFF instead of
aliased RAM garbage. Count-by-success probes (the $A05E78 scan) still count
phantoms — they did pre-fix too and the boot survived them; the killer was
the VALUE-checking probe class ($A4BEB0), which now sees a dead slot.

## Validation protocol

1. Boot 7.1 fixture (`games/MacLC/MacLC_7-1.hda`, restore from .zip if sour):
   expect NO Sad Mac, boot past T+16 s, ideally desktop (screenshot).
2. PEX3 must show zero illegals.
3. Regression: 6.0.8 (`MacLC_6-0-8.hda`) must still boot + restart cleanly.
4. If 7.1 still fails: the count-by-success scan's phantom card table is the
   remaining suspect — consider returning BERR-equivalent via... no: fix
   TG68's berr frame (deep kernel work, see lbmactwo FSAVE-frame saga for
   the working method: VHDL kernel edit + GHDL → Verilog).
5. lbmactwo port: NOT needed for this bug (its NuBus glue already FFFF-acks);
   but check whether its $F1-$F8 (cardless slots BELOW $9) probe path aliases
   like ours did.
