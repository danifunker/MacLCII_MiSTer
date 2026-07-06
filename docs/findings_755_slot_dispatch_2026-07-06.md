# FINDINGS — 7.5.5 menu-bar wedge = pseudo-VIA slot-interrupt dispatch starvation (2026-07-06)

## TL;DR
System 7.5.5 in the Verilator sim boots cleanly (Welcome, color "Mac OS"
splash, extension parade, video depth switch) and then wedges forever at
menu-bar draw: the CPU parks in the ROM idle loop with the bar empty. Root
cause: **our pseudo-VIA model diverged from the real V8 in a way that made
the ROM's slot-interrupt dispatcher read $00 forever, so slot-interrupt
queue callbacks — including the 7.5.5 Finder-launch continuation riding a
slot-VBL task — never ran.** Five concrete divergences from MAME's
hardware-verified model were found and fixed by rewriting `rtl/pseudovia.sv`
as a faithful port of MAME `pseudovia.cpp` (V8 variant). A bonus effect: the
old model also caused a ~950×/frame interrupt-ack storm during every vblank
in BOTH 7.1 and 7.5.5 (7.1 merely survived it).

## The wedge, as observed (sim, v9 binary, run sim755run/sim755_v9.log)
- Boot healthy through F2600: Welcome F800, "Mac OS" splash F1400 (1bpp),
  F2200 splash in COLOR (video depth switch works), extension icons F1800.
- F2600 screenshot: splash cleared, desktop pattern + rounded corners drawn,
  **menu bar drawn EMPTY (white)** — the classic menu-bar-draw moment.
- Disk reads stop at F2661 (last `$A092Ax` SCSI-primitive PCs), dispatcher
  activity ends F2681, and from there to F3500 (run end) the heartbeat shows
  ONLY `pc=$A06F08/$A06F0E`, `a7=$3E69B8/BC` (toggling ±4), `a2=$678E`.
  Zero [EXC], Egret transactions normal, pseudo-VIA acks continuing.
- Pixel-identical screenshots F2600/F3000/F3400. Not slow — dead.

## Decoding the parked loop (LC II ROM disassembly via unidasm)
`$A06EC0` is the **slot-interrupt dispatcher** (SIntInstall queues):
```
a06ec0: moveq   #$3f, D0
a06ec2: and.b   ($203,A1), D0      ; A1 = pseudo-VIA base → reads reg $203
a06ec6: bne     $a06eca            ; pending bits? → dispatch
a06ec8: rts
a06eca: ...priority-encode via table at $a06f14, bclr, then per-bit:
a06eec: lea     ([$d04],D0.w*4,$40), A1   ; slot queue head for this bit
a06ef4: move.l  (A1), D0           ; walk: next element
a06ef6: beq     $a06f10            ; end of list → return $33 → _SysError
a06ef8: movea.l D0, A1
a06efa: move.l  A1, -(A7)
a06efc: movea.l ($8,A1), A0        ; sqAddr (service routine)
a06f00: movea.l ($c,A1), A1        ; sqParm
a06f04: jsr     (A0)               ; call handler
a06f06: movea.l (A7)+, A1
a06f08: tst.w   D0                 ; handled?
a06f0a: beq     $a06ef4            ; no → next element
a06f0c: moveq   #$0, D0
a06f0e: rts                        ; yes → done
```
The wedge heartbeats sit at $A06F08/$A06F0E with a7 toggling around the jsr:
the dispatch machinery is the only thing left running.

## Root cause: five divergences from the real pseudo-VIA
Reference: MAME `src/devices/machine/pseudovia.cpp` (`pseudovia_device` +
`v8_pseudovia_device`, "Hardware tests run on LC II, LC III, LC 550, IIci"),
cross-checked live: a healthy MAME maclc2 7.5.5 boot at 4M RAM was watched
with `verilator/mame/pvia_watch.lua` — it boots this exact disk image to a
full Finder desktop, and its register traces confirm each semantic below.

1. **Read aliasing missing (the killer).** MAME: `read(offset)` begins
   `offset &= 0x13` — EVERY offset in $F26000-$F27FFF aliases onto the 8
   registers. The dispatcher's `($203,A1)` read therefore returns **the IFR**.
   Our RTL decoded $100+ as "VIA-compat mode" with only regs 13/14 mapped,
   returning **$00** for $203 → the dispatcher exited instantly, forever.
   (Healthy-MAME watch: `p203 == ifr` on every sample.)
