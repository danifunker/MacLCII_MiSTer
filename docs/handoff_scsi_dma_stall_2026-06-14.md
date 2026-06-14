# Handoff — SCSI boot stability: #2 pseudo-DMA stall (PRIMARY), then #3 cold-boot reboot loop

*2026-06-14. The OS7 "Welcome to Macintosh" wedge is FIXED and committed
(`2a2bd7c`, branch `fix-os7-scsi-welcome-wedge`; deployed RBF md5 `0bc29da5`).
With the fix the core boots all the way to the **Finder desktop**. Two SCSI/
boot issues remain, in priority order below. Start with #2.*

## What's already fixed (context, do not redo)

**OS7 Welcome wedge = SCSI completion-IRQ race.** The disk driver's async read
waits in the Device Manager (`$02DA14`: `MOVE.W ($10,A0),D0 / BGT` = spin until
`ParamBlockRec.ioResult <= 0`; ioResult is PB offset `$10`, `>0`=in progress).
The SCSI read's HW DMA finished (`eodma=1`) but the completion IRQ was lost:
`ncr5380.sv` only latched `irq_latch` on a `pmatch`-falling edge while
`(MR.DMA_MODE && dma_armed)`, and `dma_armed` was cleared the instant DMA_MODE
cleared — the driver clears DMA mode just before the target's DATA→STATUS phase
change, so the IRQ never latched and ioResult never cleared.
**Fix (committed):** keep `dma_armed` across a DMA-mode clear + latch on
`pmatch`-fall regardless of DMA_MODE (real 5380 latches EOP/phase-mismatch in
HW). The OSD toggle used to verify it was removed; the fix is now unconditional.
See memory `scsi-completion-irq-welcome-wedge`. NOTE this is a DIFFERENT wedge
from the old LocalTalk/SCC `welcome-wedge-async-driver`.

---

## #2 (PRIMARY) — SCSI pseudo-DMA STALL on heavier reads

**Symptom:** with the fix on, boots to the desktop, then **hangs on heavier
disk I/O** — reproduced by **opening Control Panels** (loads many cdevs). User:
"hard disk reads hang in other places."

**✅ Symptom data ALREADY CAPTURED (2026-06-14):** `scratch/hang_cp_probes.txt`
(the Control Panels stall) + `scratch/crash_latest_probes.txt`. Full readings
embedded under Evidence. The static RTL analysis below can start **offline now**;
only the "active-stall snapshot" (see Status after Evidence) needs the rig back.

**NEXT STEPS (in order — step 1 needs no rig, start here):**
1. ✅ **DONE (2026-06-14) — Offline static analysis** → `docs/findings_scsi_dma_stall_offline_2026-06-14.md`.
   Result: host-side handshake is structurally sound (ACK bit-train accounting
   verified byte/word/long; double-buffer phasing self-correcting). Ranked
   hypotheses: **H1 (primary) = `io_busy` held by slow HPS block fetch starving a
   1-block-deep read prefetch** (supported by `req_drops=65535` saturated +
   `dack_beats` advancing = death-by-many-stalls, not a wedge); H2 = early
   data-phase completion; H3 = `dma_en` cleared mid-burst; H4 ruled out.
   **CORRECTION: the recurring `vec=2 @ $A0DBFC` is NOT a SCSI DMA BERR** — ROM
   disasm proves it is benign Memory Manager handle validation (temp BERR
   handler `$A0DB50` catches it), confirmed by `PSDT berr_fires=0`. The exact
   active-stall probe to add (PSDS/PSD2/PSD3) is specified in the findings doc.
