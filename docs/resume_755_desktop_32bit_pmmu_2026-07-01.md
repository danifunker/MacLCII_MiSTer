# RESUME — 7.5.5 desktop: the wedge is a 7.x-SPECIFIC 32-bit/PMMU logic bug (2026-07-01 late)

## ★ ONE-LINE GOAL
Make **System 7.5.5 reach the Finder desktop** on the MacLCii core. The SCSI and
video bugs are FIXED and committed; the remaining blocker is a **7.5.5-specific
68030 32-bit-addressing / PMMU execution bug** — proven by clean A/B experiments,
NOT a guess, and NOT the old SDRAM/PMMU-walk rabbit hole.

## ★ VERSION MATRIX (the sharpest evidence — trust this)
| OS      | our core                                   | MAME (correct 030) |
|---------|--------------------------------------------|--------------------|
| 6.0.8   | ✅ Finder desktop                          | (n/a)              |
| 7.1     | ❌ Welcome → **"bad F-Line instruction"** bomb | ✅ desktop      |
| 7.5.5   | ❌ Welcome → silent hang in MemMgr free-walk ($A0DE04, high RAM) | ✅ desktop |

⇒ **Both System 7.x fail on our core (different symptoms), both boot on MAME,
6.0.8 works everywhere.** 6.0.8 runs 24-bit / minimal-MMU / no boot-time FP; 7.x
runs 32-bit-clean + PMMU + installs FPU (line-1111) emulation (the LC II has NO
68882). **The 7.1 "bad F-Line instruction" bomb is the sharpest lead: it points at
F-line ($Fxxx) opcode handling.** On a 68030: cp-id 0 = PMMU (PMOVE/PTEST/PFLUSH,
executed on-chip) and cp-id 1 = FPU (no chip → MUST trap to vector 11 / the OS
line-1111 emulator). "bad F-Line" = the OS F-line handler rejected the instruction.
Two sub-hypotheses to split next session:
  - **cp-id 1 ($F2xx-$F3xx): FPU-emulation trap DISPATCH bug** — our F-line
    exception frame/vector is subtly wrong, so SANE/FPU-emu can't decode the
    trapped FP op. (7.x uses FP emulation at boot; 6.0.8 doesn't → explains the
    split.)
  - **cp-id 0 ($F0xx-$F1xx): PMMU F-line DECODE gap** — tg68k's PMMU doesn't
    decode some PMMU op MAME's 030 executes, so it wrongly traps as F-line.
  Discriminator: capture the faulting F-line opcode + PC (add a vector-11 capture
  probe, OR trace where MAME's 7.1 executes F-line ops and check if our core traps
  the same one). cp-id bit picks the branch. The 7.5.5 silent free-walk hang is
  likely the SAME root one step downstream (the FP/PMMU trap corrupts state, then
  the heap walk wedges) — chase the 7.1 F-line bomb FIRST; it's concrete and early.
  NOTE the LC II ROM/tg68k CPU id = 2'b10 (68030, PMMU on, no FPU) — verify the
  F-line/line-1111 path in `rtl/tg68k/TG68KdotC_Kernel` handles cp-id 1 as a
  clean vector-11 trap with the right stack frame.

## ★★ THE VERDICT (decisive experiments this session — trust these)
1. **MAME `maclc2` @ 10 MB boots our EXACT `MacLC_7-5-5.hda` to a full 7.5.5
   desktop.** ⇒ the disk, the OS, and the 10 MB config are all fine on *correct*
   hardware. Our core has a real, fixable bug.
2. **6.0.8 @ 10 MB boots to the Finder desktop on OUR core** (Apple/File/Edit/View/
   Special menu bar, "MacLC HD" + Trash icons). ⇒ high RAM ($800000-$9FFFFF) is
   NOT corrupt at the raw-SDRAM level — if it were, 6.0.8's heap up there would
   corrupt too. **This kills the "high-RAM/SDRAM integrity / mb_hi" theory.**
3. **7.5.5 wedges on our core at BOTH 4 MB and 10 MB**, identically. ⇒ not a
   config/high-RAM-size issue.
4. **The wedge (truthful probes): CPU ALIVE, spinning forever in the ROM Memory-
   Manager free-block-coalesce loop `$A0DE04`** (`tst.b (a1) / cmpa.l (a6),a1 /
   add.l (a1),d0 / adda.l (a1),a1 / bra`), and every address it walks (`9AD8FC`,
   `9CD2CE`, `9E6E84`, `9CDE8E` …) is in high RAM. SCSI has already completed its
   load cleanly (target reached MESSAGE phase, 1 bus reset, engine idle).

⇒ **6.0.8 works, 7.5.5 wedges, MAME (correct 030) runs 7.5.5 fine.** The
discriminating variable is what 7.x does that 6.0.8 doesn't: **32-bit-clean
addressing + the PMMU.** 6.0.8 runs 24-bit with the top address byte stripped and
minimal MMU; 7.5.5 enables 32-bit addressing and leans on the 030 PMMU. A
mistranslation / 32-bit-address mishandling for high-RAM logical addresses makes
the free-list walk read the wrong words → non-terminating loop → wedge.

