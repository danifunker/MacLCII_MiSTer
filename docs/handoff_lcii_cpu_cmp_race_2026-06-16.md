# Handoff: LC II boot — CPU cmp.b flag-vs-operand race ROOT-CAUSED, fix pending

**Date:** 2026-06-16
**Branch:** `030_LCii` (MacLC_MiSTer)
**Status:** The LC II boot's "slow POST + downstream crash" is **one CPU bug**, now
**definitively root-caused with hard ALU-operand evidence**. The fix (a delicate
one-cycle timing change in the TG68K.C 030 kernel) is NOT yet applied. This handoff has
everything to apply + verify it.

---

## TL;DR — the bug (nailed)

`cmp.b (A2,D2.l),D1` @ **`$A0313A`** latches its flags **one cycle before** the ALU
inputs `OP1out`/`OP2out` settle to the cmp's real operands:

```
flags COMPUTE:  OP1=$50F01C00  OP2=$00000000  → $00−$00 = 0 → Z=1   ← WRONG (stale)
1 cycle later:  OP1=$000080FE  OP2=$00000400  → $FE−$00 ≠ 0 → Z=0   ← correct operands
```

`OP1=$50F01C00` is the **previous instruction's leftover EA address** (`$F01C00`, low
byte `$00`); paired with `$00` it gives a false "equal" (Z=1). One cycle later the real
operands settle (`OP1 = D1 = $80FE`, `OP2 = ea_data = $400`) which *would* give Z=0.
- `D1` is correct (`$80FE`, low byte `$FE`) — verified via **rf14** (the Verilator
  regfile is **REVERSED**: `D0=rf15 … D7=rf8`, `A0=rf7 … A7=rf0`).
- The memory read is correct (`$F21C00 = $00`, `debug_cpuDataIn = $00`).
- Only the **flag-vs-operand-settle TIMING** is wrong, for the indexed `(An,Xn)`
  addressing of a `$F0xxxx` (V8 I/O) read.

**Root in RTL:** the `setexecOPC` gate at `rtl/tg68k/TG68KdotC_Kernel.vhd:~2897`:
```vhdl
IF setstate="00" AND next_micro_state=idle AND set_direct_data='0' AND
   (exec_write_back='0' OR (state="10" AND addrvalue='0')) THEN
    setexecOPC <= '1';
```
For a **read** (`exec_write_back='0'`) it fires on `next_micro_state=idle` and does NOT
wait for the read's `state="10"` (write-back DOES, via the right-hand term). So the
indexed-`(An,Xn)` EA path is still putting transient values on `OP1out` (the EA address,
the index) when `execOPC` latches the flags. (`execOPC <= setexecOPC` is at line ~3107.)

NOT a flag-commit-vs-Bcc race (the `bne` reads the committed `Z=1` correctly); NOT a
chipset value bug (`$F21C00` reads `$00` correctly, same as MAME); NOT the 68030 cache
(uncached); NOT the PMMU (TC.E off during the bank-scan).

## The full causal chain (one bug explains everything)

1. The RAM/hardware enumeration's `d0/d1` subroutine **`$A02F18`** calls a byte
   write/read/`cmp` **loopback aliasing test `$A03124`** on V8 I/O regs (`$F01C00` and
   `$F01C00 + stride` = `$F21C00`, `$F41C00`, …) to probe hardware/RAM presence.
2. `cmp.b (A2,D2.l),D1` @ `$A0313A` mis-computes **Z=1** (false "aliased") → wrong
   `d0/d1`.
3. `d0/d1` drive `$A4A5C2 btst #7,d1 ; beq` → our core takes the WRONG RAM-enumeration
   path (the extensive probe / bad branch).
4. → **null/garbage RAM descriptor table**: at `$A4657E (movea.l (a7),a4)` the table
   pointer is `A4=0`; the march then reads `(start,len)` from address `$0` (zeros) and
   gets garbage (`A0=$3/$97`, `A1=0`).
