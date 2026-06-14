# Offline static analysis — SCSI pseudo-DMA stall (#2 PRIMARY)

*2026-06-14. Step 1 of `docs/handoff_scsi_dma_stall_2026-06-14.md` — offline RTL
analysis of the pseudo-DMA handshake (`rtl/ncr5380.sv` + `rtl/scsi.v` +
`MacLC.sv` glue) read against the captured probe state. No rig used.*

---

## TL;DR

1. **Correction to the handoff: the recurring `PEXC vec=2 (BUSERR) @ $A0DBFC` is
   NOT a SCSI DMA fault and NOT a "stall → BERR → retry" loop.** ROM disasm
   (capstone, `releases/boot0.rom`) shows `$A0DBF8…$A0DC2C` is a **Memory
   Manager handle/pointer validator** that installs a temporary bus-error
   handler (`$A0DB50`), probes a handle, and catches the fault by design
   (`$A0DB50: andi.w #$feff,$a(a7); rte`). These BERRs are **benign**, the same
   class as the documented `$A08D14/$A08D18` "false alarms." The count climbing
   9→13 is just the Memory Manager validating handles while loading cdevs. It is
   confirmed independently: `PSDT berr_fires=0` proves the `sdma_berr` watchdog
   (the ONLY thing that BERRs a stalled DACK) never fired — so `$A0DBFC` cannot
   be a pseudo-DMA timeout.

2. **The host-side handshake RTL is structurally sound.** The pseudo-DMA ACK
   accounting (the `dma_ack_holdoff` bit-train) generates the correct number of
   SCSI ACKs per host access (byte→1, word→2, longword→4), and reads are always
   512-aligned so a longword never straddles `data_complete`. The double-buffer
   prefetch phasing (`sd_buff_sel` vs `data_cnt[9]`) is self-correcting in steady
   state. No host-side handshake bug found by inspection.

3. **CONFIRMED stall mechanism (H1) — verified against MAME ground truth (see
   "MAME cross-check" below): `io_busy` held by a slow HPS block fetch starving a
   1-block-deep read prefetch.** The target drops flow-REQ
   (`scsi_req=0`) whenever `io_busy` is high, which gates `dreq` low, which parks
   the CPU's DACK access (DTACK held off). The read prefetch is only **one block
   deep**, and pseudo-DMA drains a 512-byte block (~90–150 µs) at least as fast
   as the HPS can refill one — so throughput is **HPS-fetch-latency-bound**, and
   every latency spike becomes a direct CPU stall. The captured
   `req_drops=65535` (saturated) is the smoking gun: REQ has paused tens of
   thousands of times under `dma_en` = tens of thousands of block-boundary
   stalls. `dack_beats` advancing (12032→14876 across captures) confirms
   progress, not a hard wedge — i.e. **death-by-many-stalls**, perceived as a
   hang under heavy reads (Control Panels), with one spike reaching
   `max_stall ≈ 209 ms` (just under the 250 ms `sdma_berr`).

4. **The one thing still needed from the rig: an active-stall snapshot.** Both
   saved captures caught the engine **idle between retries** (`dma_en=0`,
   targets IDLE) — we have proof the 209 ms stall happens but no snapshot *of*
   it. The probe to add (below) latches the live stall state the first time a
   DACK access is DREQ-starved past a threshold, discriminating H1/H2/H3 in a
   single JTAG read.

---

## Evidence map (captured state → what it rules in/out)

From `scratch/hang_cp_probes.txt` (the Control Panels hang) and
`scratch/crash_latest_probes.txt`:

