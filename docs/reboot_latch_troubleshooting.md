# Reboot-Latch Troubleshooting (the `PRST` probe)

How to catch and identify the **cold-boot "spontaneous reboot" / Egret reset latch**
(tracked issue #3) on real hardware using the JTAG In-System **`PRST`** probe.

> **What "the reboot latch" is.** On a bad cold boot the Mac chimes, draws the
> Happy Mac, then — *just before* "Welcome to Macintosh" — the 68k is yanked back
> into ROM boot/init. There is **no bus error and no `RESET` instruction**; the
> `_cpuReset` line is pulled by the **Egret HC05** asserting `egret_reset_680x0`
> (its watchdog, because the 68k is wedged in the SCSI selection poll and has
> stopped servicing the Egret). The 68k then re-runs boot, fails the SCSI select
> again, and ends on the blinking "?" floppy. `PRST` is the probe that proves
> *who pulled the reset line* — Egret vs a real system reset.

---

## TL;DR — read it

```bash
bash scripts/read_probes.sh          # single, well-spaced read — see DEVICE SAFETY
```
Look for the **`PRST reset-src`** line:

```
PRST reset-src  : reboots=1 armed=1 seen=1 first_nreset=0 n_reset=0
  live reset_src = EGRET+RESET_in (0x82)
```

- **`reboots` ≥ 1**  → the 68k was reset *after* it started running = a reboot happened.
- **`EGRET` bit set** in `reset_src`/`first_src` → the **Egret HC05** pulled the reset (the latch).
- **`reboots=0`**     → no reboot since the CPU came out of cold-boot reset (clean so far).

A clean boot reads `reboots=0`. The capture above (`reboots=1`, `EGRET` in the
source, `n_reset=0` = 68k held in reset) is the **latch firing**.

---

## What `PRST` measures

`_cpuReset` (`rtl/dataController_top.sv:189`) is forced by **exactly two** things:
`_systemReset` (`n_reset`) low, **OR** the Egret asserting `egret_reset_680x0`.
`PRST` arms once the CPU leaves cold-boot reset (`n_reset` releases), then on the
**first** `_cpuReset` falling edge it latches *which* source demanded it. This
skips the normal power-on reset and isolates the *spontaneous* one.

**RTL:** the reset-source recorder + probe live in `MacLC.sv` (search `PRST:
reset-source recorder`). The 32-bit probe word is:

| bits  | field            | meaning |
|-------|------------------|---------|
| 31:24 | `reboot_cnt`     | count of `_cpuReset` falls since arming (saturates at 0xFF) |
| 23:16 | `first_src`      | `reset_src` snapshot at the **first** reboot |
| 15:8  | `reset_src`      | **live** reset-source bits right now |
|  7    | `prst_armed`     | 1 = CPU has left cold-boot reset (recorder is live) |
|  6    | `first_rst_seen` | 1 = a reboot has been captured |
|  5    | `first_nreset`   | `n_reset` value at the first reboot (**1 ⟹ Egret-only reset**) |
|  4    | `n_reset`        | live `_systemReset` (0 = system reset asserted) |
|  3:0  | 0                | padding |

**`reset_src` / `first_src` bit map** (decoded by `scripts/cpu_state.tcl`):

| bit | name              | source |
|-----|-------------------|--------|
| 7   | `EGRET`           | `egret_reset_680x0` — **Egret HC05 firmware (the latch)** |
| 6   | `pll_unlock`      | `~pll_locked_s` |
| 5   | `rom_notloaded`   | `~rom_loaded` |
| 4   | `OSD_status0`     | `status[0]` (OSD reset) |
| 3   | `button`          | `buttons[1]` |
| 2   | `pram_force_reset`| "Reset PRAM & Core" (OSD R6) |
| 1   | `RESET_in`        | framework `RESET` |
| 0   | `rom_download`    | core/ROM (re)download (HPS index 0) |

---

## Decision table

| `PRST` reading | verdict |
|---|---|
| `reboots=0` | No spontaneous reboot since boot. (If still stuck → it's the *select* failing, not a reboot — read `PSC2`/`PIFD`.) |
| `reboots≥1`, `first_src` has **`EGRET`** (bit7), `first_nreset=1` | **Pure Egret-watchdog reboot** — the smoking gun (`first_src==0x80`). |
| `reboots≥1`, `reset_src` has **`EGRET`**, `n_reset=0` | Egret asserting reset **and** the system reset line low = 68k **held** in reset (a *hold/latch*, not a fast loop). This session's capture (`0x82`). |
| `reboots≥1`, source is `pll_unlock`/`button`/`OSD`/etc. (no `EGRET`) | A **real system reset** (user/OSD/PLL) — **not** the #3 latch; don't chase it. |

> **Why this rules things out:** PBER/PFR previously proved the reboot is **not** a
> bus error (`berr→reset=0`) and **not** a `RESET` instruction (`instr_falls=0`).
> So a non-`EGRET`, non-system-reset reboot would have *no* `PRST` source at all —
> i.e. a pure software re-entry into ROM init. `PRST` is what separates "the Egret
> hardware-reset the 68k" from "the 68k software-re-entered boot."

---

## Pin the *cause* — companion probes

The reboot is the **reaction**; the disease is the SCSI driver aborting. Read these
in the **same** `read_probes.sh` pass:

- **`PRC0`** — `scsi_bus_resets`, `boot_inits` (move #$2700,sr count), `trail_frozen`.
  A normal boot = **1** bus reset; a miss = a **2nd** bus reset (driver abort) and
  `trail_frozen=1`. The extra bus reset is what cascades into the reboot.
- **`PRT1/PRT2`** — the two IF-stage PCs frozen at the **2nd** SCSI bus reset
  (`~$A07A10`, the SCSI Manager "reset bus + walk device list" routine).
- **`PIFD` / `PSC2`** — where the CPU is spinning (`PC16=786A`/`7870` = the
  `btst #6,CSR / dbne` **BSY poll**) and the selection `id_bits`/`target_bsy`.

Typical bad-boot fingerprint: `PRC0 scsi_bus_resets≥2`, `PRT1≈A07A10`,
`PIFD` stuck in the `A0786x` poll, then `PRST reboots≥1` with `EGRET`.

---

## Root cause & fix (so you know what you're confirming)

The 68k polls the NCR5380 CSR for **BSY** during boot-device selection, but the
CPU's read of CSR bit-6 **marginally returns 0 while the disk is holding BSY=1**
(a fit-sensitive `~30.5ns` VPA read cone, STA-MET at only +0.2..0.44 ns). The SCSI
Manager concludes "no device" → aborts → 2nd bus reset → the 68k wedges → the
**Egret watchdog resets it** = what `PRST` catches. Full write-up:
`docs/handoff_cold_boot_reboot_2026-06-15.md`. Fix under test: strip the probe
deck (`NO_PROBES`) + a surgical SCSI-read `set_multicycle_path` in `MacLCii.sdc`.

---

## Caveats & device safety

- ⚠️ **Flaky/all-FF reads:** a glitched JTAG read shows `reboots=255`,
  `reset_src=0xFF`, `PC16=FFFF`, `scsi_bus_resets=255` (every bit set). **Ignore
  that row and re-read** — it is not 255 real reboots.
- ⚠️ **DEVICE SAFETY:** use **single, well-spaced** reads only. Rapid/looped
  `read_probes.sh` (or any back-to-back In-System-Probe sampler) **crashes the
  whole MiSTer** (the DE10-Nano shares JTAG with the HPS) → needs a physical
  power-cycle. Never poll JTAG while the core is wedged.
- ⚠️ **`PRST` only exists in a probe build.** The release/"clean" build defines
  `NO_PROBES` in `MacLCii.qsf`, which strips the whole probe deck (PRST/PRC0/PRT/
  dbg_probes). To use these probes, **build with `NO_PROBES` removed**. Note the
  deck has an **observer effect**: `dbg_probes` taps `scsi_bsy` and its fanout
  makes the marginal SCSI read (and thus the reboot) *more* likely — so a
  probe build reboots more than a clean build, and "0 reboots on the clean build"
  is the real success criterion (classify clean-build boots by **screenshot**:
  desktop = success / "?" floppy = miss).

## See also
- `docs/handoff_cold_boot_reboot_2026-06-15.md` — the full #3 investigation + differential method.
- `scripts/cpu_state.tcl` — the `PRST`/`PRC0`/`PRT` decoders (`proc _prst_srcname`).
- `scripts/read_probes.sh` — the single-read entry point.
