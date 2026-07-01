# FINDINGS — SCSI pseudo-DMA latching bug: reproduced in sim, root-caused, fixed (2026-07-01)

## TL;DR
The LC-family word/longword SCSI pseudo-DMA read path in `rtl/ncr5380.sv` +
`rtl/scsi.v` had a **DREQ-vs-data-settle race**: DREQ re-asserted 3 clk32 cycles
before the target's presented byte pair was valid, and the longword second-word
pre-latch captured `din_pair_next` at bus-cycle *start* (which can precede
settling). A new focused harness (`verilator/scsi_bench/`) reproduces byte-,
word- and longword-stream corruption deterministically, and the real TG68 bus
timing lands **exactly on the corrupt/clean boundary** (parity-dependent) —
which is why the failures were flaky on hardware. Fixed in `rtl/ncr5380.sv`
(settle counter + pre-latch moved to end-of-cycle); the full sweep matrix
(4 modes × 6 sample-delays × 7 gaps × 2 HPS latencies, 336 cells) is now clean.

## The three proven failure mechanisms (all one root)
Target data pipeline: ACK falling edge → (+2 clk: `old_ack`/`stb_adv` pipeline)
→ `data_cnt` advances → (+1 clk: `scsi_dpram` registered q) → `din_pair` /
`din_pair_next` valid. Total: presented data is **stale for 3 clk32 after the
last ACK of a train retires**, but `dreq = scsi_req & dma_en & !dma_ack_busy`
re-asserted as soon as the holdoff counter expired — inside the stale window.

1. **Byte/word stale-window re-read.** Host samples rdata 0–2 clk32 after
   DREQ-rise → reads the *previous* byte/word; the whole stream shifts by
   −1/−2 bytes. Bench signature: `got: 00 00 01 02 03…` (duplicated head,
   everything late). Word mode fails at sample-delay ≤2, passes at ≥3.
2. **Longword second-word duplicate.** `dma_second_word_data <= din_pair_next`
   fired at the `i_dma_rd` RISING edge. The CPU asserts the cycle *before*
   DTACK gates it (DTACK=~DREQ only holds completion), so with a tight
   inter-cycle gap the rising edge lands while the previous ACK train is
   still advancing the target — the pre-latch captures the FIRST pair (or
   mid-update garbage) as the second word. Bench signature: every longword
   reads `b0 b1 b0 b1`. **No sampling delay fixes this** (edge-triggered
   capture); only moving the capture point does.
3. **rdata instability under DREQ.** Even in "passing" alignments, rdata
   changed mid-DREQ-window (bench `unstable` counter: ~50% of reads) — the
   design only worked because the host happened to sample late. Any DTACK
   consumer is entitled to stable data for the whole DREQ window.

## Why it was FLAKY on hardware (the real-timing mapping)
`rtl/tg68k/tg68k.v` bus FSM (phi1/phi2 = clk16 enables; the LC II CPU runs the
16 MHz grid unconditionally, `MacLC.sv:664`):
- DTACK (`= ~scsiDREQ`, combinational, `MacLC.sv:637`) is sampled at
  `s_state==4` **on the phi2 grid** (every 2 clk32);
- data is captured 2 phi edges later at `s_state==6`.

Effective sample delay after DREQ-rise = **2 or 3 clk32 depending on the
parity** of DREQ-rise vs the phi2 grid — straddling the word-mode fail(≤2) /
pass(≥3) boundary. The parity is fixed within a transfer chunk but re-rolled
by ARM-timed events (HPS sector fetch completion via `io_ack`, interrupts,
which SCSI Manager loop shape runs). Different OS versions/drivers have
different blind-loop shapes → "6.0.8 mostly works, 7.5.5 storms", and
cold-boot Sad Macs at ~1/3 (0F/0028 = the ROM's bus-error-protected probe
walking into SCSI-corrupted memory/driver state). MacPlus never hits this:
fx68k 68000 samples data ≥4 clk32 after DTACK and its byte-wide path has a
single ACK per beat.

## The fix (rtl/ncr5380.sv, both mechanisms)
1. **`dma_settle` counter** (3 bits): re-armed to 4 on every ACK pulse, counts
   down after the last pulse; `dma_ack_busy` (and therefore !DREQ) now covers
   the ACK train *plus* the target's data_cnt+dpram settle pipeline. DREQ now
   means "presented data is valid and stable" for any host sampling alignment
   (ds=0 is safe).
