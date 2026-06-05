# Resume: MacLC sim-side work — SOUND, RAM, VIA/CPU timing (2026-06-05)

**Hand-off to a Verilator-capable machine.** The Quartus/Windows box (where the prior
session ran) has no working `make`/verilator in its bash, so the three sim-friendly
issues below are being moved here. Keyboard was fixed on real hardware first (see below).

This is a Macintosh LC core for MiSTer (68000-family, V8 ASIC). Read `CLAUDE.md` and the
broader `docs/resume_060526_release_polish.md` for full context; this file is the focused
prompt for the sim work.

## ALREADY DONE (hardware, committed)
- **KEYBOARD: WORKS.** Confirmed on HW (characters appear). Wire-level ADB keyboard+mouse
  live in `rtl/adb_device.sv`. The Egret runs the **real HC05 firmware** and polls **one
  ADB device at a time** (last-active lock); mouse + keyboard starve each other and recover
  via a wire-level Service Request (mouse SRQs on movement, keyboard on keypress). Held keys
  don't repeat because MiSTer doesn't forward typematic autorepeat (expected).
- **Mouse/keyboard coexistence** (one freezes while the other is active) is DEFERRED — open
  question: does real `maclc` in MAME also freeze the other device, or does the real Egret
  round-robin both? Verify vs MAME before "fixing" (it may be faithful). See memory
  `keyboard-works-egret-single-poll`.
- JTAG diagnostic probes (ADB + AUD) are ENABLED in `MacLC.qsf` (`USE_ADB_ISSP`,
  `USE_AUDIO_ISSP`). Comment both out for the release build (FPGA only; irrelevant to sim).

## TOOLING (verilator)
```
cd verilator && make && ./obj_dir/Vemu --stop-at-frame 440   # boot ~360 frames
./obj_dir/Vemu --screenshot 350 --stop-at-frame 351          # screenshot check
./check_boot.sh --run 100                                    # boot PASS/FAIL
```
- ASC register/FIFO writes are logged by `ASC-WR ...` `$display` lines in `rtl/asc.sv`
  (active under `SIMULATION` + `USE_ASC_AUDIO`, both set in `verilator/Makefile`).
- CPU instruction trace: `verilator/cpu_trace.log`. Console/peripheral debug → stderr.
- **MAME ground-truth diff:** `docs/mame_compare.md` + `verilator/mame/`. Use it heavily for
  all three issues below — MAME's `maclc` is the reference for the ASC chime, RAM sizing, and
  VIA timing.
- **Run the sim ONCE per change, then analyze the logs** (CLAUDE.md guidance).
- After ANY VIA shift-register/timing change, re-verify boot (screenshot frame 350 must show
  the grey/black alternating memory-test pattern — uniform grey = Egret comms broke).

---

## ISSUE 1 — SOUND: the CPU never touches the ASC ($F14000)
**Hardware findings (this session, JTAG AUD probe = `{asc_rd_cnt[31:16], asc_wr_cnt[15:0]}`
in `MacLC.sv` ~line 623):**
- `asc_wr=0` AND `asc_rd=0` in **every** read — at max volume, on a cold boot, and on a
  deliberate System-6.0.8 beep (volume-slider release). The CPU **never drives
  `$F14000-$F15FFF`**, for reads or writes.
- Ruled out: volume=0; decode (`addrDecoder.v:173` `$F14000`→`selectASC` is correct); wiring
  (`asc asc_inst` is identical in `sim.v:565` and `MacLC.sv:587`: `cs=selectASC`,
  `we=!_cpuRW && cpuBusControl`); `cpuBusControl` gating (a VPA cycle DOES overlap it, so a
  real access would have counted ≥1); pseudovia sound-enable (no such gate exists).
- Because `asc_rd=0`, the ROM bails **before** ever reading the ASC → a **pre-check** fails.
  **Only sound is broken** (RAM/video/disk/keyboard/mouse all work), so it is sound-specific,
  NOT a gross boot divergence.
- The ASC model (`rtl/asc.sv`) models the ROM's **FIFO power-on self-test at PC `$A45F2C`**
  (fills FIFO, spins on FIFOSTAT bit1=FULL). Prior claim (commit `cdad2b6`): the **sim plays
  the chime**. So in sim the CPU DOES write `$F14000`; on FPGA it doesn't.

