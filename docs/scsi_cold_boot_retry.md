# SCSI Cold-Boot Reboot — the "extra bus reset / retry" issue

*Complete description of the long-standing cold-boot spontaneous-reboot blocker
("#3"), as understood 2026-06-15. For the live investigation plan and ops crib,
see the companion handoff `docs/handoff_cold_boot_reboot_2026-06-15.md`.*

---

> **⚠️ 2026-06-15 LATE CORRECTION (read first).** The §3.3/§4 hypothesis that a marginal
> **`TimeDBRA`-gated poll timeout** vs. target/HPS latency causes #3 has been **DISPROVEN by direct
> measurement**: a JTAG latch read **`TimeDBRA ($0B24) = 781` (NORMAL)**, and over a *full-length*
> poll the CPU read the SCSI CSR 255+ times seeing **BSY=0 every time while the boot disk held
> CMD_IN/BSY=1** (JTAG-confirmed). So the target responds correctly and the poll is not degenerate —
> **#3 is the CPU's VPA read of the SCSI status register marginally failing to observe `scsi_bsy`**
> (a fit-sensitive timing/signal path; STA reports MET but it fails in HW). Registering the CSR/BSR
> read did not help. The fix targets the SCSI status-read path (constraint/register/restructure), not
> the timeout. Full detail + the (separate, FIXED) #2 prefetch-ring deepening are in
> `docs/handoff_cold_boot_reboot_2026-06-15.md` (top section). Treat §3.3/§4 below as superseded.

## 1. Summary

On a **cold** boot the Mac LC core intermittently **reboots itself once, right at
the ROM→System handoff (just before "Welcome to Macintosh"), then fails to find a
boot device** and parks at the blinking "?" disk. It is **not** a hardware reset,
a CPU fault, or a bus error — it is a **software re-entry into ROM init**,
triggered by the **SCSI Manager aborting and resetting the SCSI bus a second
time**. A healthy boot resets the SCSI bus exactly **once** (normal init) and
reaches the desktop; a failing boot does a **second** bus reset (an error
*retry*) whose recovery path falls back into ROM boot. The underlying trigger is
a **SCSI selection/handshake poll that times out** because our emulated target /
HPS disk responds more slowly than the ROM's (timing-calibrated) timeout allows.

## 2. Observed behavior

Boot sequence on a **miss** (user-reported, HW-precise):

> chime → basic init → mouse pointer → **Happy Mac** → *(loading the System)* →
> **spontaneous reboot** → basic init → mouse pointer → **"?" floppy disk** (parks)

Key properties:
- **Happy Mac is shown first** ⟹ the ROM already found a *blessed* System and read
  its boot blocks, so the disk is mounted and readable. The failure is **later**,
  during the System's earliest init (the boot-block→System handoff), **just before
  the Welcome screen draws**.
- **Silent — no Sad Mac, no bomb.** The machine simply re-runs basic init.
- **Cold-only, self-clearing.** Happens on a *cold* boot; **clears after 1–2 warm
  boots** from inside the core (warm retains good state). The user manually resets
  to retry — it is **not** a self-sustaining loop; each attempt either boots or
  misses once and parks at "?".
- **Probabilistic, rate ∝ System size:** 6.0.8 rarely misses < 7.1 ≈ sometimes <
  7.5.5 often. But it is a **general cold-init race on all OSes**, not
  7.5.5-specific. (A full-cold `load_core` of 7.5.5 reproduced it **100%** in this
  investigation; 6.0.8 cold-booted to the desktop.)
- The **sister core (lbmactwo)** exhibits the same behavior ⟹ a shared-architecture
  cause (the SCSI/CPU/reset glue is kept in sync between the cores).

## 3. Root-cause analysis

### 3.1 What it is NOT (eliminated by JTAG probes)

