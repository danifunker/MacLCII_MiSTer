# ============================================================================
# UPDATE 2026-06-30 (afternoon) — BREAKTHROUGH: SDRAM is PERFECT; bug is READ-DELIVERY
# ============================================================================
# Built a CELL-LEVEL self-check in sdram.v (`dbg_cell720_r`, routed to JTAG probe
# PSWL): it captures, at the REAL SDRAM command level, the word WRITTEN to and READ
# BACK from descriptor cell $0FF720. HW result on a 10MB cold Sad Mac (0F/0028):
#   >> CELL $0FF720 self-check: WRITTEN=000B  READBACK=000B   <-- SDRAM IS FLAWLESS
# This ELIMINATES every SDRAM hypothesis: the $000B write commits to the cell AND the
# cell reads back $000B. NOT write-loss, NOT cell-loss, NOT mb_hi skew. The walker
# STILL gets 0 -> the bug is purely READ-DELIVERY (SDRAM dout -> dout_held -> walk_din
# -> walker s_state6 capture).
#
# Ruled out earlier today:
#  - mb_hi SKEW: forced mb_hi=0 (addrController_top.v) -> write+read co-located at
#    $0FF720, still reads 0. Not an address mismatch.
#  - 4MB config: does NOT hit the $9FEE40 walk derail (frozen=0) -> the walk Sad Mac
#    is genuinely 10MB-specific. (4MB has its OWN 0F/7FFF, unrelated, not pursued.)
#
# READ-DELIVERY FIX ATTEMPTS (sdram.v):
#  1. dout_held was latched on the REGISTERED ram_ready_r (1 clk_64 AFTER dout settles,
#     but ram_ready ALSO releases the walk DTACK that cycle) -> 1-cycle lag. FIX: latch
#     dout_held at STATE_READ (same edge as dout). Built 0128f07a, clk_mem clean +1.756.
#     HW: STILL 0F/0028, cell still 000B/000B. The lag wasn't the (whole) bug.
#  2. dout_valid was only cleared on WRITES, never on read-start -> a STALE same-addr
#     dout_valid from a prior walk re-read pass fires ram_ready IMMEDIATELY, releasing
#     the walk DTACK before the fresh read completes -> walker captures stale dout_held;
#     the re-read loop can't escape. FIX: clear dout_valid on (we||oe) at STATE_CMD_START.
#     Built 1bb71a35 + a DECISIVE diagnostic (PSC3 = walker CAPTURED wdd, vs PSWL cell
#     self-check). TESTING. If still derails, the wdd-vs-READBACK compare pinpoints it:
#       READBACK=000B & CAPTURED=0000 -> delivery still drops it (fix clk_64->clk_sys
#         capture: register walk_din into clk_sys / capture a cycle later)
#       CAPTURED=000B -> walker latched OK -> re-read/accept (walk_tries) logic bug
#       READBACK=0000 -> the borrowed read returns 0 at the SDRAM (read mis-timed)
#
# DBG/probe state: PSWL=dbg_cell720 {written,readback}; PSC3=wdd (walker captured);
# SDC has a false_path on *dbg_cell720_r[*] (JTAG-only reg, keeps clk_mem clean).
# Saved RBFs: MacLCii_cell720diag.rbf(e58f6bc0), _doutheld_fix.rbf(0128f07a),
# _doutvalid_fix.rbf(1bb71a35), _mbhi0.rbf(dd9e8134).
# ============================================================================

# RESUME — SDRAM-walk Sad Mac ROOT CRACKED: walker captures stale `din` (data-path hold), 2026-06-30

## ★ THE ROOT (HW-confirmed via the walk probes on Build B — precise, not a guess)
The PMMU page-table **walk read captures STALE data because the fresh SDRAM read
word is not HELD long enough to reach the walker's capture point** — it is NOT a
DTACK/data-valid timing bug (registering `ram_ready` did nothing).

Evidence — `read_probes.sh` on a Build B Sad Mac (`0F/7FFF`), CPU frozen at the
walk derail of `$9FEE40`:
```
WALKER read: descriptor addr=009FEE40  data=00000000   (should be $000B)
walk-read DECODE: selRAM=1 ramOE_fired=1 mb_hi=1  SDRAMword=0FF720
din during walk read: saw_000B=0  din_OR=4ED2          ($000B NEVER on the bus)
```
- `0x4ED2` = the 68k opcode **`JMP (A2)`** = a STALE instruction-fetch value left on
  the bus from the access *before* the walk. The walker latched THAT (then 0), never
  the descriptor.

