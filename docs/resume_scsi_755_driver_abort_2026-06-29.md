# RESUME — MacLCii 7.5.5 SCSI boot failure: driver abort + bus-resets + hang (2026-06-29)

> ## ⚠ UPDATE 2026-06-29 (session 2) — the LEADING SUSPECT below is STALE; corrected here
> Static re-verification against the CURRENT tree (not the 3-day-old memory note):
> - **The "MR_DMA_MODE IRQ-gating divergence" lead is DEAD / inverted.** MacLCii's
>   `rtl/ncr5380.sv` already *deliberately* UNGATES the completion-IRQ latch (commit
>   `2a2bd7c` "Fix OS7 'Welcome to Macintosh' SCSI completion-IRQ wedge", 2026-06-14).
>   `ncr5380.sv:363-370` latches `irq_latch` on `dma_armed && pmatch_d && !bsr_pmatch`
>   **regardless of `MR_DMA_MODE`**, with a comment calling the gated form "the old"
>   broken behavior that DROPPED the completion IRQ. The sibling lbmactwo still has the
>   GATED form. So re-adding lbmactwo's gate = **REVERTING `2a2bd7c`** → likely
>   re-introduces the Welcome wedge. The memory note that flagged this is now superseded.
> - **The failing build already contains that ungating.** `videofix2` = the deployed
>   `output_files/MacLCii.rbf` (byte-identical, md5 `f4fe0e8e…`, built Jun 25), and `2a2bd7c`
>   (Jun 14) is its ancestor. The abort/bus-reset capture happened WITH the ungating in place.
> - **The pseudo-DMA DREQ engine is byte-identical to lbmactwo** — `dreq = scsi_req &
>   dma_en & !dma_ack_busy` + the `dma_ack_holdoff` FSM (`ncr5380.sv:153-221`). So the
>   7.68 ms DREQ stall is NOT a MacLCii-vs-sibling divergence in DREQ generation.
> - **The ONLY remaining SCSI-engine divergence is that IRQ ungating** (in the failing build).
> - **Notable clue:** per `../lbmactwo_Mister/docs/handoff_probe_fix_2026-06-14.md`, lbmactwo
>   boots **7.5.5 to a usable Finder WITH the GATED latch** → so two live hypotheses now:
>   **(A)** root is the DREQ mid-transfer stall (ungating is fine), or **(B)** the ungating
>   itself regressed System-load (a spurious/mis-timed completion IRQ). The loop-sample test
>   (step 2) discriminates these; do it BEFORE any rebuild. **SKIP old step 3's "start with
>   MR_DMA_MODE".**
>
> Tooling fixed this session: `scripts/sample_loop.tcl` sampled the now-**repurposed** `PDRD`
> (it carries SDRAM walk `din` since the 10MB fix, not I/O addr/value) → its "what is polled"
> output was garbage. Re-pointed at live probes `PADR`+`PSTA`; `loop_disasm.py` updated to
> histogram them. Run with `bash scripts/sample_poll.sh [N]`.

## SESSION 2 HW RESULTS (2026-06-29, later — device on `videofix2`/`f4fe0e8e`)
Drove the device live (SSH + JTAG both up; running RBF md5 = `f4fe0e8e…` = the ungated build).
- **Disk corruption is NOT the root.** The live `.hda` had been written during the prior crash;
  restored the pristine image from `MacLC_7-5-5.hda.zip` (md5 `13cbbaad…`, mtime back to Jun 11)
  and 7.5.5 STILL fails → it's the core, not the disk. (Restore cmd: on-device
  `unzip -o MacLC_7-5-5.hda.zip MacLC_7-5-5.hda -d /media/fat/games/MacLCii/`.)
- **Warm-restart symptom = ADDRESS-ERROR bomb during extension load** ("Mac OS Starting up…"
  splash, bomb: "address error"), i.e. EARLIER than the documented desktop "System-load hang".
  ⚠ **Likely contaminated**: warm-restart keeps SDRAM, so leftover crashed-state RAM may cause
  this earlier fault. A faithful repro needs a COLD boot (full relaunch / FPGA reconfig clears
  SDRAM + resets probe latches).
