# HAND-OFF — Fix Mac LC boot→STM by porting TG68K MOVES from Minimig (fresh session)

**Read this first. It is self-contained.** Deeper detail: `docs/resume_stm_060326.md`,
memory notes `stm-root-cause-moves-berr`, `verilator-top-is-sim-v`, `feedback-sim-foreground`.
Repo: `/Users/dani/repos/MacLC_MiSTer`, branch `new-video-on-fix-egret` (local). **Do NOT push.**
Read `CLAUDE.md` for build rules.

## 1. Goal (one sentence)
Make the boot ROM's hardware probe `moves.w $22000,D1` (SFC=7, CPU space) **bus-error**, so the
boot reaches the desktop / "?"-floppy loop instead of the STM serial diagnostic.

## 2. Why it fails (root cause, already proven)
The probe MUST bus-error (CPU-space access nothing decodes). MAME does (13/13 → `$A46240`); ours
completes inline → the machine-config word `D2` stays `$DC000D1F` (vs MAME `$CC000D07`) → its low
byte `$1F` overruns an 8-entry ROM jump table at `$A00AB4` → garbage → STM. At the dispatch
`$A00AB0` every register matches MAME **except D2**.

The bus-error never fires because **our TG68K MOVES/MOVEC-control support is a half-finished port**:
- `moves_fc_active` (exec bit 89) **never asserts** → MOVES data access uses normal FC (5), not
  SFC (7), so the bus glue can't fault it.
- `SFC` **never leaves its `$5` default** → `movec D1,SFC` is also non-functional.
- The MOVES EA for absolute-long is computed wrong (`$55FE000B`) — Minimig BUG #322.
(These are encoding-independent probe facts, reliable.)

## 3. What is ALREADY DONE (in the working tree — keep it)
**Part 1 — bus glue (correct, no regression).** FC=7 is CPU space; `cpuAddr[19:16]` = cycle-type
(`$F`=IACK→VPA autovector, else→BERR). Applied to BOTH files (they have duplicate CPU/bus logic;
Verilator builds `sim.v`, NOT `MacLC.sv`):
- `MacLC.sv` ~line 863-904 and `verilator/sim.v` ~line 274-321:
  `wire fc7_iack=(cpuFC==3'b111)&&(cpuAddr[19:16]==4'hF);`
  `_cpuVPA = fc7_iack ? 0 : ~(...);`  `cpu_berr=(cpuFC==3'b111)&&!fc7_iack&&!_cpuAS;`
- `sim.v` `.berr(1'b0)` → `.berr(cpu_berr)` (was hardwired off!).
This half is finished; it will fault the probe the moment MOVES presents FC=7. `git diff` shows
only `MacLC.sv` + `verilator/sim.v`. Do not revert these.

## 4. The fix — port MOVES + movec-SFC from Minimig
Source: `../Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd` — a fully-debugged descendant of the
SAME kernel (10343 vs our 4216 lines). NOT a drop-in (adds FPU/PMMU_030/cache; different entity
ports, e.g. `CACR_out` is 31:0 vs our 3:0). **Port the MOVES/MOVEC logic only.**

VHDL is the SOURCE OF TRUTH (Quartus compiles it). After edits run
`rtl/tg68k/convert_to_verilog.sh` (ghdl 6.0.0; validated deterministic) to regenerate
`TG68KdotC_Kernel.v`, then `cd verilator && make clean && make`. micro_state enum = declaration
order (idle=0 … movec1=73 … moves1=91, moves2=92, ld_An1=93).

