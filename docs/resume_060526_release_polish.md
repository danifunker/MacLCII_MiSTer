# Resume: MacLC_MiSTer release-polish session (2026-06-05)

Goal: finish polishing the Mac LC MiSTer core for release. Multi-issue hardware-debug
session. **All changes below are uncommitted in the working tree and build-verified.**
User pushes directly to master for these release items.

## TOOLING — how to build / deploy / probe (critical)
- Windows box. Quartus 17.0.2 at `C:\intelFPGA_lite\17.0\quartus\bin64`. In the Bash tool:
  `export PATH="/c/intelFPGA_lite/17.0/quartus/bin64:$PATH"`.
- **Build:** `bash scripts/build.sh` → `output_files/MacLC.rbf` (~7 min). Launch with the
  Bash tool's `run_in_background:true` (do NOT use shell `&` — it isn't tracked/notified).
  Check done via `output_files/.compile_in_progress` flag + `output_files/MacLC.fit.summary`.
- **Deploy:** `. scripts/local.env` (sets MISTER_HOST=192.168.99.143, MISTER_SSH_KEY,
  QUARTUS_BIN, HTTP port 8182). `scp -i $MISTER_SSH_KEY output_files/MacLC.rbf
  root@$MISTER_HOST:/media/fat/_Unstable/MacLC.rbf` then
  `curl -s -X POST -H 'Content-Type: application/json' -d '{"path":"_Unstable/MacLC.rbf"}'
  http://$MISTER_HOST:8182/api/launch`. Boot to desktop ≈ 100 s. (Don't clear config — the
  SCSI disk `games/MACLC/HD20SC.vhd` is mounted via MacLC.s0.)
- **JTAG probes:** USB-Blaster → DE10-Nano (jtagconfig shows 5CSEBA6). Read with
  `quartus_stp_tcl -t scripts/read_adb_aud.tcl` (or `/tmp/adb_quick.tcl`). GOTCHAS:
  need `after 300` after `start_insystem_source_probe`; wrap reads in retry (transient
  JTAG fails return 0); JTAG point-sampling (~ms) is too slow for ADB bit cells (~28 µs)
  so use **in-fabric latched counters**, not live capture.
- Diagnostic probes guarded by `USE_ADB_ISSP` + `USE_AUDIO_ISSP` in MacLC.qsf — **currently
  ENABLED**. MUST comment both out for the release build.

## FIXED & VERIFIED ON HARDWARE
1. **SignalTap removed** (cleared Critical Warning 35025). Only remaining critical warning
   is the TG68 combinational loop (332081) — expected/upstream, leave it.
