# HANDOFF (MacBook/MAME): 7.x Welcome-screen wedge — async driver completion never fires

*2026-06-12 afternoon, branch `scsi-fixes-from-lbmactwo` (working tree, uncommitted).
Continues docs/findings_pds_phantom_card_2026-06-12.md and
docs/mame_trace_71boot_results.md. Run this on the MacBook that has
`~/repos/mame` + the `verilator/mame` tooling.*

## Where we are (HW-validated today, build `MacLC_sdma.rbf` = working tree ~14:45)

- **Phantom-PDS-card fix VALIDATED.** 7.1 no longer Sad Macs: full run with
  PEXC = no fatal vector ever dispatched, PEX3 = zero illegals. The slot-space
  $F1–$FE open-bus ($FFFF-ack) window works.
- **6.0.8 regression PASS** — boots to Finder desktop in ~75 s on the same
  build (`docs/welcome_wedge_2026-06-12/boot608_t75.png`).
- **NEW (now the only) 7.x blocker:** 7.1 hangs at "Welcome to Macintosh"
  with the first extension icon drawn, static for 20+ min
  (`docs/welcome_wedge_2026-06-12/boot71_check.png`). 7.5.5: see addendum
  at the bottom.

## The wedge, fully decoded from the live FPGA (JTAG probe deck)

CPU is alive and spinning in 7.x System code in RAM:

```
$8AA38: 4A2A 060A   tst.b $060A(A2)    ; poll byte at A2+$60A
$8AA3C: 66FA        bne.s $8AA38       ; spin until it CLEARS
```

plus an outer loop (one-off PC sightings $6EBC/$6EE8/$6EFC/$6F0E/$A302/
$A30A/$A348/$B95C/$B96A/$E0F2/$E0FC — jsr (A0)/jmp (A0)/rts dispatch) that
re-enters the spin. Interrupts still run (VBL counts, Egret VIA polls show in
PDRD). Classic async-completion sleep: **a RAM flag at (A2)+$60A that only
some completion routine can clear — and it never runs.**

SCSI engine state at the wedge (all probes, one snapshot):

- Bus IDLE on both targets (PSC3 t1/t0=IDLE; max-seen phase = MSG).
- TCR=7 (MSG_IN expected — the completion STATUS/MSG sequence was set up).
- Last NCR register READ = **reg 7** (Reset Parity/IRQ — i.e. someone
  consumed/cleared an IRQ condition), `irq_latch=0`, `dma_armed=0`,
  `eodma=1`, `mr_dma=0`.
- `dack_beats` ≈ n·16384 + 5968 (14-bit wrap; absolute count unknown).
- Max DACK stall observed 0.45 ms; the new 250 ms `sdma_berr` timeout never
  fired (`berr_fires=0`). `req_drops=65535` is per-byte-REQ-fall noise —
  ignore it.
- PFR "BERR-NEAR-DEATH … RTE landed at garbage" is a **false alarm**: it
  triggers on supervisor *reads* of $8, which the MAME ground truth proved
  are routine save/install/restore triplets (~100k/boot). Ignore PFR rev 2.

**Already tried and insufficient:** the pseudovia SCSI IRQ/DRQ level wiring
(MAME pseudovia.cpp semantics: scsi_irq→IFR bit 3, scsi_drq→IFR bit 0) is
**active in this build** — re-wired this morning after the phantom-card root
cause exonerated it (the 1f6c8d5 tie-off rationale was post-hoc). The whole
chain is connected in RTL: ncr5380 `o_irq` → dataController `scsiIRQ` →
pseudovia `ifr[3]`; `irq_pending = ifr_live & ier & 0x1B`; `irq_out` → IPL 2.
**The driver still sleeps.** Either the NCR never raises the completion IRQ
the driver expects (MONBSY loss-of-BSY? — not implemented; lbmactwo audit
item 3), or IER bit 3 is never enabled, or the wake mechanism isn't an
interrupt at all.

## The pivotal fact MAME must explain

MAME `maclc` boots BOTH fixture images to the desktop with **no 5380
irq_handler connected and no pseudovia SCSI flags wired** (maclc.cpp connects
only DRQ→scsi_helper). So a healthy boot completes these async requests
WITHOUT any SCSI interrupt. Find that mechanism and we have the fix.

