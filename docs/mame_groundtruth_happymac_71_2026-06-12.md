# MAME ground truth — System 7.1 early boot (power-on → Happy Mac → Welcome)

*2026-06-12. Complete capture of everything MAME's `maclc` does from power-on
through the Happy Mac up to (and past) the moment "Welcome to Macintosh" is
drawn, for line-by-line comparison against the FPGA core's
Happy-Mac-then-restart failure. Companion doc: the same capture for 7.5.5 in
`mame_groundtruth_happymac_755_2026-06-12.md` (includes the 7.5.5-vs-7.1
delta list). Process/gotchas: `docs/mame_compare.md`.*

## Setup (all runs)

* MAME binary `~/repos/mame/maclc` (0.288 dev build), `-rompath ~/repos/mame/roms`
  (`maclc/350eacf0.rom` = good dump, == `releases/boot0.rom.stock`; Egret ROMs
  from `roms/maclc.zip`). **`-ramsize 10M`** (matches prior 7.x baseline).
  All runs via `verilator/mame/run_mame.sh` (adds `-nothrottle -video opengl
  -nowindow -sound none`), each bounded with `-seconds_to_run`.
* Disk master: fresh-from-zip extract of
  `~/Documents/MacOS_SampleDisks/MacLC_7-1.hda.zip` →
  `/tmp/mame_gt/master/MacLC_7-1.hda` (MD5 `5ef0deb214a3659ff74035550baabbc4`).
  MAME mutates mounted disks, so **every run got its own fresh clone**
  (`cp master/… /tmp/mame_gt/dXX.hd`; MAME rejects the `.hda` extension).
* PRAM: MAME persists Egret PRAM at `nvram/maclc/egret` (repo root). Hash
  `b531c0f45ddaa373d665e2cb74ab0726` before AND after all runs — a stable
  determinism input. (If the FPGA PRAM differs materially, early config can
  legitimately diverge.)
* Screen = 25.175 MHz, 800×525 ⇒ **59.94 fps; frame ≈ emulated seconds × 60**.
* Determinism: repeated runs reproduce timestamps to the microsecond through
  the whole ROM phase; the 7.1 and 7.5.5 **maincpu traces are line-for-line
  identical up to ~line 13.3M** (≈F740, where disk contents start mattering).

## Step 1 — frame timeline (snapshots)

Runs: `SNAP_EVERY=60 MAX_FRAME=3000 … -autoboot_script verilator/mame/snap.lua
-seconds_to_run 65` (coarse) and `SNAP_EVERY=6 MAX_FRAME=1080
-seconds_to_run 30` (fine, to pin the Happy Mac). PNGs:
`/tmp/mame_gt/snap/tl71/` (coarse, frame=(idx+1)·60) and
`/tmp/mame_gt/snap/tlf71/` (fine, frame=(idx+1)·6). Key frames copied to
`docs/mame_groundtruth_happymac_2026-06-12/`.

| frame | t (s) | event |
|---|---|---|
| 6 | 0.1 | white flash (V8 video comes up) |
| 18 | 0.3 | uniform mid-grey (framebuffer blank; POST running) |
| 522–528 | 8.7–8.8 | 50% dither-grey backdrop drawn, arrow cursor top-left |
| **906** | **15.11** | **Happy Mac appears** (visible F906–F918; erased by F924) |
| **930** | **15.51** | **"Welcome to Macintosh" box drawn** |
| 1380–1440 | 23–24 | menu bar appears — desktop |
| ~1800 | 30 | disk loading done (DACK trickle ends) |

The FPGA crash window (Happy Mac shown, restart before Welcome) is only
**F897–F930 ≈ 0.55 s** in MAME terms — see the event list at the bottom.

## Step 2 — captures (one bounded run each, fresh disk clone each)

All raw logs (and .gz keepers): `/tmp/mame_gt/logs/`. NB macOS wipes /tmp
after ~3 days — copy out if still needed.

### a) Full maincpu execution trace

```
MAME=~/repos/mame/maclc ROMPATH=~/repos/mame/roms RAMSIZE=10M \
  verilator/mame/run_mame.sh -hard /tmp/mame_gt/d71_tr.hd \
  -debug -debugscript /tmp/mame_gt/trace71.dbg -seconds_to_run 20
# trace71.dbg = "trace /tmp/mame_gt/logs/maincpu_71.tr,maincpu" + "go"
```

