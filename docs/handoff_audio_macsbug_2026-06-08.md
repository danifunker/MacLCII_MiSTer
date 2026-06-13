# Handoff: FPGA audio hang + the new MacsBug NMI button

Branch `new-video-technique-part-2`. Self-contained cold-resume context for the
**FPGA sound problem** and the **Level-7 NMI / programmer's-switch** debug aid that
was just added to crack it. Companion to `docs/continue-audio-fixing.md` (the
older, broader sound hunt) and the `asc-fpga-sound-and-mame-memtest-findings`
memory.

---

## 0. TL;DR

- **The core has never produced audio on FPGA.** On the current build, the Sound
  control panel's **volume slider works**, but **changing the alert sound HANGS the
  control panel.** Volume "fine," playback hangs.
- **The sim chimes perfectly and CANNOT reproduce either the silence or the hang**
  (824 ASC register writes, audio peaks to ~27648 on every cold/warm boot). So
  Verilator can't see the bug — this is a hardware-behavior problem.
- We made several MAME-faithful ASC fixes this session, but the **decisive next
  step is to catch the hang in MacsBug.** The core had **no programmer's switch**
  (it generated only IPL 1/2/4 and tied off the NMI lines), so there was no way in.
- **We added one (commit `43030cc`):** an OSD button **"Interrupt (NMI / MacsBug)"**
  that fires a Level-7 NMI. Verified in sim. **§3 is how to use it. §4 is the
  decision tree from what you see.**

---

## 1. Commits landed this session (bundle ALL of these into the next bitstream)

| Commit | What | Status |
|---|---|---|
| `90c7696` | perf(sdram): reclaim dead video bus slot for CPU (+40% mem bw) — "H1" | landed, HW-pending |
| `6f79571` | fix(ariel): gate CLUT one-shot on data strobe — **fixes H1 blue tint** | landed, sim-verified |
| `9ab39d1` | fix(asc): gate FIFO/reg write one-shot on data strobe (defensive) | landed, sim-verified |
| `91fe1b5` | fix(asc): V8 register reads hardwired (MODE/CONTROL/FIFOMODE=1) | landed; **did NOT fix the hang** |
| `43030cc` | feat(debug): Level-7 NMI / programmer's switch (OSD "R5") for MacsBug | landed, sim-verified |

`90c7696`/`6f79571` are the video/perf work; the others are this audio thread.
**The blue tint and the ASC fixes are all the same root cause class:** an `_AS`
one-shot that captured the CPU's data/strobe BEFORE the 68k drove the data strobe
on a write (the strobes assert later than `_AS`), aggravated by H1's earlier DTACK
slot. Fixed by gating the capture on `(~uds_n | ~lds_n)`.

---

## 2. Symptom + what's been ruled in/out

- **Sim:** chime + full sound-driver init on every boot. Verify with:
  ```
  cd verilator && make && ./obj_dir/Vemu --headless --no-cpu-trace --stop-at-frame 450 1>/tmp/o 2>/tmp/e
  grep -c ASC-WR /tmp/o          # ~824
  grep "ASC-AUDIO peak" /tmp/o   # peak ~27648, nonzero_samples grow
  ```
- **HW, old build (pre-fixes):** AUD JTAG probe showed the CPU **never touched the
  ASC** (`asc_wr=0`) → ROM-level skip. **This probe was NOT re-read on any
  post-fix build.**
- **HW, current build:** the cdev **reaches playback** (volume OK; changing the
  alert sound triggers a play attempt → hang). That means the CPU now gets into the
  sound path → **`asc_wr` is probably >0 now** → we're on the **output-path /
  FIFO-IRQ-completion-handshake** branch, NOT the upstream ROM-skip branch.
