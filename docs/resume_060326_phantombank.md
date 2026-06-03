# RESUME — MacLC boot: MOVES-BERR + pseudovia-A0 FIXED; next blocker = march clobbers descriptor table (2026-06-03)

Branch `new-video-on-fix-egret` (local, **don't push**). Build rules: `CLAUDE.md`.
Memory: [[moves-berr-fix-landed]], [[candidate-b-phantom-bank-fix]],
[[verilator-top-is-sim-v]], [[mame-ground-truth-maclc]], [[feedback-sim-foreground]].

## What was fixed this session (committed)
Two independent root causes on the path from the STM serial-diagnostic crash to the
RAM-test screen:

### 1. MOVES CPU-space probe must BERR (D2=$CC000D07) — DONE
The boot ROM probes hardware with `moves.w $22000,D1` (SFC=7) that MUST bus-error.
The prior handoff's Minimig-port plan was based on a WRONG diagnosis (proved wrong by an
RTL probe): SFC already reaches 7, and moves1/moves2 already run for abs-long. The real
bugs were three small things:
- **`rtl/tg68k/TG68KdotC_Kernel.vhd` (moves1, ~L4035):** used `set_exec(moves_fc)`, but
  `set_exec→exec` only propagates when `setexecOPC=1`, which is NOT asserted during the
  MOVES data beat → FC override never engaged (FC stayed 5). Changed to **`set(moves_fc)`**
  (always copies to exec next cycle); in moves1 only (active during moves2 = the data
  beat); removed from moves2 so the override is exactly one cycle. (Regen `.v` via
  `rtl/tg68k/convert_to_verilog.sh`.)
- **Bus glue `verilator/sim.v` + `MacLC.sv`:** FC=7 non-IACK must suppress BOTH VPA and
  DTACK, else a garbage-EA access lands in a decoded region and completes. Added
  `wire fc7_berr=(cpuFC==7)&&!fc7_iack;` gating `_cpuVPA`/`_cpuDTACK`/`cpu_berr`.
- **Wrapper `rtl/tg68k/tg68k.v`:** `cpu_berr` is gated on `!_cpuAS`, but AS deasserts at
  s_state 6 while the kernel samples berr at s_state 7 → make_berr never latched. Added
  **`berr_hold`** latch holding berr across the bus cycle (cleared at s_state 0). This is
  why BERR had never worked in this core; fixes sim AND FPGA (shared module).

Verify: `D2PROBE` in sim_main prints `D2=CC000D07` at `$A00AB0` (matches MAME). Was the
garbage `$DC000D1F`.

### 2. pseudovia A0 (sim-only) — DONE
After #1 the boot reached a relocation trampoline (`$A4A87C`) that relocates its stack
pointer to `$0FFFFC` (subtracts D4=$800000) and expects `$0` to mirror motherboard RAM.
That mirror is gated on `ram_configured`, set by the V8 RAM-config write to **pseudovia
reg `$01`** at ODD byte addr `$50F26001`. `sim.v` forced `cpuAddr[0]=0`, so the odd-byte
write aliased to reg `$00` (port_b) → `ram_configured` never set → `$0` never mirrored →
rts read garbage (`$C0B86DB6`) → `$Cxxxxx` execution → STM. **FIX: `sim.v` pseudovia
`.addr` now `{cpuAddr[12:1], tg68_a[0]}` — MacLC.sv already had this, so it was sim-only.**

Result (clean build, `make clean && make`):
`./obj_dir/Vemu --no-cpu-trace --stop-at-frame 460 2>e 1>o`
- `[RAMCFGD] ram_configured 0->1 F45` (was never)
- `STM_ENTRY`=0 (was 12), `[ERR]`=0 (was 2)
- screenshot @750 = grey/black RAM-test hatch (like `master` @F350; was black).

## THE NEXT BLOCKER (open) — march clobbers the descriptor table via $0↔$800000 alias
With `$0` now correctly mirrored at F45 *during* the RAM march, the march fills
`$0-$1FFFFF`, which ALIASES `$800000-$9FFFFF` where the descriptor table lives
(`$9FFFE4-$9FFFFC` = `$1FFFE4-$1FFFFC`). The march writes the test pattern `$6DB6DB6D`
over `$1FFFEC`, clobbering `$9FFFEC`. The table read then returns `$B6DB6DB6` as a region
bound → garbage RAM-clear loop spins forever at `$A4685E-$A46880`
(`movem.l D0-D5,(A2)` fill up to a garbage `$B9xxxxxx` limit). Boot now hangs (no
STM/ERR) instead of booting.