## Questions (in priority order)

1. **Find the same spin in a healthy 7.1 boot.** Lua: scan RAM each frame
   for the byte pattern `4A 2A 06 0A 66 FA` (it is NOT in ROM or on disk
   verbatim — decompressed System resource). When found, log its address and
   read A2 (debugger `bp` at the tst.b, then `r a2`). Flag byte = A2+$60A.
2. **Watch that byte.** `wpset <addr>,1,w` — who writes it, from what PC /
   call chain / interrupt context? That writer is the wake mechanism our
   core never triggers.
3. **Is the spin even entered in MAME?** If the loop runs 0 iterations (flag
   already clear), diff the driver's async-vs-sync decision inputs instead —
   what makes it choose to sleep on our core?
4. **Command-completion register choreography.** At the same boot stage,
   trace the driver's NCR access sequence from last data byte → STATUS →
   MSG_IN → bus free → next command. Which BSR/CSR bits does it read between
   MSG_IN and completion? Does it rely on MR bit 2 (MONITOR BUSY) loss-of-BSY
   interrupt (we don't implement it), EOP, or pure polling? Our last-read =
   reg 7 with TCR=7 suggests it got *through* MSG_IN and then waited.
5. (Bonus) Cumulative DACK byte count at the wedge-equivalent visual moment,
   to compare against our n·16384+5968 — detects silently lost commands
   before the wedge.

## Tooling notes (all known-good from the 06-12 trace session)

- `verilator/mame/run_mame.sh`, `scsi_trace.lua` (re-installs RAM taps every
  frame — v8.cpp `install_ram/rom` silently kills Lua taps; pattern to copy),
  `tap.lua`, `docs/mame_compare.md` (gotchas: headless debugger printf has no
  sink; PCs print 8-digit; debugger attaches to the Egret HC05 by default —
  switch to maincpu).
- ROM: use the loose file `~/repos/mame/roms/maclc/350eacf0.rom`
  (= `releases/boot0.rom.stock`); the `maclc.zip` boot ROM is the bad dump.
- Disks: MAME rejects `.hda` — clone `scratch/HDDFixtures/MacLC_7-1.hda` to
  `/tmp/*.hd`. macOS wipes `/tmp` after ~3 days.
- A memory WRITE tap (`emu.add_mem_tap` on writes) on the flag byte is the
  fastest path for Q2 — taps record PC via `cpu.state["PC"]` inside the
  callback.

## Current rig state (Windows box / MiSTer .143)

- MiSTer: `ssh root@192.168.99.143`, core `/media/fat/_Unstable/MacLC_sdma.rbf`
  (md5 == local `output_files/MacLC.rbf`, the working-tree build).
  `scripts/local.env` MISTER_HOST fixed to .143. Mount config
  `/media/fat/config/MACLC.s0` (NUL-padded 1024B, printf+truncate to edit);
  currently points at the 7.5.5 fixture. CFG = 10MB.
- Working tree (UNCOMMITTED): slot-space $FFFF-ack fix (both tops), sdma_berr
  250 ms timeout + PSDT probe, pseudovia SCSI IRQ/DRQ re-wire, INQUIRY
  identity refactor ("MiSTer  VIRTUAL DISKx"), legacy video-fetch removal,
  PEXC/PEX2/PEX3/PFR probe rev 2 (PFR readout known-bogus, see above).

## Addendum: 7.5.5 result (same build)

Same picture as 7.1: **no Sad Mac** (phantom-card fix holds there too), but
the "Mac OS Starting up…" progress bar freezes at ~10% and is pixel-identical
at T+90 s and T+180 s (`docs/welcome_wedge_2026-06-12/boot755_t90.png` /
`boot755_t180.png`). A crossed-out extension icon sits bottom-left. Both 7.x
images now die in the same async-driver sleep, at the same boot stage class
(extension/startup-item loading), strengthening the single-mechanism theory.
The wedge loop was only PC-decoded on the 7.1 run; assume same for 7.5.5
until probed.
