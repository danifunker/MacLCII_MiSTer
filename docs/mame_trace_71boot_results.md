# RESULTS — MAME ground-truth trace of the 7.1 / 7.5.5 boot

*2026-06-12. Answers `docs/handoff_mame_trace_71boot.md`. Both disks
(`MacLC_7-1.hda`, `MacLC_7-5-5.hda`) boot **fully to the desktop** in MAME
(`maclc`, 10M RAM) — proof snapshots in `docs/mame_trace_71boot/`. All four
runs were captured in ONE MAME pass per disk with a new all-in-one Lua tap,
`verilator/mame/scsi_trace.lua` (vector-$8 traffic, DACK byte counter with
`emu.time()`, NCR writes, restart-entry fetches, snapshots).*

## TL;DR — the decision tree resolves to branch 1

**Zero SCSI bus errors in MAME.** In BOTH successful boots, the only
bus-error exceptions that ever dispatch are **5 MOVES hardware-probe faults**
(`moves.w $22000.l` at `$A03A8A`, frames 445–510, t≈7.4–8.5 s) — all during
ROM hardware-probe init, **before the first byte of disk data moves**. Across
1.45 MB (7.1) / 3.55 MB (7.5.5) of pseudo-DMA transfers, the blind-transfer
primitive ran **2,882 / 7,002 times**, installed and restored its temp
handler every time, and the handler **never fired once**.

> Per the handoff: *drop the timeout theory; the fix target is why OUR
> transfer reaches a no-DREQ state at beat 14592 at all.* The MAME
> helper's FIFO/halt/16 µs-timeout machinery exists but is never exercised
> by a healthy disk — it's a safety net, not a boot-critical mechanism.

## Setup (reproducible)

```
MAME=~/repos/mame/maclc ROMPATH=~/repos/mame/roms RAMSIZE=10M \
  TR_OUT=/tmp/scsi_trace_71.txt MAX_FRAME=9000 SNAP_EVERY=300 IDLE_EXIT=1800 \
  verilator/mame/run_mame.sh -hard /tmp/MacLC_7-1.hd \
  -autoboot_script verilator/mame/scsi_trace.lua \
  -snapshot_directory /tmp/mame_snap -snapname "trace71/f%i"
```

* MAME binary = `~/repos/mame/maclc` (0.288 dev subtarget build). The
  `/private/tmp/goodroms` romset was WIPED by macOS tmp-cleaning; restored as
  a loose file `~/repos/mame/roms/maclc/350eacf0.rom` (= `releases/boot0.rom.stock`,
  SHA1 `6bef5853…` verified; the `roms/maclc.zip` boot ROM is the BAD dump
  `3ba15a9b…`). Egret ROMs load from the zip.
* MAME's harddisk device rejects `.hda` — clone to `/tmp/*.hd` (originals
  untouched).
* New tap gotcha (now in the script): v8.cpp switches overlay/RAM-config via
  `space.install_ram/rom`, which **silently kills Lua taps over low memory** —
  `scsi_trace.lua` re-installs them every frame until F700 then each 60
  frames, and counts autovector fetches at $60 as a liveness canary
  (`irqvec` must keep climbing; `vbr=0` confirmed all run, so vector reads
  really target `$8`).
* `berr_count.dbg` was NOT used: headless debugger `printf` has no
  capturable sink (mame_compare gotcha 4); the tap approach captures the
  same counts plus the data.

## Run 1 — bus-error / vector-$8 traffic (per full successful boot)

Every `$8` access decodes as save→install→restore triplets from these sites
(read pc / install pc, count 7.1 / 7.5.5):

| site (save pc → installs) | 7.1 | 7.5.5 | identified as (disassembled) |
|---|---|---|---|
| `$A0DBF8` → `$A0DB50` | 52,649 | 60,191 | guarded-dereference utility #2 |
| `$A0DB6A` → `$A0DB5C` | 50,071 | 52,874 | guarded-dereference utility #1 |
| `$A08D14` → from `($1ac,A4)` | **2,882** | **7,002** | **the blind-transfer primitive `$A08CFA`** |
| `$A06D0C` → `$A06CB0` | 497 | 617 | another ROM swap site |
| `$15DE2`/`$15A36` (RAM) | 99 | 952 | System's own vector swapper |
| **actual dispatches** | **5** | **5** | `$A03A8A` `moves.w $22000.l` probes, F445–510 only |

