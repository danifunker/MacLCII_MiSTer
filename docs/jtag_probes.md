# MacLC JTAG In-System probes (2026-06-11)

Live, build-free visibility into the running FPGA over the DE10-Nano's
on-board USB-Blaster II — the LBMacTwo methodology (`dbg_min.sv`) that
root-caused every SCSI wedge there, ported and right-sized for MacLC.
One build carries the whole deck; every later question is a JTAG read,
not a rebuild.

**RTL:** `rtl/dbg_probes.sv` (instantiated ONLY in `MacLC.sv` — never in
`verilator/sim.v`; `altsource_probe` is an Altera primitive). Probe feeds
come from `ncr5380.sv` (`dbg_ncr`/`dbg_ncr2`/`dbg_wr`, layouts identical
to LBMacTwo's) through `dataController_top.sv`.

## Reading

```bash
bash scripts/read_probes.sh                 # full decoded dump
# wedge-loop decoding (the remote disassembler):
bash -c 'PATH=/c/intelFPGA_lite/17.0/quartus/bin64:$PATH \
    quartus_stp_tcl -t scripts/sample_loop.tcl 120' > samples.txt
python scripts/loop_disasm.py samples.txt   # (capstone optional but nice)
```

Don't read probes while a Quartus compile is using the cable.

## The deck (15 instances)

| Probe | What it answers |
|---|---|
| PACT | Is the CPU alive? (bus-cycle counter; sampled twice by the reader) |
| PADR / PSTA | Where is the CPU / full bus+decoder+IRQ+DREQ state |
| PIFA | Last instruction-fetch address + wrap8 IF count (loop PC histogram) |
| PIFD | Live atomic {PC16, opcode} pair → `loop_disasm.py` reconstructs RAM loops |
| PDRD | Live atomic {I/O read addr, value} → "what is the wait loop polling" |
| PSCS | Last SCSI register the driver read + the value it got |
| PSC3 | Target phases (live + max reached), io/sd ack stickies, reset nibble |
| PSCW | Write-stall snapshot (data_cnt/phase/io_busy/tlen of DATA_IN target) |
| PSNC | Pseudo-DMA engine: dreq/dma_en/holdoff/word/long/tcr + DACK beat count |
| PSWL | **req_deferred / req_bus** + irq_latch/dma_armed/eodma + blind/req-drop counters |
| PSC6 | Bus-reset count + per-target completion flags + last opcodes |
| PASC | ASC refill IRQs vs CPU writes (FIFO underrun = distortion) |
| PAUD | Sticky audio sample min/max (full-scale = clipping, ~0 = dead) |
| PVID | VBL count / CLUT writes / CPU VRAM writes / programmed video config |

Bit layouts live in `rtl/dbg_probes.sv` and the `ncr5380.sv` port
comments; `scripts/cpu_state.tcl` decodes everything.

## Wedge playbook (System 7 Welcome hang)

1. `read_probes.sh` — PACT advancing? PIFA fetching? If frozen, PADR+PSTA
   show the stuck bus cycle (e.g. a DACK access stalled on DTACK shows
   selectSCSIDMA=1, DTACK_n=1, scsiDREQ=0).
2. PSCS/PDRD: which register is the loop polling, and what value does it
   see? (The round-6 LBMacTwo wedge: CSR reads never returning REQ=0 —
   PSWL `req_deferred`/`req_bus` now shows the deferral machine live.)
3. PSCW/PSNC: where in the transfer the target parked (the classic
   signature: `data_cnt=512`, `dreq=1`, DACK beats frozen).
4. `sample_loop.tcl` + `loop_disasm.py`: reconstruct the actual polled
   loop instructions when the PC is in RAM. PSC6 names the SCSI command
   that wedged; bus-reset count climbing = driver retry storm.

LBMacTwo probe-budget note: their JTAG hub ceiling was ~20 instances on a
much fuller device. If a MacLC fit ever fails, trim PASC/PAUD/PVID first
(sound/video probes), never the SCSI/loop core.