5. → the POST march sweeps a **garbage range** (`A1=$FFFFFF88` unclamped) = the apparent
   "600–1200-frame slow POST". The memtest itself is fast (~56 frames given a valid
   range — vindicates the dev's "≤300 frames" instinct).
6. → after POST, a continuation `jmp (a3=a5=garbage)` @ `$A4A8FA` jumps to `$FFFFFFxx`,
   takes an exception on a wrapped SP≈0, and wedges looping at `$00007FF8`.
7. **MAME `maclc2` (byte-identical ROM) computes the cmp correctly** → builds a correct
   4 MB descriptor table (its POST march sweeps real RAM `$0FFFFx/$1FFFFx/$2FFFFx`) → boots.

## THE FIX (next session — do this)

Targeted, `ld_An1`-class: make `execOPC` not latch flags until `OP1out`/`OP2out` have
settled for the indexed `(An,Xn)` source read. Two candidate approaches:
- **(A)** Add a one-cycle defer (a new micro_state, à la the old `ld_An1`) on the
  indexed `(An,Xn)` source-EA path so the execute/flag-latch happens one cycle later.
  The old core's analogous fix is **MacLC commit `42ae7a6`** (branch
  `new-video-on-fix-egret`): added `ld_An1` to `TG68K_Pack.vhd` enum + split the `(An)`
  longword case in the EA-build CASE. `git show 42ae7a6` is the template. (NOTE: that
  fix was for `(An)` longword; ours is `(An,Xn)` byte — different EA mode, see EA-build
  CASE `WHEN "110"` at `Kernel.vhd:~4127` → `ld_AnXn1`; the indexed read state is
  `ld_AnXn2` at `Kernel.vhd:~6077`.)
- **(B)** Tighten the `setexecOPC` read gate (`Kernel.vhd:~2897`) to also require the
  read/EA to have settled (mirror the write-back `state="10"` guard) for the read case.

**This gate/path is used by EVERY instruction — a wrong change silently breaks other
opcodes.** Mandatory verification after the fix:
1. `rtl/tg68k/convert_to_verilog.sh` (ghdl 6.0.0), then `cd verilator && make clean && make`.
2. Swap in `boot0-fastmem.rom`, run to F96, grep `[LOOPBACK]` — the `cmp` must now
   commit `Z=0` and the `bne` @ `$A0313E` must **take** (PC → `$A03144`, not fall to
   `$A03140`).
3. **Re-run the SingleStepTests CPU corpus** for regressions (this is the authoritative
   reproducer — see `SingleStepTests/tg68k/`).
4. Then confirm (stock + fast-mem): the descriptor table builds (`A4 != 0` at `$A4657E`),
   POST completes fast, and the boot progresses past `$A4A8FA` (no `$FFFFFFxx`/`$7FF8`).

## Tooling / instrumentation (committed on `030_LCii`)

- **`verilator/patch_fast_ramtest.py` + `releases/boot0-fastmem.rom`** — clamp ROM (full
  cold POST in ~150 frames). 4-byte swap at ROM `0x46858` (`suba.w #$78,a1`→`lea
  $78(a0),a1`). Use it to reach the bank-scan/loopback fast (~F94).
- **`[LOOPBACK]` detector** in `verilator/sim_main.cpp` — logs the cmp's
  `OP1/OP2/D1/ea_data/srin/Z` while `debug_pc ∈ [$A03124,$A03150]`. Currently logs
  `rf[14]`(=D1), `op1out`, `op2out`, `srin`, `Z`.
- **`verilator/tg68k_debug.vlt`** (added to `Makefile` `V_SRC`) — `public_flat_rd` on
  `op1out`, `op2out`, `ea_data`, `last_data_read` (Verilator optimizes these wires away
  otherwise; `=>open` debug ports were NOT enough).