Mechanism (closed end-to-end):
1. The walker captures the **live bus `din` at s_state 6, phi2** (`rtl/tg68k/tg68k.v:760-762`:
   `if(phi2 && s_state==6) walk_hi<=din / walk_desc<={walk_hi,din}`).
2. `din` (= `dataControllerDataOut` = `cpuDataOut`) only shows the fresh SDRAM read while
   `cpuDataOut = (cpuBusControl && memoryLatch) ? memoryDataIn : cpu_data`
   (`rtl/dataController_top.sv:288-307`) selects `memoryDataIn`. That window is brief
   (~`ram_ready`/s_state 4). By **s_state 6 it has reverted to `cpu_data`** (the registered
   read latch).
3. `cpu_data` (`dataController_top.sv:277`: `if(cpuBusControl && memoryLatch) cpu_data<=memoryDataIn`)
   **never latched the walk read's data** — `memoryLatch`/`cpuBusControl` don't fire
   correctly for the BORROWED, phase-misaligned walk cycle — so `cpu_data` still holds the
   prior fetch (`$4ED2`). The walker therefore captures stale `cpu_data`.
4. The re-read retry (`walk_tries`, max 6, tg68k.v:772-786) can't save it: the stale value
   is CONSISTENT (0/`$4ED2`), so two passes "agree" on garbage and it's accepted.

⇒ **It's a data-PATH HOLD bug**, marginal/fit-sensitive: the old `d98c3879` fit happened to
hold the data to s_state 6; every fresh rebuild this session (with the SCSI multicycle ±
probe strip) lost it → **10/10 cold boots Sad Mac** (vs ~⅓ on the old build). `0c7f7f1`'s
data-valid DTACK wait + addr-latch fixed the *address*/timing but NOT the data hold.

## THE FIX (precise — do this next, then build)
**Hold the walk read's valid SDRAM word until the walker captures it.** Lowest-risk first:
- **Option A (preferred):** extend the `cpu_data` latch so it ALSO fires on the SDRAM
  read-data-valid `sdram_ram_ready` (route it into `dataController_top`), not only
  `memoryLatch`. Then `cpu_data` holds the fresh descriptor word and `cpuDataOut`=`cpu_data`
  at s_state 6 → the walker captures the real data. `sdram_ram_ready` already exists
  (`MacLC.sv`, from `sdram.v` `ram_ready` — now registered as `ram_ready_r`). Verify it
  latches the RIGHT per-word value (the walk reads hi@addr then lo@addr+2; ram_ready pulses
  per word, before each s_state 6) and that adding it can't corrupt NORMAL reads (it's the
  valid read data, so it should be safe — but HW-verify).
- **Option B:** add a dedicated `reg [15:0] walk_data_held` latched on `ram_ready`, route it
  to `tg68k.v`, and capture IT (not `din`) in the walker at s_state 6 — fully isolates the
  walk path from the normal data mux. More routing, zero risk to normal reads.
- **Option C (root, biggest):** align the borrowed walk cycle so `memoryLatch`/`cpuBusControl`
  fire for it like a normal CPU read (busPhase-0 alignment in the TG68 micro-sequencer).

## ★★ BUILD C RESULT — Option B CONFIRMED working; uncovered a SECOND root (write-loss)
Built Option B (`dout_held` → `walk_din` → walker capture) = **Build C**
(`output_files/MacLCii.rbf` md5 **`bcbe486173d04c58358d1dc1a98751ae`**, saved nowhere yet —
SAVE IT; timing clean +0.261 ns). HW probe on a Build C cold Sad Mac (`0F/0028`), after a
flaky-read retry (first read was all-FF — ignore `255/7FFFFFFF/FFFF` rows):
```
WALKER read: descriptor addr=009FEE40  data=00000000
din during walk read: saw_000B=0  din_OR=0000        <-- was 4ED2 on Build B
walk-read DECODE: selRAM=1 ramOE_fired=1 mb_hi=1  SDRAMword=0FF720
```
- **`din_OR` 4ED2 → 0000 ⇒ Option B WORKS:** the walker now captures the held SDRAM value
  (`dout_held`), NOT the stale `JMP (A2)` bus. The data-path root is FIXED. **KEEP Option B.**
