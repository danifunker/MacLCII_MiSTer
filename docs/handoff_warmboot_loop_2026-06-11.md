# Handoff — warm-restart reboot loop + "phantom" disk corruption (RELEASE BLOCKER)

*2026-06-11, branch `scsi-fixes-from-lbmactwo` @ `1f6c8d5` (RBF built 11:42 in
`output_files/`). Affects BOTH MacLC and LBMacTwo (`af36828`). Blocks the next
release of both cores.*

Run the continuation session at `C:\Temp\mistercore\MacLC_MiSTer`. The sibling
repo `..\lbmactwo_MiSTer` is required (forensics scripts + cross-core checks).

## The symptom matrix (user-confirmed on hardware)

| OS | First boot | After UI Shutdown → restart |
|---|---|---|
| 6.0.8 | **WORKS fully** (desktop, sound) | **REBOOT LOOP** (repeated green-tint resets); disk then "corrupted" (won't boot) |
| 7.1.2 (PPC-enabler patch; boots a real LC) | Happy Mac, then crash-restart **~1 s later**, deterministic; then `?` | n/a (never gets there) |
| 7.5.5 | progress bar populates, then fails | n/a |

**Unifying hypothesis:** ONE warm-restart bug. System 6 only enters the broken
path when the user restarts manually. 7.1.x-style systems perform an
enabler/soft-restart transition *during* boot — that is why 7.1.2 dies ~1 s
after Happy Mac with no user action, at the exact same transfer count every
time (`dack_beats=14592`, `req_drops=33310`, probe-proven twice). 7.5.5's
different enabler flow gets further. **Fix the warm restart and likely all
three OSes fall out.**

Both cores share the failure → the cause lives in something they share:
the new SCSI RTL (identical files, verified byte-equal modulo debug — see
"code identity" below) is the prime shared suspect; both cores' (different)
SDRAM warm-reset paths are the parallel suspect. The Egret is EXCLUDED
(Mac II has none). The pseudo-VIA IFR wiring is EXCLUDED (tied off in
`1f6c8d5`, and Mac II never had it — but NOTE: the user's 6.0.8 loop
testing predates the tie-off build; retest on `1f6c8d5` first).

## Evidence already gathered (don't re-collect)

1. **First-boot SCSI is healthy** on the new RTL: full 6.0.8 sessions, heavy
   READ(10) traffic, deferral machine clean (`req_deferred` never stuck),
   normal bus resets (1/boot), sound + video alive. Probe logs:
   `scratch/boot_probe_log.txt`, `scratch/boot_watch_log.txt` (+ decoder
   `scratch/decode_watch.py`).
2. **Zero byte-level disk corruption** through all 7.1.2 attempts: live image
   vs pre-boot backup differs in EXACTLY ONE byte — MDB `drWrCnt` low byte
   (LBA 98 offset 0x49). Verified twice (`scratch/HD00_512_live2.hda` vs
   `scratch/backup_712_extract/...`). The round-6 corruption fixes hold.
3. **Post-(internal-)reset the SCSI disk goes DEAF**: ROM rescans forever in a
   `dbne` CSR poll (PC ~`$A0786A-74`), CSR reads `0x02` (SEL asserted, BSY
   never answers), zero transfers, counters frozen; **OSD remount does NOT
   revive it**; targets' live phases = IDLE. This deaf state is why a
   perfectly good disk shows the blinking `?`.
4. Two restart flavors were observed on MacLC — don't conflate:
   internal 68k reset (probe counters survive; the 7.1.2 crash) vs full FPGA
   reconfig (chain goes all-FF; ARM-side, e.g. menu core reload).
5. **Code identity:** lbmactwo `fpu-bus-adapter-dani` tip == `main` ==
   user's checkout `af36828` in ALL SCSI files; MacLC carries the same logic
   byte-for-byte (only sim-`$display` instrumentation and probe plumbing
   differ). There is no "older known-good SCSI code" to revert to — the
   known-good-first-boot code IS this code.

## Prime suspects, ranked

1. **Warm-reset state in scsi.v targets (shared RTL).** The target state
   machines have NO module reset — only `rst` = SCSI bus reset (ICR.RST).
   The ncr5380 host side DOES reset on `!_cpuReset`. After a warm reset the
   chip and targets can disagree (e.g. an in-flight HPS io_rd/io_wr whose
   `io_ack` is masked by `target_bsy` upstream — ncr5380.sv gates
   `.io_ack(io_ack[i] & target_bsy[i])` — leaving the HPS bridge or the
   target's io state wedged). Deafness mechanics: selection needs
   `sel && din[ID] && mounted && !bus_busy` (scsi.v ~line 748). The **PSC2
   probe (new in `1f6c8d5`, UNTESTED)** shows the live selection transaction:
   `{out_en, SEL, BSY, target_bsy[1:0], target_mounted[1:0], ICR_A_DATA,
   scsi_bus_data}` — one read at the deaf `?` answers WHICH term fails.
2. **SDRAM warm-reset re-init (parallel, per-core).** MacLC: 7bb574e ("cold
   boot method always"), d88c098/50d0c32 (re-init + cold-boot regression),
   90c7696 (video-slot reclaim). boot0.rom LIVES IN SDRAM — a botched warm
   re-init corrupts the ROM image → looping wild crashes (would explain a
   reboot LOOP better than a single deaf scan; PIFA going to non-ROM/wild
   PCs during the loop confirms this class).
3. **The reboot-loop driver itself.** What re-asserts reset repeatedly?
   MacLC reset sources: `status[0]`, `buttons[1]`, framework `RESET`,
   `pram_force_reset`, `dio_download(index 0)` (MacLC.sv ~line 110) — plus
   Egret `reset_680x0` (LC only, so not the shared cause). Identify which
   one fires in the loop (or whether the 68k itself keeps hitting the reset
   vector via corrupted memory).

## Tools ready to use (all in this repo unless noted)

- **JTAG probe deck** (`rtl/dbg_probes.sv`, usage `docs/jtag_probes.md`):
  `bash scripts/read_probes.sh` = decoded dump. PSC2 = selection/mounted
  visibility (NEW — confirm `scripts/cpu_state.tcl` decodes it; add if not).
- **Rapid whole-boot sampler**: `quartus_stp_tcl -t scripts/boot_watch.tcl
  <seconds> > scratch/log.txt` — ~3k samples/sec, waits for the core,
  **survives FPGA reconfigs** (re-attaches). Decode with
  `python scratch/decode_watch.py <log>`. Known wart: PDRD pairs sometimes
  mis-latch (trust PSCS for last-SCSI-read instead).
- **Loop disassembler**: `scripts/sample_loop.tcl` + `scripts/loop_disasm.py`
  (reconstructs RAM/ROM poll loops from PIFD samples; capstone optional).
- **Disk forensics** (sibling repo): `python
  ..\lbmactwo_MiSTer\scripts\hda_match_sources.py <pristine> <after>` —
  ZERO/COPY/**SHIFT±d**/NOVEL classes; `hfs_forensics.py <img> [lba...]` =
  partition map/boot blocks/MDB/B-tree walk + LBA→file mapping.
- **MiSTer access**: ssh `root@192.168.99.143` key `~/.ssh/mister_only`
  (config in `..\lbmactwo_MiSTer\scripts\local.env`). Disks in
  `/media/fat/games/MacLC/`. Pull big files via
  `ssh ... 'dd if="<path>" bs=1M' > local` (scp mangles the space-laden
  names). Pristine zips of both test disks sit in that folder.
- Verilator: `--reset-at-frame N` exists (e7a1cb1) = warm reset IN SIM, plus
  the SIMULATION SCSI detectors (`SCSI_WR_OVERRUN`, `SCSI_FLUSH_STUCK`,
  `NCR_WR_PHASE_MISMATCH`, `NCR_MANUAL_ACK_IN_DMA`, `+scsi_wr_trace`).

## The plan — ordered experiments

**E0 — phantom-corruption check (5 min, do FIRST).** When a disk is declared
"corrupted" after a loop: full power-cycle of the MiSTer, then a cold first
boot of that same disk. If it boots fine, the "corruption" is PHANTOM — it's
the deaf-SCSI/warm-state bug masquerading as disk damage (consistent with
forensics finding nothing). If it still fails, pull the image
(`ssh dd`) and diff vs its pristine zip — note this would be the FIRST
post-loop 6.0.8 image ever diffed (all forensics so far were 7.1.2).
Also pull/keep `MacLC.nvr` (PRAM) — it's outside the .hda and unexamined;
a trashed PRAM (boot order/32-bit flags) is invisible to disk forensics.

**E1 — capture the loop on the `1f6c8d5` build.** Arm
`boot_watch.tcl 300`, fresh 6.0.8 copy, boot to desktop, Special→Shut Down,
then restart and let it loop a few times before pulling the plug. The decode
answers: does each iteration die at the same PC (PIFA)? Does the SCSI scan
even start per iteration (PSC6 resets/opcodes)? Wild non-ROM PCs → SDRAM
suspect; clean ROM scan + deaf disk → scsi.v state suspect; PSC2 names the
failing selection term.

**E2 — restart-path matrix.** The trigger path is currently ambiguous
("reboot option in MiSTer or soft-reboot"). Test separately, each from a
clean desktop: (a) Mac Special→Restart, (b) Mac Shut Down then OSD R0
"Reset & Apply", (c) OSD R6 "Reset PRAM & Core", (d) menu-core reload
(FPGA reconfig — expected clean; it's the control). Record which loop.
Each exercises a different reset source; this alone may localize the bug.

**E3 — cross-core signature match.** Same protocol on LBMacTwo (own probe
deck, `scripts/read_probes.sh` there). If its loop signature matches
(same per-iteration PC class, deaf disk), the shared-SCSI suspect hardens;
if it differs (e.g. its documented FPU FSAVE vec-11 wedge), the "both cores"
premise weakens and the investigations fork.

**E4 — sim repro attempt.** `--reset-at-frame` after SCSI activity starts
(sim mounts block devices via `sd_*`/`img_mounted` in `verilator/sim.v`);
watch for the SIMULATION detectors and whether targets answer selection
after the reset. A sim repro makes the fix loop minutes instead of builds.

**E5 — candidate fixes (only after E1/E2 name the mechanism).** Likely
shapes: give scsi.v targets a real module reset (wire `!_cpuReset` in as a
second reset source — both cores); un-mask the final `io_ack` so a dying
target can't strand the HPS handshake; make the warm-reset SDRAM path prove
boot0 integrity (re-download or checksum); whatever E2 says about the loop
driver. Every RTL fix goes to BOTH tops and BOTH cores (the SCSI files are
intentionally identical — keep them that way).

## Don'ts / gotchas

- Don't re-litigate first-boot SCSI or byte-level write corruption — proven
  healthy/clean this session (see Evidence 1-2).
- Don't trust the deferral/req_bus code LESS than the old code: the old code
  could not boot System 7 at all, and round-6 on Mac II validated boots AND
  zero corruption. The bug is in what nobody ever validated: WARM restarts.
- The pseudo-VIA SCSI IFR flags stay tied off (MAME maclc ground truth);
  don't re-enable while chasing this.
- `scratch/MacLC_6-0-8-macsbug_corrpupt.hda` (old byte-slip artifact) is NOT
  a boot oracle; its System file is damaged (docs/scsi_byteslip_2026-06-10.md).
- Don't run JTAG probe reads during a Quartus compile; kill stray
  `quartus_stp_tcl` (`taskkill //IM quartus_stp_tcl.exe //F`) before builds.
- OSD case-sensitivity + deploy tooling notes: `tools/misterdeploy/`,
  `scripts/deploy_screenshot.sh`.

## Context docs

- `docs/scsi_byteslip_2026-06-10.md` — the corruption campaign + 06-11
  addendum (req_bus/deferred-REQ port rationale, validation protocol).
- `..\lbmactwo_MiSTer\docs\scsi_audit_2026-06-10.md` — three-way audit;
  items 3/4/12 are still-open chip-model gaps (MONBSY busy-IRQ, bus-reset
  IRQ, force-release stuck ACK on MR.DMA clear — that last one smells
  relevant to warm-reset state, see item 12).
- `docs/jtag_probes.md`, `docs/verilator_differences.md` (dual-top rules).
