# RESUME — STM boot failure root-caused to TG68K MOVES (abs-long EA) bug (2026-06-03)

Continues `docs/resume_stm_060226.md`. The STM-diagnostic boot failure is now **fully
root-caused**. Branch `new-video-on-fix-egret` (local, don't push). Build rules: `CLAUDE.md`.

## Root cause (PROVEN)
Boot ROM machine-ID routine (~sim frame F407) probes hardware with:
```
A03A82: move.b #$7,D1 ; A03A86: movec D1,SFC ; A03A8A: moves.w ($00022000).l,D1
```
This `moves` (SFC=7, CPU space) **must bus-error** — that's the probe's "device absent" result.
MAME bus-errors it 13/13 → routes through $A46240 → bclr #$1c,D2 (clears bit 28 of the config
word at ROM $A03BB4 = $DC000D07 → $CC000D07). Our core completes the moves inline → D2 stays
$DC000D1F → its low byte ($1F) overruns an 8-entry jump table at ROM $A00AB4 (valid index 7 →
$A00AC4) → garbage → error $0A → $A48CDA fatal → STM monitor (`*APPLE*` over SCC). At the
dispatch ($A00AB0) every reg matches MAME except D2. See memory [[stm-root-cause-moves-berr]].

## Two-part fix
### Part 1 — bus glue (DONE, in tree, no regression)
FC=7 is CPU space; `cpuAddr[19:16]` is the cycle-type ($F=IACK→autovector via VPA, else→BERR).
- `MacLC.sv` (FPGA) and `verilator/sim.v` (sim) BOTH patched:
  `wire fc7_iack=(cpuFC==3'b111)&&(cpuAddr[19:16]==4'hF);`
  `_cpuVPA = fc7_iack ? 0 : ~(...)`;  `cpu_berr=(cpuFC==3'b111)&&!fc7_iack&&!_cpuAS;`
- **`sim.v` also had `.berr(1'b0)` hardwired → changed to `.berr(cpu_berr)`.**
- IMPORTANT: Verilator builds `sim.v` (module emu), NOT MacLC.sv — they have duplicate CPU/bus
  logic and must be kept in sync. See memory [[verilator-top-is-sim-v]].

### Part 2 — TG68K MOVES abs-long EA (THE REMAINING BLOCKER, not yet fixed)
Verified by RTL probes: for the `moves.w $22000` the kernel **never presents FC=7 and never
accesses $22000** (reads garbage EA $55FE000B, completes inline). So Part-1's BERR never fires.

Mechanism (in `rtl/tg68k/TG68KdotC_Kernel.vhd`):
- MOVES decode (~1779-1797): `set_exec(opcMOVE); next_micro_state<=moves1; getbrief; set(ea_build)`.
- EA-build CASE (~1591-1651): for abs-long (opcode 111/001, line 1628-1630) does
  `set(longaktion); next_micro_state<=ld_nn` — this **overwrites** `next_micro_state<=moves1`.
- So `moves1`/`moves2` (which do `set_exec(moves_fc)` → `FC<=SFC`, see 4029-4119) never run for
  multi-word EAs. Register-mode MOVES ((An)/(d16,An)) don't set next_micro_state in the EA CASE,
  so those work; only **absolute-long (and other multi-word EA) MOVES are broken**.
- `moves_fc` is exec slot 89, within the 90-bit `exec` vector (`lastOpcBit=89`) — NOT an overflow.

