# RESUME — MacLCii 10MB boot Sad Mac: PMMU walk read gets stale SDRAM data (2026-06-25)

## TL;DR / WHERE WE ARE RIGHT NOW
- **Bug:** MacLCii **10MB** config boot shows Sad Mac **`0000000F / 00007FFF`** (CONFIRMED via screenshot —
  same code all session; it is NOT a separate code). Root cause is in the **PMMU page-table walk read**,
  not the PMMU logic.
- **DEPLOYED + CONFIRMED (handoff state):** Build #15 was rebuilt (md5 `854af5df` — bit-identical to the
  original #15, confirms the revert was clean), **deployed, and the Sad Mac `0000000F/00007FFF` is
  confirmed on screen** (`scratch/b15_redo_sadmac.png`). The device is sitting on the Sad Mac NOW. The RBF
  is **saved as `output_files/MacLCii_b15_sadmac.rbf`** → re-deploy in seconds (NO 30-min rebuild) with:
  `source scripts/local.env; python tools/misterdeploy/launch_unstable_core.py --push
  ./output_files/MacLCii_b15_sadmac.rbf --core MacLCii.rbf`. Working tree == build #15.
- **IMMEDIATE NEXT STEP (user's explicit instruction):** when #15 deploys, **screenshot** to confirm the
  Sad Mac, then do a **WARM RESTART of the core** (re-run the 68K boot WITHOUT reloading the FPGA/ROM —
  keeps SDRAM state), **screenshot again**, and see **if the Sad Mac persists or clears**. This isolates:
  - clears on warm restart ⇒ **intermittent** → timing / **cold-boot SDRAM flakiness** = a "separate issue"
    (the user's hypothesis; `rtl/sdram.v` init has documented cold-load flakiness — see lines ~85-100).
  - persists ⇒ **deterministic** logic/timing bug.
- **USER DIRECTIVES (critical):** (1) "**Stop looking for shortcuts — actually fix the issue, isolate
  it.**" No more band-aids (the re-read retry + the sdram.v pending-latch were both shortcuts). (2)
  **SCREENSHOT every deploy** — do NOT infer screen state from JTAG (I made that mistake; the user caught
  it). (3) Go back to the last Sad Mac build (#15) and run the warm-restart test.
- **OPEN QUESTION TO USER (asked, not yet answered):** *how do you normally warm-restart the core* (a
  keyboard hotkey, the OSD, a physical button)? Needed to drive the warm restart reliably. Fallback: OSD
  **"Reset & Apply CPU+Memory"** (the core's `R0`/`status[0]` reset — keeps ROM/SDRAM = true warm restart).

## SCREENSHOT — DO THIS, don't infer from JTAG
`bash scripts/grab.sh <out.png>` (copied into this repo this session). It POSTs `/api/screenshots`,
waits 2s, downloads the newest. Then **Read the PNG** (the Read tool renders images). Confirmed working.
- Existing captures in `scratch/`: `hung_debug_screen.png` = build #15 Sad Mac `0000000F/00007FFF`;
  `b16_t35/t75/t135.png` + `b16_after_resetcmd.png` = build #16 uniform GRAY (a stall, video never init'd).

## ROOT CAUSE (precise, HW-confirmed)
`rtl/sdram.v` samples the access request (`oe`/`we`) **only at `t == STATE_CMD_START`** (its one clk_8-edge
command slot, ≈ busPhase 0; see line ~160-161). If an access's `oe`/`we` is NOT high at that instant the
controller issues **AUTO_REFRESH instead** and leaves `dout` holding the **stale previous value** — yet the
top-level **DTACK fires anyway** (it's generated from bus phase in `MacLC.sv` ~498-520, NOT tied to actual
SDRAM completion). Normal CPU accesses are phase-aligned and always hit the slot; the **PMMU walker's
BORROWED bus cycle** (`tg68k.v`, `walk_cycle`) asserts `oe` in a short, phase-misaligned window that
misses it → the descriptor read at `$9FEE40` returns stale garbage → bad translation → Sad Mac.
- Build #11 HW proof: walker's own `wda/wdd` = addr `$009FEE40`, data `$00000000`; `din_OR` during the
  walk read = `$0000` then `$4ED2` (stale bus values, never the written `$000B`).
- The table-build WRITE of `$000B` to `$9FEE40` is fine (`we_fired=1`, `cw_cnt=1`). 68030 cache is OFF
  (`USE_68030_CACHE=1'b0` in tg68k.v:71) — not a cache issue.

## DIAGNOSTIC TABLE (empirical, from HW builds) — the key to the fix
| build | walk read data @CAS | walk read ADDR @CAS | result |
|---|---|---|---|
| original (#8-#11) | n/a (dropped→refresh) | n/a | Sad Mac (walk reads stale) |
| #12 = re-read only, no latch | live | live | **BOOTS (slow)** — re-read retries walk until it aligns |
| #13/#14 = latch, **latched** din + **latched** addr | latched | latched | walk OK (`frozen=0`) but **normal WRITES corrupt** → gray stall |
| #15 = latch, **live** din + **live** addr | live | live | **walk BROKE → Sad Mac** (writes OK) |
| #16 = hybrid, **live** din + **latched** addr | live | latched | walk OK (`frozen=0`) **but STILL gray-stalls** |
**Two truths:** SDRAM **write data** is valid only at CAS (must be **live**); the borrowed walk read's
**address is NOT stable** slot→CAS (needs **latched**). BUT even the hybrid (#16) gray-stalled — the
**pending-latch machinery itself (`req`/`svc_pending`/`cur_*`/the pending service path) breaks NORMAL SDRAM
access** (the late pending service clobbers `dout` for subsequent normal reads + perturbs refresh). The
latch is present in #13/#14/#16 (all broken) and ABSENT in #12 (boots-slow). **⇒ the sdram.v pending-latch
is the WRONG mechanism. Abandon it.**

## THE PROPER FIX (no shortcuts) — candidates to pursue AFTER the warm-restart test
The walk read's borrowed bus cycle is phase-misaligned with the SDRAM command slot. Fix the ROOT, two
clean options (NOT the pending-latch, NOT the re-read retry):
1. **Align the walk cycle to the bus slot** (in `tg68k.v`): make the borrowed walk read assert AS/`oe` at
   the same busPhase as a normal CPU cycle (which works), so `sdram.v` services it at `STATE_CMD_START`
   like any aligned access. The walk FSM starts on phi1 (`tg68k.v` ~735) — needs busPhase-0 alignment;
   may need `clk8`/busPhase routed into tg68k.v.
2. **Gate DTACK on real SDRAM completion**: add a "read serviced/data-valid" output from `sdram.v` and
   make the RAM-read DTACK in `MacLC.sv` wait for it, so the walk read can never capture stale data
   (spans `sdram.v` + the `dtack_en` logic in MacLC.sv ~498-520).
- **VALIDATION:** the Verilator sim uses `sim_ram.v` (ideal RAM), so it **cannot** reproduce this SDRAM
  timing — HW only, UNLESS you build a focused testbench (`sdram.v` + a small behavioral SDRAM chip model
  driven at clk_64≈65MHz / clk_8). The user pushed back on the testbench as a "shortcut," so confirm
  before investing. (WSL has Verilator 5.020 + GHDL 4.1.0; see "Tooling".)
- **ALTERNATE ROOT (if warm-restart CLEARS it):** the bug is **cold-boot SDRAM init flakiness**, not the
  walk — pursue `rtl/sdram.v`'s init ladder (the JEDEC `reset` ladder ~85-152; the comment notes prior
  "per-load luck" cold-load flakiness). A warm restart skips re-init, so clearing-on-warm points here.

## RELEVANT RTL (current working-tree state == build #15)
- `rtl/sdram.v`: has (a) **relocation** `mb_hi`→A12: `sd_addr <= {addr[23], addr[19:8]}; sd_ba <=
  addr[21:20]` (added build #9; moves the motherboard bank to upper 16MB but it stayed in SDRAM bank0 so
  it did NOT fix anything — consider reverting); (b) the **pending-latch** (regs `req, oe_we_d, req_we,
  req_addr, req_din, req_ds, cur_addr, cur_din, cur_ds, svc_pending`; rising-edge `req` capture; current/
  pending/refresh paths at `STATE_CMD_START`; CAS uses `svc_pending ? cur_* : live`). **This latch is the
  wrong mechanism — plan to remove it entirely** (restore the original simple `{oe_latch,we_latch}<={oe,we};
  if(oe||we) ACTIVE else REFRESH;` + original live-param CAS).
- `rtl/tg68k/tg68k.v`: the **re-read-until-stable** walk FSM (regs `walk_desc, walk_prev, walk_tries`,
  `WALK_MAX_TRIES=6`; re-issues the descriptor read until two consecutive 32-bit reads agree, capped).
  This is build #12's band-aid (boots-slow). Also added outputs `dbg_walk_cycle_o` + `dbg_pmmu_*_o`
  (un-`ifdef`'d for FPGA). Keep for now; it's why #12 boots-slow.
- `rtl/addrController_top.v`: `mb_hi` output + assign (relocation: `mb_hi = !dskReadAck* && selectRAM &&
  motherboard_high`).
- `MacLC.sv`: `sdram_addr = {1'b0, mb_hi, memoryAddr[22:0]}` (relocation); `cpu_walk_cycle` wire; dbg
  probe threading (`cpu_pmmu_*`, `cpu_dout`=tg68_dout, `cpu_memaddr`=memoryAddr, `cpu_ramwe_n`=_ramWE,
  `mb_hi_i`=mb_hi, `walk_cycle`=cpu_walk_cycle, `ramOE_n`=_ramOE, `selectUnmapped`, `cpuBusControl`).
- `rtl/dbg_probes.sv`: BUILD#10/#11 walk-read capture. Probe map: `PFR*`=derail/`frozen` flag + derail
  addrs; `PSCS`=newest write {a16,data}; `PSC2`=write cpuAddr; `PSC6`=write count; `PSC3`=walker `wda`;
  `PSWL`=walker `wdd`; `PSNC`=walk-read DECODE {seen,selRAM,selROM,selVRAM,selUnmap,busCtl,ramOE,mb_hi,
  memoryAddr}; `PDRD`=din-during-walk {saw_000B,din_OR}; `PVID`=video {vbl_cnt,clut_wr,vram_wr,
  video_config}; `PRC0`=boot_inits/scsi_resets.
- `scripts/cpu_state.tcl`: decodes the above (the "BUILD#10 walker read" block). Tcl gotcha: `root[8]`→`root#8`.
- Sim-only (regenerated/edited): `rtl/tg68k/TG68KdotC_Kernel.v` + `TG68K_Cache_030.v` (regenerated from
  `.vhd` via GHDL — the `.v` had been stale, missing `debug_berr_opcode`/`exe_opcode`/`berr_frame_pc`);
  `verilator/sim.v`, `verilator/Makefile` (mb_hi etc.). `verilator/sim_main.cpp` STILL has drift (pokes a
  removed VIA `cb2_i` at line ~735) → sim won't build until stubbed. Sim is low value here anyway
  (`sim_ram.v` can't model `sdram.v`).

## BUILD HISTORY THIS SESSION (HW, ~30 min each)
#8 write-strobe pin (we_fired=1) · #9 relocation+walk-decode · #10/#11 walk-read decode (walk reads
$0000; din_OR=4ED2 stale) · #12 re-read → **boots slow (user played a game)** · #13/#14 pending-latch
(latched din) → gray stall · #15 live din+addr → **Sad Mac** (last Sad Mac build) · #16 hybrid (live din,
latched addr) → walk fixed `frozen=0` but **gray stall**. Current rebuild = #15.

## TOOLING / ENVIRONMENT (Windows + Git Bash; Quartus on Windows; sim in WSL)
- `source scripts/local.env` first. `MISTER_HOST=192.168.99.143`, key `~/.ssh/mister_only`, web port
  `8182`, `QUARTUS_BIN=/c/intelFPGA_lite/17.0/quartus/bin64`. **10MB config**: `/media/fat/config/
  MacLCii.CFG` byte0=`$08`.
- **Build:** `rm -rf db incremental_db && bash scripts/build.sh` (~27-30 min). Quartus 17.0.2. Watch the
  newest `output_files/auto_compile_*.log` for `Compile exit=0`. (One fitter crash seen — `Access
  Violation` at placement; just retry, it's transient.)
- **Deploy:** `python tools/misterdeploy/launch_unstable_core.py --push ./output_files/MacLCii.rbf --core
  MacLCii.rbf` (verifies md5, reboots, OSD-selects, launches). **Save good RBFs** (builds overwrite
  `output_files/MacLCii.rbf`): `cp output_files/MacLCii.rbf output_files/MacLCii_bNN.rbf`.
- **JTAG probes:** `bash scripts/read_probes.sh` (USB-Blaster; decodes cpu_state.tcl). `frozen=1` ⇒ a
  high-RAM derail was captured.
- **Warm restart:** `echo reset > /dev/MiSTer_cmd` does NOT work (Main ignores it). Use the core reset:
  OSD "Reset & Apply CPU+Memory" (`status[0]`). Remote keystrokes go over MiSTer Remote websocket
  `/api/ws`; menu via `/api/menu/view`; full reboot via `/api/settings/system/reboot`. Easiest: have the
  USER press their reset.
- **MiSTer HPS dies after ~8 reboots/session** (the many deploys) → needs a physical power-cycle; the web
  service (8182) can be revived with `ssh … /media/fat/Scripts/remote.sh -service restart`.
- **WSL:** `wsl.exe -- bash -lc '…'`. Verilator 5.020, GHDL 4.1.0. Kernel `.v` regen: run the GHDL cmds
  DIRECTLY (the `convert_to_verilog.sh` has CRLF → bash chokes); set `LD_LIBRARY_PATH=$HOME/ghdllib` with
  shim `ln -sf /lib/x86_64-linux-gnu/libLLVM.so.18.1 ~/ghdllib/libLLVM-18.so.18.1`; analyze Pack→ALU→
  PMMU_030→Cache_030→Kernel then `ghdl synth -fsynopsys -fexplicit --latches --out=verilog`.

## MEMORY NOTES (recall these)
`maclcii-sadmac-0f-is-pmmu-mistranslation` (full evidence chain), `maclcii-mister-hardware-access`
(SSH/JTAG/screenshot/build), `maclcii-pmmu-sim-harnesses`, `prefers-autonomous-driving`. NOTE: the
"motherboard bank doesn't persist writes / relocate it" conclusion in those notes is **superseded** — the
real cause is the walk read's phase-misaligned SDRAM access (above). Relocation didn't fix it.

## NEXT STEPS (in order)
1. Confirm #15 rebuild finished (`grep "Compile exit=0" output_files/auto_compile_*.log`); deploy it.
2. **Screenshot** → confirm Sad Mac `0000000F/00007FFF`.
3. **Warm-restart** the core (ask user how, or OSD "Reset & Apply CPU+Memory"); **screenshot** → persist or clear?
4. Branch: clears ⇒ chase cold-boot SDRAM init (`sdram.v` reset ladder). persists ⇒ proper walk-cycle fix
   (align the borrowed walk cycle, or DTACK-on-completion) — NOT the pending-latch.
5. After a real fix: rebuild, deploy, **screenshot** to verify boot past `$A416B2` to the desktop.
