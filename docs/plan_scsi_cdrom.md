# Plan — SCSI CD-ROM drive (ISO / TOAST + CHD)

Date: 2026-06-08 (rev 2026-06-09) · Branch: `new-video-technique-part-2`
Scope agreed with user: **ISO + TOAST** (in-core) **+ CHD** (via firmware).
**One CD drive** (SCSI ID 3). BIN/CUE no longer a target (it comes free once the
firmware path exists, but isn't a goal). **CD audio deferred** (data CDs only).

---

## REVISION (2026-06-09) — supersedes §0, §2.2, §5, §7

Three clarifications reshape the plan:

1. **Firmware ≠ Mac detecting the drive.** The Mac mounts a CD via the **RTL
   SCSI device** (INQUIRY type `0x05`, READ TOC, READ(10) @ 2048) + the **Apple
   CD-ROM extension** in the booted System (host software). That's pure FPGA +
   host SW. Firmware only matters for **decoding the image format** (CHD). The
   host-driver requirement can't be "baked into" the RTL drive (it's Mac
   software) — document it / optionally ship a sample HD image with the
   extension preinstalled.
2. **CHD is compressed → unreadable in the FPGA.** It MUST be decoded by
   Main_MiSTer (libchdr) and pushed to the core. Confirmed mechanism
   (PCE-CD `mister_load_chd`/`pcecd_send_data`, ao486): **per-core firmware
   support code** decodes the image and sends sectors over a core-specific
   download/management channel (data 2048 / audio 2352; TOC from CHD metadata).
   **Not** a transparent block device. ⇒ CHD = real C++ in Main_MiSTer + an
   FPGA bridge, **hardware-validated only** (no Verilator coverage).
3. **CD audio deferred.** 2352 raw + SCSI PLAY AUDIO + routing PCM into the
   core's audio mixer is a separate feature. v1 = **data CDs only**.

**Recommended sequencing (de-risk the novel part first):**
* **Phase 1 (now): in-core ISO/TOAST.** Prove the SCSI CD-ROM *device* — the
  format-independent, novel, risky part — using ISO via the existing block
  interface, fully testable in Verilator + MAME oracle, then on HW (Mac mounts
  an ISO). Architect the device's sector source as a clean **"give me 2048-byte
  block N"** interface with two backends: (a) block-device (ISO) now,
  (b) firmware-fed (CHD) later. This is the "bake it into the drive" goal — the
  device is format-agnostic.
* **Phase 2: firmware CD subsystem for CHD** behind the same interface.
  Cross-repo (Main_MiSTer), hardware-only.

Why ISO first: the SCSI target + Apple-driver mounting is identical for every
format and is the part most likely to fight us. Proving it on the cheapest,
sim-testable format means Phase 2 only adds a *sector source*, not a new device.

---

## MAME GROUND TRUTH (verified 2026-06-09, `../mame`)

`src/mame/apple/maclc.cpp:352` attaches `NSCSI_CDROM_APPLE` at **SCSI ID 3**
(HD at ID 6) — our existing ID layout is already MAME-faithful. Device model:
`src/devices/bus/nscsi/cd.cpp` `nscsi_cdrom_apple_device`.

* **INQUIRY (page 0):** type `0x05`, removable `0x80`, b2=`01`, b3=`01`, addl
  len `0x31`, vendor `"SONY    "`, product `"CD-ROM CDU-8002 "`, rev `"1.8g"`,
  then vendor bytes `d0 90 27 3e 01 04 91 .. 18 06 f0 fe`. **Our existing
  `scsi_empty_cd` INQUIRY bytes already match this exactly** (it was modeled on
  this device) — reuse verbatim.
* **No-disc sense = ASC `0xB0`** (vendor), *not* `0x3A`. MAME comment
  (cd.cpp:1214): with `0x3A` "MacOS … hammers the drive asking the user to
  format it." `scsi_empty_cd` already returns `0xB0`. Keep it.
