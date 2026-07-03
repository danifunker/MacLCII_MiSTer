# RESUME — MacLCii 7.5.5 SCSI boot: disk moved to ID 0, PRAM-fixation blocker, disk corruption (2026-06-29 late)

## MISSION (drive autonomously, minimize check-ins — user pref [[prefers-autonomous-driving]])
Continue root-causing the **System 7.5.5 SCSI boot failure** on the MacLCii MiSTer core, on **REAL
HARDWARE**. This session moved the SCSI disk to **ID 0** (committed in the working tree) and that
neutralized the "latch" (Egret reset). The remaining blocker: **the Mac fixates on the PRAM
startup SCSI ID and never scans/selects the disk at ID 0** → "?" floppy. ALSO: the disk is likely
HFS-**corrupted** by the repeated failed boots — REFRESH IT FIRST.

## DO THIS FIRST — refresh the (corrupted) disks
The user added **`refresh_disks.sh`** (restores the .hda images to a "factory" state; drives get HFS-
corrupted after these boot failures — see [[maclcii-disk-corruption-from-hard-restarts]]). FIND + RUN
it before any boot test. Then set `.s0` to 7.5.5:
`cp MacLCii.s0 MacLCii.s0.bak; { printf 'games/MacLCii/MacLC_7-5-5.hda\0'; head -c 994 /dev/zero; } > /media/fat/config/MacLCii.s0`

## CODE STATE — changes made this session (working tree, NOT committed to git)
- **`rtl/ncr5380.sv:569`** — SCSI target IDs `3'd6 - i` → **`i`** (slot0 = **ID 0**, slot1 = ID 1). The
  boot disk is now at SCSI ID 0 (was ID 6). Phantom CD stays at ID 3 (`ENABLE_EMPTY_CD=0`; CD-ROM is
  planned for this core later — do NOT disturb ID 3).
- **`MacLC.sv:63-64`** — CONF_STR labels "Mount SCSI-6/-5" → "SCSI-0/-1".
- **`rtl/dbg_probes.sv`** — PSC2/PSCS probes RESTORED to SCSI **selection visibility** (re-pointed from
  the obsolete SDRAM-walk sources `c0`/`c0_cpa` to `psc2_r`/`pscs_r`). `read_probes.sh` now prints
  `PSCS img_seen` + `PSC2 id_bits/MOUNTED`.
- **`scripts/cpu_state.tcl`** — added the PSCS (img_seen) + PSC2 (selection id_bits/MOUNTED) decode.
- **`tools/misterdeploy/launch_unstable_core.py`** — FIXED 3 bugs (it was launching the WRONG core).
- **`rtl/scsi.v`** (+ `../lbmactwo_Mister/rtl/scsi.v`) — a `mounted = |img_blocks` change was tried then
  **REVERTED** (flawed: img_size is shared, PRAM overwrites it). Back to the original strobe-latch.
- **Build:** `output_files/MacLCii_scsiid0.rbf` md5 **`d98c38792c0759268ee466a640753740`** = the
  SCSI-ID-0 build, deployed to `_Unstable/MacLCii.rbf`. (Pre-fix `videofix2` = `f4fe0e8e`.)
- **New scripts:** `sample_loop.tcl`+`loop_disasm.py`+`sample_poll.sh` (live loop sampler, FIXED to read
  PIFD/PADR/PSTA since PDRD was repurposed); `sample_sel.tcl` (PSC2 sampler — ⚠ **CRASHED the whole
  MiSTer** with 150 rapid reads, do NOT use); `menu_highlight.sh` (highlight a core w/o launching).

## KEY FINDINGS (chronological, so you don't repeat them)
1. **The original leading suspect (SCSI IRQ-gating divergence) is DEAD/inverted** — the failing build
   ALREADY has the ungating fix `2a2bd7c`; DREQ engine byte-identical to lbmactwo. [[maclcii-scsi-irq-gating-divergence]] superseded. Do NOT re-add lbmactwo's MR_DMA_MODE gate.
2. **Cold-boot "?" floppy = the Mac fixating on the PRAM's startup SCSI ID, NOT scanning to the disk:**
   - disk@ID6 → Mac wedges selecting **ID 2** (+ Egret holds 68k in reset = the "latch").
   - disk@ID0, STALE PRAM → Mac selects **ID 6** (`PSC2 id_bits=0xC0`).
   - disk@ID0, FRESH/zeroed PRAM → Mac selects **ID 2** (`id_bits=0x84`).
   - In all cases the disk is `MOUNTED=01` at its slot but the Mac NEVER selects the disk's ID. It
     sticks on ONE id (150/150 samples), i.e. it is NOT doing a full bus scan.
3. **Moving the disk to ID 0 REMOVED the "latch"** — `PRST reboots=0, live reset_src=(none)` (was
   `EGRET+RESET_in`, `n_reset=0`). So issue #1 is neutralized by the ID change.
4. **Research: SCSI ID 6 is the WORST boot ID for a Mac** (lowest OS boot priority; de-channeled by the
   7.x SCSI Manager). Mac internal/boot drive = ID 0. Matches "7.5.5 worse than 6.0.8". [[maclcii-scsi-id6-bad-for-mac-boot]].
