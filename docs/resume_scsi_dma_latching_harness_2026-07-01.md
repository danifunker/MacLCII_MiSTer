# RESUME — SCSI word/longword DMA latching is the ROOT; build the Verilator harness (2026-07-01)

## ★ START HERE — the next task
Build a **focused Verilator SCSI-DMA harness** to reproduce and pin the exact
word/longword pseudo-DMA **latch** bug, then validate a fix in seconds (no 30-min
FPGA builds). This is the agreed next step. It works because — UNLIKE the PMMU walk
(fit-sensitive *analog* timing, un-reproducible in ideal sim) — the SCSI DMA is
**deterministic logic**, so Verilator WILL reproduce it.

### Harness spec
- Instantiate `rtl/ncr5380.sv` + `rtl/scsi.v` (the target) together (that's the whole
  SCSI read datapath). Model on the existing `verilator/pmmu_bench/` or
  `verilator/ksw_bench/` harness structure (Makefile + a small .cpp driver).
- Preload the target disk buffer (`sd_buff_dout` via the buffer BRAMs in scsi.v) with a
  known ramp: `00 01 02 03 04 05 …`. Note the SIM-vs-HPS byte-pack difference in
  `scsi.v:111-124` (sim packs byte0 in the HIGH half) — drive it in "sim" packing.
- Get the target into a data-in (target→initiator) transfer: force `phase` to
  `PHASE_DATA_OUT` with `cmd_read` active and `data_cnt` running, OR drive the full
  select→command→data sequence. Forcing `phase`+buffer directly is the fast path.
- Drive the CPU-side pseudo-DMA reads the way the Mac SCSI Manager blind-reads:
  assert `dack`(=selectSCSIDMA), set `dma_word`(=UDS&LDS) / `dma_longword`(=cpuLongword)
  / `dma_second_word`, pulse `i_dma_rd`(bus_cs&dack&ior), capture `rdata`.
- **Check:** the byte stream the initiator reads back must equal the ramp. Bugs show as
  **swapped / dropped / duplicated** bytes at word or longword boundaries.
- Signals to log each cycle: `rdata`, `dreq`, `dma_ack`, `dma_ack_holdoff`,
  `cur_data_pair`, `din_pair`, `din_pair_next`, `dma_second_word_data`,
  `dma_suppress_ack_latched`, `dma_word_latched`, `dma_longword_latched`, and the
  target's `data_cnt` / `buffer0_dout`/`buffer1_dout`.
- **Reference = MacPlus byte-wide path** (downloaded to `scratch/macplus_ncr5380.sv`,
  `scratch/macplus_scsi.v`): 302 / 448 lines, dead-simple, KNOWN STABLE. Any fix must
  keep byte transfers behaving like MacPlus while making word/longword correct.

## ★★ ROOT CAUSE (the real one, cross-core-confirmed by the user)
The Sad Macs / "7.5.5 storm" / disk corruption / spontaneous reboots are ONE shared
bug across the sibling cores (**MacLC has NO PMMU and hits it too**, plus lbmactwo):
the **LC-family word/longword SCSI pseudo-DMA latching**. It is NOT a PMMU bug.

Evidence chain:
- **MacPlus (68000, `fx68k`) is stable**; LC cores (`tg68k`, 68020/030) are not. Same
  disease in all LC-family cores → shared RTL.
- **The SCSI blocks tripled in the LC fork:** `ncr5380.sv` 302→**763** lines, `scsi.v`
  448→**1293**. MacPlus does **byte-wide** DMA (`rdata[7:0]`, `cur_data = out_en?dout:din`).
  The LC cores bolted on **word/longword pseudo-DMA** for the faster CPUs' blind word
  transfers, adding a fragile latch stack MacPlus never had:
  `cur_data_pair`, `din_pair`/`din_pair_next`, `dma_second_word_data`,
  `dma_suppress_ack_latched`, `dma_ack_holdoff`, `dma_word_latched`, dual-buffer
  even/odd pairing in scsi.v. **That is the "latching" surface.**

The latch stack is 3 layers (the bug lives in their interaction across a blind xfer):
1. `ncr5380.sv` DMA FSM (~163-223): multi-cycle `dma_ack_holdoff` (word=2, longword=6),
   second-word replay (`dma_second_word_data<=din_pair_next` on 1st cycle,
   `dma_suppress_ack_latched` on 2nd), `dreq = scsi_req & dma_en & !dma_ack_busy`.
2. `ncr5380.sv` read mux (226-252): `rdata=(dack&dma_word)?cur_data_pair:{rdata8,rdata8}`.
   `dma_word=!_cpuUDS&&!_cpuLDS`, `dma_longword=cpuLongword`, `dack=selectSCSIDMA`
   (all from `dataController_top.sv:365-367`).
3. `scsi.v` byte source (304-338): dual-buffer (`buffer0`=even bytes, `buffer1`=odd),
   even/odd unaligned select on `data_cnt[0]`, peek-ahead `dout/_next/_next2/_next3`.
   `cmd_dout_pair = data_cnt[0] ? {buffer1_dout,buffer0_dout_next} : {buffer0_dout,buffer1_dout}`.

Prime suspects for the mis-latch (verify in the harness): the **longword second-word
pre-latch** relying on `din_pair_next` being valid on the FIRST cycle; the peek-ahead
DEPTH vs `data_cnt` advancement per holdoff-ack; even/odd byte ordering. The memory
note [[maclcii-scsi-irq-gating-divergence]] already flagged a "DREQ stall" lead here.

