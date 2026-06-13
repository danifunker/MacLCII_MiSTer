# Handoff — MAME ground-truth trace of the 7.1 / 7.5.5 boot (the core's "reboot bug")

*2026-06-12, branch `scsi-fixes-from-lbmactwo`. Run this on the Mac with the
MAME setup + disk images. Goal: a comprehensive, timestamped picture of what
MAME's `maclc` does at the points where our core dies, so the FPGA-side fix
targets the **actual** divergence instead of another plausible theory.*

## Where the FPGA investigation stands (context for cold pickup)

The 7.x boot on the core dies **deterministically** at SCSI transfer count
`dack_beats=14592` (~1 s after Happy Mac; 7.5.5 dies in the same window).
The failure is **not**: SCSI deafness (disproven — the rescan never re-selects
ID 6), memory size, video/SDRAM, disk state (pristine images fail), heat
(actively cooled now), or an illegal instruction (sticky probe stayed empty).
A flight-recorder probe (PFR rev 2, `rtl/dbg_probes.sv`) caught the death
neighborhood:

* The hot code at death is the ROM **blind-transfer primitive at `$A08CFA`**:
  `move.l $8.w,-4(a6)` (save bus-error vector) → install temp handler from
  `$1ac(a4)` → `jsr (a0)` (the transfer) → restore vector. Called dozens of
  times around the death moment.