→ `/tmp/mame_gt/logs/maincpu_71.tr.gz` — **18,537,034 lines** (500 MB raw,
10.6 MB gz), power-on (line 1 = `0000002A: jmp ($8c,PC)`, the reset vector
via the overlay mirror) through F≈1199. PCs are 8-digit `00Axxxxx`
(mame_compare gotcha 6). Diff recipe: mame_compare §4.

Landmark first occurrences (for aligning a divergence diff):

| line | PC | what |
|---|---|---|
| 41 | `0000312E` | early POST running in the low overlay mirror |
| 468 | `00A03A8A` | first MOVES hardware-probe (`moves.w $22000.l`) |
| 12,045,973 | `00A47322` | probe-init SCSI bus-reset site (F467) |
| 13,133,235 | `00A14842` | Egret VIA-SR write helper |
| 13,304,491 | `00A07A0A` | SCSI-Manager-init bus reset (F524) |
| 14,057,449 | `00A07784` | first ROM SCSI-Manager CDB byte write (F745) |
| 14,132,118 | `00A092A2` | first pseudo-DMA (DACK) read loop (F897) |

### b) SCSI (scsi_trace.lua — NCR writes, CDBs, DACK bytes, BERR/restart audit)

```
TR_OUT=/tmp/mame_gt/logs/scsi_trace_71_welcome.txt MAX_FRAME=1560 \
  SNAP_EVERY=300 IDLE_EXIT=0 … -hard /tmp/mame_gt/d71_scsi.hd \
  -autoboot_script verilator/mame/scsi_trace.lua -seconds_to_run 35
```

→ `scsi_trace_71_welcome.txt(.gz)`; per-command table (new tool
`verilator/mame/parse_scsi_cmds.py`) → `logs/cmds_71_welcome.txt`
(`t= F= sb= dir= CDB=`, sb = cumulative DACK byte count at command start).

* **879 commands** F742→F1560. First disk command F742 (`08` READ(6) LBA 0,
  polled, no DACK). First DACK access **F897 t=14.9777**, first data
  `4C4B…` ("LK" boot-block signature), pc `00A092A2`. By F1560:
  **1,360,896 DACK bytes / 377,664 accesses**.
* **Bus resets (ICR bit7): exactly 3 writes, all pre-disk-I/O** — F467
  double-pulse (pc `A47322`/`A47334`, ROM probe init) + F524 (pc `A07A0A`,
  SCSI Manager init). **Zero resets after F524.** Any reset near the FPGA
  death window is abnormal.
* **Bus-error vector dispatches: exactly 5** — the `moves.w $22000.l` probes
  at pc `00A03A8A`, frames 445/467/471/510/510. **Zero from F511 through
  Welcome+margin.** All other vector-$8 traffic is the known
  save→install→restore triplets (guarded-dereference `A0DBF8`/`A0DB6A`,
  blind-transfer primitive `A08D14` save sites, `A06D0C`, System swapper
  `15DE2`) — handlers never fire.
* **Warm-restart "entries" $A14880/$A14908**: 5,739 fetch hits, almost all
  F500–700 (Egret-heavy phase), single-digits per 100 frames afterwards —
  reconfirming these are common ROM poll/delay helpers, NOT restart evidence.

### c) Egret / VIA shift register (complete byte exchange)

From the combined run (d) — `hw_trace.lua` logs every SR ($F01400) read and
write with frame/PC (`SRR` / `V1W reg=A` lines). Caveat: Lua taps install at
frame 1, so frame 0 (~16 ms) is blind — the maincpu trace covers it.

Distribution (bytes through the SR): F0 idle ·· **F445–F799 = POST/ADB
enumeration storm** (W=2,810 R=5,977; cursor+param reads) ·· then sparse
autopoll. **In the crash window**: three transactions, all on the ROM
helpers (`A14842` write entry, `A148DE` byte loop, `A14928`/`A14970` reads):