* **Block size = 2048** (`cd.h:55`). Data reads use **standard**
  `READ(6)=0x08 / READ(10)=0x28 / READ(12)=0xA8` and `READ CAPACITY=0x25` —
  the Apple device falls through to the base CD handler for these
  (cd.cpp:1789-1797).
* **Apple VENDOR commands (all 10-byte CDBs, group 0xc0):** `EJECT=0xC0`,
  **`READ TOC=0xC1`** (BCD track #s, MSF addresses — *not* standard MMC
  `0x43`), `READ Q SUBCODE=0xC2`, `READ HEADER=0xC3`, audio
  `0xC8–0xCE`. `scsi_command_done`: 0xc0-group commands are length 10.
* **TEST UNIT READY:** GOOD if media present, else no-disc (`0xB0`).
* **CD audio** (CDDA) is wired to the speaker in MAME (`maclc.cpp:355`) — but
  **deferred** here (data CDs only); stub `0xC8–0xCE` as accepted/no-op.

**Firmware / internal-vs-external answer (your question):** MAME models the
internal `NSCSI_CDROM_APPLE` and external `NSCSI_CDROM_APPLE_EXT` with
**identical** SCSI behavior (the `_ext` class just delegates; no INQUIRY/command
override). So there is **no per-drive "firmware" the core must provide, and no
internal-vs-external difference** at the SCSI level. What makes the Mac *mount a
data CD* is the **Apple CD-ROM system extension** in the booted System Folder
(host software), or a **driver partition on the disc** (bootable Apple CDs load
their driver from block 0 — that's image content, not core/firmware). The
MiSTer-firmware piece remains **only** for decoding CHD (libchdr); it is
unrelated to the Mac recognizing the drive.

## 0. TL;DR / recommendation  *(historical — see REVISION above)*

There are two honest routes to "BIN/CUE":

* **Phase 1 — in-core CD target, no firmware.** A real read-only SCSI CD-ROM
  device that reads **2048-byte logical blocks** off a mounted image via the
  block interface the core already has. Auto-detects the on-disk sector format,
  so it transparently handles **ISO**, **TOAST** (identical to ISO), and a
  **raw single-track data `.bin`** (mounted directly). Fully verifiable in
  Verilator. This is the bulk of the value and the recommended first milestone.

* **Phase 2 — full `.cue`/`.chd` the MiSTer-native way.** Mounting the `.cue`
  *text* file (or a `.chd`) so it "just works" like other CD cores requires
  **Main_MiSTer firmware support code + an `EXT_BUS`/`hps_ext` bridge** in the
  FPGA (this is how ao486 — an ATAPI *data-CD* reader, the closest analog —
  does it; MegaCD/PSX too). Cross-repo, needs hardware to validate. Optional
  follow-on.

> Why `.cue` can't be done in-core: the HPS mounts exactly **one** file per
> slot. Selecting a `.cue` mounts the tiny text file; the core can't then open
> the `.bin` it references. So in-core BIN/CUE means **mount the `.bin`**, and we
> sniff the format from the data. The convenience of picking the `.cue` (and
> multi-track / audio / CHD) is what needs Phase 2.

Everything Phase 1 needs already half-exists: `rtl/scsi.v::scsi_empty_cd`
(SCSI **ID 3**, INQUIRY device-type `0x05`, identifies as
`SONY CD-ROM CDU-8002`) is a media-less CD-ROM stub gated off by
`ENABLE_EMPTY_CD=0` (`rtl/dataController_top.sv:340`). Phase 1 replaces it with a
media-capable target and puts it on a mountable OSD slot.

---

## 1. Current state (verified)

* `rtl/ncr5380.sv` instantiates `DEVS=2` real disk targets (`scsi.v`, SCSI **ID
  6 & 5**) → HPS slots **0,1** (`SC0`,`SC1`), plus `scsi_empty_cd` (ID 3, gated
  off). `scsi.v` is hardwired to **512-byte** blocks (`scsi.v:355` returns
  block-size `0x200`; lengths use `tlen<<9`).
* `MacLC.sv` CONF_STR: `SC0`,`SC1` (HD), `SC2,NVR` (PRAM). `VDNUM=3`
  (slots 0,1 SCSI; slot 2 PRAM). `localparam VD_PRAM=2`.
* `img_size` is a **single** 64-bit bus, valid only for the slot pulsing in
  `img_mounted`; each target latches its own size on its `img_mounted[i]`.
  HD targets get `img_size[40:9]` = byte size ÷512 = count of 512-byte blocks.
* `verilator/sim.v` has its **own** SCSI/HPS wiring; `sim_blkdevice.{h,cpp}`
  serves images (supports `kVDNUM=10`, 512-byte blocks). `sim_main.cpp` has
  `--scsi0/--scsi1`. **CPU-glue/top-level wiring must change in BOTH
  `MacLC.sv` and `sim.v`** (see `docs/verilator_differences.md`).
* `sys/hps_io.sv` is a **generic block device** (no `sd_req_type`/CD channel),
  but it **does** expose the `EXT_BUS` port (line 174) — the hook Phase 2 needs.

---

## 2. Phase 1 — in-core CD-ROM target (ISO / TOAST / raw BIN)

### 2.1 New module `scsi_cdrom` (in `rtl/scsi.v`)

Model on `scsi.v` (the HD target) — reuse its phase machine, REQ/ACK
handshake, `scsi_dpram` buffering, and `io_rd`/`io_wr` generation. Differences:

| Concern | HD target (`scsi.v`) | CD target (`scsi_cdrom`) |
|---|---|---|
| INQUIRY | type 0x00, "SEAGATE ST225N" | type **0x05**, removable **0x80**, **"SONY"/"CD-ROM CDU-8002"** (reuse `scsi_empty_cd` descriptor bytes so the Apple CD driver binds) |
| READ CAPACITY block size | 512 (`0x200`) | **2048** (`0x800`); last-LBA = `(blocks512/4) - 1` |
| READ(6/0x08)/READ(10/0x28)/READ(12/0xA8) | `io_lba=lba`, len `tlen<<9` | logical block N, len L → SD reads `4*N..` , data-out length `L*2048` (standard MMC opcodes; Apple driver uses these for data) |
| TEST UNIT READY | OK | **OK when mounted**, else no-disc (sense `SK_NOT_READY` / ASC **`0xB0`**) |
| WRITE | supported | **rejected** (read-only) → CHECK COND |
| READ TOC | — | **Apple `0xC1`** (BCD/MSF), synthesize single data track (see 2.3) |
| EJECT `0xC0`, READ Q SUBCODE `0xC2`, READ HEADER `0xC3` | — | minimal (eject → set no-disc; subcode/header → zeros) |
| AUDIO `0xC8`–`0xCE` | — | **deferred** — accept as no-op GOOD (data CDs only) |
| MODE SENSE(6/0x1A) | minimal | minimal valid header (block size 2048) |
| PREVENT/ALLOW MEDIUM REMOVAL (0x1E), START/STOP (0x1B) | — | accept (GOOD) |
| REQUEST SENSE (0x03) | supported | supported (report no-disc `0xB0` when unmounted) |

### 2.2 Block-size mapping & sector source (the crux)

> **Phase 1 = ISO/2048 only** (the 2352 straddle path below is **out of scope**;
> CHD's firmware backend delivers normalized 2048 user data in Phase 2). The key
> deliverable here is a clean **`get block N (2048 bytes)`** interface the device
> reads through, with a block-device backend now and a firmware backend later.

One 2048-byte CD logical block. Layouts (for reference; only 2048 in Phase 1):

* **ISO / TOAST (Mode1/2048 or Mode2/2048):** file is contiguous 2048-byte
  user data. CD block N = SD sectors `[4N .. 4N+3]` (4×512). Clean, 512-aligned,
  reuses the HD buffer pattern (just 4 sectors/block instead of 1).
* **Raw `.bin` (Mode1/2352):** each 2352-byte raw sector = 12 sync + 4 header +
  **2048 user** + 288 EDC/ECC. User data for block N is at file byte
  `N*2352 + 16`, length 2048. 2352 is **not** 512-aligned → the 2048 window
  straddles 5 consecutive 512-byte SD sectors at a variable sub-offset.

**Auto-detect** at first read after mount: read SD sector 0, test bytes 0..11
for the Mode1 sync `00 FF*10 00`. Present → `sec_size=2352, data_off=16`
(Mode1) / `24` (Mode2/Form1, header byte test). Absent → `sec_size=2048,
data_off=0`. Latch per mount.

**Buffering for 2352:** widen the read path to cover a 2048 window spanning ≤5
SD sectors. Cleanest is a small **image-reader** helper that, given logical
block N, computes `first_sd = (N*sec_size + data_off) >> 9`,
`byte_off = (N*sec_size + data_off) & 511`, issues the needed consecutive SD
reads, and streams out 2048 bytes starting at `byte_off`. For ISO this collapses
to `byte_off=0`, 4 sectors. Implement the reader once; both formats flow through
it.

> If the 2352 straddle path proves too fiddly to land cleanly, fall back:
> **Phase 1 ships ISO/TOAST + 2048-mode `.bin`**, and 2352 `.bin` rolls into
> Phase 2 (firmware already normalizes to user data). Decide during impl.

### 2.3 Synthesized TOC — **Apple READ TOC `0xC1`** (not MMC 0x43)

The Apple driver uses the vendor command `APPLE_READ_TOC=0xC1` with BCD track
numbers and **MSF** addresses (cd.cpp:1296). `cmd[9]` bits 7:6 select the
operation: `00`=first/last track # (BCD), `01`=lead-out start MSF,
`10`=track range from a start track. For a single data track, synthesize:

* op `00`: first track=1, last track=1 (BCD).
* op `01`: lead-out start = `to_msf(capacity)` (BCD M/S/F).
* op `10`: per-track descriptor = ADR/control `0x14` (data track), then start
  MSF (BCD). Frame=LBA → `m=lba/(75*60)`, `s=(lba/75)%60`, `f=lba%75`, each BCD.

Return no-disc (`0xB0`) when unmounted. This is enough for the Apple CD-ROM
driver to read an ISO9660/HFS data CD. (Standard MMC `0x43` need not be
implemented — the Apple driver doesn't use it.)

### 2.4 Wiring `scsi_cdrom` into `ncr5380.sv`

* Give the CD target its own `io_lba/io_rd/io_wr/io_ack/sd_buff_din` on a
  **new block-device index 2** (the two HD targets keep 0,1). Keep the `DEVS=2`
  HD `generate` loop; instantiate the CD target separately wired to index 2.
  Drop/disable `scsi_empty_cd` (superseded).
* Its `target_bsy/cd/io/msg/req/dout` join the same wired-OR mux that already
  handles targets + empty_cd.
* `img_mounted[2]`, `img_size`, `io_*[2]`, `sd_buff_din[2]` come from the new
  HPS slot.

### 2.5 OSD slot + HPS plumbing (`MacLC.sv`)

* CONF_STR: insert CD slot, renumber PRAM:
  * Phase 1: `"SC2,ISO,Mount CD-ROM;"` (CD = block slot **2**). Add `CHD` to the
    ext list only once the Phase-2 firmware path lands → `"SC2,ISOCHD,...;"`.
  * `"SC3,NVR,Mount PRAM;"` (PRAM moves 2 → **3**)
  * **Confirm at impl:** the `SCn` token + 3-char extension list. Extensions are
    3-char chunks (`ISO`,`CHD`). `.toast` is 5 chars → likely won't
    extension-match; treat TOAST as ISO and document "rename `.toast`→`.iso`"
    (RTL auto-detect handles the bytes regardless of name).
* `VDNUM 3 → 4`; `VD_PRAM 2 → 3`. Extend `sd_lba/sd_rd/sd_wr/sd_ack/
  sd_buff_din/img_mounted` stitching for slot 2 (CD) and move PRAM to 3.
* Feed the CD target `img_size` (use `[40:9]`, i.e. 512-block count, ÷4 inside
  the target for 2048-block capacity; for 2352 capacity derives from
  `bytes/2352`).

### 2.6 Sim parity (`verilator/sim.v` + `sim_main.cpp`)

* Mirror §2.4–2.5 wiring in `sim.v` (its own SCSI/HPS glue).
* Add `--cdrom <file>` in `sim_main.cpp` mounting an ISO to the CD slot
  (`sim_blkdevice` already supports the extra slot; bump its used count).
* Update `docs/verilator_differences.md` with the new top-level slot.

### 2.7 Host-side requirement (document, not code)

The booted System needs the **Apple CD-ROM** extension (or a 3rd-party driver,
e.g. FWB CD-ROM ToolKit) to mount the drive. The INQUIRY string
(`SONY CD-ROM CDU-8002`) is a known Apple-supported drive, so the stock Apple
driver should bind. Note in README/handoff.

---

## 3. Verification (Phase 1)

1. **Build gate:** `cd verilator && make clean && make`; boot screenshot still
   shows the memory-test pattern (VIA-SR regression gate from CLAUDE.md).
2. **CD command stream vs MAME oracle:** run MAME `maclc` with the same ISO
   (`docs/mame_compare.md`) and diff the SCSI INQUIRY / READ TOC / READ(10)
   request+response stream against our target. Single run, analyze logs
   (per `feedback_simulation`).
3. **End-to-end:** boot the SCSI HD (`--scsi0 HD0-...hda`, which has the Apple
   CD-ROM extension) + `--cdrom test.iso`; confirm the CD volume mounts on the
   desktop (or at minimum INQUIRY=type5, READ CAPACITY=2048, TOC, and the first
   READ(10) of the HFS/ISO9660 volume header return correct bytes).
4. **Regression:** existing `--scsi0` HD boot unchanged (`check_boot.sh`).

## 4. Quartus-clean check (per CLAUDE.md)

Each new `reg` driven from exactly one `always`; no multi-driver. New SCSI ID 3
target replaces the empty_cd cleanly. Verify before FPGA.

---

## 5. Phase 2 — CHD via firmware

To mount `.chd` directly (cue/bin would come free through the same path):

1. Add an `hps_ext`-style bridge on the existing `hps_io` `EXT_BUS` port.
2. Write Main_MiSTer support code (new `support/maclc/` or reuse a CD lib) that
   decodes CHD via libchdr (and parses cue/bin), serves **data-track** 2048-byte
   sectors + TOC over the management/download channel. Mirror **ao486's /
   PCE-CD's data-CD path** (`mister_load_chd` / `*_send_data`).
3. The `scsi_cdrom` target asks the **same "give me block N" interface** (§2.2)
   for logical blocks; the firmware backend supplies normalized 2048-byte user
   data. No new device logic.
* **Risks:** cross-repo (Main_MiSTer), exact EXT_BUS/download handshake mirrored
  from a reference core, **hardware-only** validation (no firmware in
  Verilator). This is the larger half of the effort.

---

## 6. Touch list

**Phase 1 (RTL + sim, this repo only):**
* `rtl/scsi.v` — new `scsi_cdrom` (2048-block target, format auto-detect, TOC).
* `rtl/ncr5380.sv` — instantiate CD target on block-index 2; retire empty_cd.
* `rtl/dataController_top.sv` — pass CD `img_*`/`io_*`/`sd_buff_din[2]`.
* `MacLC.sv` — CONF_STR (+CD slot, renumber PRAM), `VDNUM`, `VD_PRAM`, slot
  stitching.
* `verilator/sim.v` — same wiring.
* `verilator/sim_main.cpp` — `--cdrom` arg.
* `docs/verilator_differences.md`, README/handoff — host-driver + toast note.

**Phase 2 (optional):** `sys/` bridge + Main_MiSTer support code.

## 7. Open decisions to confirm before coding
1. **2352 `.bin` in Phase 1, or defer to Phase 2?** (straddle complexity)
2. **CONF_STR token/ext** — confirm `SCn` + 3-char ext matching; toast handling.
3. **One CD drive (ID 3) or two?** Default: one, at ID 3 (Apple default).