| Probe reading | Interpretation |
|---|---|
| `PSDT berr_fires=0 max_stall=6783546 (~208.7 ms)` | A real ~209 ms DACK stall happened, but the watchdog did **not** fire (209 < 250 ms). So `$A0DBFC` BERRs are **not** sdma timeouts. |
| `PSWL req_drops=65535` (saturated) | REQ paused ≥65535× under `dma_en` → tens of thousands of block-boundary `io_busy` stalls. **Strong H1.** |
| `PSNC dack_beats=14876` (was 12032) | Pseudo-DMA beats accumulate across the session → transfers progress; not a hard wedge. **H1 (slow, not stuck).** |
| `PSWL eodma=1`, `PSNC dma_en=0`, `PSC3 t0=IDLE` | Capture is **between** transfers (idle), not during the stall → we have no active-stall snapshot yet. |
| `PSC3 max t0=MSG` | At least one full command ran CMD→DATA→STATUS→MSG normally → the engine works; the failure is intermittent/throughput. |
| `PSNC tcr=7` (MSG+CD+IO) | Last TCR write set the MESSAGE-IN expectation = end-of-command, consistent with the idle capture (not a mid-DATA hang snapshot). |
| `PEXC vec=2 @ $A0DBFC fires 9→13` | **Benign** Memory Manager handle validation (disasm below), recurring because cdev loading does many validations. **Not the stall.** |

---

## ROM disasm — what `$A0DBFC` and the transfer primitive actually are

`scratch/dis_dma_stall.py` (capstone `CS_MODE_M68K_020`, ROM offset = addr &
0x7FFFF):

**`$A0DBFC` = handle/pointer validator with BERR protection (benign):**
```
A0DBF8: movea.l $8.w, a2            ; save current BusErr vector
A0DBFC: lea.l   $a0db50(pc), a3     ; A3 = temp BERR handler   <== "faulting IF"
A0DC00: move.l  a3, $8.w            ; install temp handler at $8
A0DC04: btst.b  #$0, $1efc.w
A0DC0C: move.l  $3c(a6), d0         ; risky deref (may bus-error)
A0DC14: and.l   $31a.w, d0          ; $31A = Lo3Bytes ($00FFFFFF) → 24-bit strip
A0DC1A: move.l  $38(a6), d0         ; risky deref
A0DC22: move.l  a2, $8.w            ; restore BusErr vector
A0DC2A: moveq   #$8f, d0            ; return error code if it faulted
```
The installed temp handler **catches and continues**:
```
A0DB50: andi.w  #$feff, $a(a7)      ; clear trace bit in stacked SR
A0DB56: clr.l   $2c(a7)             ; result = 0 (fault occurred / handle bad)
A0DB5A: rte                         ; return — execution continues
```
This is the classic Mac OS "probe a handle, catch the bus error, report
validity" idiom. The BERRs are expected and harmless.

**`$A08CFA` = the real polled pseudo-DMA transfer primitive** (BERR-guarded;
its handler at `$1ac(a4)` is what the 250 ms `sdma_berr` is designed to trip):
```
A08D14: move.l  $8.w, -$4(a6)       ; save BusErr vector
A08D1A: move.l  $1ac(a4), $8.w      ; install transfer-timeout handler
A08D24: movea.l (a0,d4.l), a0       ; pick byte/word/long transfer routine
A08D28: jsr     (a0)                ; do the transfer
...
A08D4C: btst.b  #$5, $40(a3)        ; poll DRQ (CSR bit 5)
A08D5E: move.b  (a0), (a2)+         ; the actual data-register read → memory
```
In the captured window this primitive did **not** time out (`berr_fires=0`),
consistent with `max_stall=209 ms < 250 ms`.

---

## Why the host-side handshake is sound (rules H-host-bug down)

**ACK accounting (`rtl/ncr5380.sv:206-221`).** One host DACK access produces the
right number of SCSI ACK pulses via the `dma_ack_holdoff` bit-train: the block
pulses `dma_ack` on the initial cycle and on each odd holdoff value.
- byte (holdoff 0): 1 pulse → `data_cnt += 1`.
- word (holdoff 2): pulses at init and holdoff=1 → 2 pulses → `data_cnt += 2`.
- longword (holdoff 6): init,5,3,1 → 4 pulses → `data_cnt += 4`; the 2nd 68020
  word cycle is ACK-suppressed (`dma_suppress_ack_latched`).