- **Menu-bar-flash test:** selecting an alert sound **flashed the screen** (Mac
  believes it can't play) on the older build.
- **A *hang* (vs silence)** = the Sound Manager spinning on a status/IRQ that never
  arrives ("poll-with-timeout around sound hardware"). `91fe1b5` (register reads)
  was the leading hang suspect but **did not fix it** — so it's either a different
  register, or a missing interrupt.

---

## 3. THE DECISIVE NEXT STEP — break the hang into MacsBug

The whole point of `43030cc`. **Stop guessing; see where the CPU is stuck.**

**Prereq:** MacsBug must be **installed** (in the System Folder so it loads at boot
and announces itself), **not just sitting on the desktop.** If it isn't installed,
the NMI hits the ROM's default level-7 handler instead.

1. Reproduce the hang (change the alert sound in the Sound cdev).
2. Open the **MiSTer OSD** — it works even while the Mac is frozen (it's the
   framework, not the Mac).
3. Click **"Interrupt (NMI / MacsBug)"** (the new `R5` button). → drops into MacsBug.
4. Note the **PC**. Type **`ip`** to disassemble the loop. Optionally `dm` the
   address being read.
5. Capture: the **PC**, the instruction that **reads** something, and the
   **`bne`/`beq`** that loops back.

---

## 4. Decision tree from the MacsBug loop

- **Loop reads an ASC address (`$50F148xx`)** → it's a register-readback divergence.
  The address pinpoints which register. Compare our `rtl/asc.sv` `data_out` against
  MAME asc_v8 (§5) for that offset and fix it. (e.g. `$50F14804`=FIFOSTAT,
  `$806`=VOLUME, `$801/2/3`=MODE/CONTROL/FIFOMODE — those last three are already
  hardwired by `91fe1b5`.)
- **Loop reads a RAM flag** that an interrupt handler is supposed to set → the ASC
  **IRQ isn't firing/clearing** as the Sound Manager expects → implement the
  deferred IRQ-handshake fix (§6). This is the riskier change; the loop confirms
  it's worth it.

Also worth grabbing while in MacsBug: `il a05c0a` / the Sound Manager dispatch, and
whether the ASC IRQ (via PseudoVIA level 2) is pending in the VIA IFR.

---

## 5. MAME asc_v8 audit (source: `~/repos/mame/src/devices/sound/asc.cpp`)

Our model is `rtl/asc.sv` (the `USE_ASC_AUDIO` path). The Mac LC uses
`asc_v8_device` (version 0xE8, MONO, FIFO-only). Authoritative semantics:

**FIFOSTAT ($804) bits:** `bit0 = STAT_HALF_FULL_A (0x01)` set when cap < 0x200
(half-empty); `bit1 = STAT_EMPTY_OR_FULL_A (0x02)` set when cap==0 (empty) OR
cap>=0x3ff (full). Idle/empty = `0x03` (matches real-HW ASCTester "804Idle:$03").
**Our `fifo_stat` already matches this.**

**V8 register READS (`asc_v8_device::read`):**
- MODE/CONTROL/FIFOMODE ($801/2/3) → **always 1** (chip ignores writes to them)
- WTCONTROL/CLOCK/BATMANCONTROL ($805/7/8) → **always 0**
- VERSION ($800) → **0xE8**; FIFOSTAT ($804) → live (see IRQ below)
- FIFOA/B_IRQCTRL ($F09/$F29) → **1** (these are outside our $800–$80F decode)

**V8 IRQ handshake (the part we still DIVERGE on):**
- ASSERT: in `sound_stream_update` (the drain), per sample, when `cap < 0x200`.
- CLEAR on FIFOSTAT read: **only if `!(FIFOSTAT & STAT_HALF_FULL_A)`** (i.e. only
  when the FIFO is no longer half-empty). If still half-empty, the read does NOT
  clear the IRQ.
- CLEAR on FIFO write: when the resulting `FIFOSTAT == 0` (refilled past half, not
  full) — `asc_v8_device::write` tail.
- Reset: `MODE=1`, `FIFOSTAT=0x02`.

**What our `rtl/asc.sv` does vs MAME:**
| Behavior | MAME asc_v8 | our asc.sv | verdict |
|---|---|---|---|
| MODE/CONTROL/FIFOMODE read | always 1 | **fixed → 1** (`91fe1b5`) | ✅ matched |
| WTCONTROL/CLOCK/BATMAN read | always 0 | **fixed → 0** (`91fe1b5`) | ✅ matched |
| FIFOSTAT-read IRQ clear | only if bit0 clear | **unconditional** | ❌ DIVERGES (#3) |
| FIFO-write IRQ clear | yes, at FIFOSTAT==0 | **never** | ❌ DIVERGES (#4) |
| VERSION / FIFOSTAT bits / mono drain 22257Hz / idle-IRQ | — | match | ✅ |

Note the comment in `asc.sv`: the **current unconditional FIFOSTAT-read clear was
deliberately tuned to avoid a boot interrupt-storm** ("re-asserting every clock
would re-interrupt before RTE"). That's why #3/#4 are deferred — see §6.

---

## 6. The deferred IRQ-handshake fix (#3/#4) — only if §4 points at a missing IRQ

Make our IRQ match MAME asc_v8 (in `rtl/asc.sv`, the `USE_ASC_AUDIO` always block):
1. **FIFOSTAT-read clear → conditional:** clear the IRQ on a FIFOSTAT ($804) read
   **only when `!(count_a < 512)`** (bit0 clear), not unconditionally.
2. **FIFO-write clear → add it:** on a FIFO A push, clear the IRQ when the resulting
   `fifo_stat == 0` (i.e. `count_a` lands in `[512, 1023)`: bit0=0 && bit1=0).
3. Keep ASSERT on the drain/`pop_tick` when `count_a < 512`.

**#3 and #4 MUST land together** — #3 alone causes a storm (the IRQ stays asserted
while half-empty and the ISR can only clear it by refilling, which needs #4).

**Risk + guard:** could reintroduce the boot interrupt-storm. After the change,
re-run the sim chime check (§2): it must still reach `ASC-AUDIO peak ~27648` AND
**must not hang** (boot reaches `--stop-at-frame 450`). If it storms, the boot will
hang well before then.

---

## 7. The NMI / programmer's switch — implementation reference (`43030cc`)

- **FPGA (`MacLC.sv`):** new OSD CONF_STR entry `"R5,Interrupt (NMI / MacsBug);"`
  (status[5], a momentary pulse). Logic near the `_cpuDTACK` assign:
  `_cpuIPL = nmi_req ? 3'b000 : _cpuIPL_dc;` where `_cpuIPL_dc` is the
  dataController output (renamed from `_cpuIPL`). `nmi_req` latches on the
  status[5] rising edge and clears on the **level-7 IACK**
  (`fc7_iack && cpuAddr[3:1]==3'b111`) or a ~2 ms (`0xFFFF`-cycle) timeout backstop
  so it fires once and never masks levels 1/2/4.
- **Sim (`verilator/sim.v`):** identical logic; trigger is a new `nmi_pulse` input
  instead of the OSD button; logs `NMI: asserted` / `NMI: cleared (...)`.
- **Sim driver (`verilator/sim_main.cpp`):** new `--nmi-at-frame N` flag drives
  `VERTOPINTERN->nmi_pulse`.
- **Verified:** `./obj_dir/Vemu --headless --no-cpu-trace --nmi-at-frame 360 --stop-at-frame 366`
  → `NMI: cleared (level-7 IACK TAKEN)` (the CPU genuinely takes the autovector),
  boot continues. Re-run this if you touch the IPL/VPA/IACK glue.
- Why it works: the level-7 autovector reuses the **same IACK/VPA path** that
  already serves levels 1/2/4 (`fc7_iack` → `_cpuVPA` low → autovector). Mac IRQs
  work, so level 7 works.

---

## 8. HW telemetry still available (if MacsBug isn't enough)

`USE_AUDIO_ISSP` is still set in `MacLC.qsf` (the AUD In-System Sources & Probes).
- **Re-read the AUD probe on the bundled build** (`asc_wr`): >0 → output-path hunt;
  0 → ROM-level skip. **This has never been re-read post-fixes — do it.**
- **Output-path suspect (if `asc_wr>0` but still silent):** `sys_top.v`
  `initial vol_att = 5'b11111` = **hard mute**, only cleared by HPS cmd `0x26`
  (`audio_out.sv` `if(att[4]) a4<=0`). After a template sync the `0x26` decode may
  be broken. Quick test: temporarily `initial vol_att = 0` and rebuild — if the
  chime appears, the decode is the bug.
- **Sample-output probe (offered, not built):** repoint the AUD probe at
  `{sample_tick_cnt, asc_sample}` to see whether nonzero samples reach `AUDIO_L/R`
  on HW — splits "ASC makes no samples" from "samples made but muted".

---

## 9. Key files

- `rtl/asc.sv` — ASC model. `USE_ASC_AUDIO` block: FIFO, `we_stb` one-shot
  (now strobe-gated, `9ab39d1`), `fifo_stat`, IRQ logic (still #3/#4 divergent),
  `data_out` (V8 reads hardwired, `91fe1b5`). Instantiated `.uds_n(_cpuUDS)
  .lds_n(_cpuLDS)` in both tops.
- `rtl/ariel_ramdac.sv` — CLUT; `req_stb` strobe-gated (`6f79571`).
- `MacLC.sv` — FPGA top: NMI button + `_cpuIPL` override (`43030cc`); ASC/Ariel
  instances; CONF_STR.
- `verilator/sim.v` — sim top: NMI parity + `nmi_pulse` input.
- `verilator/sim_main.cpp` — `--nmi-at-frame N`.
- `~/repos/mame/src/devices/sound/asc.cpp` + `asc.h` — MAME ground truth
  (`asc_v8_device`).

## 10. Reference docs / memory

- `docs/continue-audio-fixing.md` — prior (2026-06-05) sound hunt: HW JTAG steps,
  theories disproven (RAM mismatch, warm-boot persistence, filter defaults),
  output-path vs ROM-level branches, the `$A464EA tst.l D6; bne` gate and Egret
  PRAM-volume suspects. The 7.1.2-slow-boot note may also be sound-related.
- Memory: `asc-fpga-sound-and-mame-memtest-findings` (kept in sync with this doc).
- Useful addrs: ASC `$50F14000-$50F15FFF` (VERSION `$800`=E8, FIFOSTAT `$804`,
  VOLUME `$806`); sound-init `$A464FE`/`$A45C0A`, ASC VERSION read `$A45C0C`,
  D6 gate `$A464EA`.

---

## 11. Suggested order of attack next session

1. Synth the 5-commit bundle. Confirm the **blue tint is gone** (sanity that
   `6f79571` works on HW) and audio behaviour.
2. **Re-read the AUD probe** (`asc_wr`) — one number, branches everything.
3. **Reproduce the hang → NMI → MacsBug → `ip`** (§3). Send the loop.
4. Per §4: fix the specific register, OR land the IRQ-handshake #3/#4 (§6) with the
   chime/no-hang guard.
5. Separately, the general silence (no chime even when not hanging) may still be the
   output-path `vol_att 0x26` mute (§8) — test with the temporary `vol_att=0`.
