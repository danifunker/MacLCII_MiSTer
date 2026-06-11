# SCSI write byte-slip + missing pseudo-VIA IRQ delivery — findings & fixes (2026-06-10)

*Branch `scsi-fixes-from-lbmactwo`, following the LBMacTwo port (`8c8a895`).
User report: System 7 still hangs at boot; hard disks occasionally corrupt.
Forensic evidence: `scratch/MacLC_6-0-8-macsbug.hda.zip` (pristine) vs
`scratch/MacLC_6-0-8-macsbug_corrpupt.hda` (after corrupting sessions).*

## TL;DR

1. **The 8c8a895 port is faithful** — `rtl/scsi.v` is byte-identical to the
   LBMacTwo reference, the ncr5380 chip-side round-3 edits match `b760944`.
   The old COPY-class corruption (wedged-target stale-buffer flushes) is
   **gone** from the forensic record: the 4376c8f-class fixes hold.
2. **OS 7 hang**: the port stopped at "step 2" — `o_irq` was dangling and
   `pseudovia.sv` had **no SCSI inputs**, so the HD SC 4.3 driver (loaded
   from the `Apple_Driver43` partition both test disks carry) sleeps on
   pseudo-VIA IFR flags that could never set. FIXED this session (below).
3. **NEW corruption class, forensically proven**: individual multi-sector
   WRITE commands land on disk with **one foreign byte inserted
   mid-stream and the rest of the payload shifted +1** (last byte pushed
   out). At least FOUR separate write commands slipped in one session.
   Additionally, several write commands were **lost entirely** (resource
   map updated to point at data that never landed). NOT yet fixed —
   instrumentation added (below).

## Forensic detail (how we know)

Tooling: `../lbmactwo_MiSTer/scripts/hda_match_sources.py` (now with a
SHIFT class — see below) + `hfs_forensics.py` + per-window alignment
sweep (best `d` where `corrupt[i] == pristine[i-d]`).

- 83 changed sectors, **zero COPY-class**. Legit churn: MDB, catalog
  B-tree nodes, a 640×480→512×384 screen Rect inside the System file.