2. **Second-word pre-latch moved** from the i_dma_rd rising edge to the
   falling edge of the *first* longword cycle (inside the ACK-train arm).
   At that point the cycle has completed (⇒ DREQ was up ⇒ settled, by fix 1)
   and the train hasn't consumed anything yet, so `din_pair_next` is
   guaranteed to be the correct bytes 2–3.

Cost: each DMA beat's DREQ returns ~3–4 clk32 later (the CPU usually wasn't
that fast anyway; steady-state loops are unaffected because DREQ is already
high when the next cycle reaches its DTACK sample).

Also included in this tree: the SCSI ID remap (slot 0/1 → ID 0/1, was 6/5) for
7.x SCSI Manager boot priority (see memory `maclcii-scsi-id6-bad-for-mac-boot`).

## The harness (verilator/scsi_bench/)
Instantiates `ncr5380` + both `scsi` targets (whole read datapath), no CPU/no
dataController. The C++ driver plays both sides:
- **Mac SCSI Manager**: real register PIO (arbitrated-select → READ(6) via
  ODR/ICR ACK pulses with CSR polling — exercises the deferred-REQ logic) then
  blind DACK reads paced like the DTACK gate: assert cycle → wait for dreq →
  sample `ds` cycles later → deassert → idle `gap` cycles.
- **HPS**: serves `io_rd` with parameterizable latency, streams 256 words per
  sector with the SIM byte-packing (byte0 in `sd_buff_dout[15:8]`).
- Disk content = ramp (`byte(off) = off & 0xFF`); checker verifies the exact
  stream and classifies mismatches; per-read ring log captures
  `din_pair/din_pair_next/dma_second_word_data/suppress/pending/holdoff/
  data_cnt` for post-mortem.

Run (WSL): `cd verilator/scsi_bench && make && ./obj_dir/Vscsi_bench_top`
- Full sweep: modes byte/word/long/mix × ds {0,1,2,3,4,6} × gap {1,2,3,4,6,8,12}
  × HPS {600, 6000}. Exit code 0 = all clean.
- Single run: `--mode long --ds 0 --gap 1 --sectors 4 --detail` (per-read log),
  `--wave out.fst` for waves, `--id N` if the SCSI ID mapping changes.
- `mix` mode = seeded random width+pacing interleave (torture for the
  width-latch state machine).

### Pre-fix matrix (sectors=2, hps=600) — for the record
- byte: FAIL (stream −1) at ds0/gap≤3, ds1/gap≤2, ds2/gap1
- word: FAIL (stream −2) at ds≤2 && gap≤4  ← **real HW ds∈{2,3}, gap≈2-4**
- long: FAIL (second word duplicates first) at ds0/gap1 — and unfixable by ds
- everything: rdata unstable during DREQ on ~half the reads
Post-fix: **all 336 cells clean, unstable=0 everywhere.**

## HW validation log (2026-07-01 evening)
- Build `755dc194` (HEAD + latching fix + SCSI-ID-0 remap; STA all-positive
  slack, worst +0.142ns) deployed via launch_unstable_core.
- Cold #1 (carried-over PRAM): Welcome -> System loaded from disk -> wedged at
  Finder-start. Probes: CPU ALIVE in the ROM Memory-Manager free-block walk
  ($A0DE04: tst.b/add.l/adda.l loop — spins forever on a ZERO block header),
  heap accesses at $9CD2CE/$9AD8FC = HIGH RAM = the KNOWN fit-sensitive 10MB
  motherboard-high region (docs/resume_walk_root_data_path_2026-06-30.md,
  write-loss root, mb_hi relocation never landed). SCSI bus frozen mid-scan as
  a VICTIM (SEL+$40 parked while the CPU spins). NOT a SCSI-fix failure.
- Warm #1 (dirty disk): "Welcome" -> illegal-instruction bomb during extension
  load — PRE-EXISTING disk damage; the .hda had been pounded by corrupting
  builds for weeks. After `refresh_disks.sh` (pristine images) the bomb is gone.
- Cold #2 (pristine media): Welcome + full extension parade clean -> same
  Finder-start heap wedge (high-RAM issue, 10MB config).
