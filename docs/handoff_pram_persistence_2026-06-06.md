# Handoff: PRAM persistence (Mac LC) — 2026-06-06

Branch: `video-fixes`. **All changes are uncommitted in the working tree** (user commits/merges
themselves — do NOT commit without asking). This doc is self-contained so a fresh session can
**build → deploy → test fully autonomously** (no Verilator on this Windows box; verify via Quartus
+ live MiSTer screenshots). See also memory `[[pram-persistence]]` and `[[mister-remote-osd-deploy]]`.

## Goal
Persist Mac LC PRAM across reboots "like a real Mac": auto-load at boot, auto-save on change, plus
an OSD **"Reset PRAM & Core"** (zap) option. Plumbing follows the X68000 core's mountable save-image
pattern; the user chose **autosave** (not manual buttons).

## STATUS (what works / what doesn't) — HW-confirmed
- ✅ **SAVE works.** `MacLC.nvr` gets real Mac PRAM (XPRAM `NuMc` signature etc.). Mount (SD slot 2),
  firmware-write mirror, dirty flag, OSD-open flush, and SD write all function.
- ✅ **Load-race FIXED.** The Egret copied `pram[]`→working RAM at 68k-reset-assert (early), before the
  SD load of `MacLC.nvr`→`pram[]` finished → Mac booted on pre-load PRAM. Fix: the boot-copy waits for
  a new `pram_ready`, **and the 68k is held in reset until `pram_loaded`** (`reset_680x0 =
  reset_680x0_latched | ~pram_loaded`), with a ~3s `pram_ready` timeout so a missing image never hangs.
  HW-confirmed: **boots clean (no stall)**, and a 2bpp PRAM image written to `.nvr` **survived a reboot**
  in the readback (byte 129 came back `00` = the loaded 2bpp value, not the 1bpp default `a6`).
- ❓ **OPEN: screen depth doesn't visually apply at boot.** PRAM *holds* 2bpp (confirmed) but the Mac
  comes up **1bpp** regardless. So this is NOT a persistence bug — the saved depth isn't being *applied*
  to the V8/Ariel video at startup. Likely an OS/ROM depth-restore matter (boot disk is
  `HD00_MacII_HDD.vhd`, a **Mac II** system image) or a V8 video gap. **Depth was a poor test setting.**

## Files changed (PRAM work)
- `rtl/egret/egret_wrapper.sv` — 6 PRAM ports + `pram_ready`; `pram[]` mirror (gated on `pram_loaded`);
  boot-copy now latches the PC3-edge as `pram_copy_pending` and fires on `pram_ready`; 68k held in
  reset until `pram_loaded`.
- `rtl/dataController_top.sv` — 7 PRAM pass-through ports to the Egret (guarded `ifndef EGRET_BEHAVIORAL`).
- `MacLC.sv` — `VDNUM` 2→3 (SCSI split to slots 0/1 via `scsi_*`, PRAM = slot 2); CONF_STR `SC2,NVR,Mount
  PRAM` + `R6,Reset PRAM & Core`; the PRAM FSM (load-on-mount, flush-on-OSD-open-when-dirty, Reset
  PRAM&Core = clear+flush+pulse reset); `pram_ready` (load-done OR ~3s timeout); 256-byte `pram_buf`.
- `verilator/sim.v` — slot-2 `pram_*` tied off, `pram_ready=1` (FPGA-only feature; sim unchanged).
- `scripts/deploy_screenshot.sh`, `tools/misterdeploy/launch_unstable_core.py` (+README) — deploy/seed.
- `releases/MacLC.nvr` — 512-byte zeroed seed. `docs/verilator_differences.md` — PRAM row added.
- ⚠️ `MacLC.qsf` shows modified — **not an intentional edit** (Quartus auto-touch during build). Verify
  `git diff MacLC.qsf` is benign / revert before committing.

## Autonomous BUILD → DEPLOY → TEST loop (exact commands)
All run from repo root via the Bash tool (git-bash). `scripts/local.env` sets `MISTER_HOST=192.168.99.143`,
`MISTER_SSH_KEY`, `QUARTUS_BIN`, HTTP port 8182, `RBF_NAME=MacLC.rbf`.