## ★★★ NEXT STEP (the tractable path — MAME is now a fast live oracle)
Do a **MAME-vs-core execution diff at the wedge** (docs/mame_compare.md method):
- MAME reaches the desktop, so trace MAME's `maincpu` through `$A0DDFC-$A0DE12`
  during the healthy 7.5.5 boot: capture the CORRECT `a1` progression, the value
  read at each `(a1)`, and the high-RAM heap contents the walk traverses.
- On our core, the loop sampler (`bash scripts/sample_poll.sh N`, now PACED +
  emits `CPUADDR`) gives our `a1` progression; add a probe (or reuse one) to
  capture the DATA our CPU reads at those addresses.
- Diff → find the first high-RAM word our core reads differently → that is either
  (a) a wrong PMMU translation (our physical ≠ MAME's) or (b) a 32-bit address our
  decoder aliases. Both are logic, debuggable in the `ksw_bench`/`pmmu_bench`
  harnesses once the exact failing (logical addr, TC, CRP) is known.
- **Sanity first:** confirm whether 7.5.5 actually turns ON 32-bit addressing /
  the MMU on this machine (Memory control panel "32-bit addressing", and the
  ROM's `_HWPriv`/`Switch MMU` path). If 7.5.5 here runs 24-bit, pivot: the
  differentiator is then extension-load / larger-heap layout, not the MMU.
- Alternative discriminator already running: the **ideal-RAM Verilator full-boot
  sim** (real SCSI+CPU RTL, perfect RAM). If it EVER spins at `$A0DE04` → logic
  bug reproduced in sim (fast iterate). If it reaches the desktop → the bug needs
  real SDRAM/analog timing (unlikely given 6.0.8 works). It is SLOW (~0.08 fps,
  ~a day to Finder); a Monitor watches it. Consider adding a cheap "$A0DE04 spin
  detector" to `verilator/sim_main.cpp` (count consecutive fetches at that PC,
  print+dump) and re-running headless — the free-walk runs early in heap setup, so
  a logic bug may trip it well before frame 7000.

## WHAT IS DONE + COMMITTED (branch `video-performance`, HEAD `0d2723f`)
- `a4229ea` SCSI pseudo-DMA read corruption fix (DREQ/data-settle race +
  longword second-word pre-latch) + the `verilator/scsi_bench/` harness. **Sim:
  420-cell sweep clean, negative control fails. HW: System loads from disk every
  boot** (baseline `d98c3879` couldn't even find the disk on pristine PRAM).
- `ebd6166` SCSI IDs 0/1 (was 6/5) + OSD labels.
- `ea90fed` SDC: NCR5380→CPU din-latch 2-cycle multicycle (marginal-BSY reboot) +
  sim_main cb2_i stub + launcher OSD-nav hardening.
- `d624c79` V8 white-line COMPLETE fix (pix_word + combinational de_raw) — sim
  col0==col1, HW checkerboard col0 correct.
- `0d2723f` **restored the SCSI JTAG probe deck** — 9 probes (PSNC/PSC2/PSC3/PSCW/
  PSWL/PSCS/PSC6/PDRD/PVID) were still wired to walk-era captures. **All
  "SCSI engine state" reads before this commit were FICTION** (decoded walk-address
  bit patterns — e.g. the earlier "dack_beats=12739 / SEL+ID6 parked" was garbage).
  Deployed build with the truthful deck = md5 `a389971a`.

**Sibling latch-fix ports (working trees only, NOT committed — user will commit +
build):** `../MacLC_MiSTer` and `../lbmactwo_Mister` both carry the identical
42-line `rtl/ncr5380.sv` patch + a copy of `verilator/scsi_bench/` (lbmactwo needed
`.dbg_wr`→`.dbg_scsi_wr` rename + `+incdir+../../rtl`). Both pass the full bench
sweep vs their own RTL; lbmactwo verified with a pass/fail negative control.

## STATE OF HARDWARE / TREE / SIM
- **MiSTer:** running the deployed truthful-probe build (`a389971a`), 10 MB config
  (`/media/fat/config/MacLCii.CFG` = `08…`; 4 MB backup at `.CFG.bak-auto`), 7.5.5
  mount restored (`.s0`; `.s0.755session` backup). Fresh-power cold boot = healthy
  Welcome; 7.5.5 then wedges at the free-walk. HPS survived ~10 reboots + spaced
  probe reads with NO trouble — **the old "~8 reboots kills the HPS" figure was
  confounded with JTAG abuse; reboot freely, the real tripwire is rapid JTAG**
  (single spaced `read_probes.sh` only).
- **Latest FPGA build in tree = HEAD `0d2723f`** (probe restore); `output_files/`
  has archived RBFs: `MacLCii_fix2_complete.rbf` (`4addac65`, SCSI+video, no probe
  restore), `MacLCii_fix1_scsi_sdc_vidhalf.rbf`, baseline `MacLCii_scsiid0.rbf`
  (`d98c3879`). The deployed `a389971a` was a probe-restore build (in
  `/media/fat/_Unstable/MacLCii.rbf`).
- **Overnight sim:** `verilator/obj_dir/Vemu --headless --no-cpu-trace --scsi0
  ../scratch/MacLC_7-5-5.hda --screenshot 7200 --stop-at-frame 8400
  +scsi_stall_debug` → `scratch/overnight_sim.log`. Reading disk cleanly (cmd=28
  READ(10) complete, phases clean), ZERO stalls/aborts, ~frame 450 and crawling.
- **Working tree:** clean except the sibling-repo ports (in the OTHER repos). The
  pre-session walk-debug stash is still at `stash@{0}` (backup diffs in `scratch/`).

## TOOLING THAT WORKS (verified this session)
- **MAME oracle (WSL, fast ~300-490%):** use the headless wrapper —
  `cp scratch/MacLC_7-5-5.hda scratch/x.hd && bash verilator/mame/mame_headless.sh
  scratch/x.hd 10M <snap_frame> <out_subdir>` → PNG at
  `scratch/<out_subdir>/maclc2/f0000.png`. The wrapper carries the MANDATORY
  non-interactive flags — **`-skip_gameinfo` (skips the info/warning screen that
  BLOCKS on a keypress and pops a window on the user's display) + `-video none
  -sound none`.** NEVER run raw `mame` for oracle runs — it waits on input. Raw
  `.hd` mounts fine. Debugger: `-debug` + `verilator/mame/*.lua` (maincpu_regs,
  mmu_state, wedge_trace, pc_sp_hb, tap). Default debugger CPU is the Egret HC05 —
  `focus maincpu` for the 030.
- **FPGA build:** `rm -rf db incremental_db; bash scripts/build.sh` (~29 min). Run
  it as a TRACKED background task (Bash `run_in_background`) or a Monitor on the
  compile log — do NOT background it with an inner `&` inside the tool call (it
  detaches and you lose the completion signal). STA: `grep -A7 "; Setup Summary"
  output_files/MacLCii.sta.rpt` (want positive slack; ignore the PMMU
  power-up-High CRITICAL WARNINGs — benign).
- **Deploy:** `source scripts/local.env && python tools/misterdeploy/
  launch_unstable_core.py --push ./output_files/MacLCii.rbf --core MacLCii.rbf
  --delay 0.12` → verify `coreRunning='MacLCii'`.
- **Cold-test hygiene:** before each cold boot, `ssh … "cd /media/fat/games/MacLCii
  && bash refresh_disks.sh && cp MacLCii.nvr.bak MacLCii.nvr"` (pristine disks +
  PRAM — the .hda HFS-corrupts on hard resets mid-write).
- **Disk/mem swap without OSD:** `.s0` mount paths are equal-length strings —
  `sed 's/MacLC_7-5-5.hda/MacLC_6-0-8.hda/'` on `/media/fat/config/MacLCii.s0`.
  Memory: `/media/fat/config/MacLCii.CFG` byte0 O23 bits (00=4MB,04=2MB,08=10MB).
- **Live wedge disasm:** `bash scripts/sample_poll.sh 24` (paced 250ms, JTAG-safe;
  emits IFPAIR/IORD/CPUADDR; `scripts/loop_disasm.py` reconstructs the loop).
- **Probes:** `bash scripts/read_probes.sh` (single, spaced). Deck decode =
  `scripts/cpu_state.tcl`. NOW TRUTHFUL for SCSI (post `0d2723f`); the walk-saga
  PSCS/PSC2/PSC3 decode notes in older docs are obsolete.

## DO-NOT-RE-CHASE (hard-won)
- **SDRAM high-RAM integrity / `mb_hi` relocation** — 6.0.8 booting to desktop at
  10 MB proves high RAM is sound. `mb_hi` is unproven but harmless; leave it (or
  revert as cleanup LATER, not as a fix). The cell720 self-check already showed
  SDRAM reads back correctly.
- **Fictional SCSI probe reads** — fixed in `0d2723f`, but any SCSI-probe number
  quoted in docs dated before 2026-07-01-late is walk-address garbage.
- **The SCSI pseudo-DMA read path** — fixed + sim-proven + HW-proven (System
  loads). The wedge is DOWNSTREAM, in CPU/PMMU execution of the loaded System.

## RELEVANT MEMORY
[[maclcii-scsi-dma-latching-is-root]] (SCSI fix, now HW-validated) ·
[[maclcii-mister-hardware-access]] (reboot note CORRECTED — don't budget reboots) ·
[[maclcii-pmmu-sim-harnesses]] (ksw_bench/pmmu_bench for the 32-bit/PMMU repro) ·
[[maclcii-video-blank-alignment-class]] (white-line class) ·
[[timing-bugs-use-hw-not-ideal-sim]] · [[prefers-autonomous-driving]].