**Verilator next steps:**
1. **First question — does the CURRENT sim still chime?**
   `make && ./obj_dir/Vemu --stop-at-frame 440 2>asc.log 1>/dev/null; grep -c ASC-WR asc.log`
   - **Zero ASC-WR ⇒ reproducible in sim** (best case): debug entirely in sim. In
     `cpu_trace.log` find where execution reaches (or skips) `$A45F2C`; identify the branch/
     register read just before the first intended `$F14xxx` access and why it diverts.
   - **Nonzero ASC-WR ⇒ strictly an FPGA divergence:** the pre-check passes in sim but fails
     on FPGA. Capture what the ROM reads right before `$A45F2C` (machine-ID? the `SoundBase`
     low-memory global `$0266`? a config byte?) — that value is what differs on hardware.
     Likely shares a root with ISSUE 2 (RAM). Confirm against MAME.
2. Cross-check `$F14000` and the chime sequence against MAME `maclc` (`docs/mame_compare.md`)
   to be 100% sure the ASC base address and the FIFO-POST handshake match.

---

## ISSUE 2 — RAM: 10 MB selected (OSD O4) but Mac detects only 2 MB
(from `docs/resume_060526_release_polish.md` §C and memory `v8-renderer-matches-mame`.)
- `configRAMSize = status[4] ? 8'hE4 : 8'h24` (`MacLC.sv:218`) → `addrController` →
  `ram_config_phys`. `0xE4` ⇒ `[7:6]=11` ⇒ 8 MB SIMM (`$0-$7FFFFF`) + 2 MB board
  (`$800000-$9FFFFF`) = 10 MB. **The address decode supports 10 MB**, so the bug is upstream.
- Suspects: `status_mem` latch (`MacLC.sv:112`, latches `status[4]` on reset) vs
  `configRAMSize` (uses `status[4]` directly); `pseudovia` `ram_config` programming;
  `sdram.v` size/mirror. Possibly the same `§9 descriptor / RAM-fill` divergence (the `$0 ↔
  $800000` SDRAM mirror; `$9FFFEC` descriptor table) noted in memory.

**Verilator next steps:** set the 10 MB config, run the sim, trace the ROM's RAM-sizing march.
Verify the SDRAM model returns correct, non-aliased data across `$0-$9FFFFF` (watch the
2 MB / 8 MB boundary and any `$0↔$800000` mirror). Diff the sizing path against MAME `maclc`.
This may well be the same divergence that gates ISSUE 1 — check whether fixing RAM also makes
the sound POST run.

---

## ISSUE 3 — VIA E-rate: CPU self-reports 8 MHz (should be 16 MHz)
(from §E and memory `clock-audit-vs-mame`; **user wants this fixed so the CPU report
self-corrects**.)
- The CPU is genuinely 16 MHz (`clk16_en`; there is no CPU-speed OSD option). Tattle Tech
  times against the VIA. The VIA E-clock = CPU/10 = **1.625 MHz** vs the correct
  `C15M/20 = 783.36 kHz` (2× too fast) → it reads **half** → "8 MHz".
- `E_rising`/`E_falling` (from TG68 = CPU/10, `MacLC.sv:353-354`) drive **BOTH** the VIA
  timers AND the 6800/VPA bus sync — so they can't simply be slowed without breaking the VPA
  handshake (and the ASC/floppy share this E path).

**Fix direction:** give the VIA timers a fixed ~783 kHz tick (a `/20`-from-`C15M` clock
enable) **decoupled from** the E-clock used for VPA bus sync. **RISKY** — the VIA shift
register is fragile (CLAUDE.md). Same root as floppy-won't-read-at-16 MHz.

**Verilator next steps:** measure the VIA Timer1 tick rate in sim; introduce a separate
783 kHz VIA tick without touching the VPA E sync; re-verify boot (frame-350 memory-test
pattern + Egret comms intact) and then confirm the CPU-speed report. Keep the VPA handshake
(and ASC/floppy timing) unchanged.

---

## RELEASE CLEANUP (later, back on the Quartus box)
1. Comment out `USE_ADB_ISSP` + `USE_AUDIO_ISSP` in `MacLC.qsf`.
2. Optionally strip the guarded probe blocks + diag counters (or leave guarded-off).
3. Verify clean build (only the expected TG68 `332081` combinational-loop critical warning).
4. Push to master (user pushes directly to master for these release items).

## PROBE BIT MAPS (for reference if re-enabling on HW)
- ADB (64b, `rtl/adb_device.sv`): `[7:0]cmd [11:8]mouse_addr [15:12]kbd_addr [23:16]mtalk
  [31:24]mmove [39:32]mresp [47:40]ktalk [55:48]kbd_evt [63:56]ksrq`. Reader:
  `scripts/read_adb_aud.tcl` (run via `quartus_stp_tcl`).
- AUD (32b, `MacLC.sv`): `[15:0]asc_wr_cnt [31:16]asc_rd_cnt`.