1. **Build** (~12 min): `bash scripts/build.sh` (use `run_in_background:true`; you're notified on exit).
   Verify: `awk 'NR==1' output_files/MacLC.fit.summary` → "Fitter Status : Successful"; rbf in `output_files/`.
   Cheap syntax/multi-driver check without a full fit (~3.5 min): `export PATH="$QUARTUS_BIN:$PATH"; quartus_map MacLC` (0 errors expected; 92 benign warnings).
2. **Deploy**: `bash scripts/deploy_screenshot.sh` — pushes the rbf, seeds `MacLC.nvr`+`config/MacLC.s2`
   (create-only-if-missing, never clobbers a saved `.nvr`), reboots, OSD-selects, verifies `coreRunning`
   (auto-retries up to 2× — blind OSD nav occasionally misses on the first reboot).
3. **Wait ~105-140s** for the Mac to boot from the SCSI HD, then screenshot:
   `bash scripts/grab.sh scratch/pram_test/<name>.png` then **Read** the PNG (it renders) to see the desktop.
4. **PRAM round-trip test (no Mac UI needed):**
   - Read current PRAM: `ssh -i $MISTER_SSH_KEY root@$MISTER_HOST "od -Ad -tx1 /media/fat/games/MACLC/MacLC.nvr"`
   - Inject a known PRAM: build 512 bytes locally, `scp` to `root@$MISTER_HOST:/media/fat/games/MACLC/MacLC.nvr`
     (the `root@host:` prefix avoids MSYS path mangling). Then deploy/relaunch and screenshot.
   - Read the Mac's *live* PRAM: trigger an autosave by opening the OSD over the websocket
     (`python scripts/mister_ws.py --host $MISTER_HOST osd sleep:1.5 osd`), then re-read `MacLC.nvr`.

## State / reference
- Deployed rbf (load-gate build) md5: `7174b6671bec19994c3978e13379fffb`.
- `MacLC.nvr` currently = **2bpp** PRAM (byte88=`80`, byte129=`00`). Backup of the prior 1bpp state:
  `/media/fat/games/MACLC/MacLC.nvr.bak.1bpp` (byte88=`81`, byte129=`a6`). `.nvr` byte i = PRAM byte i
  (CPU 0x100+i); 16-bit SD words are little-endian (verified: `NuMc` reads correctly at offset 12).
- `config/MacLC.s2` = 1024-byte NUL-padded `games/MACLC/MacLC.nvr` (MiSTer per-slot mount memory).
- **Gotchas:** no Verilator/make on this box (gate is `quartus_map`/HW); `export MSYS_NO_PATHCONV=1`
  when passing bare `/media/fat/...` args to python under git-bash; the MiSTer screenshot API captures
  the core video but NOT the OSD menu (blind nav).

## Open items / next steps (priority)
1. **Sentinel test to 100%-confirm the load** (autonomous): write `0xAA` to an unused PRAM byte (with a
   valid `NuMc` sig so it isn't reinitialized), reboot, autosave-flush, confirm `0xAA` survives.
2. **Confirm end-to-end persistence with a boot-restored setting** (sound/alert volume or keyboard
   repeat rate) instead of depth — these are applied at startup from PRAM.
3. **Investigate depth-apply-at-boot** (the real open question): does `maclc` in MAME, booted with a
   saved 2bpp PRAM, come up 2bpp? If yes → our V8/Ariel or PRAM-read path has a gap; if MAME also needs
   the OS to apply it → it's a disk/System matter. Tooling in `verilator/mame/`, see `docs/mame_compare.md`.
4. **`reboot_and_wait` robustness** (`launch_unstable_core.py`): it sleeps a fixed 12s then polls *up* —
   it never confirms the service went *down*, so it can navigate a not-yet-rebooted menu (caused a
   `GenMidi` mis-launch once). Fix: poll DOWN then UP, then settle.
5. **Autosave trigger** is OSD-open-only; for true "set-and-shut-down" real-Mac feel, add auto-flush on
   dirty+idle (or on Mac shutdown).