* MAME's own `src/mame/apple/macscsi.cpp` documents the hardware contract:
  blind transfers rely on DRQ-gated DTACK/DSACK with a **BERR timeout**
  ("the SCSI Manager anticipates bus errors by inserting its own exception
  handler … later Macs attempt a limited number of recoveries … before
  exiting with `scBusTOErr`"). MAME implements this with a **16 µs/byte
  timer + a 4-byte FIFO + halting the CPU** (`mac_scsi_helper_device`), and
  wires the timeout to `M68K_LINE_BUSERROR` (`maclc.cpp:372`,
  `scsi_berr_w`).
* Our glue historically had **no timeout at all** (stalls DTACK forever) —
  and the "restart" the user sees is a **pure software transfer into ROM
  init** (no reset line, no RESET instruction — measured by the recorder).

**The open question this handoff answers:** in a *successful* MAME boot of
the same images, does the SCSI bus-error/timeout machinery actually fire and
recover (→ our missing timeout + TG68's bus-fault frame are load-bearing),
or does MAME boot with zero SCSI bus errors (→ the divergence is on the
DREQ/stall side and the timeout is a red herring)? Plus: what exactly happens
at the transfer count where we die?

## Runs to do (each for BOTH `MacLC_7-1.hda` and `MacLC_7-5-5.hda`)

Existing tooling: `verilator/mame/run_mame.sh` (env `MAME`, `ROMDIR`, etc. —
see `docs/mame_compare.md` for the gotchas: debugger defaults to the Egret
HC05 (`focus maincpu`), MAME PCs print as 8-digit `00Axxxxx`, macOS has no
`timeout`).

### Run 1 — bus-error counters (fast, decisive)

```
mame maclc -hard1 <disk>.hda -debug -debugscript verilator/mame/berr_count.dbg
```

`berr_count.dbg` (already in the repo) counts, with auto-continue:
* `$A08CFA` — every blind-transfer-primitive call
* `$A09BB0` — the exception-handler tail near our observed (bogus) RTE
  landing; fires only if a bus-error-class exception dispatches
* writes to vector `$8` — handler install/restore traffic

**Deliverable:** the three counts for a full successful boot, per disk.
If `$A09BB0` never fires, also add a breakpoint on whatever address gets
written into vector `$8` by the primitive (the temp handler itself — read it
with `print w@8` / the wp log) and count THAT.

### Run 2 — pseudo-DMA access timeline (the dack=14592 equivalent)

Lua tap on the DACK window, with timestamps, to find what the 14592nd
transfer corresponds to:

```
TAP_LO=0xf06000 TAP_HI=0xf07fff TAP_MODE=rw TAP_OUT=/tmp/dack_<disk>.txt \
  verilator/mame/run_mame.sh -hard1 <disk>.hda -autoboot_script verilator/mame/tap.lua
```

(If `tap.lua` doesn't timestamp, add `emu.time()` per line — it's a small
edit. Each 16-bit access ≈ one of our `dack_beats`.)

**Deliverables:**
* total DACK accesses by the time the desktop appears;
* the access-count timeline around 14000–15000: is there a pause, a burst,
  a phase change, a bus reset near there?
* correlate with Run 3's command log: which SCSI command (opcode/LBA) is in
  flight at beat ~14592? (That LBA ↦ which file via
  `..\lbmactwo_MiSTer\scripts\hfs_forensics.py <disk> <lba>`.)

### Run 3 — SCSI register/command log

Tap the NCR register window to capture the command stream:

```
TAP_LO=0xf10000 TAP_HI=0xf11fff TAP_MODE=rw TAP_OUT=/tmp/ncr_<disk>.txt \
  verilator/mame/run_mame.sh -hard1 <disk>.hda -autoboot_script verilator/mame/tap.lua
```

**Deliverable:** the sequence of commands (writes to reg 0 after selection =
CDB bytes) around the Run-2 hot window; note any bus reset (ICR bit 7
writes) mid-boot. Our core sees exactly TWO bus resets in the failing boot —
does MAME's successful boot have one or two?

### Run 4 — does MAME's boot ever pass through the ROM restart entry?

Our core's "reboot" enters ROM init around `$A1490A`/`$A14880`. In MAME:

```
bpset 0xa1490a,1,{printf "ROM-INIT %d\n",temp2; temp2=temp2+1; g}
```

added to a debugscript (or interactively). **Deliverable:** hit count during
a successful boot AFTER the initial reset — expected 0 if the restart is
purely our bug; >0 would mean a soft restart is normal and our divergence is
in surviving it.

### Run 5 (optional, only if Run 1 shows bus errors) — VERBOSE macscsi

Rebuild MAME with `#define VERBOSE 1` in `src/mame/apple/macscsi.cpp` and
capture the helper's own log of FIFO fills / timeouts / halt toggles around
the hot window. This is the highest-resolution view of the blind-transfer
mechanics but needs a MAME rebuild — skip unless Run 1 says the timeout
machinery is active.

## What comes back

A short report (counts + the two tap logs + the trace excerpt around beat
14592) is enough. The decision tree on the FPGA side:

* **Zero bus errors in MAME** → drop the timeout theory; the fix target is
  why OUR transfer reaches a no-DREQ state at beat 14592 at all (compare
  Run 2/3's command boundaries against our PSCW/PSNC captures; suspect the
  blind-transfer/HPS-fetch interaction or a phase change MAME handles
  differently).
* **Bus errors present + recovered** → the missing BERR timeout + TG68's
  bus-fault stack frame are confirmed load-bearing. The fix is the MAME
  helper shape (FIFO + CPU halt + per-byte timeout — NOT a naked 250 ms
  timer; see `macscsi.cpp` for the reference implementation) plus whatever
  TG68 frame repair the OS handler needs. A diagnostic build with a 250 ms
  stall-timeout probe (`PSDT`, build `MacLC_sdma`) exists to measure our
  stall distribution from the FPGA side.

## FPGA-side state at handoff (for whoever resumes there)

* Deployed: `_Unstable/MacLC.rbf` = `95cac3` (DC42 floppy support + recorder
  rev 1); `_Unstable/MacLC_fr2.rbf` = `c51fb4` (recorder rev 2 — the one that
  caught the primitive; INQUIRY ids now `MiSTer VIRTUAL DISKx`).
* In tree, unbuilt-at-handoff: pseudo-DMA 250 ms stall-timeout + PSDT probe.
* Floppy: DC42 header skip implemented (mount registers; data unreadable —
  separate known 16 MHz IWM/E-clock pacing issue, next floppy work item).
  1.44 MB MFM images unsupported (needs SWIM).
* All findings: `docs/findings_pds_phantom_card_2026-06-12.md` (phantom PDS
  card root-cause + the exoneration list), CLAUDE.md gotchas still apply.