Reads are always `data_len = tlen×512` (multiple of 4), so a longword burst
never crosses `data_complete` → no read-side over-run. The byte-slip concerns in
the comments are **WRITE-path** only (odd-byte re-latch), not relevant to the
read stall.

**Double-buffer phasing (`rtl/scsi.v:187-194, 211-248`).** `sd_buff_sel` toggles
on each `io_ack` falling edge; the Mac is gated behind the fetch (`io_busy`
stalls it until the block is valid), so `sd_buff_sel` is always the opposite of
`data_cnt[9]` while the Mac reads. Prefetch (`req_rd`) fires once per block at
offset 20 and is 1:1 with `io_ack` — no double-prefetch into the same half. No
deadlock found in steady state.

**Conclusion:** with the host handshake correct, `dreq = scsi_req & dma_en &
!dma_ack_busy` can only stay low for ~209 ms via `scsi_req=0` (i.e. `io_busy` or
`data_phase_complete`) or `dma_en=0`. `dma_ack_busy` drains in ≤6 cycles and is
ruled out.

---

## Ranked stall hypotheses

### H1 — `io_busy` held by HPS block-fetch latency (PRIMARY)
The target holds `req=0` while `(io_rd|io_ack) && data_cnt[9]==sd_buff_sel`
(`rtl/scsi.v:211`), starving `dreq`. Prefetch is **1 block deep**; pseudo-DMA
drains a block faster than the HPS refills, so any HPS latency directly stalls
the CPU. Heavy reads accumulate these into an apparent hang; the 209 ms spike is
a latency outlier (SD GC / hps_io contention across the shared slots 0/1/2; see
memory `shared-mister-hps-exhaustion`).
- **Supports:** `req_drops=65535` saturated, `dack_beats` advancing, `max_stall`
  just under the watchdog, "boots fine but hangs on heavy I/O."
- **Active-stall fingerprint:** `phase=DATA_OUT(2)`, `io_rd=1`, `io_ack=0`,
  `io_busy=1`, `dma_en=1`, `scsi_req=0`, `data_cnt[9]==sd_buff_sel`.
- **Fix directions (after confirmation):** deepen the read prefetch beyond one
  block / widen the sector buffer; start the next fetch earlier than offset 20;
  reduce HPS per-block latency / slot contention. **Do not implement before the
  snapshot confirms H1.**

### H2 — early data-phase completion (byte-count mismatch)
Target leaves `DATA_OUT` (→ STATUS) while the host's DACK burst still expects
bytes; `bsr_pmatch` drops, `dma_ack` stops, `scsi_req` for data is gone → host
parks. Lower likelihood (read ACK accounting verified correct, block-aligned),
but possible on odd/non-block commands.
- **Active-stall fingerprint:** `phase != DATA_OUT` (or `data_complete=1`),
  `bsr_pmatch=0`, `dma_en=1`.

### H3 — `dma_en` cleared mid-burst
Driver clears `MR.DMA_MODE` between sub-chunks / in a recovery path → `dreq`
can't assert while the CPU still DACKs. Driver-behavior dependent.
- **Active-stall fingerprint:** `dma_en=0` / `mr_dma=0` with `phase=DATA_OUT`.

### H4 — `dma_ack_holdoff` / `dma_ack_busy` stuck (RULED OUT for long stalls)
Holdoff decrements unconditionally every cycle (≤6), so it cannot hold `dreq`
low for ms. Listed only for completeness; the snapshot will show `holdoff=0` if
so.

---

## The exact probe to add (active-stall snapshot)