2. **IFR readback is the recalc'd/masked value.** After recalc, MAME stores
   `(pending & IER & $1B) | $80` when nonzero — the dispatcher only ever
   sees ENABLED sources in the $3F mask. Returning raw pending bits (old
   ifr_live) would have the dispatcher walk queues for masked sources (ASC
   bit 4 is pending almost always) — likely empty queue → `_SysError`.
3. **VBL slot source must be state, not a live wire.** MAME asserts slot
   bit 6 (active low, regs[2]) at vblank START and deasserts at vblank END
   or on the ROM's `$40` write to reg 2. Our old live `~vblank_irq` made
   the ack a no-op while vblank was high → the level-2 IRQ re-fired
   continuously for the whole vblank: ~950 ack-pairs/frame ($40→reg2 +
   $82→reg3, byte lanes of the logged f26002 writes) in BOTH OSes' logs.
   One interrupt per vblank now.
4. **Write decode:** V8 routes $200-$3FF writes to port A (unwired on LC →
   ignored); everything else decodes `offset & 0x1f`. The old invented
   "$1A00 compat IFR-ack / $1C00 compat IER" registers don't exist on V8
   (those offsets alias to port B / reg 0). Sim logs confirm the ROM acks
   natively at $F26002/3 — the compat path was never exercised.
5. **Small V8-vs-RBV details:** IFR ack must NOP bit 4 (ASC is level on
   V8); the IER `write $FF → $1F` quirk is IIci/RBV-only (removed); reset
   values are regs[2]=$7F, regs[3]=$1B (the healthy trace's initial
   ifr=$19/$09 readings are exactly this reset value being acked off).

## Why 7.1 boots but 7.5.5 wedges
Classic VBL tasks run off VIA1's 60.15 Hz CA1 interrupt (level 1), which
works. Only tasks installed on the SLOT interrupt queues (_SIntInstall — the
slot-VBL path, pseudo-VIA level 2) were starved. 7.1's Finder launch doesn't
block on one; 7.5.5's launch sequence parks a continuation on the slot-VBL
queue right at menu-bar time and waits forever. This also cleanly explains
the version matrix (6.0.8 ✓, 7.1 ✓ post-v9, 7.5.5 ✗) without any residual
CPU/PMMU involvement — and it is consistent with the 2026-07-01 HW capture
(same starvation upstream, surfacing downstream as the MemMgr free-walk spin
after enough state damage — the HW presentation differs by timing, as usual).

## SCSI IRQ wiring — settled against current MAME
`maclc.cpp` (maclc/maclc2/maclc3) connects the NCR5380's `drq_handler` ONLY
to the pseudo-DMA helper and **never connects irq_handler at all**; nothing
calls `pseudovia scsi_irq_w/scsi_drq_w` for the LC family. Our tops' tie-off
(`.scsi_irq(1'b0), .scsi_drq(1'b0)`, 2026-06-12) is CORRECT — keep it. The
IFR bits 3/0 exist in the register model but no LC source drives them (the
OS enables IER bit 3 anyway; it simply never fires — visible in the healthy
MAME watch as ier=$0A with ifr bit 3 never asserting).

## Fix
`rtl/pseudovia.sv` rewritten as a faithful state-for-state port of MAME's
`v8_pseudovia_device` (see file-header changelog for the five points).
Interface unchanged — no top-level edits needed in either `sim.v` or
`MacLC.sv` (`addr({cpuAddr[12:1], tg68_a[0]})` already delivers true byte
addresses; `ram_cfg`/`ram_configured` semantics preserved for the C++
harness and address controller).

## Validation
- MAME ground truth: maclc2 @ 4M boots this disk to desktop (goal-state PNG
  `scratch/mamesnap755_4m/maclc2/f0000.png`).
- Sim: F350 Egret/SR smoke + full 7.1 boot to F2500 (regression) + full
  7.5.5 boot to F3500 (cure test) — in flight at writing; results to be
  appended below.
- Old-binary forensic run (bounded cpu_trace F2500-2820 + SCSI phase log)
  still recording as the broken-behavior reference.

## VALIDATION RESULTS (appended)
- (pending)