- **System file resource map** (cnid 34, rsrc fork): the OS rewrote the
  map; the 6-sector command covering LBAs 3419–3424 landed with byte 0
  intact, a foreign `0x0e` at payload offset 1, everything after shifted
  +1 (alignment d=+1 holds continuously to the command's end at the
  extent boundary; the command's last byte was dropped). Fork header,
  dataLen, mapLen, type count all unchanged → not a legit RM rewrite;
  the type list is garbled on disk → System file unusable.
- **MacTCP DNR** (rebuilt at every boot, written as three commands across
  its extents): 2-sector command at 9503–9504 slipped starting ~offset
  264; two contiguous 32-sector (16 KB) commands at 10899–10930 and
  10931–10962 **each independently shifted +1** from near their own
  start. Slip onset offset varies per command → mid-stream insertion,
  consistent with interrupt-interleaved transfer resume (LBMacTwo
  "Suspect 3"), not just a command-start race.
- **Lost writes**: the map tail (separate, clean command at 3739–3742)
  updated ~20 resource data offsets from `0x07xxxx` to `0x06xxxx`, but
  the data section at those targets is byte-identical to pristine — the
  moved resources' data writes never hit the disk and the OS saw no
  error. Candidate mechanism: the final-block flush ack racing the BSY
  drop (`io_ack & target_bsy` masking in ncr5380.sv) + the Mac's
  timeout/bus-reset recovery storm; unproven.

## Changes made this session

1. **Pseudo-VIA SCSI delivery (the OS 7 fix)** — `rtl/pseudovia.sv` gained
   `scsi_irq`/`scsi_drq` LEVEL inputs driving IFR bits 3/0 per MAME
   `pseudovia.cpp` (`scsi_irq_w` → bit 3 "CB2", `scsi_drq_w` → bit 0
   "CA2"; assert sets, deassert clears). Bit 3 was previously
   (incorrectly vs MAME) assigned to `slot_irq` — slot input is tied 0 in
   both tops, so nothing depended on it. `dataController_top.sv` now
   exposes `scsiIRQ` (= ncr5380 `o_irq`, the reg-7-cleared latch) and
   both tops (`MacLC.sv`, `verilator/sim.v`) wire `scsiIRQ`/`scsiDREQ`
   into the pseudovia.
   **Why LEVEL, never edge:** LBMacTwo round-3 HW test (`1ee80e8`) proved
   the edge model deadlocks — the latched IRQ from the previous chunk
   holds the line, no new edge fires at the next chunk boundary, the
   driver's IFR poll sleeps forever. Level-driven flags are
   self-correcting: driver polls IFR → ISR reads 5380 reg 7 → latch
   clears → flag follows.
   Note: MAME's `maclc.cpp` boots System 7 *without* these flags only
   because it implements the other hardware path (DACK-without-DRQ → bus
   error → driver retry), which this core does not have (it has the
   indefinite DTACK stall, `MacLC.sv` `selectSCSIDMA ? ~scsiDREQ`).
2. **Byte-slip instrumentation** (SIMULATION-gated, no FPGA impact):
   - `rtl/scsi.v`: `SCSI_WR_OVERRUN` (ACK beat after `data_complete` in a
     write data phase = a phantom byte was consumed earlier),
     `+scsi_wr_trace` per-beat write log, and `SCSI_FLUSH_STUCK` (io_wr
     pending while bus idle = the masked-ack race).
   - `rtl/ncr5380.sv`: `NCR_WR_PHASE_MISMATCH` (host pseudo-DMA write
     while `!bsr_pmatch` = leftover host bytes after the target completed
     early — catches the slip even though `dma_ack` is suppressed once
     pmatch drops).
3. **SHIFT-class detector** in
   `../lbmactwo_MiSTer/scripts/hda_match_sources.py`: classifies a
   changed sector as `SHIFT±d` when it matches the pristine image
   displaced by d ∈ ±1..±4 at ≥92%. Validated against the corrupt pair:
   flags exactly the System-map and DNR slip runs.

## Validation protocol (per session / per fix)

1. Keep a pristine copy + md5 of the test .hda.
2. Boot a session on HW (controlled ops: boot → Finder → small copy →
   clean shutdown), copy the image back.
3. `python scripts/hda_match_sources.py <pristine> <after>` (lbmactwo
   repo): PASS = zero COPY **and zero SHIFT** runs; NOVEL only in
   catalog/Desktop/MDB/DNR regions (`hfs_forensics.py <img> <lba>...`
   maps suspects to owning files).
4. OS 7 boot test for the pseudo-VIA fix: System 7 should get past the
   Welcome screen SCSI mount scan. If it still wedges, MacsBug (OSD R5
   Level-7 NMI) to capture the poll loop PC.

## Open items (next sessions)

- **Find the byte-slip mechanism.** Leads, in order: (a) interrupt-
  interleaved transfer resume (slip onset at arbitrary offsets); (b) the
  manual-PIO→pseudo-DMA transition at data-phase start; (c) longword
  write path (`tg68_longword` glue — LBMacTwo "Suspect 1", never
  byte-validated on the LC's 16-bit TG68 bus). Trace MAME `maclc` 5380
  write sequences for the driver's exact access pattern
  (`docs/mame_compare.md` tooling); try to repro in Verilator with the
  new instrumentation (`+scsi_wr_trace`, watch for `NCR_WR_PHASE_MISMATCH`
  / `SCSI_WR_OVERRUN`).
- **Lost writes**: correlate with `SCSI_FLUSH_STUCK`; consider holding
  BSY (or deferring IDLE) until the final `io_ack` arrives, so the flush
  ack can't be masked — needs care vs the documented reset/re-scan
  recovery behavior.
- Expect corruption frequency may go **UP** after the OS 7 fix (the async
  driver path will exercise multi-chunk transfers it never completed
  before) until the slip is fixed — treat both as one campaign gated by
  the protocol above.