* The two ~50k-call sites are a generic **guarded pointer dereference**
  (swap vector 8 → `move.l (A1),A0` → restore; the installed handlers at
  `$A0DB50/$A0DB5C` are RTE stubs that patch the 68020 fault frame SSW and
  stuff D0=0/-1). Unrelated to SCSI; runs ~6 Hz at idle desktop forever.
  Its guard never faulted either.
* `$A47C62` reads of `$8` are a **vector-table copy loop**
  (`movec VBR,A0; move.l (A0)+,(A1)+`), not a dispatch.
* `$A09BB0` (handler tail): no bus-error-class exception dispatches at all
  during the transfer phase, so it cannot have run from one.
* Bonus: the famous temp handler from `($1ac,A4)` resolves to `$A026F0`
  during boot; vector 8 rests on it from F523 until the System installs its
  RAM handler (`$667EE` in 7.1 at F1369; via `$16BF2` site in 7.5.5).

## Run 2 — DACK timeline (the dack=14592 equivalent)

Counting bytes through `$F06000-$F07FFF` (our `dack_beats` are 16-bit
strobes, so **beat 14592 ≈ byte 29184**; MAME does 1/2/4-byte accesses,
mask-decoded):

* Both OSes: **first DACK access at F=897, t=14.9776 s** — identical to the
  microsecond (deterministic ROM phase); first data = boot block (`4C4B`
  "LK"). Everything before that (165+ early commands: INQUIRY, capacity,
  driver load, etc., F742–896) goes through the **polled** path (NCR reg5/
  reg4 read storms, thousands/frame) — NOT the DACK window.
* Totals: 7.1 = 1,448,448 bytes / 401,376 accesses (loading done by ~F1800);
  7.5.5 = 3,554,816 bytes / 970,289 accesses (bulk done by ~F1800, trickle
  to F3600).
* **At byte 29184 there is NO anomaly in MAME**: no pause, no burst, no
  phase change, no bus reset, no retry. Steady command cadence (~4–14 ms
  between commands in 7.1; ~1 µs/byte inside transfers).

**Where byte 29184 falls — strikingly different between the two OSes:**

* **7.1: exactly at a command boundary.** It is the FIRST longword of the
  data phase of `READ(10) LBA 0x2902 (10498), 1 sector` — a fresh selection
  + CDB + DMA-start ~4 ms after the previous command:
  ```
  t=15.118011 F=906 sb=28669 IN CDB=28000000290100000100   (LBA 10497)
  t=15.122288 F=906 sb=29181 IN CDB=28000000290200000100   (LBA 10498) ← byte 29184 is its 1st longword
  t=15.136689 F=907 sb=29693 IN CDB=280000002DB600000100   (LBA 11702)
  D 29184 RD t=15.122306 F=906 off=00F06060 data=76000643 pc=00A092A2
  ```
  The sector content (`dd skip=10498`) is System-file **resource-map data**
  (`CDEF/MBDF/WDEF/KCHR/DRVR/clut/atlk/INIT…`) — bit-identical to the tap
  data. Nothing special about the data; the boot at this stage is a flurry
  of scattered single-sector resource reads.
* **7.5.5: mid-burst.** Byte 29184 lands at offset ~20,483 (sector 40 of 48)
  inside `READ(10) LBA 0x143BF len 0x30`, during a byte-wide alignment
  stretch of the copy loop (pc `$A092BC`), 30 µs loop-transition gap only.

**Implication:** if the FPGA death is at the same cumulative count for BOTH
OSes, the trigger correlates with OUR cumulative state (count/FIFO/pointer
wrap, HPS interaction), not with a particular SCSI command shape. If 7.5.5
actually dies at a different count, the 7.1 boundary correlation says: look
at **first-DREQ-of-a-new-data-phase handling** (selection → CDB → TCR=data-in
→ MR=DMA → reg7 DMA-start → first DRQ) — the deferred-CSR-REQ / req_bus
continuity territory of the lbmactwo wedge fixes. *FPGA side: capture the
exact dack count at the 7.5.5 death to disambiguate.*