- **FAITHFUL COLD BOOT (pristine disk) → stuck on the blinking "?" floppy** ("disk not latching at
  cold boot" = documented symptom #2), and a LIVE loop-sample PINS IT TO SCSI (verified, NOT the
  stale PFR latch). The CPU spins in the ROM polled SCSI driver at `$A0786A`:
    - `$A0786A: BTST #6, $40(A3)` / `$A07870: DBNE D1, $A0786A` (outer `DBNE D5`).
    - `A3 = $F10000` (SCSI base) ⇒ `$40(A3) = $F10040` = NCR5380 **reg 4 = Current SCSI Bus Status
      (CSR)**; **bit 6 = BSY**. PADR confirms `$F10040` hit repeatedly.
    - ⇒ The ROM SELECTED the boot target and is spinning until **BSY asserts**. The core's SCSI
      target never drives BSY within the selection timeout (`D1`) → selection fails → no device →
      "?" floppy. Fresh `PSDT` = 2.7 ms SCSI stall + 1 bus reset (`berr_fires=0`).
  - ⚠ **The `$9FEE40` SDRAM-walk was a RED HERRING** — the stale `PFR` latch the doc says to ignore;
    a real walk failure produces a Sad Mac `0F`, not a "?" floppy. **SCSI confirmed.**
- **So there appear to be TWO SCSI sub-failures, both TARGET-HANDSHAKE:** **(1)** cold-boot
  **SELECTION / BSY** never completes → "?" floppy (this finding); **(2)** System-load multi-block
  **DMA REQ/DREQ** stall → driver abort `$A499F2` → hang (the original doc capture). A shared
  SCSI-target handshake fix may address both. Investigate `rtl/scsi.v` (target BSY-on-selection +
  REQ pacing) and `rtl/ncr5380.sv` (`scsi_bsy`/`scsi_sel`/selection). Portable to lbmactwo
  (byte-identical SCSI engine). **Bonus: the "?" floppy is a STABLE, loop-sampleable cold-boot
  repro — no need to chase the transient desktop hang to make progress.**

### ROOT HYPOTHESIS for the cold-boot "?" floppy — the `mounted` strobe-race
`scsi.v:391`: `reg mounted=0; always @(posedge clk) if (img_mounted) mounted <= |img_blocks;` —
`mounted` updates ONLY while the one-shot `img_mounted` strobe is high. Cold boot reconfigures the
FPGA → `mounted` resets to 0; if the HPS `img_mounted` strobe lands during/before reconfig (core
not live yet), it is MISSED and `mounted` stays 0 forever → the HDD target's selection gate
(`sel && din[ID] && mounted && !bus_busy`, scsi.v:771) never fires → no BSY → "?" floppy. Warm
restart keeps `mounted=1` (no reconfig) → boots further. Explains the cold-vs-warm asymmetry
OBSERVED this session AND symptom #2 "disk not latching at cold boot (less frequent lately)" = a
race. **lbmactwo has the IDENTICAL strobe-only `mounted` (scsi.v:384)** → same risk; fix ports to both.

**Can't confirm on the current build (probe constraint):** PSC2 ("selection transaction
visibility": `target_MOUNTED`/`din[ID]`/BSY, dbg_probes.sv:559) and PSCS (`img_seen`, :534) were
REPURPOSED to the SDRAM walk capture (`.probe(c0_cpa)`/`.probe(c0)`) — `psc2_r`/`pscs_r` are
computed but UNWIRED, so they read SDRAM data, not selection state. To confirm:
- **No-rebuild:** at the "?" floppy, RE-MOUNT the `.hda` via OSD (re-pulses `img_mounted`). If that
  un-sticks the boot → mounted-race CONFIRMED.
