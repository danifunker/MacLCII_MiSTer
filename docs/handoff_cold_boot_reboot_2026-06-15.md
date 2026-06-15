# Handoff — #3 cold-boot spontaneous reboot (SCSI 2nd-bus-reset → reboot)

*2026-06-15. Long-running blocker; this session got the **breakthrough** (a clean
success-vs-miss differential that isolates the failure to one event). Continue
from "Next steps". All HW work on MiSTer `.143` via local USB-Blaster JTAG.
**Complete issue writeup: `docs/scsi_cold_boot_retry.md`** (the what/why/evidence;
this handoff is the action plan).*

---

## TL;DR — what we know

**Symptom (user, HW-precise):** chime → basic init → mouse → Happy Mac →
**spontaneous reboot JUST BEFORE the "Welcome to Macintosh" screen** → basic init
→ mouse → "?" floppy disk (then sits at "?"). The **user manually resets** to
retry (NOT a self-loop); a *fraction* of cold boots "miss", **rate scales with
System size: 6.0.8 rare < 7.1 < 7.5.5 many**, but it is a **GENERAL cold-init
race on ALL OSes**. "Just before Welcome" = the **boot-block → System handoff**
(System's earliest SCSI/driver bring-up). Sister core lbmactwo shows the same.

**★ BREAKTHROUGH — the differential (2026-06-15).** Captured a clean **success**
(`scratch/success.{txt,png}`) and the **miss** (`scratch/diff_a1.txt`,
`reinit_1.txt`) with the same RBF (probes are cumulative *per FPGA config*, so
each `load_core` = a fresh per-attempt read):

| Probe | **SUCCESS** (6.0.8 cold → desktop) | **MISS** (7.5.5 cold, deterministic) |
|---|---|---|
| `scsi_bus_resets` (PRC0) | **1** | **2** |
| `boot_inits` = move#$2700,sr count | **2** | **3** |
| `trail_frozen` (2nd bus reset) | no | **yes** (CPU @ `A07A10`) |
| `PRT3` init-entry | `A001A6` | `A001A6` *(same → normal boot)* |
| end state (PIFA) | running Toolbox (`A1CF74`) | stuck SCSI poll (`A0786A`), "?" |

⟹ **The bug is the EXTRA (2nd) SCSI bus reset.** A normal boot does **1** bus
reset (the SCSI Manager's init reset) and reaches the desktop. A miss does a
**2nd** bus reset — the driver **aborts and resets the bus** — and *that* cascades
into the spontaneous reboot (+1 ROM init). The reboot is the *reaction*, not the
disease; the disease is a **SCSI op that fails only on the bad boot**.

Note: success=6.0.8, miss=7.5.5, so the OS differs — but the counts are ROM-driven
(SCSI Manager init is in ROM), so the comparison is valid. Confirm the matrix
(see Next steps): a 7.5.5 *warm* success and a 6.0.8 *cold* miss would fully
nail "miss ⟺ 2 bus resets" independent of OS.

---

## RULED OUT by probes — do NOT re-chase these dead ends

- **NOT a hardware reset:** PRST `reboots=0`, PFR `rst_falls=0` → no `_cpuReset`
  edge ⟹ not `n_reset`, not the Egret `egret_reset_680x0` (both pull `_cpuReset`;
  generated in `dataController_top.sv:189`).
- **NOT a RESET instruction:** PFR `instr_falls=0`.
- **NOT a bus error:** PBER (since removed) showed `sdma_berr=0`, `cpu_berr`=100%
  routine `fc7` probes, `berr→reset=0`. **The unrecoverable-BERR / sdma_berr
  hypothesis is DEAD** (a wrong turn — was chased for ~2 builds).
- **NOT overlay re-assert:** `addrController_top.v:294` re-enables the overlay
  only on `_cpuReset` (never fires).

⟹ **The reboot is a pure SOFTWARE re-entry into ROM boot/init** — no hardware
signature, which is why it's been invisible/long-standing.

---

## The failure code — disassembled ROM PCs (from `releases/boot0.rom`, off = addr & 0x7FFFF)

- **`A07A04` = the SCSI Manager "reset bus + walk device list" routine** (where
  the 2nd bus reset comes from; `PRT1/PRT2` froze here on the miss):
  ```
  A07A04: move.w sr,-(a7)
  A07A06: ori.w  #$700,sr           ; mask interrupts
  A07A0A: move.b #$80,$10(a3)       ; ICR = $80  → ASSERT SCSI BUS RESET (ICR.RST)
  A07A10: lea $50(a4),a5            ; walk a device linked-list...
  A07A20: movea.l (a5),a5           ;   a5 = next node
  A07A2A: jsr (a0)                  ;   call handler [a4+$198] per device
  A07A2C: bra $a07a20
  ```
  (`a3` = NCR5380 base `$F10000`; `$10(a3)`=ICR reg1, `$40(a3)`=CSR reg4.)
- **`A0786A` / `A0788E` = the SCSI selection/handshake POLLS** — `btst #6,$40(a3)`
  = poll **CSR bit6 BSY**, `btst #5,$40(a3)` = poll **bit5 REQ**, each
  `dbne/dbeq` with a **timeout count scaled by `[$0B24]`**:
  ```
  A07860: mulu.w $b24.w, d1         ; timeout = [$0B24] * d1
  A07882: move.w $b24.w, d1 / lsl.l #8,d1
  ```
- **`A001A6` = `move.w #$2700,sr` init dispatcher** (`movea.l $0DBC.w,a0; jsr(a0)`)
  — **NORMAL boot** (both success and miss hit it; `boot_inits` baseline = 2).
- Boot entry: reset PC `$2A` → `JMP $8C`; cold boot runs init in the **overlay at
  `$00008C`**; first live high-ROM fetch = **`$A02E3E`** (NOT `$A02E00`).

---

## Leading hypothesis — marginal SCSI poll timeout vs our target/HPS latency

`$0B24` = **`TimeDBRA`**, the ROM's *calibrated* DBRA-delay count (iterations per
unit time, measured at boot vs the VIA timer) — it scales the SCSI BSY/REQ poll
timeouts above. It can't be *systematically* wrong cold (6.0.8 cold succeeds), so
the timeout is **marginal**, and a SCSI op in 7.5.5's heavier handoff has a
**target/HPS response latency that exceeds the (TimeDBRA-gated) poll timeout** →
the poll times out → the SCSI Manager **aborts → 2nd bus reset → reboot**. This
fits: general cold-init race, all OSes, cold-fails/warm-fixes (warm retains a
good TimeDBRA + warmed SD/HPS), probabilistic, and rate ∝ System size. It is the
**handshake-timing** cousin of the #2 pseudo-DMA-latency issue (FIXED) —
i.e. **our SCSI target / HPS round-trip is slower than the ROM expects**, but on
the *selection/handshake* path, not the data path.

**Two candidate roots (not mutually exclusive):**
1. **`TimeDBRA` miscalibrated/marginal** at cold boot (VIA-timer / E-clock timing
   at first config — see memory `clock-audit-vs-mame`). Fix = the calibration.
2. **Our SCSI target (`scsi.v`) / HPS responds too slowly** to a selection or
   command at the handoff (cold SD mount/first-access latency), tripping the
   poll. Fix = speed/ack the target's BSY/REQ on that op, or pre-warm.

---

## Next steps (in order)

1. **Read `TimeDBRA` ($0B24) on miss vs success.** Add a probe that latches
   `cpuDataIn` when `cpuAddr==$00000B24` (and/or the *write* to it during
   calibration). If miss's TimeDBRA ≪ success's → root #1 confirmed. (`$0B24` is
   RAM, so it can't be read with the current probes — needs this small latch.)
2. **Catch what triggers the 2nd bus reset** (the failed op + the caller of the
   reset routine). Current `PRT1/2` froze *inside* `A07A04` (`A07A10`); need the
   trail *into* it: freeze a deeper PC ring at the **routine entry `A07A04`**, or
   statically find `A07A04`'s callers (disasm `boot0.rom`, grep operands for
   `a07a04`) = the SCSI Manager recovery path. The op that fails right before is
   the target.