#### Proper fix (do carefully — shared CPU core, affects FPGA)
Rework the MOVES microcode so the extension word is fetched and the EA fully built FIRST, THEN
moves1/moves2 run (presenting FC=SFC during the data cycle). Even an imperfect EA is fine — once
FC=7 is presented, Part-1 glue bus-errors it and the data is discarded on fault. Likely approach:
give MOVES its own pre-EA microstate (fetch brief), then enter the normal EA build with a flag
that routes the post-EA-build completion into moves1 instead of the plain opcMOVE execute.
Edit VHDL (source of truth) → regenerate `.v` via `rtl/tg68k/convert_to_verilog.sh` (ghdl) →
`cd verilator && make clean && make`. **Regression test = the boot itself** (exercises ~all
instructions; if a common op breaks it won't even reach F407). Verify all ROM `moves` still work:
$A03A8A (abs-long, must BERR) and the register-mode ones ($A03C4E, $A600AA, $A6231A, $A7768A,
$A7DBBA).

## Verify the whole fix is done
`cd verilator && make clean && make`
`./obj_dir/Vemu --no-cpu-trace --screenshot 750 --stop-at-frame 800 2>run.err 1>/dev/null`
- `grep -c '[ERR]' run.err` = 0 and `grep -c '[STM_ENTRY]'` = 0
- `grep -c ' 00A46240:' cpu_trace.log` > 0 (BERR dispatch now runs); D2=$CC000D07 at $A00AB0
- boot reaches $A148xx/$A149xx "?"-disk loop; screenshot grey desktop + blinking "?" (not orange)
- phantom-bank intact: `[TBLMEM]` single entry $800000/$200000@$9FFFEC

## THE FIX SOURCE — Minimig-AGA's TG68K (found 2026-06-03)
`../Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd` is a **fully-debugged** descendant of the
same TG68K kernel (10343 lines vs our 4216; adds FPU/PMMU_030/cache — NOT a drop-in, different
entity ports e.g. CACR_out is 31:0). It contains explicit fixes for **our exact bugs**:
- **BUG #322**: "Latched EA for MOVES complex addressing modes (d16,An)/(d8,An,Xn)/(xxx).W/L —
  by the time moves1 executes, it's overwritten." (= our garbage EA $55FE000B) → signals
  `moves_ea_latched`, `moves_ea_use_base`.
- **BUG #149**: MOVES bus-access tracking + FC-override window → `moves_bus_pending`,
  `moves_fc_override` (`moves_fc_override <= '1' when micro_state=moves1 or (moves_bus_pending=...)`).
- **BUG #318**: latched MOVES extension-word fields → `moves_direction`, `moves_reg`.
- **BUG #214**: MOVES mem→CPU writeback guard → `moves_writeback_pending`.
- Decode condition differs: Minimig `opcode(11 downto 8)="1110" AND opcode(7:6)/="11"` vs our
  looser `opcode(11 downto 9)="111"`.

### Confirmed-broken in OUR kernel (encoding-independent probes, reliable)
- `moves_fc_active` (exec bit 89) **NEVER asserts** → FC override never engages → MOVES data
  access uses FC_normal (5), not SFC (7) → bus glue can't fault it.
- `SFC` **never leaves its $5 default** → `movec D1,SFC` is also non-functional.
- Net: our whole 68010+ MOVES/MOVEC-control path is a half-finished port. `moves1`/`moves2`
  micro-states effectively never take effect.

### Regen toolchain VALIDATED
`rtl/tg68k/convert_to_verilog.sh` (ghdl 6.0.0) is deterministic — regenerating from the unchanged
VHDL reproduces the committed `.v` byte-for-byte. micro_state enum = declaration order
(idle=0 … moves1=91, moves2=92, ld_An1=93). So edit VHDL → run convert script → `make clean && make`.

### Port plan (the remaining work — sizable, do in a focused session)
Port Minimig's MOVES + MOVEC-SFC/DFC handling into our `TG68KdotC_Kernel.vhd`:
1. movec SFC/DFC write (compare Minimig's movec process vs ours ~line 4061; get `SFC<=reg_QA(2:0)`
   actually firing — verify `exec(movec_wr)` + brief="000" decode).
2. MOVES decode: adopt Minimig's `opcode(11:8)="1110"` form; latch ext-word fields (#318) and EA (#322).
3. Replace moves1/moves2 with Minimig's microstates + `moves_bus_pending`/`moves_fc_override`/
   `moves_active` and the FC mux (`FC <= FC_moves when moves_fc_override ...`). For the boot goal
   the EA can even stay approximate — once FC=7 reaches the data beat, Part-1 glue faults it.
4. Keep our Mac-specific edits (the (An) longword flag-commit defer at EA-build "010", the FC=7
   IACK/BERR glue). Regen `.v`, rebuild, verify (below). Watch for Minimig-only signal deps.
RISK: shared CPU core (also FPGA). The boot is a strong regression test (won't reach F407 if a
common instruction breaks), but validate other ROM `moves` ($A03C4E etc.) too.

## MAME ground truth (unchanged)
`/tmp/mame_maincpu.tr` (full trace), `/tmp/tapvia2.lua` (register taps at the machine-ID route).
`grep -c '^00A46240:' /tmp/mame_maincpu.tr` = 13 (all from the moves probe bus-erroring).