- **Rebuild (selection failure is DETERMINISTIC, so a rebuild won't mask it):** restore PSC2→`psc2_r`
  / PSCS→`pscs_r` and read `target_MOUNTED`/`din[ID]`/`img_seen` directly.

**Candidate fix (portable to both cores):** make `mounted` robust to a missed strobe — hold it from
a persistent mount-status / `img_size`, or re-request mount on reset — in `rtl/scsi.v`.

### ATTEMPT 1 (mounted = |img_blocks) — FLAWED, REVERTED. Why it's wrong:
Tried `wire mounted = |img_blocks` to be robust to a missed strobe. **Built (md5 `9f0714f5`),
deployed, cold-booted → NO change** (HW probes: same `BTST #6,BSY / DBNE` spin, `PRST reboots=0` =
stuck not looping, `scsi_bus_resets=1`). Then realized it's actively WRONG: `img_size` is a SINGLE
SHARED hps_io wire (MacLC.sv:165) reflecting the LAST-mounted slot. The original per-target
strobe-latch is correct *because* it captures `img_size` at each target's OWN `img_mounted` strobe
and HOLDS it. Combinational `|img_blocks` reads the *current* shared size, which the **PRAM mount
overwrites** (256 B → `img_size[40:9]`=0) → SCSI target reads `mounted=0` even after a real mount.
**Reverted both cores to the original strobe-latch.** There is no persistent per-slot size to fall
back on, so a missed/never-sent SCSI-6 strobe can't be fixed in scsi.v — the real issue is upstream
mount DELIVERY.

### CURRENT: diagnostic build to READ the mount/selection ground truth (stop guessing)
The cold-boot "?" floppy = SCSI selection never completes (`sel && din[ID] && mounted && !bus_busy`,
scsi.v:771; target never asserts BSY). Cold-specific (warm boots) ⇒ strongly `mounted=0` because the
SCSI-6 mount isn't delivered/captured after FPGA reconfig — but I was BLIND (PSC2/PSCS were
repurposed to the SDRAM-walk debug). **Restored them** (dbg_probes.sv: PSC2→`psc2_r`, PSCS→`pscs_r`;
cpu_state.tcl decodes added) and rebuilding. After deploy + cold boot, `read_probes.sh` now prints:
- `PSCS img_seen slot0` — did the core EVER receive the SCSI-6 `img_mounted` strobe?
- `PSC2 target_MOUNTED slot0` + `id_bits@SEL` — is target 0 mounted, and does it see its ID, at the
  ROM's selection?

Decision tree from that read:
- `img_seen=0` → HPS never delivered the SCSI-6 auto-mount after reconfig → fix is at the
  delivery/hps_io / `.s0` auto-mount level (NOT scsi.v). This is the "disk not latching at cold boot".
- `img_seen=1` but `MOUNTED=0` → the per-slot latch lost it (img_size overwrite race) → fix the latch
  to capture per-slot size at the strobe and hold it independently of later mounts.
- `MOUNTED=1` → selection fails on `din[ID]`/`bus_busy` → look there.