### Key line anchors
| Piece | Minimig (.vhd) | Ours (.vhd) |
|---|---|---|
| MOVES signal decls | 461-484 (`moves_active/_bus_pending/_fc_override/_direction/_reg/_ea_latched/_ea_use_base/_d16_phase/_writeback_pending`) | only `moves_fc_active` @360 |
| MOVES decode | 5345 `ELSIF opcode(11 downto 8)="1110" AND opcode(7:6)/="11"` | 1779 `ELSIF opcode(11 downto 9)="111"` |
| MOVES microstates | `moves0` @8320 (addr setup, BUG#149), `moves1` @8392 | `moves1` @4029, `moves2` @4047 (no moves0) |
| movec SFC/DFC write | 9784 (`elsif clkena_lw='1' and exec(movec_wr)='1'` → `SFC<=reg_QA(2:0)`) | 4077 (`if exec(movec_wr)='1'` → `SFC<=reg_QA(2:0)`) |
| movec_wr decode | 6250 `set_exec(movec_wr)<='1'` | 2637 |
| FC mux | PROCESS @1438-1451 using `moves_fc_override`+`moves_direction` (`FC<=SFC/DFC`); override @1426 | concurrent assign @4119 using `moves_fc_active` (`FC<=FC_moves`); FC_moves@4116 |

### Recommended order (test after each step where possible)
1. **First fix `movec→SFC`** (smaller, isolated). Diagnose why ours doesn't set SFC: add a temp
   probe (see §6) for `SFC` and `exec(movec_wr)`; compare reg_QA / brief decode to Minimig 9784.
   Likely `set_exec(movec_wr)` not firing or wrong reg. SUCCESS = `SFC` becomes `7` (`111`) after
   the probe's `movec D1,SFC`.
2. **Port the MOVES FC-override path** (BUG #149 + #318): add `moves_active`/`moves_bus_pending`/
   `moves_fc_override`/`moves_direction` signals; replace the `moves_fc_active`/FC-mux with
   Minimig's `moves_fc_override`-based FC PROCESS. SUCCESS = FC=7 appears on the MOVES data beat.
3. **Port the MOVES microstates** (`moves0`+`moves1`) and EA latching (BUG #322,
   `moves_ea_latched`/`moves_ea_use_base`) so the data access actually happens. For the boot goal
   the EA may stay approximate — once FC=7 reaches the data beat, Part-1 glue faults it.
4. Adopt Minimig's tighter decode `opcode(11:8)="1110" AND opcode(7:6)/="11"`.
5. **Preserve our Mac-specific edits**: the `(An)` longword flag-commit defer in the EA-build CASE
   (~`WHEN "010"|"011"|"100"`, line ~1593-1606, `ld_An1`), and the FC=7 IACK/BERR glue. Do not let
   the port clobber them.

Watch for Minimig-only signal deps (`fc_internal`, `rte_fmt_a_ssw`, PMMU/cache signals) — adapt or
stub to our kernel's existing names (ours uses `FC_normal`, not `fc_internal`).

## 5. Build / run / verify
```
cd rtl/tg68k && ./convert_to_verilog.sh          # after ANY .vhd edit (ghdl regen)
cd ../../verilator && make clean && make          # incremental build gives FALSE POSITIVES
./obj_dir/Vemu --no-cpu-trace --screenshot 750 --stop-at-frame 800 2>run.err 1>/dev/null
```
Run the sim in the **FOREGROUND only** (never backgrounded — stray sessions pile up). Run once,
analyze logs.

**DONE when ALL of:**
- `grep -c '\[ERR\]' run.err` = 0 and `grep -c '\[STM_ENTRY\]' run.err` = 0
- `grep -c ' 00A46240:' cpu_trace.log` > 0 (the BERR result-dispatch now runs)
- D2 = `$CC000D07` at PC `$A00AB0` (was `$DC000D1F`)
- boot reaches `$A148xx`/`$A149xx` "?"-floppy loop; `screenshot_frame_0750.png` = grey desktop +
  blinking "?" (not orange, not black)
- phantom-bank intact: `[TBLMEM]` single entry `$800000`/`$200000`@`$9FFFEC`
- the 5 register-mode ROM `moves` still work ($A03C4E, $A600AA, $A6231A, $A7768A, $A7DBBA) — boot
  won't reach F407 if a common instruction broke, so reaching the desktop is strong validation.

## 6. Re-diagnosis probes (encoding-independent, reliable)
Temp probe inside the kernel `.v` (regen wipes it; back up first `cp TG68KdotC_Kernel.v /tmp/k.bak`):
add before the final `endmodule` of module `TG68KdotC_Kernel`:
```verilog
`ifdef SIMULATION
  reg [2:0] sfc_d=3'b101;
  always @(posedge clk) if (clkena_in) begin
    if (sfc!=sfc_d) begin $display("SFC->%b",sfc); sfc_d<=sfc; end
    if (moves_fc_active) $display("mfa=1 sfc=%b FC=%b busstate=%b addr=%h",sfc,FC,busstate,addr_out);
  end
`endif
```
Signal names in the .v: `sfc`, `moves_fc_active`, `FC` (output), `busstate`, `addr_out`,
`micro_state` (`wire [6:0]`, == 7'd91 is moves1). FC=7 should appear on the MOVES data beat once
fixed. Bus glue probe lives in `sim.v` (`fc7_iack`/`cpu_berr`).

## 7. MAME ground truth (already captured)
- Full trace: `/tmp/mame_maincpu.tr`. `grep -c '^00A46240:'` = 13 (probe bus-erroring).
- Register taps at the machine-ID route: `/tmp/tapvia2.lua`. Re-run:
  `cd /Users/dani/repos/mame && /opt/homebrew/bin/mame maclc -rompath /private/tmp/goodroms -ramsize 2M -autoboot_script /tmp/tapvia2.lua -seconds_to_run 12 -nothrottle -video none -sound none 2>/dev/null`
- Confirmed MAME D2 at `$A00AB0` = `$CC000D07` (low byte 7 = valid jump-table index).

## 8. Gotchas (don't get bitten)
- **Verilator builds `verilator/sim.v` (module `emu`), NOT `MacLC.sv`.** Duplicate CPU/bus logic —
  any CPU-glue change goes in BOTH. (This wasted a build cycle last session.)
- **`make clean && make`** after RTL changes; incremental builds lie.
- **Foreground sim only**; screenshots/stop-at-frame fine.
- VHDL is source of truth; never hand-edit the generated `.v` except for throwaway probes.
- Don't break the phantom-bank fix (`72c5f99`) or the Part-1 bus glue.
- This core is full of subtle timing races (VIA SR, last-data-read flag-commit) — "boots to X"
  isn't full proof; sanity-check the register-mode moves and watch for new `[ERR]` elsewhere.
