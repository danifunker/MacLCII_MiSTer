> **✅ RESOLVED 2026-06-13 PM — see `docs/findings_mame_floppy_driveid_2026-06-13.md`.**
> MAME 0.264 `maclc` ran in WSL (tooling in `verilator/mame/floppy/`). The ground
> truth **overturned the bit-order theory below**: the maclc ROM drives the SWIM in
> **ISM mode** for floppy access (even 800K), and the real bugs are (1) our ISM
> register decode (`cpuAddrRegHi[3:1]`→ must be `[2:0]`/n&7), (2) the drive never
> reports a SuperDrive because sense regs 0xC,0xD aren't 1 (signature must be
> `x011`), and (3) ISM head-select is Mode bit5, not VIA PA5. Three source-grounded
> fixes were applied to `rtl/swim.v` + `rtl/floppy.v` (UNVERIFIED — needs a Quartus
> build + HW deploy). The `{ca2,ca1,ca0,SEL}` bit-order was a red herring. Read
> the findings doc; the original analysis below is kept for history.

> **HW RE-TEST 2026-06-14 (parked by user) — symptom UNCHANGED.** On RBF
> `270c24d4` (today's SCSI-prefetch build off `fix-os7-scsi-welcome-wedge`,
> commit `1a732bf`), floppy re-tested: **`TETRIS MAX` (a 1.4 MB MFM disk)** →
> "*This disk is unreadable — Eject / One-Sided / Two-Sided*" dialog; a
> **System 6.0.7 disk** (800K) → the **same** dialog. A 1.4 MB disk getting the
> One-/Two-Sided **GCR** prompt = bug #1 below (SuperDrive not recognized → OS
> never enters MFM); the 800K disk = bug #2 (GCR data path garbage). No change vs
> 06-13. **The three 06-13 ISM/drive-ID fixes ARE in this build** (verified in
> tree): Fix A SuperDrive `x011` signature `rtl/floppy.v:122-134`, Fix B ISM
> `n&7` decode `rtl/swim.v:258`, Fix C mode-bit5 head-select `rtl/swim.v:144`.
> So they are **necessary-but-not-sufficient** — with all three in, the OS still
> does NOT enter MFM mode and still reads garbage. The remaining blocker is the
> **read DATAPATH + the deeper drive-ID handshake** (does the OS need the
> MFM-mode phase strobe `$9`-on/`$D`-off reflected in `MFMModeOn`? is the ISM
> FIFO/Setup read path needed? is_2m/DRVIN polarity?), per "Still open" in
> `docs/findings_mame_floppy_driveid_2026-06-13.md`. **NEXT SESSION:** get a MAME
> runtime trace of the drive-ID phase→register reads AND a clean sector read with
> a *bootable* disk image (the 06-13 attempt failed because the test images
> weren't bootable, so MAME bailed before a sector read).

# Handoff — MAME ground-truth: floppy drive-ID + GCR/MFM read (for 1.44 MB)

*2026-06-13. The 1.44 MB MFM read build (`MacLC.rbf` md5 `49e69e55`) is deployed.
The RTL is correct as far as it goes — DC42/raw **detection** and the **MFM track
encoder** are verified — but HW testing shows the OS reads **every** floppy as
800K GCR and gets garbage. Two bugs need MAME runtime ground truth to fix.
**Can run from WSL** — see setup. Companion source-spec already in tree:
`docs/swim_ism_read_reference.md`.*

## The two bugs (confirmed on HW this session)

1. **SuperDrive not recognized → the OS never enters MFM/ISM mode.** Every disk
   triggers the GCR "*This disk is unreadable — Eject / One-Sided / Two-Sided*"
   dialog (One-/Two-Sided = the 400K/800K **GCR** format prompt), including a
   *valid* 1.44 MB DC42 (`Tetris Max.dsk`: header verified — name-len `0f`,
   **disk_format byte 80 = `03`** = 1440K MFM, magic `0100`, data_size
   `0x168000`, tag_size 0). So detection is fine; the OS just never switches to
   MFM.
   - **Root suspicion:** the OS identifies a SuperDrive via a **multi-register
     sense SIGNATURE** (the "`x011`" pattern across the top drive-ID registers),
     not just the one SUPERDR bit. Our `floppy.v` decodes the sense register as
     **`{ca2,ca1,ca0,SEL}`**; MAME `floppy.cpp` uses **`(phases&7)|(SEL<<3)`** —
     a DIFFERENT bit order. SUPERDR (our idx `$A`) and is_2m (our idx `$F`) were
     verified at the right indices, but the rest of the signature maps through
     that bit-reversal to indices we did NOT set correctly. Need the exact phase
     combos the OS strobes and the values it expects.
   - Also unknown: does the OS require the **MFM-mode-on phase strobe** (`$9`;
     `$D` = GCR-on) reflected in the `MFMModeOn` sense before it proceeds?

2. **GCR data path produces garbage** — genuine 800K disks (`tattletech2.17.dsk`
   = 819,200 bytes) are **also** unreadable. Pre-existing "data unreadable"
   issue; the byte-demux fix this session (`extra_rom_data_demux` now selects on
   `dskReadAddr[0]`, the correct byte-parity, in `MacLC.sv`) was **not**
   sufficient. Need the IWM read protocol + cadence MAME uses.

## What to capture (run `maclc` reading an 800K disk AND a 1.44 MB disk)

1. **Drive-ID / sense reads — THE key capture.** Every IWM-mode read of the
   drive register during the OS's drive probe: log the **phase lines**
   (`ca0/ca1/ca2/SEL`) and the **bit returned**. Build the truth table of
   `(phase combo → value)` the OS expects for: *SuperDrive present*, *is_2m
   (HD)*, and the **full identify signature**. Diff against our
   `floppy.v driveRegsAsRead`. This directly fixes bug #1 (the bit-order).
2. **IWM→ISM mode switch.** Does the OS issue the ISM-switch sequence (the 4×
   IWM mode-reg write toggling bit 6 — `swim.v iwm_to_ism_counter`) for a 1.44 MB
   disk, and at what point? If it NEVER switches, drive-ID is the sole blocker.
3. **GCR read protocol (800K).** The IWM data-register accesses (`$F16000`,
   the `q6`/`q7` register combos) read loop + cadence, vs our `floppy.v` 128-clk
   byte timer + IWM read latch (`readLatchClearTimer`). Pins bug #2.
4. **ISM/MFM read protocol (1.44 MB).** mode/setup/action writes, FIFO (reg0/1)
   reads, handshake (reg7) polling — confirm `swim.v`'s ISM read path matches
   once the drive-ID lets the OS get there.

## Can this run from WSL? YES.

MAME is native on Linux, so WSL2 works — and it's a **better** fit than the prior
macOS setup (WSL has `timeout`; macOS didn't — see `docs/mame_compare.md`
gotchas). The existing tooling is bash/lua/python, fully portable.

**Setup:**
- **MAME with the `maclc` driver:** `apt install mame` (may be old) OR fetch/
  build a recent MAME — the `maclc` machine + the SWIM1 / `mfd75w` SuperDrive
  are in mainline. Verify: `mame -listxml maclc` shows a floppy device, and
  `mame -listmedia maclc` shows `flop1`.
- **ROMs:** the GOOD maclc boot ROM = `releases/boot0.rom.stock` (==
  `maclc/350eacf0.rom`) + Egret/cuda ROMs (from a maclc romset). Put them in a
  `-rompath`. **The `maclc.zip` boot ROM is the BAD dump — use the loose good
  one.**
- **Disk images:** copy the `.dsk` files into WSL. NB MAME's 3.5" loaders are
  GCR-oriented (`ap_dsk35`); for MFM 1.44 MB use the IBM/`-flop1` path and
  confirm MAME ingests a **raw 1,474,560-byte** image (`OS-6.0.8 disk 1 of
  2.dsk`). DC42 (`Tetris Max.dsk`) may NOT load directly — convert DC42↔raw with
  `..\rusty-backup` if needed (`encode_dc42` / its converter).
- **Tooling** (`verilator/mame/`, all portable): `run_mame.sh`, `tap.lua`,
  `hw_trace.lua`, `scsi_trace.lua`, `snap.lua`. You'll likely need a **NEW lua
  tap** on the IWM/SWIM register window **`$F16000–$F17FFF`** that logs the phase
  lines + read values per access (model it on the existing taps, which re-install
  every frame — v8 `install_ram/rom` silently kills Lua taps). The debugger
  `trace`/watchpoints also work (SWIM accesses are plain memory reads).

## Reference already in tree

`docs/swim_ism_read_reference.md` — MAME-**source**-grounded spec (`swim1.cpp` /
`floppy.cpp`): ISM register map, MFM track layout, CRC seed `0xCDB4`, drive sense
reg `0x5`/`0xF`, the `f..c` "`x011`" signature, the `$9`/`$D` MFM/GCR mode
strobes, the DC42 container appendix. **This trace adds the RUNTIME sequence** —
especially the exact **phase→register mapping** the OS actually uses, which is
what we need to fix our bit-order.

## Files to fix once traced

- `rtl/floppy.v` — `driveRegsAsRead` (the SuperDrive sense **signature**; the
  `{ca2,ca1,ca0,SEL}` bit-order vs MAME); the GCR byte timer / IWM read latch.
- `rtl/swim.v` — IWM→ISM switch detect; ISM read path; the MFM-mode strobe.
- `rtl/mfm_track_encoder.v` — the MFM generator (already build-verified correct).
- Detection in `MacLC.sv` (DC42 byte-`$50` + raw size → `dsk_*_mfm/hd`) — verified
  working for Tetris Max; leave as is.
- Memory: `mfm-1440-floppy-implemented`, `swim-ism-mfm-read-reference`.

## Test images on the rig (`/media/fat/games/MacLC/`)

| file | size | type |
|---|---|---|
| `Tetris Max.dsk` | 1,474,644 | DC42 1.44 MB MFM (valid) |
| `OS-6.0.8 disk 1/2 of 2.dsk` | 1,474,560 | **raw 1.44 MB** (valid — use for raw tests) |
| `Install Disk 1 RAW.dsk` | 1,301,504 | NOT a 1.44 MB image (wrong size; correctly ignored) |
| `tattletech2.17.dsk` | 819,200 | 800K GCR |
| `6.0.7 *.dsk` | 838,484 | DC42 800K + tags |
