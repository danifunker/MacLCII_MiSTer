# MAME ground truth — System 7.5.5 early boot (power-on → Happy Mac → Welcome)

*2026-06-12. Companion to `mame_groundtruth_happymac_71_2026-06-12.md` — read
that one first; the setup, tooling, commands, decode notes and caveats are
identical (only image, durations and output names differ). This doc records
the 7.5.5 numbers and, at the bottom, **everything 7.5.5 does differently
from 7.1 in this window**.*

## Setup deltas only

* Disk master: fresh-from-zip extract of
  `~/Documents/MacOS_SampleDisks/MacLC_7-5-5.hda.zip` →
  `/tmp/mame_gt/master/MacLC_7-5-5.hda` (MD5
  `f2d4b662c9725a068bf67e3a06aac55b`, 73,446,400 bytes). NB: this is the
  current 7.5.5 image (built 2026-06-12 11:09), NOT `MacLC_7-5-5_OG.hda`;
  the prior full-boot baseline (`docs/mame_trace_71boot_results.md`) used an
  earlier copy — small frame offsets vs that doc (e.g. first DACK F899 here
  vs F897 there) are image-content differences, not behavior changes.
* Same MAME/ROM/RAMSIZE(10M)/PRAM (`nvram/maclc/egret` md5 `b531c0f4…`
  unchanged across all runs). Fresh clone per run.

## Step 1 — frame timeline

Coarse `SNAP_EVERY=60 MAX_FRAME=4200 -seconds_to_run 90` →
`/tmp/mame_gt/snap/tl755/`; fine `SNAP_EVERY=6 MAX_FRAME=1320
-seconds_to_run 35` → `/tmp/mame_gt/snap/tlf755/`.

| frame | t (s) | event |
|---|---|---|
| 6 / 18 | 0.1/0.3 | white flash / uniform grey (identical to 7.1) |
| 522–528 | 8.7–8.8 | dither-grey backdrop + cursor (identical to 7.1) |
| **906** | **15.11** | **Happy Mac appears** (visible F906–F924) |
| **930** | **15.51** | **"Welcome to Macintosh" box drawn** (same frame as 7.1) |
| 1092 | 18.2 | backdrop switches dither→solid grey (splash transition begins) |
| 1122–1140 | 18.7–19.0 | **"Mac OS" splash** (2nd-stage, solid-grey panel) drawn |
| ~1860 | 31 | menu bar — desktop (extensions done) |

The ROM/boot-block phase is frame-identical to 7.1 through Welcome (F930).

## Step 2 — captures

Raw logs in `/tmp/mame_gt/logs/`, same commands as the 7.1 doc with `755`
substituted; trace bounded `-seconds_to_run 23` (F≈1379), tap runs
`MAX_FRAME=1560`.

### a) Full maincpu trace

→ `maincpu_755.tr.gz` — **22,279,021 lines** (598 MB raw, 17.5 MB gz),
power-on through F≈1379. **Line-for-line identical to `maincpu_71.tr` up to
at least line 13,304,491** (the F524 SCSI-Manager reset; all ROM-phase
landmarks at identical line numbers — see 7.1 doc table). Disk-dependent
divergence begins in the polled-SCSI phase; first CDB writer `00A07784` at
line **14,057,378** (7.1: 14,057,449 — a 71-line poll-loop drift). For
PC-stream diffing, the entire ROM phase needs no alignment at all.

### b) SCSI

→ `scsi_trace_755_welcome.txt(.gz)` + parsed `cmds_755_welcome.txt`.

* **800 commands** F742→F1560 (early polled stream identical to 7.1 for the
  first 16 commands — boot blocks + driver at fixed LBAs — diverging at
  command 17 where file layout starts to matter).
* First DACK access **F899 t=15.0115** (data `4C4B…` "LK" boot block, pc
  `00A092A2`); 7.1 was F897 — the 2-frame offset is the only ROM-phase
  timing difference, driven by this image's longer polled phase.
* By F1560: **2,110,464 DACK bytes / 585,216 accesses** (7.5.5 loads ~55%
  more than 7.1 by the same frame; bulk continues well past F1560).
* **Bus resets: identical 3 writes** — F467 double-pulse + F524, zero after.
* **Bus-error dispatches: the same 5 MOVES probes** (pc `00A03A8A`, F445–510),
  zero afterwards. Vector-$8 site distribution matches 7.1 (System's RAM
  swapper lives at `15A36` instead of `15DE2`).
* Warm-restart-entry fetches: same poll-helper noise profile (5,862 hits,
  concentrated F500–700).

### c) Egret / VIA SR

Same POST/enumeration storm F445–F799 (W=2,815 R=5,939), then sparse.
Window transactions — same three commands as 7.1, two frames earlier:

| frame | t (s) | host→Egret | note |
|---|---|---|---|
| 899 | 15.01 | (status poll `00 03`) | |
| 907 | 15.14 | `01 02 01 AE` → `00 01 00 02 00` | 7.1: F910 |
| 923 | 15.40 | `01 02 01 82` → `00 01 00 02 00 00…` | 7.1: F925 |
| 942 | 15.72 | `01 02 01 56` → clock/XPRAM bytes | **initiated from RAM pc `00016210`** (7.1 used ROM `A14842`) |