- **Kernel debug ports** `debug_OP1out`/`debug_OP2out` (in `TG68KdotC_Kernel.vhd` +
  `TG68K.vhd` + regen'd `.v`) — currently mapped to `ea_data`/`last_data_read`. Temp
  instrumentation; remove or gate when the fix lands.
- **`--trace-frames A,B`** option in `sim_main.cpp` — gate `cpu_trace.log` to a frame
  window (skip the slow chime). E.g. `--trace-frames 88,96`.
- **MAME oracle** lua in `verilator/mame/`: `maincpu_regs.lua`, `loopback_vals.lua`,
  `bankscan_trace.lua`.

## Build / run gotchas

- VHDL is source of truth. After editing `TG68KdotC_Kernel.vhd`/`TG68K_Pack.vhd`:
  `rtl/tg68k/convert_to_verilog.sh` (ghdl 6.0.0 present) → `cd verilator && make clean &&
  make`. Clean rebuild of the 103k-line kernel ≈ **10–14 min**. `sim_main.cpp`-only
  changes: plain `make` ≈ 1 min.
- Sim ≈ 0.6 FPS (inherent — don't tune `-O`/threads/trace flags; see memory
  `maclc-verilator-sim-speed`). Loopback runs ~F94; `--stop-at-frame 96` is enough.
- Repro: `cp ../releases/boot0-fastmem.rom ../releases/boot0.rom && ./obj_dir/Vemu
  --headless --no-cpu-trace --verbose --stop-at-frame 96 2>x.log`; **always restore**
  `cp /tmp/stock_boot0.rom ../releases/boot0.rom` (or from git). Stock sha `18c3de07…`.
- macOS has no `timeout`; bound with `--stop-at-frame`.

## MAME oracle gotchas (these cost a wasted gdbstub detour — don't repeat)

- Binary `/opt/homebrew/bin/mame` (0.288); romset `/private/tmp/goodroms/maclc2/`
  (4 chips `341-047{3,4,5,6}`, interleaved `hh,mh,ml,ll` == our `boot0.rom`, sha
  `18c3de07…`). Run via `verilator/mame/run_mame_maclc2.sh`.
- **ALWAYS `-skip_gameinfo`** (and `-autoboot_delay 1`). Without it, with `-debug` the
  CPU stays FROZEN on the info/warning screen — breakpoints never fire.
- The debugger / `-debugscript` / **gdbstub default to the Egret HC05, NOT the 68030**.
  Target the main CPU: `trace /tmp/x.tr,maincpu`. (This is why my breakpoints missed.)
- **Watchpoints reliable; breakpoints/tracelog flaky.** Lua read-taps on code DON'T fire
  on opcode fetch in 0.288 (a custom build elsewhere did). Lua DATA taps work.
- 68030 ROM PC = `$00A4xxxx`; mask `global_mask(0x80ffffff)`.

## Key addresses / files / lines

- **CPU bug:** `cmp.b` @ `$A0313A`, `bne` @ `$A0313E` (target `$A03144`, fall-through
  `$A03140`). Loopback subroutine `$A03124`. `d0/d1` routine `$A02F18`. Enumeration
  branch `$A4A5C2`. Bank-scan `$A4A590`, called from `$A4A5A4`.
- **Boot:** StartTest1 `$A46558`; table-ptr load `$A4657E`; march `$A46850`; march check
  `$A46910`; ROM checksum `$A46AF2`; chime `$A45E3A`; crash `$A4A8FA`→`$FFFFFFxx`→`$7FF8`.
- **Kernel RTL** (`rtl/tg68k/TG68KdotC_Kernel.vhd`): `setexecOPC` gate ~2897;
  `execOPC<=setexecOPC` ~3107; `ea_data` latch ~2144; `OP1out` ~2020, `OP2out` ~2052;
  EA-build CASE source modes ~4166 (`WHEN "110"`→`ld_AnXn1` ~4127); `ld_AnXn2` ~6077.
  Regfile **reversed** in Verilator (`D0=rf15..D7=rf8`).
- **Old analogous fix:** `git show 42ae7a6` (branch `new-video-on-fix-egret`), the
  `ld_An1` defer for `(An)` longword.

## Repo state

- Branch `030_LCii`; tree clean; `boot0.rom` stock (`18c3de07`). This session's commits:
  `bf346e9` (fast-mem ROM + root-cause), `040b313` (`--trace-frames`), `576ae0e`/`fdb5f56`/
  `a93d76f`/`6ec2987`/`ea19f19`/`e6e5339`/`40da646`/`09d9edf` (the MAME-oracle + CPU-bug
  narrowing), `95d66da` (NAIL: execOPC-before-operands-settle + debug instrumentation).
- The kernel currently carries TEMP debug ports (`debug_OP1out/OP2out`) + the `.vlt`.
  The real fix is a SEPARATE logic change; keep or remove the instrumentation after.
- Full evidence: `docs/findings_lcii_ramtable_2026-06-15.md` (the "NAILED (2026-06-16)"
  section). Earlier context: `docs/handoff_lcii_boot_postpmmu_2026-06-15.md`.

## Memories (read before resuming)

This project (`MacIIvi_MiSTer` memory dir): `lcii-boot-blocker-ramtable`,
`mame-debugger-and-cmpl-bug`, `maclc-verilator-sim-speed`.
`MacLC_MiSTer` memory: `tg68k-last-data-read-bug` (the ld_An1 fix — same bug CLASS),
`ram-descriptor-garbage-root-cause`, `mame-ground-truth-maclc`.
`lbmactwo_MiSTer` memory: `reference-mame-invocation`, `tg68k-verilator-regfile`
(regfile layout caveat), `tg68k-bugs`.