- **NEW root revealed:** the SDRAM read returns **`0`, not `$000B`** = **WRITE LOST** (the
  decode's `saw_000B=0 & din_OR=0000` case). The descriptor write of `$000B` is not at the
  walk-read location (`SDRAMword 0FF720, mb_hi=1`). Also fit-sensitive (old `d98c3879`
  committed it; my multicycle-shifted fits don't).

### NEXT (the 2nd root — SDRAM write-commit)
The walk read reads `mb_hi=1` (upper-16MB relocation). Confirm the descriptor WRITE lands on
the SAME location. Suspects (from `docs/resume_walk_sdram_timing_2026-06-25.md`):
- **`mb_hi` relocation** (`rtl/sdram.v` `sd_addr <= {addr[23],...}` + `MacLC.sv`
  `sdram_addr={1'b0,mb_hi,...}` + `addrController_top.v` `mb_hi=!dskReadAck && selectRAM &&
  motherboard_high`): if the WRITE's `mb_hi` ≠ the READ's `mb_hi` (timing/condition skew),
  they hit different SDRAM locations → read sees an unwritten `0`. The prior doc says the
  relocation "stayed in bank0, did NOT fix anything — consider reverting." **Try: revert mb_hi
  (write+read share one location) on top of Build C, build, re-probe `saw_000B`.**
- OR the WRITE DATA path is fit-broken (sd_data write multicycle in `MacLCii.sdc` lines 60-65;
  writes must be LIVE at CAS per the diag table). The write probes (PSCS/PSC2/PSC3/PSWL) are
  REPURPOSED to SCSI now — to see the write side, re-point them to the walker `wda/wdd` +
  newest-write capture (was BUILD#10/11), or read `$9FEE40` back with a CPU read after the
  table build.

## STATE THIS SESSION
- **SCSI reboot fix = DONE + STA-verified, just blocked from cold validation by this walk
  Sad Mac.** Build B `output_files/MacLCii.rbf` md5 **`991415945998136bf2f1686b0eb62d0f`**
  = probes + SCSI-read multicycle (`MacLCii.sdc`, +41 ns on the marginal BSY read) +
  registered `ram_ready` (`sdram.v`). On a WARM boot PRST/PSC2 read cleanly: `id_bits=0x81`
  (ID 0), `target_bsy=01 BSY=1`, `reboots=1`=OSD(my warm-restart) **no EGRET** ⇒ consistent
  with the reboot fixed, but warm always worked so the COLD #3 path is still unvalidated.
- Saved RBFs: `MacLCii_buildA_probes_mc.rbf` (`ae2b8b7a`, probes+mc), `MacLCii_noprobe_sdc.rbf`
  (`74acd5cb`, no-probe+mc), `MacLCii_scsiid0.rbf` (`d98c3879`, ORIGINAL probe build that
  cold-boots fine — the good walk fit). Working tree = Build B.
- Probes ARE in Build B (kept deliberately — the multicycle's +41 ns overwhelms the probe
  observer effect, and stripping them regressed the SDRAM fit). `read_probes.sh` works
  (retry once on a flaky "No In-System... instance" / all-FF read).

## VALIDATION PLAN (after the walk fix builds)
Refresh disk → cold-boot batch (screenshot). Walk fixed ⇒ Sad Mac rate drops, cold boots
reach SCSI. On the FIRST cold boot that reaches SCSI: `read_probes.sh` → **`PRST reboots=0`
with no EGRET = the #3 reboot fix VALIDATED** (the whole point), and Welcome/desktop = it
boots. ⚠ Reboot budget ~8/power-cycle; refresh `.hda` before each test (Sad Macs are
pre-SCSI = disk-safe). Tooling/commands: `docs/resume_walk_sdram_timing_2026-06-25.md` +
`docs/resume_scsi_755_driver_abort_2026-06-29.md`.

## RELEVANT MEMORY
[[maclcii-755-boots-warm-cold-races]] (this session) · [[maclcii-10mb-walk-read-mistiming]]
(the walk Sad Mac) · [[maclcii-mister-hardware-access]] · [[prefers-autonomous-driving]].