### d) VIA1 + pseudovia

VIA1 write totals: ORB 15,588 · SR 2,934 · ACR 1,481 · IFR 1,246 ·
T2CH 593/T2CL 299 · ORA\* 210 · IER 153 · (rest single-digits) — same shape
as 7.1, slightly fewer ORB handshakes. Pseudovia: again **only PB (5,113)
and VIDEO reg $10 (1,660) writes**; reads PB 46,915 / VIDEO 2,471; RAM
config in the frame-0 blind window; IER/IFR untouched after frame 1.

### e) V8 / video

Identical program: POST `7F 40 FF`, probe pairs F446–467, **depth config
F559 `C0` + F561 `32` at the same t to the microsecond as 7.1**, then the
88↔08 slot-VBL toggle. Ariel CLUT bursts F15 (769), F510–523 (843), F10xx
(128) — the Mac OS splash (F1122+) does NOT reload the CLUT in this window.
No depth/mapping change anywhere near the crash window.

### f) SCC

Identical POST exercise (F445–446, 7,710 writes) and F511 two-channel init
(same 32-write program, same PC `A00A5C`). **Silent F512→F1099.** LocalTalk
storm: F1100–F1300, **24,791 writes** (vs 7.1's 19,594 over F1100–F1200) —
later-running and bigger, still entirely post-Welcome.

### g) Interrupts

Totals F1–F1560: **L1 = 4,435, L2 = 827**, L4 ≤10. Window cadence identical
to 7.1 (1×L2 + 1–3×L1 per frame). One 7.5.5-only signature: from ~F1038,
and steadily after F1350, something reads the **L7/NMI vector $7C about
once per few frames** (7.1 never does outside the three all-vector table
sweeps at F146/261/475) — post-Welcome only.

## The crash window (F880→F960) — 7.5.5 ordering

Identical skeleton to the 7.1 table (see that doc), with these substitutions:
first DACK F899 (not 897); ~113 commands F897–935 (7.1: 123) reaching
sb=148,991 by F935 (7.1: 133,628); Happy Mac F906 during the single-sector
READ flurry; Egret transactions F907/F923/F942; Welcome F930. The same
**red-flag list** applies verbatim: no resets, no BERR dispatches, no SCC
traffic, no pseudovia IER/IFR writes, no depth/CLUT changes in the window.

## What 7.5.5 does that 7.1 doesn't (this window + margin)

1. **2-frame-late disk phase**: first DACK F899 vs F897; command stream
   diverges from 7.1 at command #17 (layout), though command *shape* stays
   the same (storms of single-sector `28` READ(10)s with occasional `2A`
   boot-block write-back).
2. **More data, longer**: ~2.11 MB via DACK by F1560 vs 1.36 MB; loading
   continues far past F1560 (full boot moves ~3.5 MB; desktop F1860 vs F1440).
3. **Second-stage "Mac OS" splash** F1092–1140: backdrop dither→solid grey,
   big splash panel — pure framebuffer drawing; NO V8/Ariel/depth writes
   accompany it.
4. **Egret clock/XPRAM read initiated from RAM** (pc `00016210`, F942) —
   the System, not the ROM, makes the third window transaction.
5. **Periodic L7/NMI vector reads** post-F1038 (≈F1350+ steady) — absent in
   7.1.
6. **Bigger, later LocalTalk/SCC storm** (24.8k writes F1100–1300 vs 19.6k
   F1100–1200).
7. System's vector-8 swapper at `15A36` (7.1: `15DE2`) with ~20× more
   swaps (952 vs 99 over a full boot — prior baseline).

None of these differences land inside Happy-Mac→Welcome (F906–F930): in
that window the two OSes are hardware-behaviorally interchangeable, so an
FPGA failure that reproduces on BOTH images cannot be OS-content-specific —
it must sit in the common mechanics: the pseudo-DMA single-sector READ
cadence (selection→CDB→TCR=01→MR DMA→reg7 start→first DRQ, ~30 cmds/frame
burst), the Egret `AE/82/56` exchanges riding the VIA SR between commands,
and the steady L1/L2 interrupt mix on top.

## Raw artifacts

| path | what |
|---|---|
| `/tmp/mame_gt/master/MacLC_7-5-5.hda` | pristine master (MD5 above) |
| `/tmp/mame_gt/logs/maincpu_755.tr.gz` | full 68020 trace, 22.3M lines, F0–F1379 |
| `/tmp/mame_gt/logs/scsi_trace_755_welcome.txt(.gz)` | NCR/DACK/vector tap log to F1560 |
| `/tmp/mame_gt/logs/cmds_755_welcome.txt` | parsed per-command table (800 CDBs) |
| `/tmp/mame_gt/logs/hw_trace_755.txt(.gz)` | VIA1/pseudovia/Ariel/SCC/Egret-SR/AV log to F1560 |
| `/tmp/mame_gt/snap/tl755/`, `/tmp/mame_gt/snap/tlf755/` | timeline PNGs |
| `docs/mame_groundtruth_happymac_2026-06-12/755_*.png` | committed milestone shots |
| `/tmp/scsi_trace_755.txt` | (prior session) full-boot-to-desktop SCSI log |
