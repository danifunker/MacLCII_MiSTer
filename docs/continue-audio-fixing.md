# Resume: continue-audio-fixing — FPGA sound hunt (parked 2026-06-05)

**Hand-off to the Windows/Quartus machine.** The Verilator side is exhausted:
the sim plays the boot chime and full sound-driver writes on every cold AND
warm boot — the remaining work needs the FPGA + JTAG (or zero-tool tests on the
booted Mac). This doc is the complete state of the hunt.

## Current state (all verified on HW with the new build)
- Commits `02b6d3c` (10MB RAM: ROM relocated $280000→$500000 out of the SIMM
  SDRAM region + `ram_config_phys` wired in MacLC.sv) and `1850a7f` (VIA timers
  prescaled /2 to the real C15M/20 = 783.36 kHz).
- ON HW: **10MB detected ✓, TattleTech reports 16 MHz ✓, keyboard+mouse ✓.**
- **STILL NO SOUND** (no chime, no beeps), and System 7.1.2 boots extremely
  slowly (parked separately, see bottom).

## Evidence matrix
| Fact | Source |
|---|---|
| Sim plays chime + full sound init (850 ASC-WR, audio peaks to ~27k) | every cold run |
| Sim plays chime even on a TRUE warm boot (full 16MB RAM image persisted between two boots) | two-boot test, see below |
| HW (PRE-fix build): CPU **never touches** $F14000-$F15FFF (asc_rd=0, asc_wr=0) | AUD JTAG probe |
| HW (current build): silent; **probe NOT yet re-read** | — |
| Forcing MiSTer volume re-sends (`echo "volume 3" > /dev/MiSTer_cmd`) does not help | user test |

## Theories DISPROVEN — do not re-litigate
1. **RAM mismatch gating sound** — RAM is fixed on HW, sound still dead.
2. **Warm boot via persistent SDRAM** — two-boot sim test: boot #1 cold to
   desktop F1600 (verified 'WLSC' written to `$0CFC` in the RAM dump), boot #2
   preloaded with the byte-identical 16MB image → still chimes (829 ASC-WR).
   Real Macs chime on warm restarts too. Partial cookie seeding ($0CFC +
   the POST cookie at $9FFFEA) also stays cold.
3. **New-template filter/anti-pop defaults** — `audio_out.sv` defaults are the
   stock MiSTer values (aflt_rate=7056000, real coefficients; only a short
   anti-pop delay). Not a permanent mute by default.
4. *(method note)* The old "grep -c ASC-WR" experiment from the prior handoff
   was invalid: `$display` goes to **stdout** (cmd redirected it to /dev/null)
   and the ROM FIFO POST writes only the FIFO data ports — it never emits
   `ASC-WR` lines. Correct check: `1>out.log`, expect ~850 ASC-WR by F440.

## NEXT STEPS — in this exact order

### 1. Menu-bar-flash test (zero tools, booted Mac)
Trigger an alert beep (release the Sound control panel volume slider).
- **Menu bar flashes** → the Mac itself believes sound can't play (volume 0 /
  no sound channel) → ROM/PRAM level. Then check: what does the volume slider
  show on a fresh boot? Does a max setting survive a reboot? If it boots at 0
  or reverts → **Egret PRAM volume** is the prime suspect (the ROM reads the
  chime volume from PRAM very early; volume 0 silences the chime and may skip
  ASC setup entirely). Compare how the sim's Egret answers the same PRAM read.
- **No flash** → the Sound Manager believes it played → samples ARE being
  generated → it's the output path (step 3).

### 2. Re-read the AUD probe on the CURRENT build (decisive)
The asc=0 evidence predates all three fixes. `USE_AUDIO_ISSP` is still set in
`MacLC.qsf`; from the Quartus box: `quartus_stp_tcl -t scripts/read_adb_aud.tcl`
(AUD probe[15:0]=asc_wr_cnt, [31:16]=asc_rd_cnt — both edge-detected, sticky).
- **asc_wr > 0** → ROM feeds the ASC now; go to step 3 (output path).
- **asc_wr = 0** → ROM-level skip persists; go to step 4.