Latch the live stall state **once**, the first time a pseudo-DMA DACK access is
DREQ-starved past a threshold (well above a normal HPS-fetch bridge, far below
the 250 ms BERR), and hold it for JTAG read. Reuses the existing
`sdma_stall_ctr`. Three new `altsource_probe` instances (`PSDS/PSD2/PSD3`) mirror
the `PSDT` pattern; decode mirrors `PSNC`/`PSCW`.

**1. `MacLC.sv` (next to the `sdma_berr` watchdog, ~line 589):**
```verilog
// Active-stall snapshot (PSDS/PSD2/PSD3): the first time a pseudo-DMA DACK
// access is DREQ-starved past SDMA_SNAP_THRESH (above a normal HPS sector-fetch
// bridge, far below the 250 ms BERR), latch the live SCSI state so JTAG sees the
// stall instead of the idle-between-retries state. Sticky until reset.
localparam SDMA_SNAP_THRESH = 23'd520000;   // ~16 ms @ 32.5 MHz (tunable)
reg        sdma_snapped    = 1'b0;
reg [15:0] sdma_snap_scsi2 = 16'd0;
reg [31:0] sdma_snap_ncr   = 32'd0;
reg [31:0] sdma_snap_wr    = 32'd0;
always @(posedge clk_sys) begin
    if (!_cpuReset)
        sdma_snapped <= 1'b0;
    else if (selectSCSIDMA && !scsiDREQ && !sdma_snapped &&
             sdma_stall_ctr == SDMA_SNAP_THRESH) begin
        sdma_snap_scsi2 <= dbg_scsi2_w;   // phase0/1, io_rd, io_wr, io_ack
        sdma_snap_ncr   <= dbg_ncr_w;     // dreq/dma_en/dma_ack/holdoff/mr_dma/pmatch/tcr
        sdma_snap_wr    <= dbg_wr_w;       // data_cnt/phase/io_busy/sd_buff_sel/data_complete
        sdma_snapped    <= 1'b1;
    end
end
altsource_probe #(.instance_id("PSDS"), .probe_width(32), .source_width(1),
    .sld_auto_instance_index("YES")) cp_psds
    (.probe({15'd0, sdma_snapped, sdma_snap_scsi2}), .source(), .source_clk(clk_sys), .source_ena(1'b1));
altsource_probe #(.instance_id("PSD2"), .probe_width(32), .source_width(1),
    .sld_auto_instance_index("YES")) cp_psd2
    (.probe(sdma_snap_ncr), .source(), .source_clk(clk_sys), .source_ena(1'b1));
altsource_probe #(.instance_id("PSD3"), .probe_width(32), .source_width(1),
    .sld_auto_instance_index("YES")) cp_psd3
    (.probe(sdma_snap_wr), .source(), .source_clk(clk_sys), .source_ena(1'b1));
```
Single-driver, mirrors `PSDT` → Quartus-clean.

**2. `rtl/ncr5380.sv` (PSCW mux, ~line 695): also route a READ target** so the
latched `data_cnt`/`io_busy`/`phase` are valid during a read stall (the mux
currently only selects `PHASE_DATA_IN`):
```verilog
        if (target_phase[j] == 3'd3 || target_phase[j] == 3'd2) dbg_wr_mux = target_wrstall[j];
```

**3. `scripts/cpu_state.tcl` (after the PSDT block):** read PSDS; if
`sdma_snapped`, decode `PSDS` (dbg_scsi2 layout), `PSD2` (PSNC layout), `PSD3`
(PSCW layout) with the existing `$phn` phase names. H1 ⇒ `phase0=DATA_OUT
io_rd=1 io_ack=0 io_busy=1 dma_en=1`; H2 ⇒ `pmatch=0`/`phase≠DATA_OUT`; H3 ⇒
`dma_en=0`.

---

## Next steps

1. **Apply the probe** (RTL edits above are ready), `bash scripts/build.sh`
   (~19 min, no rig), deploy `_Unstable/MacLC.rbf`.