NOTE for next session: the SDRAM-walk JTAG decode (PSCS/PSC2/BUILD#10/11 block in cpu_state.tcl) now
reads garbage (those probes were repurposed back to SCSI) — ignore it; trust the new PSCS/PSC2 lines.

### GROUND TRUTH from the restored probes (diag build d44bef97) — reframes EVERYTHING
At the cold-boot "?" floppy:
- **Disk IS mounted.** `PSCS img_seen=11` (both slots' strobes received), `PSC2 target_MOUNTED=01`
  (target 0 mounted). And **target 0 = SCSI ID 6** (`ncr5380.sv:569 .ID(3'd6 - i)`). ⇒ EVERY mount /
  strobe-race / mount-delivery theory was WRONG. The disk is fully present to the core at cold boot.
- **The ROM is fixated on selecting SCSI ID 2, not the disk's ID 6.** `PSC2 id_bits=0x84` = initiator
  bit7 + target **bit2** (ID 2), `target_bsy=00 BSY=0`, and **150/150** rapid samples identical — it's
  not even scanning, it's stuck on an ID-2 selection that no device answers. The mounted ID-6 disk is
  never selected → no BSY → "?" floppy. CPU spins `A07870: BTST #6,CSR / DBNE` (wait-for-BSY).
- **The 68k is HELD in reset by the Egret** = the "latch". `n_reset=0`, `PRST live reset_src =
  EGRET+RESET_in (0x82)`, `PACT FROZEN` at a fixed value. reboots=1 (not a fast loop — a hold).
- **A clean core swap (menu→Apple-II→MacLCii via `/dev/MiSTer_cmd load_core`) did NOT clear it** —
  still "?" floppy. So it's not stale FPGA/SDRAM state.
- Warm-restart DOES boot (finds the disk) ⇒ the failure is a cold-boot-specific selection/boot-device
  problem, intermittent ("disk not latching at cold boot").

**Leading chain:** ROM's boot-device selection targets ID 2 (empty) → never selects the ID-6 disk →
68k hangs in the wait-for-BSY loop → Egret watchdog asserts+holds the 68k reset (the latch) → frozen.

**Open root questions:** (1) WHY does the ROM select ID 2 instead of the ID-6 boot disk on cold boot?
(PRAM "blessed" boot-device SCSI ID? the PRAM/.nvr load on SC2 racing? the boot-device scan logic?)
(2) What exactly triggers the Egret `egret_reset_680x0` (watchdog on the 68k hang?). Investigate
STATICALLY first — PRAM/boot-device handling + the Egret reset glue (`dataController_top.sv:189`).

⚠ **DEVICE-SAFETY (learned the hard way 2026-06-29):** rapid/repeated JTAG probe reads crashed the
WHOLE MiSTer (not thermal — it was cool). The killer was `sample_sel.tcl` firing 150 back-to-back
In-System-Probe reads with NO delay, plus looping `read_probes`. The DE10-Nano shares JTAG with the
HPS; aggressive `quartus_stp` contention hangs the HPS bridge. **Use single, well-spaced `read_probes`
only; NO rapid samplers; prefer HTTP screenshots; never poll JTAG while the core is wedged.**

### TEST A — move boot disk SCSI ID 6 → 0 (user-approved 2026-06-29; BUILDING)
RESEARCH (Apple *Inside Macintosh: Devices* SCSI Manager + Low End Mac): **SCSI ID 6 is the worst place
for a Mac boot disk** — highest *hardware* arbitration priority but **LOWEST OS boot priority** (IDs
0–4 rank above 5,6), and a device on ID 6 is de-prioritized/"de-channeled" by the **7.x SCSI Manager**.
The Mac's normal boot device is the internal drive at **ID 0**; "scan 6→0" is only the *forced*
(Cmd-Opt-Ctrl-Shift) recovery path. This explains **"7.5.5 worse than 6.0.8"** (6.0.8's older SCSI
Manager boots ID 6; 7.x's doesn't) and the probe evidence (ROM selecting low IDs, wedging on empty
ID 2, never booting the ID-6 disk). Sources in the session log.
- **CHANGE:** `ncr5380.sv:569` `.ID(3'd6 - i)` → `.ID(i)` (slot0=ID0, slot1=ID1); `MacLC.sv:63-64`
  CONF_STR labels "SCSI-6/-5" → "SCSI-0/-1". Phantom CD stays at ID 3 (ENABLE_EMPTY_CD=0; future CD-ROM
  is planned for this core). Build = original strobe-latch scsi.v + restored PSC2/PSCS probes + new IDs.
- **VALIDATE (gently — minimal JTAG):** cold boot → expect the disk found at ID 0 → reaches the real
  7.5.5 boot/crash instead of "?" floppy. Confirm via HTTP screenshot; one spaced `read_probes` to see
  `PSC2` selecting ID 0 (`id_bits` bit0) and `target_MOUNTED`.
- **If it works:** ID-6 placement was the cold-boot "disk not latching" root → then chase the actual
  7.5.5 crash (issue 2). **If not:** Test B = the core wedges on selections to EMPTY IDs (ROM hung on
  ID 2 instead of timing out) → fix `scsi.v` no-device / selection-timeout handling.

### ⚠ CRITICAL TOOLING BUG: the launcher was launching the WRONG core (fixed 2026-06-29)
`tools/misterdeploy/launch_unstable_core.py` was silently launching **`MacLC.rbf`** (the OLD core,
disk at ID 6) instead of **`MacLCii.rbf`** (disk at ID 0) — which INVALIDATED several tests. Three
compounding bugs, all now fixed:
1. **verify substring** (line ~292): `if exp in r or r in exp` made `"maclc" in "maclcii"` rubber-stamp
   the wrong sibling as "OK launched". → fixed to a word-boundary match (reject partial-word overlaps).
2. **osd-at-menu**: pressing `osd` at the MAIN MENU opens a *settings* overlay, not the browser nav, so
   keys land on nothing ("coreRunning empty - still at the menu"). Do NOT send `osd` for a menu launch.
3. **timing**: default `--delay 0.3` + `sleep:1.2` exceeds the menu's ~5s cursor-nav timeout → a key
   silently drops → lands one row short (on MacLC). → fixed: `--delay 0.12`, `sleep:0.6`.
**Reliable faithful launch now:** `python tools/misterdeploy/launch_unstable_core.py --push
./output_files/MacLCii.rbf --core MacLCii.rbf --delay 0.12` → verify must print `coreRunning='MacLCii'`
(NOT `'MACLC'` — the conf_str name is the only thing distinguishing the builds; `coreRunning` alone of
the right *name* still doesn't prove the right *build*, so also md5 `/media/fat/_Unstable/MacLCii.rbf`).
Helper `scripts/menu_highlight.sh` highlights a core WITHOUT launching (for visual screenshot check).

### FAITHFUL SCSI-ID-0 RESULT (2026-06-29): disk-at-ID-0 + Egret-gone, but ROM fixates on PRAM's ID
On the CONFIRMED MacLCii scsi-id0 build (`d98c3879`, verified `coreRunning='MacLCii'`): disk
`MOUNTED=01` at ID 0, **Egret latch GONE** (`reboots=0`, `live reset_src=(none)`) — real progress on
issue #1. BUT still "?" floppy because the ROM keeps selecting the PRAM's startup ID, not the disk's:
`PSC2 id_bits=0xC0` = ID 6 (stale PRAM, re-written by the wrong MacLC core's run). And a FRESH/zeroed
PRAM made it fixate on ID 2 (also empty), still not the ID-0 disk. So the Mac is **trying only the
PRAM startup-device ID (6 stale / 2 fresh) and not scanning down to ID 0**. Open: set PRAM startup to
the disk's ID, OR find why it isn't falling through to a full scan (the user expects MacOS to scan all
disks — it isn't here). PRAM file = `/media/fat/games/MacLCii/MacLCii.nvr` (512 B; backups `.bak`/`.bak2`).
- **SCSI bug is ACTIVE**: `PRC0 scsi_bus_resets` climbed 3→7 across the boots; `PRT1=A499F2`
  (driver abort path) still latched. So the driver is stalling→aborting→bus-resetting during load.
- **The fixed loop-sampler works end-to-end on HW.** At the bomb it cleanly reconstructed the
  spin loop `A02A38: TST.B $0172 / BNE $A02A38`. **`$0172` = `MBState`** (Mac low-mem mouse-button
  state) → this is the **bomb dialog's "click to restart" wait**, i.e. the POST-CRASH idle loop,
  an EFFECT not the cause. ⇒ The post-bomb state can't reveal the root; must capture the LIVE
  failure moment (or a faithful cold-boot stall). The sampler reads live PIFD/PADR/PSTA; note
  ~30% of JTAG reads come back all-`FFFF` (flaky) and the decoder shows them as `FFFFFE` / every
  select+DREQ+IRQ set at once — ignore those rows.
- `PEXC` showed last fatal = `BUSERR vec=2 @ $A0DBFC` (the bomb says "address error" — the
  address fault likely fired first, then the handler hit a bus error). `PFR` walk-derail `$9FEE40`
  is the STALE SDRAM Sad-Mac latch (warm-restart doesn't reset it) — ignore for SCSI, as before.

**Open root question (unchanged):** is the failure (A) a missed SCSI completion / DREQ delivery
that wedges the load, or (B) memory/data corruption → the address error? Need a faithful
cold-boot capture of the live stall to decide. Reboot budget caveat: HPS dies ~8 reboots/session
→ physical power-cycle (ask user).

## MISSION (do this autonomously)
Root-cause the **System 7.5.5 SCSI boot failure** on the MacLCii MiSTer core, on **REAL HARDWARE**.
Drive it yourself — minimize check-ins, don't wait for hand-holding (user pref:
[[prefers-autonomous-driving]]). Pin down the mechanism, then fix the root (no band-aids).
**Confirm the root BEFORE spending a 30-min build** — the user is tired of speculative builds.

## HARD CONSTRAINTS (read first — these were learned the hard way)
1. **This is a TIMING bug → debug on HARDWARE, NOT the simulator.** The ideal-timing Verilator
   sim CANNOT reproduce it (zero-latency timing erases the race; it fails to boot even
   known-good 6.0.8). DO NOT invest in sim repro. See [[timing-bugs-use-hw-not-ideal-sim]].
2. **Don't ADD JTAG probes.** Adding probes perturbs timing and can make the bug vanish
   (Heisenbug). Use the EXISTING probes only (read-after-failure). New probes = a rebuild =
   risk of masking the bug.
3. **Don't hard-restart the core once it reaches System-load** (disk writes) — that HFS-
   corrupts the disk ([[maclcii-disk-corruption-from-hard-restarts]]). Restarting during the
   early SDRAM Sad Mac (pre-SCSI) IS safe. Keep a pristine 7.5.5 to restore (see TOOLING).

## SYMPTOMS (user-reported)
(1) hard-disk corruption reported by Finder during a session; (2) disk not latching at cold
boot (less frequent lately); (3) hang during bootup. All **worse on 7.1/7.5.5 than 6.0.8**
(6.0.8 uses the ROM polled SCSI driver; 7.x loads the interrupt-driven on-disk HD SC 4.3
driver + large multi-block transfers + VM).

## WHERE WE ARE — faithful HW capture (2026-06-29, device running the `videofix2` build)
Booting 7.5.5 on the real device:
1. **Cold boot → SDRAM PMMU-walk Sad Mac `0F / 0028`.** This is the KNOWN racy cold-boot SDRAM
   issue (walk read of the page-table descriptor @ `$9FEE40`; this time the probe said the
   descriptor WRITE was lost). It is **separate from the SCSI bug but BLOCKS reaching it**.
   7.5.5 hits it far more than 6.0.8 (more PMMU walks via VM/bigger footprint) → likely a big
   part of "7.5.5 boots worse." **Warm-restart past it** (osd→up→up→confirm; pre-SCSI, disk-safe).
   See [[maclcii-10mb-walk-read-mistiming]].
2. **After warm-restart → System-load HANG**: grey desktop with a half-drawn empty white window.
3. **JTAG at the hang (existing probes) = SCSI DRIVER FAILURE:**
   - `PRC0 scsi_bus_resets=3`; `PRT1 cpu pc @ 2nd SCSI bus reset = A499F2 (driver abort path)`
     → the SCSI driver is **aborting + resetting the bus repeatedly**.
   - `PSDT max_stall ≈ 249651 cyc (~7.68 ms)` → a huge SCSI DMA stall (normal handshakes are
     µs). berr_fires=0 (the 250ms glue timeout didn't fire).
   - CPU then spinning in a RAM poll loop (`cpuAddr≈$06843C`, `PC16=8442`, `opcode=0CAF`=`CMPI.L`),
     `scsiDREQ=0/scsiIRQ=0`, ILLEGAL exceptions firing.
   → SCSI transfer stalls → driver times out → aborts + bus-resets → can't recover → hang.
   - **IGNORE the `PFR`/walk-read block here** (`9FEE40`, `data=FFFFFFFF`, counters=`65535`):
     that's the STALE/saturated latch from the earlier SDRAM Sad Mac, NOT this hang. Trust
     `PRC0`/`PRT1`/`PSDT`/`PSTA`.

## LEADING SUSPECT (⚠ SUPERSEDED — read the UPDATE banner first)
*Original framing kept for context; the IRQ-gating half is already done/inverted — see banner.*
**LC SCSI interrupt/DRQ delivery.** The 7.x HD SC 4.3 driver (Apple_Driver43 partition,
ddBlock 64) is interrupt-driven: between pseudo-DMA chunks it polls the interrupt controller's
IFR for SCSI **IRQ and DRQ**. The LC has **NO VIA2**: `scsiIRQ → pseudo-VIA IFR bit 3`
(MacLC.sv ~485; dataController_top.sv ~33/369), and `scsiDREQ` only gates DTACK — it is **not
exposed as a pollable IFR flag**. If the driver waits on a SCSI IRQ/DRQ flag the LC mis-/never
delivers → stall → abort → the observed failure. **(The DRQ-pollability half of this is still
live; the IRQ-delivery half is the part already addressed by `2a2bd7c` — see banner.)**

~~Concrete RTL divergence already found~~ — **NOW STALE.** The current code is the OPPOSITE of
what [[maclcii-scsi-irq-gating-divergence]] reported: MacLCii's `ncr5380.sv:363-370` IRQ latch
is **intentionally NOT gated** on `MR_DMA_MODE` (the Welcome-wedge fix), and the **DREQ engine
is byte-identical to lbmactwo** (`ncr5380.sv:153-221`). MacLCii ALREADY has the other lbmactwo
SCSI fixes (req_bus, req_deferred, irq_latch infra, word-mode `odd_byte_r` write fix, `!bus_busy`
bus-free selection). lbmactwo's full SCSI debugging history is in `../lbmactwo_Mister/docs/`:
handoff_scsi_corruption_2026-06-10, handoff_scsi_bootfail_pram_2026-06-12,
scsi-multiblock-handshake, scsi_audit_2026-06-10, SCSI_IOTEST_INVESTIGATION,
handoff_probe_fix_2026-06-14 (notes lbmactwo boots 7.5.5 to Finder with the GATED latch).

## PLAN — testing to pin it down (in order)
1. **Reproduce**: set `.s0` to 7.5.5, launch the core, warm-restart past the SDRAM Sad Mac
   (≤ a few tries) until the System-load hang, confirm via JTAG (scsi_bus_resets climbing).
2. **Pin the root (the key test)**: at the hang, `bash scripts/sample_poll.sh 160` — the FIXED
   loop-sampler (`sample_loop.tcl`→`loop_disasm.py`). It reconstructs the spin loop @ `~$068442`
   from `PIFD`, **and** histograms `PADR` (full cpuAddr) + `PSTA` (FC/RW/selects/scsiDREQ/scsiIRQ)
   to show WHAT the driver polls — any `$F1xxxx` (SCSI reg) or `$F26xxx` (pseudo-VIA IFR) data
   read stands out by region. Cross-check with `bash scripts/read_probes.sh` `PSDS/PSD2/PSD3`
   (stall-mode snapshot: H1 phase=DATA io_ack=0 / H2 pmatch=0 / H3 dma_en=0) — that directly
   names the DREQ-stall mode. (Existing probes only — do NOT add probes / rebuild for this.)
   Discriminates banner hypotheses **(A)** DREQ stall vs **(B)** spurious completion-IRQ.
3. **Decide from the data, not the stale diff.** If the poll target is a SCSI **DRQ/DREQ** wait
   → DREQ-delivery root (engine identical to lbmactwo ⇒ look at the *target* side `rtl/scsi.v`
   REQ generation, the `req_deferred` CSR-hide `ncr5380.sv:393-415`, or the `scsiDREQ→DTACK`
   glue). If it spins on a stale/spurious SCSI **IRQ** (pseudo-VIA IFR bit 3) → re-examine the
   `2a2bd7c` ungating (hypothesis B). Do NOT re-apply lbmactwo's `MR_DMA_MODE` gate blind — that
   reverts `2a2bd7c`.
4. **Fix the root**, PRESERVING LC-specific pseudo-VIA routing — do NOT blind-copy Mac II VIA2
   wiring (the LC has no VIA2). Build, deploy, validate.

## PORTABILITY — port fixes back to the sibling Macintosh cores
The SCSI engine (`rtl/ncr5380.sv`, `rtl/scsi.v`) shares a lineage with `../lbmactwo_Mister`
(lbmactwo was ported FROM MacLC). The DREQ engine + `dma_ack_holdoff` FSM are currently
**byte-identical**, so any DREQ-path fix should port cleanly to lbmactwo (and the other cores in
the family). Caveats: (a) the IRQ-latch path has DIVERGED — MacLCii ungated it (`2a2bd7c`),
lbmactwo is still gated; reconcile deliberately, don't blind-sync either way. (b) the LC has NO
VIA2 — `scsiIRQ`/`scsiDREQ` route via pseudo-VIA, not VIA2, so the top-level wiring
(`MacLC.sv`, `dataController_top.sv`, `pseudovia.sv`) is LC-specific and must NOT be copied to
Mac II cores. Land the chip-side fix (`ncr5380.sv`/`scsi.v`) in both; keep the glue per-machine.
5. **Validate on HW (intermittent → statistical)**: boot 7.5.5 several times (warm-restart past
   the SDRAM Sad Mac each time); success = reaches the desktop, and JTAG `scsi_bus_resets` stays
   0 / `PSDT` stall small. Restore 7.5.5 from its `.zip` between runs if corruption suspected.

## TOOLING / ENVIRONMENT
- `source scripts/local.env` first. `MISTER_HOST=192.168.99.143`, key via `$MISTER_SSH_KEY`
  (`~/.ssh/mister_only`), web port `8182`. Windows host; Quartus 17.0 on Windows; WSL has
  Verilator/GHDL (sim is useless for THIS bug). HTTP screenshot API: `:8182/api/screenshots`.
- **Switch booted SCSI disk** — `/media/fat/config/MacLCii.s0` = relative path, null-terminated,
  zero-padded to 1024 B. To boot 7.5.5:
  `cp MacLCii.s0 MacLCii.s0.bak; { printf 'games/MacLCii/MacLC_7-5-5.hda\0'; head -c 994 /dev/zero; } > MacLCii.s0`
  Images: `/media/fat/games/MacLCii/MacLC_7-5-5.hda` (+ `.hda.zip` pristine; also `LBMacTwo/`).
  6.0.8 control = `MacLC_6-0-8-POP.hda`.
- **Launch core (no rebuild)**: `python tools/misterdeploy/launch_unstable_core.py --core MacLCii.rbf`
  (reboots, OSD-launches; core auto-mounts `.s0`).
- **Screenshot**: `bash scripts/grab.sh <out.png>` → Read the PNG. Crop+scale with PIL to read
  small dialog text. Boot (memtest ROM) takes ~30-35 s to reach the SCSI phase. **Foreground
  `sleep` is BLOCKED** by the harness — background a `sleep 35; bash scripts/grab.sh ...`.
- **Warm-restart** (past the SDRAM Sad Mac): OSD keystrokes over MiSTer-Remote ws `/api/ws`:
  `osd → up → up → confirm` (= "Reset & Apply CPU+Memory", keeps SDRAM). Python `websockets`
  snippet: connect `ws://$HOST:8182/api/ws`, drain, send `kbd:osd`, `kbd:up`, `kbd:up`,
  `kbd:confirm` with ~0.4 s gaps. (`echo reset > /dev/MiSTer_cmd` does NOT work.)
- **JTAG probes (READ existing only)**: `bash scripts/read_probes.sh` (USB-Blaster; decodes
  `scripts/cpu_state.tcl`). Flaky ("device not found"/all-FF) → just retry. SCSI-relevant:
  `PRC0` (scsi_bus_resets + `PRT1` cpu pc @ bus reset = driver abort path), `PSDT` (SCSI DMA
  max_stall / berr_fires), `PSTA` (scsiDREQ/scsiIRQ/selects/FC/AS/DTACK), `PACT` (advancing vs
  wedged). IGNORE `PFR` for SCSI.
- **Build**: `rm -rf db incremental_db && bash scripts/build.sh` (~30 min). Watch newest
  `output_files/auto_compile_*.log` for `Compile exit=0`. Save good RBFs
  (`cp output_files/MacLCii.rbf output_files/MacLCii_<name>.rbf`). Deploy with `--push`:
  `python tools/misterdeploy/launch_unstable_core.py --push ./output_files/MacLCii.rbf --core MacLCii.rbf`.
- **HPS dies after ~8 reboots/session** → physical power-cycle (ask user). Revive web svc:
  `ssh … /media/fat/Scripts/remote.sh -service restart`.
- Branch `fix-video` (has SDRAM walk fix `0c7f7f1` + video fixes `a961750`/`75f6353`).
  SCSI RTL: `rtl/ncr5380.sv` (~758 L), `rtl/scsi.v` (~1293 L). Sibling: `../lbmactwo_Mister`.

## VERIFY-BEFORE-ASSERTING
Memory notes here are point-in-time; re-check current code (file:line may have drifted) before
acting. Confirm the device's running build (md5 of `/media/fat/_Unstable/MacLCii.rbf`) — it
should have the SDRAM read-fix (walk read returns a clean 0, `din_OR=0000`).

## RELEVANT MEMORY
[[timing-bugs-use-hw-not-ideal-sim]] · [[maclcii-scsi-irq-gating-divergence]] ·
[[maclcii-mister-hardware-access]] · [[maclcii-disk-corruption-from-hard-restarts]] ·
[[maclcii-10mb-walk-read-mistiming]] · [[prefers-autonomous-driving]]