| Mechanism | Probe evidence | Verdict |
|---|---|---|
| Hardware CPU reset (`n_reset` or Egret `egret_reset_680x0`) | PRST `reboots=0`, PFR `rst_falls=0` (no `_cpuReset` edge) | **Ruled out** |
| 68k `RESET` instruction | PFR `instr_falls=0` | **Ruled out** |
| Bus error (`sdma_berr` watchdog / `fc7_berr`) | PBER `sdma=0`, `cpu_berr`=100% routine `fc7`, `berr→reset=0` | **Ruled out** (BERR theory dead) |
| ROM overlay re-assert | overlay only re-enables on `_cpuReset` (`addrController_top.v:294`) | **Ruled out** |

⟹ The reboot asserts **no reset line and executes no reset instruction**: it is a
**pure software transfer back into ROM boot/init**, running from high ROM with the
overlay off (hence no hardware signature — the reason it stayed hidden so long).

### 3.2 What it IS — the second SCSI bus reset (differential evidence)

Captured a clean **success** vs a **miss** with the same RBF (the JTAG probes are
cumulative per FPGA config, so each `load_core` is a fresh per-attempt reading):

| Probe | **SUCCESS** (6.0.8 cold → desktop) | **MISS** (7.5.5 cold, deterministic) |
|---|---|---|
| `scsi_bus_resets` | **1** | **2** |
| `boot_inits` (`move.w #$2700,sr` count) | **2** | **3** |
| 2nd-bus-reset PC trail frozen? | no | **yes** (CPU at `A07A10`) |
| ROM-init entry (`PRT3`) | `A001A6` | `A001A6` *(identical — normal boot)* |
| End state (`PIFA`) | running Toolbox (`A1CF74`) | stuck in SCSI poll (`A0786A`), "?" |

The miss has **exactly +1 SCSI bus reset and +1 ROM init** versus the success.
The init re-entry address is *identical* on both (`A001A6` is ordinary boot), so
the discriminator is unambiguous:

> **A miss = a normal boot + one extra SCSI bus reset + one extra ROM init.**
> The extra bus reset is the SCSI Manager **aborting**; its recovery path re-enters
> ROM init = the reboot.

### 3.3 The mechanism — poll timeout vs. target/HPS latency

The relevant ROM code (disassembled from `releases/boot0.rom`, offset = addr &
`0x7FFFF`):

**The bus-reset + device-rescan routine** (where the 2nd reset is asserted; the
miss's PC trail froze here):
```
A07A04: move.w sr,-(a7)
A07A06: ori.w  #$700,sr            ; mask interrupts
A07A0A: move.b #$80,$10(a3)        ; ICR = $80  →  ASSERT SCSI BUS RESET (ICR.RST)
A07A10: lea $50(a4),a5             ; walk a device linked list...
A07A20: movea.l (a5),a5            ;   next node
A07A2A: jsr (a0)                   ;   per-device handler [a4+$198]
A07A2C: bra $a07a20
```
(`a3` = NCR5380 base `$F10000`; `$10(a3)` = ICR reg 1, `$40(a3)` = CSR reg 4.)

**The selection/handshake polls** that gate each SCSI op — and time out:
```
A0786A: btst #6,$40(a3)            ; poll CSR bit6 = BSY
A07870: dbne d1,$a0786a            ;   with timeout count d1
A0788E: btst #5,$40(a3)            ; poll CSR bit5 = REQ
A07894: dbeq d1,$a0788e            ;   with timeout count d1
...
A07860: mulu.w $b24.w,d1           ; timeout = [$0B24] * d1
A07882: move.w $b24.w,d1 / lsl.l #8,d1
```

`$0B24` = **`TimeDBRA`**, the ROM's *calibrated* DBRA-delay count (loop iterations
per unit time, measured against the VIA timer during boot). It **scales the SCSI
BSY/REQ poll timeouts**. So:

> If a SCSI selection or command's BSY/REQ does not arrive within the
> `TimeDBRA`-derived window, the poll **times out** → the SCSI Manager treats the
> op as failed → it **resets the bus (the 2nd reset) and retries**, and that
> recovery path **re-enters ROM init = the reboot**.