2. **On a QUIET, freshly power-cycled rig:** boot to desktop, open Control
   Panels, then `bash scripts/read_probes.sh` and read `PSDS/PSD2/PSD3` →
   confirm/refute H1.
3. **If H1:** decide between deepening the prefetch (RTL) vs an HPS-latency fix;
   re-check #3 (cold-boot loop) which may share the fetch-readiness root.
4. The `$A0DBFC` BERR probe noise can be **de-prioritised** in future captures —
   it is benign Memory Manager validation, not a SCSI fault.

---

## MAME ground-truth cross-check (2026-06-14) — H1 CONFIRMED

Read against the local MAME source (`C:\Temp\mistercore\mame`, driver
`src/mame/apple/maclc.cpp`, helper `src/mame/apple/macscsi.cpp`, controller
`src/devices/machine/ncr5380.cpp`, disk `src/devices/bus/nscsi/hd.cpp`). MAME's
`maclc` is the ground-truth LC.

**The pseudo-DMA stall/BERR architecture is correct — it matches real HW.**
`macscsi.cpp` header (the real LC's SCSI glue), verbatim: *"the hardware enables
DRQ onto DTACK (MC68000) or DSACK0 (MC68020/030) so wait states can be inserted
to correspond to SCSI delays. Too long a delay will result in a BERR timeout,
and the SCSI Manager anticipates bus errors by inserting its own exception
handler in the vector table."* That is exactly our `MacLC.sv:593`
(`_cpuDTACK = selectSCSIDMA ? ~scsiDREQ`) + the `sdma_berr` watchdog, and it
explains the `$A08CFA/$A08D14` handler-install we saw in the disasm (the SCSI
Manager's own BERR handler). So **do not "fix" the stall by removing the gate or
the watchdog** — the gate is faithful; the problem is upstream data latency.

**Why MAME never stalls on reads (and our core does) — the divergence is purely
the data source + buffering depth:**

| | MAME / real HW | MacLC core |
|---|---|---|
| Read data source | `nscsi_harddisk::scsi_get_data` → `image->read(lba, block)` — **synchronous host-file read, 0 emulated latency** (`hd.cpp:74-82`); first sector pre-read on the READ command (`hd.cpp:130`) | HPS block device: `io_rd`→`io_ack` round-trip per 512 B, **real SD/HPS latency (100s µs … 209 ms)** |
| CPU-facing buffer | whole-sector device buffer + **4-byte CPU FIFO** kept topped up by halting the CPU (`macscsi.cpp:106-149`) | **2-block double buffer, 1-block-deep prefetch** (`scsi.v:428` `req_rd` fetches only the next block at offset 20) |
| Per-boundary CPU wait | ≤ **16 µs** FIFO timeout (`macscsi.cpp:77`); data always ready → never trips | CPU halts (DTACK held via `~scsiDREQ`/`io_busy`) for the **whole HPS fetch**, at every boundary it catches up to |
| Watchdog → BERR | 16 µs → release CPU; empty-FIFO read → `scBusTOErr` | 250 ms `sdma_berr` |

MAME crosses every sector boundary with a **synchronous, instantaneous**
host-file read, so its 4-byte FIFO always refills inside 16 µs and the CPU halt
is released immediately — no accumulation, no perceptible stall, no BERR. Our
core must do a real HPS round-trip per 512 B block and prefetches only **one**
block ahead, so under heavy reads the CPU stalls per boundary and the stalls
accumulate into the apparent hang (H1), with `req_drops=65535` counting them.

**Fix direction, now ground-truth-backed:** keep read data ready *ahead* of the
CPU's demand so the per-block HPS latency is hidden — i.e. **deepen the read
prefetch / widen the sector buffer** beyond one block (mirroring a real drive's
track cache and MAME's synchronous read). The 1-block-deep `req_rd` is the
specific structural limiter. The stall gate and watchdog stay as-is.

**Status:** H1's *mechanism* is now confirmed against ground truth, so the
active-stall snapshot (PSDS probe) becomes a fast *validation* of the live state
(expect `phase=DATA_OUT io_rd=1 io_ack=0 io_busy=1 dma_en=1`) and a check that no
H2/H3 contribution is hiding — cheap insurance before committing the deeper-
prefetch RTL. A dynamic MAME trace would only re-confirm the source analysis and
is not required.

---

## Implementation (2026-06-14) — deeper read prefetch + PSDS diagnostic

**The fix (`rtl/scsi.v`): a parameterized N-sector read prefetch ring** (replaces
the 1-block-deep "fetch next sector at byte 20" double buffer). `RING_LOG=3` → an
**8-sector ring**; `RING_LOG=1` reproduces the original two-sector double buffer
exactly (built-in regression baseline). Key pieces:
- `RING_LOG`/`RING_BLOCKS`/`BUF_AW` params; both `scsi_dpram` buffers widened to
  `BUF_AW` (256 words × RING_BLOCKS).
- `rd_hps_blk` = sectors fetched this command (HPS-side); `rd_cur_blk =
  data_cnt[31:9]` = sector the Mac is reading. Ring slot = each index mod N.
- **Prefetch is now a level** (`req_rd`): issue back-to-back sector fetches while
  `rd_hps_blk < tlen` AND `(rd_hps_blk − rd_cur_blk) < RING_BLOCKS` — the engine
  keeps the ring filled up to N sectors ahead, one fetch per `io_ack`, so the
  per-sector HPS latency is hidden after the initial fill.
- **Read stall** simplified to `cmd_read && (rd_cur_blk >= rd_hps_blk)` — the Mac
  waits only when the wanted sector isn't in the ring yet (gated on `cmd_read` so
  INQUIRY/READ_CAPACITY/MODE_SENSE/REQUEST_SENSE, which serve DATA_OUT
  combinationally, never take this stall).
- Ring slots never collide: the fetch slot equals the read slot only when the
  distance is 0 (Mac stalled, not reading) or N (excluded by the `< RING_BLOCKS`
  prefetch guard). `rd_hps_blk ≥ rd_cur_blk` is invariant, so the distance
  subtraction never underflows.
- **WRITES are untouched**: confined to ring slots 0/1 via direction-muxed
  addressing (`hps_addr`/`mac_addr`), with the original `sd_buff_sel` toggle,
  `req_wr`, write `io_busy` clause and `io_wr` engine byte-for-byte unchanged.
  `lba` (sequential per `io_ack`) is unchanged and already matches the ring.

Worked trace (4-sector read, N=8): sector 0 fetched while the Mac stalls; once in,
the Mac reads sector 0 while the engine prefetches 1,2,3 — the Mac then crosses
into sectors 1–3 with **zero boundary stalls** (vs. 3 stalls before).

**The diagnostic (same RBF):** `PSDS/PSD2/PSD3` active-stall snapshot —
`MacLC.sv` sticky-latches `{dbg_scsi2_w, dbg_ncr_w, dbg_wr_w}` the first time a
DACK access is DREQ-starved past `SDMA_SNAP_THRESH` (~16 ms; reuses
`sdma_stall_ctr`). `ncr5380.sv` PSCW mux extended to route a `DATA_OUT` (read)
target so `data_cnt`/`io_busy` are valid during a read stall. Decoded by
`scripts/cpu_state.tcl` (`PSDS` block).

**Validation so far:** `rtl/scsi.v` and `rtl/ncr5380.sv` pass `verilator
--lint-only` clean under the project's warning policy; single-driver-per-reg
maintained (Quartus-clean). Quartus build + on-rig "does Control Panels open?"
test pending. Tunable: drop `RING_LOG` to 2 if M10K/timing is tight, or raise to
4 (16 sectors) to hide more latency.