5. **Disk likely CORRUPTED** (user, end of session) — refresh first (above).
6. **The launcher was launching the WRONG core** (`MacLC.rbf` disk@ID6, not `MacLCii.rbf` disk@ID0),
   masked by a verify substring bug → several mid-session tests were on the wrong build. NOW FIXED.

## OPEN ROOT QUESTION — why no full SCSI scan?
The user says MacOS scans all disks (blessing is on-disk, not PRAM). But the probes show the ROM stuck
on the PRAM startup ID, not scanning. Leads to try (after refreshing the disk):
- A zeroed PRAM is INVALID (bad checksum) → the Mac may default to ID 2 / skip the scan. Get/build a
  **valid PRAM** whose startup device = ID 0 (or that triggers a scan). PRAM layout: the classic-Mac
  "default startup device" bytes in the .nvr.
- OR the corrupted disk was the real reason it never booted — a fresh disk + disk@ID0 may just work.
- OR (less likely) the core wedges on selections to EMPTY IDs and that blocks the scan — verify in
  `rtl/scsi.v` selection / bus-free / no-device-timeout (the core does NOT assert BSY for empty IDs, so
  the Mac SHOULD time out and move on; confirm it does).

## NEXT STEPS
1. **`refresh_disks.sh`** → fresh 7.5.5; set `.s0`.
2. **Faithful-launch the SCSI-ID-0 build** (FIXED tool, command below). Screenshot + ONE gentle
   read_probes (PSC2 id_bits — does it now select ID 0 and boot, or still fixate on 2/6?).
3. If it still fixates on a non-0 id: pursue the PRAM startup (set to ID 0 / valid scan), per above.
4. If it boots: chase the ACTUAL 7.5.5 crash (the original on-disk-driver SCSI DMA / driver-abort hang
   at `$A499F2` — see `docs/resume_scsi_755_driver_abort_2026-06-29.md` for that whole thread).

## TOOLING / COMMANDS / GOTCHAS
- `source scripts/local.env`. `MISTER_HOST=192.168.99.143`, key `$MISTER_SSH_KEY`, web `:8182`.
- **FAITHFUL launch** (use THIS; load_core is unfaithful; launch-by-path is FORBIDDEN by the user):
  `python tools/misterdeploy/launch_unstable_core.py --push ./output_files/MacLCii.rbf --core MacLCii.rbf --delay 0.12`
  MUST print `coreRunning='MacLCii'` (NOT `'MACLC'`). `_Unstable` has 4 `MacLC*` cores; the launcher
  counts menu rows and the conf_str **name** is the only build discriminator → ALSO `md5sum
  /media/fat/_Unstable/MacLCii.rbf` and compare to the build you intend.
- Launcher fixes made (so it works for MacLCii): (a) verify is now a word-boundary match (was
  `"maclc" in "maclcii"` → false OK); (b) do NOT press `osd` at the main menu (opens a settings overlay
  → "still at the menu"); (c) `--delay 0.12` + `sleep:0.6` beat the menu's **~5s cursor-nav timeout**
  (slow keys silently drop → land one row short on MacLC).
- **Build:** `rm -rf db incremental_db && bash scripts/build.sh` (~30 min); watch newest
  `output_files/auto_compile_*.log` for `Compile exit=0`. Save good RBFs with a name.
- **Screenshot:** `bash scripts/grab.sh <out.png>` (HTTP, no JTAG; the MAIN MENU renders as garbled
  noise via this API — use the user's eyes for menu nav; core screens are fine). Foreground `sleep`
  is BLOCKED → background `sleep 42; bash scripts/grab.sh ...`.
- **Probes:** `bash scripts/read_probes.sh` (SINGLE, well-spaced). SCSI lines: `PSC2`
  (id_bits=selected SCSI ID, MOUNTED), `PSCS` (img_seen), `PRST` (Egret reset/`live reset_src`),
  `PRC0` (scsi_bus_resets), `PIFD` (`opcode 56C9/56CD`=DBNE = the BTST-BSY selection-wait loop @ ~$A0786x).
  Ignore the stale `PFR`/`$9FEE40` SDRAM-walk block.
- ⚠ **DEVICE-SAFETY (learned the hard way):** rapid/repeated JTAG In-System-Probe reads CRASH the whole
  MiSTer (cool to touch — NOT thermal; the killer was `sample_sel.tcl` doing 150 back-to-back reads,
  and looping `read_probes`). The DE10-Nano shares JTAG with the HPS. **Single spaced reads only; NO
  rapid samplers; never poll JTAG while the core is wedged.** Recovery = physical power-cycle (ask user).
- **PRAM:** `/media/fat/games/MacLCii/MacLCii.nvr` (512 B; backups `.bak`/`.bak2`). Zeroing it makes the
  Mac pick ID 2 (NOT a clean scan) — a VALID startup-disk PRAM is what's needed.
- **Menu/HPS:** main-menu cursor times out ~5s; HPS dies after ~8 reboots/session → physical power-cycle.

## RELEVANT MEMORY
[[maclcii-scsi-id6-bad-for-mac-boot]] · [[maclcii-disk-corruption-from-hard-restarts]] ·
[[maclcii-mister-hardware-access]] · [[timing-bugs-use-hw-not-ideal-sim]] ·
[[prefers-autonomous-driving]] · [[maclcii-scsi-irq-gating-divergence]] (superseded)