| frame | t (s) | host→Egret | Egret→host |
|---|---|---|---|
| 899 | 15.00 | — | status poll reads `00 03` |
| 909–910 | 15.18 | `01 02 01 AE` | `00 01 00 02 00` |
| 925 | 15.44 | `01 02 01 82` | `00 01 00 02 00 00 00 00 00 00` |
| 944 | 15.75 | `01 02 01 56` | `… 00 29 82 A6 06 …` (XPRAM/clock read) |

### d) VIA1 + pseudovia (VIA2) register traffic

```
TR_OUT=/tmp/mame_gt/logs/hw_trace_71.txt MAX_FRAME=1560 \
  … -hard /tmp/mame_gt/d71_hw.hd \
  -autoboot_script verilator/mame/hw_trace.lua -seconds_to_run 35
```

→ `hw_trace_71.txt(.gz)` — every write logged (`V1W`/`PVW` value+PC+frame),
reads summarized per-register per-frame (`V1R`/`PVR` lines).

VIA1 ($F00000, reg=(addr>>9)&0xF) write totals F1–F1560:
ORB 18,119 (Egret TIP/byteack handshakes) · SR 2,946 · ACR 1,487 (SR mode
flips in/out) · IFR 1,246 · T2CH 593/T2CL 299 · ORA\* 210 · IER 153 ·
DDRA 17/DDRB 12 · T1CH 5/T1CL 2 · PCR 2. Reads are dominated by IFR polling
(per-frame counts in the `V1R` lines).

Pseudovia ($F26000, V8 decode `off&0x1f`, PA at off $200–$3FF): writes touch
**only PB (4,872 — includes alias offsets $1A00) and VIDEO reg $10 (1,808)**;
reads only PB (56,238) and VIDEO (2,471). **The RAM-config write (reg $01)
happens inside the frame-0 blind window** (POST sizes RAM in the first
~16 ms) — it's in the maincpu trace; no OTHER config write ever follows.
The pseudovia IER/IFR regs ($02/$03/$12/$13) are **never touched after
frame 1** in this whole window.

### e) V8 / video control writes

From the same `hw_trace` run (`PVW reg=10` + `ARW` Ariel lines):

* Depth/monitor setup: POST writes `7F 40 FF` (F15, pc `A02Fxx`); probe
  dance F446–467 (`7F 00 FF` pairs, pc `A46FD6`/`A47006`); **F559
  `data=C0` (pc `A4B54E`) then F561 `data=32` (pc `A4B7BC`)** = the boot
  depth/monitor config — identical in 7.5.5.
* From F734 onward a steady **`88`↔`08` toggle at alias off `$1C10`**
  (pc `A0A08A`/`A0A0BA`, ~3–6/frame once the system runs) — the video
  driver's slot-VBL ack/re-enable cadence. Present through the whole
  window; **no depth change anywhere near Happy-Mac→Welcome**.
* Ariel RAMDAC ($F24000): CLUT bursts at F15 (769 writes, POST grey ramp),
  F510–523 (843, desktop pattern setup), F10xx (128). None in the window.

### f) SCC (every register write, WR-decoded)

`SCW` lines in `hw_trace_71.txt` (WR decode via WR0-pointer tracking;
ports: ctlB=$F04000 ctlA=$F04002 dataB=$F04004 dataA=$F04006, byte on
D15-D8):

* F445–446: POST register exercise, 7,710 writes (WR2 value ramp, pc
  `A46Exx/A46Fxx`).
* F511: real init, both channels, 32 writes (pc `A00A5C`):
  `WR9=C0` (force reset) → `WR9=40` → `WR4=4C` → `WR2=00` → `WR3=C0` →
  `WR15=00` → 2× `WR0=10` (reset ext/status) → `WR1=00`, then the same for
  the second channel with `WR9=80`.
* **F512 → F1099: total silence (zero writes).** The crash window contains
  NO SCC traffic.
* F1100–F1200: **19,594 writes — the LocalTalk/.MPP driver init storm**
  (the scc.v wedge-fix territory) — entirely POST-Welcome.

### g) Interrupts (per-frame autovector fetch counts)