2. **Mouse freeze-after-boot FIXED** = wire-level ADB **Service Request (SRQ)**. Egret
   autopolls only one device; others must assert SRQ (hold bus low after another device's
   command). adb_device advertised SRQ-capable (Talk-R3 bit5) but never asserted it.
   Added `S_SRQ` (state 4'd10) + `D_SRQ`≈2700. Verified: cmd=3c (Talk R0 to mouse), mtalk
   climbs, cursor moves. See memory `adb-mouse-needs-wire-srq`.
3. **ADB Listen R3** (address reassignment) + defensive guard (never relocate to addr 0).
   Addresses now correct: mouse@3, kbd@2.

## OPEN ISSUES (priority order)

### A. KEYBOARD not working — IN PROGRESS, primary
- Symptom: mouse works, keyboard dead. Probe: `mtalk` climbs (~270/s, mouse polled), but
  `ktalk` STATIC at 41 even while user holds a key → **Egret never polls the keyboard**.
- Added keyboard SRQ: `wire srq_want = (mouse_evt && cmd_addr!=mouse_addr) ||
  (!kbdFifoEmpty && cmd_addr!=kbd_addr);` used in both S_TSTOP exits. Built+deployed, but
  `ktalk` still static when typing.
- ROOT QUESTION (next step): do PS2 keys even reach adb_device's `kbdFifo`? There's NO
  kbd-event counter (mouse has `mmove`; kbd has none). **Add a kbd-event counter** (++ when
  a key is pushed into kbdFifo, i.e. `key_pending && keyData[6:0]!=7'h7F` in adb_device.sv)
  to the ADB probe, rebuild, read while typing:
    - kbd-event climbs but ktalk doesn't → Egret ignores the keyboard's SRQ (SRQ asserted
      during a *mouse* poll may not be detected the same as during a kbd poll). Investigate
      SRQ timing/detection; the mouse SRQ (during kbd poll) works, kbd SRQ (during mouse
      poll) seemingly doesn't.
    - kbd-event = 0 → keys not reaching adb_device (ps2_key path / decode).
- Files: rtl/adb_device.sv. kbd path: ps2_key → scancode case → kbdFifo[kbdFifoWr];
  kbdFifoEmpty=(kbdFifoRd==kbdFifoWr); keyboard Talk R0 responds from kbdFifo.
- Probe bus (64b) decode (scripts/read_adb_aud.tcl & /tmp/adb_quick.tcl):
  [7:0]cmd [11:8]mouse_addr [15:12]kbd_addr [23:16]mtalk [31:24]mmove [39:32]mresp
  [47:40]ktalk [55:48]listen_seen [63:56]listen_done.

### B. White bar (flashing, left edge) — proper fix not done
- maclc_v8_video.sv: pre-first-word leading pixels: pixel_shift=0x0000 → index 0x7F →
  WHITE; flashes because first-word fetch lands late on some lines. (0xFFFF fill was tried
  → flashing colored line because index 0xFF isn't reliably black; REVERTED to 0x0000.)
- FIX: force **RGB=0** (palette-independent) for pre-first-word pixels. RGB output block is
  ~lines 303-328 (`de_d1` gates palette RGB vs 0). Add `line_loaded` reg: set when the
  shift reg loads its first word this line (the `video_latch_pending` load branch ~line
  231), cleared on hblank/vblank; delay to align with de_d1; then output 0 when
  `de_d1 && !line_loaded`.

### C. RAM: 10MB selected (OSD O4) but Mac detects only 2MB — REAL BUG
- configRAMSize = `status[4] ? 8'hE4 : 8'h24` (MacLC.sv:218) → addrController ram_config_phys.
  0xE4 → ram_config_phys[7:6]=11 → simm_byte_size=8MB → addrDecoder maps 8MB SIMM
  ($0-$7FFFFF) + 2MB board ($800000-$9FFFFF) = 10MB. **Decode supports 10MB**, so bug is
  upstream: configRAMSize not 0xE4 at boot, OR RAM march beyond 2MB fails (SDRAM
  mapping/mirror), OR the known **"§9 descriptor / RAM-fill" bug** (see memory
  `v8-renderer-matches-mame`: CPU stuck in $A4685E RAM-fill loop on garbage A1 bound;
  $9FFFEC descriptor table; $0↔$800000 SDRAM mirror). Likely tied to that.
- Check: status_mem (MacLC.sv:112, latches status[4] on reset) vs configRAMSize (uses
  status[4] directly); pseudovia ram_config programming; sdram.v size/mirror.

### D. SOUND not working — root-caused, not fixed
- Probe: `asc_wr_cnt=0` AND `asc_rd_cnt=0` (clean, 3 reads) → CPU NEVER touches the ASC
  ($F14000) on hardware. Audio output works on other cores (so it's the ASC feed, not out).
- ASC is in $F0 region → 6800/VPA E-clock bus cycle. asc_inst.we = `!_cpuRW && cpuBusControl`
  but the working VIA (also VPA) uses `_cpuVMA`. Suspect wrong access qualifier and/or
  sim/FPGA bus-glue divergence (sim.v has own bus glue; sim plays the chime, FPGA doesn't).
- NEXT: add a RAW `selectASC` counter (NOT gated on cpuBusControl) to distinguish "CPU
  never addresses $F14000" vs "cpuBusControl misses the VPA access". Then fix ASC access
  timing (use _cpuVMA like VIA) or the decode. AUD probe currently = {asc_rd_cnt, asc_wr_cnt}.

### E. CPU shows 8 MHz (Tattle Tech) = VIA E-rate wrong — DEFERRED but worth fixing
- CPU is genuinely 16 MHz (clk16_en; no CPU-speed OSD option). Tattle Tech times against
  the VIA; VIA E-clock = CPU/10 = 1.625 MHz vs correct C15M/20 = 783.36 kHz (2× fast) →
  reads half. **User confirmed this hypothesis.** See memory `clock-audit-vs-mame`.
- E_rising/E_falling (from TG68 = CPU/10, MacLC.sv:353-354) drives BOTH VIA timers AND the
  6800/VPA bus sync. Fix = give the VIA a fixed ~783 kHz tick (decouple from E) WITHOUT
  breaking the VPA handshake. RISKY (CLAUDE.md: don't touch fragile VIA SR). SAME root as
  floppy-at-16MHz (F) and possibly the ASC VPA access (D). High-value if done carefully.

### F. Floppy won't read at 16 MHz — known limitation, deferred. Same E-rate root as (E).

### G. 640x480 video — PARKED in docs/640_tweaks.md. 3-layer rework (25.175MHz PLL clock +
   CDC line-buffer scanout + bus bandwidth). Fractional pixel clock was tried → shaky,
   reverted. 512x384 (monitor_id 0x2, OSD "Monitor") is the working/recommended mode.

## UNCOMMITTED CHANGES (working tree)
- MacLC.qsf: SignalTap block removed; USE_ADB_ISSP + USE_AUDIO_ISSP ENABLED (comment out for release).
- MacLC.sv: stp_*/v8_dbg removed; guarded AUD probe (asc_rd_cnt/asc_wr_cnt counters).
- rtl/adb_device.sv: Listen R3 + addr-0 guard + wire SRQ (S_SRQ, D_SRQ) + srq_want
  (mouse+kbd) + guarded ADB probe (mtalk/mmove/mresp/ktalk/listen counters).
- rtl/maclc_v8_video.sv: dead dbg telemetry removed; white-bar fill = 0x0000 (still flashing).
- MacLC.sv CONF_STR: floppy F1/F2 ext DSK→DSKIMG (allow .img); SCSI SC0/SC1 ext
  IMGVHD→IMGVHDHDA (allow .hda), matching lbmactwo. Needs a rebuild to take effect.
- scripts/read_adb_aud.tcl (probe reader). /tmp/adb_quick.tcl, /tmp/aud_quick.tcl (transient).
- Memories: clock-audit-vs-mame, adb-mouse-needs-wire-srq, v8-renderer-matches-mame, etc.

## RELEASE CHECKLIST (before committing to master)
1. Finish keyboard (A), white bar (B); decide on RAM (C), sound (D), E-rate (E).
2. Comment out USE_ADB_ISSP + USE_AUDIO_ISSP in MacLC.qsf; rebuild clean.
3. Optionally remove the guarded probe blocks + diag counters (or leave guarded-off).
4. Verify build clean (only TG68 332081 critical warning). Commit + push to master.

## USER PREFERENCES
- Push directly to master for these release items.
- User does the hands-on hardware test (move mouse / type / look at screen); assistant
  deploys + reads JTAG probes. Coordinate: tell the user to act DURING the probe-read window.
- Clocks were "don't touch" (risky) but user now open to the E-rate fix given it underlies
  Tattle Tech + floppy.