3. **Confirm the cold/warm × OS matrix:** a 6.0.8 *cold MISS* (does it also show 2
   bus resets?) and a 7.5.5 *warm SUCCESS* (1 bus reset?) — proves "miss ⟺ 2nd
   bus reset" is OS-independent and warm-fixes-it.
4. **MAME cross-check** (`C:\Temp\mistercore\mame`, `maclc`): how the ROM's SCSI
   Manager poll/timeout + TimeDBRA calibration behave, and the target's expected
   BSY/REQ latency. (#2 was cracked this way — `macscsi.cpp`/`ncr5380.cpp`/
   `nscsi/hd.cpp`.)
5. **Fix + verify** via the differential (cold-boot N times, miss-rate → 0).

---

## Probe deck (current RBF — `dbg_probes.sv` + `MacLC.sv`, decode `scripts/cpu_state.tcl`)

Standard deck (PADR/PSTA/PACT/PIFA/PIFD/PEXC/PEX2-3/PFR0-3/PDRD/PSCS/PSC2-3/
PSCW/PSNC/PSWL/PSC6/PVID) + SCSI stall (PSDT/PSDS/PSD2-3) + **#3 probes**:
- **PRST** (MacLC.sv) — reset-source recorder (proved no `_cpuReset`).
- **PRC0/PRT1-3** (dbg_probes.sv) — #3 reboot isolation: `PRC0` = `scsi_bus_resets`
  + `boot_inits`(move#$2700,sr) + `trail_frozen`; `PRT1/PRT2` = the 2 IF PCs at
  the **2nd SCSI bus reset** (frozen); `PRT3` = latest move#$2700,sr entry.
- **Removed:** PBER/PBEA (BERR ruled out), PRIN/PRIA (address-window detector was
  noisy — counted line-A trap dispatch). ~30 probes total; timing ~+0.15–0.37 ns
  (**near the probe budget ceiling — trim a probe before adding one**).

---

## Ops / tooling crib

- **Build:** `bash scripts/build.sh` (Quartus 17.0.2, ~19 min → `output_files/
  MacLC.rbf`). Lint offline first: `verilator --lint-only` in WSL with a stub for
  `altsource_probe` (`scratch/altsource_probe_stub.sv`) — catches width/syntax
  before the 19-min build. **NO Verilator *sim* on this box (user directive).**
- **Deploy / cold boot:** `bash scripts/deploy_screenshot.sh` (push+reboot+OSD =
  a cold boot). Faster cold boot that **resets the cumulative probes**:
  `ssh -i $MISTER_SSH_KEY root@$MISTER_HOST "echo load_core /media/fat/_Unstable/
  MacLC.rbf > /dev/MiSTer_cmd"`.
- **Capture:** `bash scripts/read_probes.sh` (decoded via `scripts/cpu_state.tcl`);
  `bash scripts/grab.sh out.png`. JTAG via local USB-Blaster (works from this
  Windows box); transient `FFFF/FFFE` read = glitch, re-read.
- **Differential method:** cold-boot (`load_core`) repeatedly; classify each by
  screenshot (**desktop = success / blinking floppy "?" = miss**); read probes per
  attempt. **Background monitor** that auto-catches a success: poll PIFA each
  ~50 s, exit when it escapes the `A078x`–`A07Ax` poll region (= reached the
  desktop) — see this session's `b1j96wxtm` loop / `scratch/mon_*`.
- **ROM disasm:** WSL capstone on `releases/boot0.rom` (off = addr & 0x7FFFF;
  reset SP/PC at off 0/4; PC=`$2A`).
- **MAME:** source at `C:\Temp\mistercore\mame` (read natively); binary `0.264`
  in WSL (`/usr/games/mame`).
- **Shared rig caveat** (`shared-mister-hps-exhaustion`): `.143` shared with
  lbmactwo; power-cycle + one-driver + batch ssh before trusting verdicts. This
  session's rig was freshly power-cycled & cooled.

## Captures saved (scratch/, gitignored)
- `success.{txt,png}` — 6.0.8 **cold SUCCESS** (1 bus reset, 2 inits, desktop).
- `diff_a1/a2/a3.txt`, `reinit_1.txt`, `trail_1.txt` — 7.5.5 **MISSES** (2 bus
  resets, 3 inits, "?"; deterministic).
- `mon_*` — the background-monitor poll log + candidate screenshots.

## Git
Branch `fix-os7-scsi-welcome-wedge`. #2 SCSI-prefetch fix committed (`1a732bf`);
the #3 diagnostic probes (PRST/PRC0/PRT) + these docs committed (`1530824`,
diagnostic-only — keep or revert once #3 is fixed). User merges PRs themselves.

## Related memory
`cold-boot-reboot-welcome-handoff` (this issue), `scsi-dma-stall-offline-analysis`
(#2, FIXED), `scsi-completion-irq-welcome-wedge` + `welcome-wedge-async-driver`
(the FIXED OS7 welcome *hangs* — distinct from this *reboot*), `clock-audit-vs-mame`
(VIA/E-clock timing — relevant to the TimeDBRA calibration), `shared-mister-hps-exhaustion`.