## ★★★ WHAT WAS A RABBIT HOLE (do NOT re-chase) — the hard-won meta-learnings
- **The PMMU "walk read delivery" was the wrong layer.** ~11 HW builds this session
  (mb_hi=0, dout_held@STATE_READ, clear-dout_valid, a clk-domain synchronizer, a
  root[8] force-feed causation test) ALL changed nothing. The tell was ignored too long:
  four textbook-correct fixes contradicting the probe evidence = wrong model.
- **The PMMU-oriented probes have confirmation bias** — they were built to freeze on a
  "hiram_pf derail," so they always find one. Don't treat the frozen `$9FEE40` derail
  as the fatal path.
- **The Sad Mac `0000000F / 00000028` decoded:** `0F` = a *startup processor exception*
  (NOT inherently PMMU); `0028` ≈ vector-offset 0x28 = vector 10 = a Line-A trap = the
  CPU already jumped into garbage. Disasm of the fault: `$A416B6: jmp (a5)` with
  `a5=$40A0010E`; and `$A0DBxx` is the ROM's **bus-error-protected hardware-probe**
  idiom (install temp `$8` vector, deref, catch) — i.e. device probing. So the fault is
  downstream of the CPU/SCSI going wrong, consistent with the SCSI-latching root.
- **It's FLAKY, not deterministic.** Even the "known-good" `d98c3879` cold-boots to the
  same `0F/0028` ~1/3 of the time. My session's builds shifted the fit to 10/10, which
  looked like a new deterministic bug but wasn't. A flaky coin-flip failure = timing/
  latching, never a deterministic-logic PMMU walk bug.
- **Re-baseline was clean:** the FPGA ROM (`releases/boot0.rom`, md5 `9575cd95…`,
  checksum `$35C28F5F` = genuine LC II) is **byte-identical to MAME's `maclc2`** (4×
  128KB chips combined). So MAME comparisons were apples-to-apples; MAME was NOT running
  a patched ROM. (The Doug Brown 68030-`CAS` boot bug / MacPlus issue #15 / commit
  `8c72033a` = a TG68K kernel fix for `bra.l`/`bsr.l`/`movep`; **MacLCii already has all
  three** — ncr5380 movep line 1938, bra1 line 7003, bsr2 line 7015. Not the missing piece,
  but confirmed the kernel descends from MacPlus.)

## STATE OF THE TREE / HARDWARE
- **Working tree is DIRTY** with this session's + the prior session's uncommitted debug/
  fixes (mb_hi=0 in addrController_top.v, dout_held/clear-dout_valid/walk_cycle-gated
  readback + walk_din synchronizer + root[8] force-feed injection in sdram.v/tg68k.v,
  dbg_cell720 probe wiring in MacLC.sv/dbg_probes.sv, SCSI+sd_data multicycles + a
  dbg_cell720 false_path in MacLCii.sdc, `MISTER_DISABLE_YC/ADAPTIVE` in MacLCii.qsf,
  cpu_state.tcl decodes, plus the pre-session SCSI multicycle + Option B + ncr5380
  Welcome-wedge fix). **All backed up to `scratch/session_and_presession_changes.diff`.**
- These walk "fixes" are NOT the solution — the walk was a rabbit hole. Before serious
  SCSI work, strongly consider `git stash` (reverts tracked files to HEAD `f05f3bf`,
  keeping untracked docs) to get a clean baseline. The diff backup + this doc preserve
  everything.
- **Hardware currently on `d98c3879`** (`output_files/MacLCii_scsiid0.rbf`) — the last
  "cold-boots-fine" build (but still ~1/3 flaky). git HEAD = `f05f3bf` (video-performance).
- The SCSI-multicycle work IS legit (STA +41ns on the marginal BSY read) but was a
  band-aid on the same latching disease; keep it in the stash for later.

## TOOLING / ENVIRONMENT
- Windows + Git Bash (Bash tool) + PowerShell. Quartus 17.0.2 (`scripts/build.sh`, ~30 min).
- **WSL + MAME ARE available here** (`/usr/games/mame`; `verilator/mame/run_mame_maclc2.sh`,
  ROMs in `verilator/mame/roms/maclc2/`). Verilator is in WSL (memory
  [[maclcii-pmmu-sim-harnesses]]).
- `gh` CLI works for upstream compares: `gh api repos/MiSTer-devel/MacPlus_MiSTer/...`.
  MacPlus SCSI already downloaded: `scratch/macplus_ncr5380.sv`, `scratch/macplus_scsi.v`.
- MiSTer HW: `source scripts/local.env`; deploy `python tools/misterdeploy/
  launch_unstable_core.py --push <rbf> --core MacLCii.rbf`; screenshot `bash scripts/
  grab.sh <out.png>` (then Read the PNG); probes `bash scripts/read_probes.sh` (single,
  well-spaced reads only — JTAG loops crash the HPS). Disasm: capstone m68k in python3
  (`CS_ARCH_M68K, CS_MODE_M68K_040`), ROM at CPU `$A00000` in `releases/boot0.rom`.

## RELEVANT MEMORY
[[maclcii-scsi-irq-gating-divergence]] (DREQ engine == lbmactwo; "DREQ stall" lead) ·
[[maclcii-755-boots-warm-cold-races]] (the flaky cold-boot modes) ·
[[timing-bugs-use-hw-not-ideal-sim]] (walk = analog timing, un-simmable; but SCSI DMA =
logic, IS simmable) · [[maclcii-mister-hardware-access]] · [[prefers-autonomous-driving]] ·
[[maclcii-scsi-id6-bad-for-mac-boot]]. NOTE: all the `maclcii-*sadmac*` / `*walk*` /
`*pmmu*` memory notes describe the SUPERSEDED PMMU-walk framing — the real root is the
shared SCSI word/longword DMA latching.