`TimeDBRA` cannot be *systematically* wrong on a cold boot (6.0.8 cold succeeds, so
the calibration is usable). It is **marginal**: a SCSI op in 7.5.5's heavier
handoff has a **target/HPS response latency that exceeds the marginal timeout**,
while 6.0.8's lighter handoff never issues that op (or our target answers it in
time). This is the **handshake-timing analogue of the #2 pseudo-DMA-latency issue
(fixed)** — our SCSI target / HPS round-trip is slower than the ROM expects, but
on the *selection/handshake* path rather than the data path.

This single mechanism explains every observed property: software reboot (the
Manager's retry path), cold-only (cold SD-mount/first-access latency + a fresh
`TimeDBRA`), warm-fixes-it (warmed HPS + retained calibration), all-OSes, and
rate ∝ System size (more handshakes at a bigger handoff → more chances to trip
the margin).

## 4. Leading hypothesis & candidate fixes

**Hypothesis:** our SCSI target (`rtl/scsi.v`) / HPS disk does not assert
**BSY/REQ** fast enough on a selection or command at the System handoff, so the
ROM's marginal (`TimeDBRA`-gated) poll times out → abort → 2nd bus reset → reboot.

Candidate roots (not mutually exclusive):
1. **`TimeDBRA` calibrated too short at cold boot** — a VIA-timer / E-clock timing
   error at first config (see `docs/` clock notes / memory `clock-audit-vs-mame`).
   Fix the calibration's timing source.
2. **Target / HPS responds too slowly** to a specific selection/command — cold SD
   mount/first-access latency. Fix = make `scsi.v` assert BSY/REQ promptly on that
   op (or pre-warm the HPS path) so it answers within the poll window.

## 5. Diagnostic instrumentation (this RBF)

Added to the JTAG probe deck (`rtl/dbg_probes.sv` + `MacLC.sv`, decoded by
`scripts/cpu_state.tcl`, read with `bash scripts/read_probes.sh`):
- **PRST** — reset-source recorder (proved no `_cpuReset` / Egret reset).
- **PRC0 / PRT1-3** — reboot isolation: `scsi_bus_resets`, `boot_inits`
  (`move.w #$2700,sr` count), and the 2 instruction-fetch PCs frozen at the **2nd
  SCSI bus reset** (`PRT1/PRT2`), plus the latest ROM-init entry (`PRT3`).
- (Removed during the investigation: PBER/PBEA — proved this is not a bus error;
  PRIN/PRIA — an address-window re-init detector that mis-counted line-A trap
  dispatch.)

**Differential method:** cold-boot (`load_core`) repeatedly, classify each by
screenshot (desktop = success, blinking floppy "?" = miss), and read the probes
per attempt; the success-vs-miss diff is what isolated the 2nd bus reset.

## 6. Status & next steps

The failure is **isolated to the 2nd SCSI bus reset**; the trigger (a timed-out
SCSI handshake at the handoff) and the mechanism (`TimeDBRA`-gated poll vs target
latency) are **hypothesized but not yet confirmed**. Open work (detail in the
handoff):
1. Latch `[$0B24]` (`TimeDBRA`) and compare miss vs success.
2. Capture the SCSI op that fails right before the 2nd reset (freeze the PC trail
   at the reset routine's *entry* `A07A04`, or find its callers statically).
3. Confirm the cold/warm × OS matrix (a 6.0.8 cold *miss*, a 7.5.5 warm *success*).
4. MAME cross-check of the SCSI Manager poll/timeout + `TimeDBRA` calibration.
5. Implement the fix and verify by driving the cold-boot miss-rate to zero.

## 7. Related

- `docs/handoff_cold_boot_reboot_2026-06-15.md` — live investigation plan + ops crib.
- #2 SCSI pseudo-DMA stall (FIXED) — `docs/findings_scsi_dma_stall_offline_2026-06-14.md`
  (the *data-path* latency cousin of this *handshake-path* issue).
- OS7 "Welcome" wedges (FIXED) — distinct *hangs* (not reboots) at the same screen.