### 3. Output-path hunt (if asc_wr > 0)
Suspect list, in order:
- `vol_att` / HPS cmd `0x26` decode after the template sync (`f8dd7d3`/
  `b037a62`): `sys_top.v:317` `initial vol_att = 5'b11111` = **hard mute**
  (`audio_out.sv`: `if(att[4]) a4 <= 0`), only cleared by cmd `'h26`
  (`sys_top.v:466`). The sync changed HPS_BUS [48:0]→[45:0] and moved command
  handling between hps_io.sv and sys_top.v — verify 0x26 actually lands
  (SignalTap/ISSP on `vol_att`, or temporarily `initial vol_att = 0` and
  rebuild: chime audible ⇒ decode broken).
- The second AUD probe variant documented in MacLC.sv (~line 607): repoint the
  probe at `{sample_tick_cnt, asc_sample}` to see whether nonzero samples reach
  AUDIO_L/R on HW.
- clk_sys→clk_audio CDC + I2S in sys_top (stock, low probability).

### 4. ROM-level hunt (if asc_wr = 0)
- The skip happens UPSTREAM of any ASC access: sound init entry `$A464FE` /
  `$A45C0A` reads ASC VERSION at `$A45C0C` — never reached. Gate: `$A464EA`
  `tst.l D6; bne $a48cda`. D6=0 in sim at both gate passes (init `moveq #0,D6`
  at `$A463A0`; only exception/POST-failure paths set it).
- Most useful next probe: ISSP/SignalTap on a write to the `$A498xx` reporter
  path or capture D6-gate divergence; OR check TattleTech's hardware/sound
  pages on the booted Mac (does the Sound Manager report any sound HW?).
- PRAM volume read via Egret during early boot (ties into step 1).

## Useful addresses / facts
- ASC: `$50F14000-$50F15FFF` (VERSION `$800`=E8, FIFOSTAT `$804`, VOLUME `$806`).
- WarmStart global `$0CFC` = 'WLSC' `$574C5343`; StartMgr check at `$A05DFA`
  (F339); POST variant at `$A46558` reads `(-4,A0)` = `$9FFFEA`.
- Boot chime window in sim: FIFO POST F28 (9 reg writes + FIFO fill), Sound
  driver/volume-ramp writes from ~F100; ~850 ASC-WR total by F440.
- Two-boot warm test recipe (if ever needed again): temp hooks in
  `verilator/sim_ram.v` — `$readmemh("ram_seed.hex")` in `initial` if the file
  exists + frame-triggered `$writememh("ram_dump.hex")` (a `final` block never
  fires; harness lacks `top->final()`). **Delete ram_seed.hex afterwards** or
  every later run silently warm-boots.

## Parked separately: System 7.1.2 boots extremely slowly
- 6.0.8 SCSI boot is FAST on HW → SCSI throughput itself is fine.
- 7.1.2 lives on `HD20SC.vhd` ON THE MISTER (not copied here yet).
- Plan: copy it over (`scp root@<mister>:/media/fat/.../HD20SC.vhd`), boot it
  in sim AND in MAME (`-ramsize 10M`, attach as SCSI HD), compare frame counts;
  if slow in sim too, a PC histogram of the trace names the spin loop.
- Note: VIA-paced delays are now 2x their old (wrong) duration — correct
  behavior, but System 7 leans on calibrated delays far more than System 6;
  a polls-with-timeout path (e.g. around the dead sound hardware!) would
  show exactly as a slow-but-working boot. The sound fix may help 7.1.2 boot
  speed too — retest order matters.

## Release reminders (after sound works)
- Comment out `USE_ADB_ISSP` + `USE_AUDIO_ISSP` in `MacLC.qsf` (keep them
  until the probe re-read is done!).
- Expect only the known TG68 `332081` combinational-loop critical warning.