Evidence (`run` to F800, cpu_trace + `[MARCH]`/`[TBL]`/`[TBLMEM]` probes in sim_main):
- `[MARCH] PASS#2 F232 A0=0 A1=$200000 A2=$1FFFFC` — marches the full 2MB `$0` region.
- `[TBL] $A4658A #2 F232 D0(len)=0 A0=$B6DB6DB6` — descriptor read came back as the
  march pattern (clobbered).
- `[TBLMEM]` gained a 2nd entry (`$9FFFE8` 0→$200000) vs the single entry before.

This is exactly the [[candidate-b-phantom-bank-fix]] self-clobber, RE-EXPOSED now that the
config write works. The candidate-b `ram_configured`-gating of `$0` was a workaround for
the (then-broken) config write; with #2 fixed, the REAL march/table-vs-mirror interaction
must be solved.

### Key open question — answer with MAME first
MAME does NOT hit this: its `$8FFFFC` stays valid (`$A0010A`) through the march. WHY?
Candidates:
1. **Ordering:** does MAME execute the config write (`$A467E0`) BEFORE or AFTER the march
   (`$A4685E`..`$A4694C done`)? Ours does it at F45, before the march passes. If MAME
   does it after, `$0` isn't mirrored during the march → no clobber. Check by tapping
   both PCs in MAME and comparing order (taps fire on branch-target fetches; sequential
   fetches don't — see below).
2. **Mirror semantics / size:** does MAME's `$0` map only part of the 2MB, or does the
   march stop below the table? Our `addrController_top.v` motherboard_low/high mapping
   (`{3'b000, cpuAddr[20:1]}` / `mb_mirror_offset`) — re-check vs `mame/src/mame/apple/
   v8.cpp ram_size()` (mb at `$0` for config&0xc0!=0xc0, plus the always `$800000` mirror).
3. Whether the descriptor table SHOULD be built after the march (so clobber is moot).

If MAME's order differs, the fix may be to keep candidate-b's `$0` gating but trip
`ram_configured` only AFTER the march completes — but prefer understanding the true
mechanism over another workaround. RISK: shared with FPGA (addrController/addrDecoder).

## MAME ground truth (how to)
```
cd /Users/dani/repos/mame && /opt/homebrew/bin/mame maclc -rompath /private/tmp/goodroms \
  -ramsize 2M -autoboot_script /tmp/SCRIPT.lua -seconds_to_run 12 -nothrottle -video none -sound none 2>/dev/null
```
Lua taps: `pgm:install_read_tap(addr&~3, +3, name, fn)`; in fn check
`(cpu.state["PC"].value & 0xFFFFFF)==addr`. **Taps only fire reliably on branch-target
PCs** (e.g. `$A4A87C`, `$A4A888`, `$A4A892`) — sequential post-prefetch PCs (`$A4A8A6`,
`$A4A8C2`) often DON'T. Use `print()` (stdout) not stderr. `pgm:read_u32(a)` to read mem.
Full ref trace: `/tmp/mame_maincpu.tr` (PC-only, no regs); addresses are 24-bit-masked
there (`$00F21C00`). v8 device map / RAM remap: `mame/src/mame/apple/v8.cpp` (LOG_RAM is
off by default — `VERBOSE(0)`).

## Build / run / gotchas
- VHDL is source of truth → `cd rtl/tg68k && ./convert_to_verilog.sh` → `cd ../../verilator
  && make clean && make` (incremental builds lie).
- **Verilator builds `verilator/sim.v` (module emu), NOT MacLC.sv** — duplicate CPU/bus
  logic, keep in sync. [[verilator-top-is-sim-v]].
- sim.v `$display` → **stdout**; sim_main `fprintf(stderr)` → **stderr**. (Wasted a lot of
  time grepping the wrong stream — pseudovia probes go to stdout.)
- Foreground sim only; run once, analyze logs. [[feedback-sim-foreground]].
- Useful sim_main probes still in tree: `[D2PROBE]` ($A00AB0 D2), `[RAMCFGD]`/`[RAMCFG]`,
  `[MARCH]`/`[TBL]`/`[TBLMEM]`, `[STM_ENTRY]`, `[ERR]`. sim.v: `[PVIA ACTIVE WRITE]`.

## Done-when (next session)
- march no longer clobbers `$9FFFEC`; `[TBL]` region bounds are real (not `$B6DB6DB6`);
  no infinite clear loop.
- boot proceeds past the RAM-clear to `$A00AB0` (D2=$CC000D07) and onward to the
  `$A148xx`/`$A149xx` "?"-floppy loop; screenshot = grey desktop + blinking "?".
- the 5 register-mode ROM `moves` still work; STM/ERR stay 0.