1b. ✅ **DONE (2026-06-14) — MAME ground-truth cross-check → H1 CONFIRMED.**
   Read local MAME source (`C:\Temp\mistercore\mame`): `maclc.cpp` +
   `macscsi.cpp` (the `mac_scsi_helper`) + `ncr5380.cpp` + `nscsi/hd.cpp`. The
   pseudo-DMA stall/BERR architecture (DRQ→DTACK wait-states, BERR timeout, SCSI
   Manager's own handler) is **faithful — do NOT remove our gate/watchdog**. The
   ONLY divergence is the data source: MAME's `nscsi_harddisk` reads each sector
   **synchronously from the host file (0 emulated latency)** + a 4-byte CPU FIFO,
   so its 16 µs FIFO timeout never trips; our HPS-round-trip-per-512B with a
   **1-block-deep prefetch** stalls the CPU per boundary (= H1, `req_drops=65535`).
   **Fix direction (ground-truth-backed): deepen the read prefetch / widen the
   sector buffer** so blocks are ready ahead of demand (mirrors a drive track
   cache). PSDS snapshot is now fast *validation*, not exploration.
2. ✅ **IMPLEMENTED (2026-06-14) — deeper read prefetch + PSDS diagnostic, in
   `rtl/scsi.v` + `rtl/ncr5380.sv` + `MacLC.sv` + `scripts/cpu_state.tcl`.**
   Details: `docs/findings_scsi_dma_stall_offline_2026-06-14.md` §Implementation.
   - **Fix:** `rtl/scsi.v` read path is now a parameterized **N-sector prefetch
     ring** (`RING_LOG=3` ⇒ 8 sectors; `RING_LOG=1` == original double buffer).
     The engine keeps the ring filled up to N sectors ahead, hiding per-sector
     HPS latency. **WRITES untouched** (confined to slots 0/1, original logic).
   - **Diagnostic (same RBF):** `PSDS/PSD2/PSD3` sticky snapshot latches the live
     stall state (~16 ms threshold) → H1 vs H2 vs H3 in one JTAG read.
   - Lints clean (`verilator --lint-only`, project policy); Quartus build kicked.
3. **NEXT (on rig — the only remaining step): deploy + validate end-to-end.**
   `scp output_files/MacLC.rbf …/_Unstable/` (or
   `tools/misterdeploy/launch_unstable_core.py`), boot to desktop, **open Control
   Panels** → should open without the multi-hundred-ms stalls. If a residual
   stall remains, `bash scripts/read_probes.sh` → read the **PSDS** block (expect
   it to say "no deep stall captured"; if it captured, the H1/H2/H3 fingerprint
   tells you what's left). Tunables: `RING_LOG` (2…4) in `rtl/scsi.v`,
   `SDMA_SNAP_THRESH` in `MacLC.sv`. Re-check #3 (may share the fetch-readiness
   root).
4. Circle back to **#3** (cold-boot reboot loop) — **quiet-rig repro first**
   (the `0F` Sad Mac may be environmental, see #3).

**It is NOT the completion-IRQ issue** (that's fixed) and NOT caused by the fix
(the fix only touches the IRQ latch; the DREQ/DACK transfer path is unchanged,
and these stalls predate it — the first 7.1 boot BERR was this same class).

**Evidence (probes at the Control Panels hang — `scratch/hang_cp_probes.txt`):**
- `PSDT dma timeout: berr_fires=0 max_stall=6783546 cyc (~208.72 ms)` — a SCSI
  pseudo-DMA transfer **stalled ~209 ms** (near the ~250 ms `sdma_berr` watchdog
  threshold; the very first 7.1 boot BERR fired at ~250 ms).
- Recurring **`PEXC ... vec=2 (BUSERR) faulting IF=A0DBFC`**, fires count
  climbing (9→13). ~~bus errors recurring at the SCSI-driver DMA access.~~
  **CORRECTED 2026-06-14 (offline disasm): `$A0DBFC` is benign Memory Manager
  handle validation** (installs temp BERR handler `$A0DB50`, probes a handle,
  catches the fault by design — same class as the `$A08D14` false alarm). NOT a
  SCSI DMA fault, NOT a retry loop. Proven by `PSDT berr_fires=0` (the `sdma_berr`
  watchdog, the only thing that BERRs a stalled DACK, never fired).
- **CPU active in the ROM Device Manager** (`PIFA A1B8xx`, `A1B904`/`A1B87E`),
  not a frozen spin → a read **stalls → BERR → driver retries → stalls again**
  (retry loop). DMA idle between attempts (`dma_en=0 dreq=0 eodma=1`),
  interrupts serviced (`IPL` toggles), so it's not masked / not a completion
  miss.
- `PSC3 t0 max=MSG` (commands do reach STATUS/MSG at times); `req_drops=65535`
  (saturated REQ-drop counter — REQ pauses during transfers).

**STATUS — this symptom data is CAPTURED, not "to gather."** Caveat: both saved
snapshots (`hang_cp_probes.txt`, `crash_latest_probes.txt`) caught the DMA
engine **idle between retries** (`dma_en=0`), and `PSDT max_stall` is a
high-water mark — so we have proof the ~209 ms stall happens, but not a snapshot
*during* the active stall. The static RTL analysis ("Where to look" below) can
proceed **offline now** against the captured state; the only remaining LIVE step
is one **active-stall snapshot** (`dma_en=1` with `dreq`/`dma_ack` stuck
mid-transfer) to pin the exact handshake hang — that's the sole thing needing
the rig back on MacLC (likely via a debug-probe rebuild that latches the stall
point: byte index, phase, `dack_beats`, which of dreq/ack/holdoff is stuck).

**Hypothesis:** the pseudo-DMA **DREQ/DACK handshake hangs mid-transfer** (host
starved of DREQ, or `dma_ack`/`holdoff`/`pmatch` lost mid-chunk). This is the
known **byte-slip / DMA-wedge class** — memory `scsi-port-state-and-byte-slip`
("+1 byte insertion in one write cmd + lost write cmds"). The 06-12 pseudovia
IRQ/DRQ rewiring did NOT fix it.

**Where to look (`rtl/ncr5380.sv`):**
- DREQ generation `bsr_dmarq = scsi_req_bus & dma_en`; `dma_ack <= dma_en &
  bsr_pmatch` (~line 216); `dma_ack_holdoff`/`dma_ack_busy` logic.
- The deferred-REQ machine (`req_deferred`, ~line 387) — "MacII race, REQ on
  Data→Status" Snow semantics; suspect interaction with multi-chunk transfers.
- `bsr_pmatch` (TCR vs actual phase) dropping mid-transfer.
- The `NCR_STALL` `$display` (~line 710) flags the wedge condition in sim.
- `MacLC.sv` `sdma_berr` watchdog (`PSDT` probe: `sdma_berr_cnt`,
  `sdma_stall_max`) — fires BERR after ~250 ms to unwedge; tune/diagnose here.
- `rtl/scsi.v` — the SCSI target/disk model (REQ/ACK pacing, the dpram path).

**Probe/repro method (steps 1-2 DONE — see captures + Status above):**
1. ✅ DONE — fix RBF (`_Unstable/MacLC.rbf` md5 `0bc29da5`) boots to desktop;
   opening **Control Panels** triggers the stall.
2. ✅ DONE — `read_probes.sh` → `hang_cp_probes.txt` (`PSDT` ~209 ms stall +
   retry-loop BERRs). Remaining live gap = the **active-stall snapshot** (Status
   above). Everything below this line is doable **offline now**.
3. `quartus_stp_tcl -t scripts/sample_loop.tcl 200` + `loop_disasm.py` for the
   retry loop; `scripts/sample_padr.tcl` for the operand/wait address.
4. Ground-truth vs MAME (WSL `~/maclc_roms`, built from `releases/boot0.rom` +
   `rtl/egret/*.bin`): trace `maclc` SCSI pseudo-DMA over the same op; the
   `mac_scsi`/`ncr5380` device + the .Sony/HDSC driver path. `scratch/
   disasm_rom.py` (WSL capstone) disassembles `boot0.rom` (offset = addr &
   0x7FFFF; ROM aliased at $A00000).
5. A **debug-probe rebuild** likely needed: expose the live DREQ/DACK
   handshake + the chunk byte-count + where the transfer stalls (the current
   deck shows engine state but not the mid-chunk stall point). Add a sticky
   "stalled at byte N / phase P / dack=M" capture.

**Goal:** reads complete without the ~200 ms stall → no watchdog BERR → no
retry loop → Control Panels (and apps) open. Likely fixes the reboot loop (#3)
too if that shares the DMA-stall root.

---

## #3 (CIRCLE BACK) — cold-boot happy-mac reboot loop

**Symptom (user-confirmed 2026-06-14):** at **cold** start the core often
shows the happy Mac then reboots/Sad-Macs; **clears after 1–2 warm boots** from
within the core. Persists WITH the welcome-wedge fix (the fix neither helps nor
hurts it — different mechanism).

**Signature → cold-boot state/init, not the completion path.** "cold fails →
warm boot fixes it" means first-config state is bad and a warm reset (ROM +
SDRAM retained) is clean. Matches `MacLC.sv:99-108` (rom_loaded latch; cold
loads can run on previous-core SDRAM garbage) + memory `warmboot-reboot-loop`
(the phantom-PDS `$FFFF`-ack fix was validated but clearly not 100% at cold
boot). Candidates: SDRAM/overlay readiness, PRAM/Egret cold-init timing
(`pram-persistence`: HC05 zeroes PRAM on startup), HPS SD/SCSI block-device not
ready at first config.

**⚠ Environmental caveat (READ FIRST):** during this session a reset produced a
**`0F` Sad Mac (`0000000F / 00000028`, `scratch/crash_latest.png`)**. Per memory
`shared-mister-hps-exhaustion`, `0F`/`0003` Sad Macs on KNOWN-GOOD RBFs are the
signature of **shared `.143` HPS exhaustion** (this session hammered it with
probes/screenshots/ssh; rig is shared with the lbmactwo session). **#3 must be
reproduced on a QUIET, freshly power-cycled rig** before treating any cold-boot
Sad Mac as a real core bug — otherwise the verdict is void.

**Method:** power-cycle the rig, one driver only, batch ssh; cold-boot N times,
record Sad Mac codes + `read_probes.sh` (PEXC vec, PADR, PSDT, PRAM/Egret
state); compare cold vs warm. Decode Sad Mac codes against the maclc ROM.

---

## Shared context / tools / ops crib

- **Diagnostic deck:** `rtl/dbg_probes.sv` (JTAG In-System Probes — PADR/PSTA/
  PIFA/PIFD/PEXC/PFR/PSDT/PSCS/PSC2/PSC3/PSCW/PSNC/PSWL/PSC6/PVID). Read:
  `bash scripts/read_probes.sh` (decoded), `scripts/sample_loop.tcl` +
  `scripts/loop_disasm.py`, `scripts/sample_padr.tcl`. JTAG via local
  USB-Blaster; **don't run while a Quartus compile uses the cable.** Occasional
  garbage read (`FFFF FFFE`) = transient JTAG glitch, just re-read.
- **`PFR "BERR-NEAR-DEATH" @ $A08D18` and `PEXC $A08D14` are FALSE alarms**
  (routine `$8`-region vector reads) — ignore. `PSDT` is the reliable SCSI-stall
  signal; `PEXC vec=2 @ $A0DBFC` is the SCSI-driver DMA BERR.
- **Build:** `bash scripts/build.sh` (Quartus 17.0.2, `scripts/local.env` has
  `QUARTUS_BIN`; ~19 min; → `output_files/MacLC.rbf`). Timing meets (~+0.3 ns).
- **Deploy:** `scp output_files/MacLC.rbf root@$MISTER_HOST:/media/fat/_Unstable/
  MacLC.rbf` (no reboot) OR `tools/misterdeploy/launch_unstable_core.py`
  (push+reboot+OSD-select). Screenshot: `bash scripts/grab.sh out.png`.
- **MAME ground truth (WSL Ubuntu-24.04):** `mame 0.264`, romset built by
  `verilator/mame/floppy/setup_roms.sh` → `~/maclc_roms` (verifyroms OK). MAME
  loads `.dc42`/`.dsk` natively. Confirmed `v8.cpp pseudovia_r`: Video Config
  ($F26010) = `montype<<3` CONSTANT (ruled out an earlier wrong "pseudovia
  reads 0" theory). DC42 + Main_MiSTer review: **no Main_MiSTer change needed**
  for DC42 (F-mount streams raw; core parses the header).
- **Shared rig:** `.143` shared with lbmactwo — HPS exhaustion → `0F` Sad Macs /
  crashes on good RBFs. One driver, batch ssh, power-cycle + re-validate before
  ANY verdict. (memory `shared-mister-hps-exhaustion`)
- **Git:** fix committed on `fix-os7-scsi-welcome-wedge` (`2a2bd7c`), NOT pushed,
  NOT merged (user merges PRs themselves — `dont-auto-merge-prs`). Working tree
  clean at handoff except this doc.
- **Captures (local, scratch/ is gitignored):** `hang_cp.png` +
  `hang_cp_probes.txt` (#2 the Control Panels stall), `crash_latest.png` +
  `crash_latest_probes.txt` (`0F` Sad Mac, likely environmental), `hang71*`
  (the welcome wedge, now fixed).
```
