# RESUME — MacLC boot now REACHES THE DESKTOP (grey pattern + cursor, frame ~1490). SWIM upper-byte bug fixed; next = boot a volume / FPGA validation (2026-06-03)

Branch `new-video-on-fix-egret` (local, **don't push**). Build rules: `CLAUDE.md`.
Memory: [[swim-upper-byte-fix]], [[pseudovia-irq-ier-fix]],
[[phantom-bank-simm-physical-fix]], [[ram-config-2mb-vs-10mb]],
[[moves-berr-fix-landed]], [[verilator-top-is-sim-v]],
[[mame-ground-truth-maclc]], [[feedback-sim-foreground]].
Refs: `docs/post_diagnostics_and_irq_levels.md` (SWIM section + 3 fidelity checks).

Focus = **2MB config only** (`configRAMSize=$24`). 10MB ($E4) unverified.

## What was fixed this session (committed `973824b`)
**SWIM is on the UPPER data byte (`_cpuUDS`) on the LC V8, not `_cpuLDS`.** The
$A009CE blocker from the previous resume was the IWM status poll
(`$01E0` = IWM low-mem global = `$50F16000`, the SWIM — NOT a VIA; the prior
resume mis-read the data address). `rtl/swim.v` gated all accesses on `_cpuLDS`
(never asserted for these even-address byte accesses) and returned the read byte
on the lower lane while the LC reads V8 peripherals on the upper byte → CPU
latched the hardwired `$BE` (bit5=1) → infinite `bne $a009ce`. Fix: gate on
`_cpuUDS`, present read byte on D15-D8 (`{dataOutLo, 8'hBE}`); writes already use
`dataIn[7:0]`. Also corrected the addrDecoder SWIM stride comment (`>>9`/$200).

VERIFIED in Verilator (single run to frame 1500):
- `$A009CE` hit **7×** (was infinite) — status poll falls through.
- Boot reaches the **floppy boot-disk wait loop** (`$A01484`/`$A014CA`, a Ticks
  `$16a` timeout retry using disk-driver A-traps `$A07D/$A084/$A07F`).
- Ticks `$16a` increments via the VBL ISR (`addq.l #1,$16a` at `$A0A296`).
- ASC sound chip actively programmed (`$F14800`/`$F14804`).
- **Screenshot frame 1490 = the grey 50% Mac desktop pattern + arrow cursor**
  top-left. Frame 350 = unchanged orange-dither + grey-band test pattern.

This is the furthest the core has ever booted. No disk is mounted in the sim, so
it correctly sits at the boot-volume wait (CLAUDE.md: "desktop won't fully load"
without a drive).

## Three fidelity checks (answered; full text in post_diagnostics doc)
1. **Egret/chime** — present; ASC programmed; desktop reached with behavioral
   Egret (sim default). TODO: verify real-HC05 build (`USE_EGRET_CPU`) boots the
   same. Respect the `via6522.sv` SR caveat in CLAUDE.md.
2. **V8 bank-sizing** — still good: single-entry descriptor table at `$9FFFEC`
   (writes at `$9FFFEA/EE`), march completes, no clobber. 10MB still unvalidated.
3. **24/32-bit / A31** — gap characterized, not a current blocker. MAME uses
   `M68020HMMU` + `global_mask(0x80ffffff)` (maclc.cpp:181); we decode only
   `address[23:0]` (always 24-bit). LC ships 24-bit and boots to desktop, so OK.
   Future risk: if MODE32/32-bit-clean code drives A31=1, our decode aliases it.
   Watch the sim `cpuAddrFullHi`/`HIGH_ADDR` probe.

## NEXT STEPS (pick up here)
1. **Boot a real volume.** The sim has no drive. Options:
   - Mount a floppy image (the boot is in the IWM/SWIM wait loop right now — a
     bootable 800K/1.4M image should let it load System). Check how the sim
     feeds `insertDisk`/floppy data (`sim_blkdevice`, `floppy.v`,
     `dskReadData = memoryDataIn[7:0]`). Floppy is read-only (Known Limitations).
   - Or a SCSI HD image (`scsi.v`/`ncr5380.sv`); SCSI writes experimental.
   With a volume, expect Happy Mac → System load → Finder desktop with icons.
2. **FPGA validation.** This whole boot chain was validated only in Verilator
   (sim.v). The SWIM fix lives in `rtl/swim.v` + `rtl/dataController_top.sv`
   (shared by both toolchains) so it should carry to FPGA, but the historic
   FPGA "overlay-stuck"/SR issues mean a real DE10-Nano boot test is warranted.
   Confirm Quartus-clean (single-driver) — the change was only a port rename +
   wire concat, no new drivers.
3. If a new hang appears after mounting a disk, first suspect the 24/32-bit gap
   (check the HIGH_ADDR probe) and the SWIM **data-register** read path (q6/q7
   sequencing, `readDataLatch`, `newByteReady`) now that real disk reads occur.

## Build / run / gotchas
- Verilator builds `verilator/sim.v` (module emu), NOT MacLC.sv. Keep CPU/bus
  glue in sync. [[verilator-top-is-sim-v]].
- `cd verilator && make && ./obj_dir/Vemu --stop-at-frame N` (foreground; run
  once, analyze `verilator/cpu_trace.log`). `--screenshot F --stop-at-frame F+1`.
- Boot-disk wait loop sits ~frame 1454+; desktop pattern visible by ~1490.
- MAME ground truth at `/tmp/mame_pc.tr` (Jun 3). In the headless `maclc` build,
  MAME debugscript breakpoint/watchpoint/`tracelog` **actions don't fire** and
  68020 opcode-PC breakpoints are defeated by prefetch — only the `dump` command
  and `trace`-to-file work. [[mame-ground-truth-maclc]].

## Done-when (next session)
- A bootable disk image is mounted and the core loads System past the boot-disk
  wait loop (Happy Mac / Finder), screenshotted.
- OR the SWIM fix is validated on real FPGA hardware (chime + boot past overlay).