- **A/B baseline `d98c3879` (pristine media): cannot find the boot disk at all
  ("?" floppy) and shows the left-edge white line** (it predates the Jun 25
  video fixes). The fixed build loads the System every time it finds the disk
  — strictly better at the pseudo-DMA read level.
- Cold #3 (fixed build): "?" floppy once — the flaky marginal-BSY selection
  read (the stashed SDC multicycle +41ns fix was NOT in this build; now
  applied to MacLCii.sdc for the next build).

## White-line regression (user report, same evening) — root-caused (TWO parts)
The committed fixes a961750/75f6353 are in HEAD but INCOMPLETE — the
HW-verified state must have carried further uncommitted pieces. Sim A/B
(shot_base/shot_fixed_0300.png: col0 solid BLACK against the uniform gray
field) plus FPGA pixel forensics (col0 480/480 WHITE on the ROM 1bpp screen,
masked on the 4bpp System desktop where the primed index 0x0F renders dark)
pinned two independent one-pixel misalignments in rtl/maclc_v8_video.sv:
1. **pixel_shift is a registered shift register** — even with the load at
   h_count==0, its OUTPUT lags one pixel; col0 showed the primed value and the
   line shifted +1. Fix: `pix_word` presents the freshly-loaded linebuf word
   COMBINATIONALLY on load cycles; the load stores pixel_shift pre-shifted so
   the register stream lines up from the word's 2nd pixel onward.
2. **de_raw was registered on the pix_en grid** (+1 pixel), then de_d1/de add
   the palette(+1)+output(+1) clk_sys stages — DE opened exactly one pixel
   late vs the RGB data path. The sim's DE-strict renderer showed col0 BLACK;
   the FPGA scaler sampled the late-DE'd first output = the primed color
   (WHITE in 1bpp). Fix: de_raw combinational from h_count/v_count; the
   pix_en-registered hsync/hblank/vblank outputs are already +2 clk_sys
   aligned (same as the RGB path) and stay as-is.
Fix #1 alone changed nothing visible in sim (col0 still black) — the DE gate
sat downstream; both are required.

## Next build contents (queued)
rtl/ncr5380.sv (latching fix + ID remap) · rtl/maclc_v8_video.sv (first-pixel
combinational fix) · MacLC.sv (OSD labels SCSI-0/1) · MacLCii.sdc (SCSI CSR
multicycle). Test plan: sim video A/B, FPGA build, boots at BOTH 4MB (avoids
the high-RAM heap issue entirely) and 10MB (documents the remaining separate
wedge).

## Validation status
- [x] Harness READ sweep clean (byte/word/long/mix × ds{0..6} × gap{1..12} ×
      hps{600,6000}, 2 and 4 sectors) — was 42+ failing cells pre-fix
- [x] Harness WRITE sweep clean (wbyte/wword × gap{1..12} × hps{600,6000}):
      blind DMA writes, per-512 flush captured by the HPS model, image == ramp.
      The settle counter also closes the write-side race documented at
      scsi.v odd_byte_r ("(1) RACE"): the next write cycle cannot END until
      DREQ returns, which is now after the target's din sampling window, so
      dout/dma_write_low_byte can no longer be re-latched mid-train.
- [x] Negative control: bench vs pre-fix RTL still fails (word 1022, long 512
      mismatches at ds0/gap1) — checker is live
- [x] Selection/command/status/message PIO still clean (incl. deferred-REQ)
- [ ] Full-system Verilator boot regression (running)
- [ ] FPGA build (running) → HW cold-boot loop: expect the ~1/3 Sad Mac
      0F/0028 to vanish; then 7.5.5 install/boot + write stress
- [ ] Port the same two fixes to lbmactwo (its DREQ engine was byte-identical)

## Remaining known gaps (NOT addressed by this fix — future work)
- **Abort hygiene (mechanism D)**: a BERR'd/timed-out DACK cycle still fires
  the ACK train on its falling edge (bytes consumed without delivery) and can
  leave `dma_longword_second_pending` stale → the next A1=1 read would replay
  stale data (mechanism C). Rare (needs the 250 ms sdma_berr or an aborted
  sequence) but real; consider clearing pending/suppress on `!dma_en` or bus
  reset, and suppressing the train for cycles that never saw DREQ.
- The SDC multicycle work (BSY-read +41 ns) and other stash items from the
  walk-chase era remain in `git stash` / `scratch/*.diff` — evaluate after HW
  results with the root fix.