## Run 3 — NCR command stream

Full per-command tables (time, frame, cumulative start byte, direction,
CDB) extracted from the taps: `docs/mame_trace_71boot/cmds_71.txt` (1,017
DACK-phase commands) and `cmds_755.txt` (2,175). CDBs decode only for the
ROM SCSI-Manager path (CDB writer pc `$A07784`); the early polled commands
show empty CDBs.

**Bus resets: identical in both runs, and all PRE-disk-I/O:**
```
t=7.797 F=467  pc=$A47322/$A47334  (ROM probe init — double pulse)
t=8.753 F=524  pc=$A07A0A          (SCSI Manager init)
```
Zero ICR-bit7 writes after F524 in either OS. So: a successful boot contains
exactly these two reset episodes; if our failing boot's two resets are at
the same points, they're normal — any reset NEAR the death window would be
something MAME never does.

## Run 4 — the "ROM restart entry" premise is wrong

`$A14880` and `$A1490A` are NOT restart entries. Disassembly:

* `$A14878-84`: a **poll loop** (`tst.l ($10,A0); btst #0,(A2); bsr $a148c4;
  bra $a14878`) — `$A14880` is its back-branch.
* `$A14900-10`: a **TimeDBRA-calibrated delay** (`move.w $cea.w,D1;
  lsr.w #3,D1; tst.b (A1); dbra D1,$a14908`) — `$A1490A` is the dbra.

MAME executes them **constantly during a healthy boot** (≈5,400 fetch-hits
F300–900) and **~6 Hz forever at the idle desktop** (30 hits/300 frames,
in lockstep with the 6 Hz guarded-dereference vector swaps — a periodic OS
task). A PC sighting of `$A1490A`/`$A14880` in our flight recorder therefore
carries **no restart information** — it means only "the CPU is in a common
ROM delay/poll helper", which any driver (SWIM, Egret, SCSI) uses. The
FPGA-side restart evidence needs to be re-anchored on something else (e.g.,
the actual ROM reset entry from the recorder's jump-target history, or
low-mem `BootGlobs`/warm-start flag writes).

## Artifacts

* Tool (committed): `verilator/mame/scsi_trace.lua` — one-pass capture,
  env-configurable; regenerate everything with the Setup command above.
* Tables + desktop proof (committed): `docs/mame_trace_71boot/`.
* Full tap logs (NOT committed — 62 MB / 120 MB, regenerable in ~2 min each):
  `/tmp/scsi_trace_71.txt`, `/tmp/scsi_trace_755.txt`; snapshots under
  `/tmp/mame_snap/trace{71,755}/`. NB: macOS wipes `/tmp` after ~3 days.
* `hfs_forensics.py` (handoff's LBA→file mapper) does not exist on this Mac
  (Windows-box path); the death LBA was identified by direct sector dump
  instead.

## What the FPGA side should do with this

1. **Stop building the BERR timeout as the boot fix.** It's still worth
   having eventually (real LCs have it; MAME documents it), but a healthy
   boot never uses it — it cannot be the 7.x divergence.
2. **Target the DREQ/stall side at beat 14592.** For 7.1 the death beat is
   the very first data longword after a fresh
   selection→CDB→TCR(01)→MR(02)→reg7-DMA-start sequence. Diff our
   PSCW/PSNC captures against this exact sequence; suspects: first DRQ of a
   new phase never asserting (deferred CSR REQ path), req_bus continuity
   across the command boundary, or the HPS block-fetch latency for a new
   LBA colliding with the CPU's immediate blind read.
3. **Get the 7.5.5 death count** from the recorder to test the
   "same-count ⇒ our-side state accumulation" hypothesis.
4. The two bus resets in our failing boot are likely the normal F467/F524
   pair — verify their timing; a third or late reset would be abnormal.