`AV` lines (vector=addr>>2: hex 19=L1, 1A=L2, 1C=L4, 1F=L7). Totals
F1–F1560: **L1 = 5,310, L2 = 827, everything else ≤10** (the 5-ish counts
on L3–L7 are three all-vector table sweeps at F146/F261/F475, not
dispatches). Window cadence (F890–960): **exactly 1×L2 + 1–3×L1 per frame**
(L2 = pseudovia slot-VBL 60 Hz; L1 = VIA1 tick + Egret SR), with a brief
10×L1 burst at F911 (Egret transaction completion). No L4 (SCC) interrupts
anywhere in the window.

## The crash window, as one ordered event list (F880 → F960)

Everything the hardware does between "dither grey + cursor" and "Welcome
drawn", merged from the captures (t in emulated seconds):

| F | t | event (PC) |
|---|---|---|
| 880–896 | 14.69–14.96 | polled-SCSI tail: driver/System single-sector READ(6)/READ(10)s, no DACK; steady 1×L2+1×L1 per frame; video 88/08 toggles |
| 897 | 14.9775 | **first pseudo-DMA command**: READ(10) LBA $60 ×2 (boot blocks, "LK"), first DACK read t=14.9777 pc `A092A2` |
| 899 | 15.00 | Egret status poll (SR reads `00 03`, pc `A14970`) |
| 900–905 | 15.02–15.11 | ~30 single-sector READ(10)s, sb 1,532→28,156 (incl. one WRITE(10) `2A` LBA $62 — boot-block dirty flag); scattered resource reads |
| **906** | **15.117** | **Happy Mac drawn.** READs continue: LBA $2D82/$2D83/$2901/**$2902** (sb=29,180 = the famous beat-14592 boundary, byte 29,184 = 1st longword of LBA $2902's data) |
| 909–910 | 15.18 | Egret transaction `01 02 01 AE` → `00 01 00 02 00` |
| 911 | 15.19 | L1 burst ×10 (Egret completion IRQs) |
| 912–924 | 15.2–15.4 | READ stream continues (System file resources), sb → ~79k |
| 925 | 15.44 | Egret transaction `01 02 01 82` → `00 01 …` |
| 927 | 15.47 | re-READ LBA $2902 (sb=79,868) |
| **930** | **15.51** | **Welcome to Macintosh box drawn** |
| 944 | 15.75 | Egret transaction `01 02 01 56` (clock/XPRAM read → `29 82 A6 06`) |
| 960 | 16.0 | READ stream ongoing; SCC still silent; no resets, no BERRs, no depth changes |

**What never happens in this window (FPGA red flags if seen):** SCSI bus
reset (ICR bit7), bus-error dispatch, SCC access of any kind, pseudovia
IER/IFR writes, video depth change, Ariel CLUT write, T1 reprogramming.

## Raw artifacts

| path | what |
|---|---|
| `/tmp/mame_gt/master/MacLC_7-1.hda` | pristine master (MD5 above) |
| `/tmp/mame_gt/logs/maincpu_71.tr.gz` | full 68020 trace, 18.5M lines, F0–F1199 |
| `/tmp/mame_gt/logs/scsi_trace_71_welcome.txt(.gz)` | NCR/DACK/vector tap log to F1560 |
| `/tmp/mame_gt/logs/cmds_71_welcome.txt` | parsed per-command table (879 CDBs) |
| `/tmp/mame_gt/logs/hw_trace_71.txt(.gz)` | VIA1/pseudovia/Ariel/SCC/Egret-SR/AV log to F1560 |
| `/tmp/mame_gt/snap/tl71/`, `/tmp/mame_gt/snap/tlf71/` | timeline PNGs (60- and 6-frame grain) |
| `docs/mame_groundtruth_happymac_2026-06-12/71_*.png` | committed milestone proof shots |
| `/tmp/scsi_trace_71.txt` | (prior session) full-boot-to-desktop SCSI log, F9000 |

Tools: `verilator/mame/hw_trace.lua` (NEW — combined VIA/SCC/V8/Egret/IRQ
tap), `verilator/mame/parse_scsi_cmds.py` (NEW — CDB table + reset audit
from scsi_trace logs), plus the existing `scsi_trace.lua`/`snap.lua`/
`run_mame.sh`. Regenerate everything with the commands above (~2 min each;
the debug traces ~1–2 min more).
