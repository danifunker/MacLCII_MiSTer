# Findings + FIX: LC II PMMU-enable deadlock — bus-FSM s_state↔phi parity flip

**Date:** 2026-06-15
**Branch:** `030_LCii`
**Status:** ROOT-CAUSED and **FIXED** in `rtl/tg68k/tg68k.v`. Found via the
no-memtest ROM (`releases/boot0-nomemcheck.rom`), which skips the slow RAM march
and reaches the PMMU-enable stage by frame ~96.

## FIX (verified)

The bus micro-sequencer in `tg68k.v` assumes a fixed parity — AS is asserted at
`s_state 1` in the **phi1** branch and deasserted at `s_state 6` in the **phi2**
branch, i.e. odd s_state ⟷ phi1, even ⟷ phi2. The **variable-length wait at
s_state 4** (DTACK is slot-aligned, so it can last an *odd* number of phi edges)
and **PMMU walks** (clkena suppressed) can flip that parity; a later cycle then
passes `s_state 1` on a phi2 edge, the AS-assert is **skipped**, and the access
runs to `s_state 4` with AS deasserted → never gets DTACK → deadlock.

Fix: re-sync the parity every cycle by only **leaving `s_state 0` on phi2**
(`s_state != 0` added to the phi1-branch advance), exactly as a clkena-gated
kernel cycle already does. Guarantees `s_state 1` lands on phi1 so AS always
asserts, regardless of any prior parity flip. One-line change (`tg68k.v` :126).

Verified (no-memtest ROM): PMMU walks now complete **20/20** (was a 1-ACK
deadlock), multi-level and with sane descriptors (root `$003FEE00`→table
`$003FEDD0`→page desc `$00100019`); boot proceeds past `$A416xx` into
MMU-translated execution (kernel PC runs at `$001ff36e`, `$000025a6`, …); the
startup chime still plays (no regression, `$A45F26` fill loop ran). 030-only
change — the LC's 68020 core has no walker, so it cannot regress the LC.

NOTE: the no-memtest ROM then runs into zeroed low RAM (`$600`) because it skips
RAM/low-memory init — a *skip artifact*, not a PMMU issue. Use the stock ROM
(full RAM init) for end-to-end boot.

---

## Original investigation (how it was found)

## Symptom

With the RAM march skipped, boot reaches the **PMMU/cache enable** sequence at
`$A416xx` (`movec CACR` → `pmove srp/crp` → `pmove tc` → `jmp`), then **freezes**.
Screen = uniform startup gray, byte-identical across frames 95→400. `cpu_trace`
goes blind after `$A416xx` because the CPU pipeline is frozen mid table-walk.

## Root cause (measured with `+define+PMMU_TRACE`, probe in `rtl/tg68k/tg68k.v`)

The first MMU-translated access triggers a PMMU page-table walk. The walk reads
the (long-format) root descriptor as two longwords:

```
PMMU REQ #0 addr=003fee00 we=0  → PMMU ACK data=0009fc0a      (1st longword OK)
PMMU REQ #1 addr=003fee04 we=0  → (no ACK — hangs)            (2nd longword stalls)
```

Heartbeat then frozen identically for millions of cycles:

```
PMMU HB kpc=00a416b6 sstate=4 bs=00 walk=1 wreq=0 waddr=003fee04 berrh=0 dtack=1
```

- `walk=1` — `walk_cycle` stuck high; the walker FSM never completes the transfer.
- `sstate=4` — the main bus FSM (`tg68k.v`) is parked in its **wait-for-DTACK**
  state; it only advances from 4 on `!dtack_n | busstate==01 | xVma | berr`.
- `dtack=1` — **DTACK never asserts** for the walker's read of `$003FEE04`.
- `wreq=0`, `bs=00` — the kernel has already timed out the walk (deasserted req,
  resumed `busstate=00`), but the walker FSM is still holding the bus
  (`walk_cycle=1`, AS asserted for `$003FEE04`) → permanent deadlock.

So: **the 2nd, back-to-back PMMU-walker descriptor read does not receive a DTACK
from the slot-based address controller.** The 1st read (`$003FEE00`) acked fine;
`$003FEE04` (next longword, both within 4 MB RAM, `[23:21]=001`) hangs.

## Where to look (the open question)

`verilator/sim.v` DTACK gen (`:254-308`): for a RAM cycle,
`_cpuDTACK = !dtack_en`, and `dtack_en` sets on
`!_cpuAS & cpuBusControl & mem_latch_d` (a CPU-slot start while AS is low).
The addr controller (`rtl/addrController_top.v:86-118`) cycles `busPhase`/
`busCycle` continuously; `cpuBusControl` = busCycle ∈ {0,1,3}, `memoryLatch` =
busPhase==3. Since the stalled walker holds AS low at s_state 4 indefinitely, a
CPU-slot start *should* strobe `dtack_en` within a few bus cycles — but the
heartbeat shows it never does. The specific reason `dtack_en` fails to set for a
walker-driven cycle (vs a kernel-driven one) is the bug to pin down — next step
is to probe `_cpuAS`, `cpuBusControl`, `busPhase`, `dtack_en` during the stall.

Likely candidates:
1. The walker's AS / slot timing for a back-to-back cycle misses the
   `cpuBusControl & mem_latch_d` strobe window.
2. The walker FSM not being reset when the kernel times out the walk
   (`walk_cycle` stuck) — a secondary deadlock that should also be guarded.

## Scope / risk

This is **MC68030-PMMU-specific** (the table-walker, commit `178c008`). The Mac
**LC** core runs a 68020 with no page-table walks, so a fix here cannot regress
the LC. The bug is independent of the RAM-march skip — the stock ROM would hit
the same `$A416xx` PMMU-enable after its (slow) RAM test; the no-memtest ROM just
exposes it ~100 frames sooner.

## Repro

```bash
# build with the probe:  Makefile line ~23  ->  V_DEFINE += +define+PMMU_TRACE=1 ; make
cd verilator
cp ../releases/boot0.rom /tmp/boot0_lcii_stock.rom
cp ../releases/boot0-nomemcheck.rom ../releases/boot0.rom
./obj_dir/Vemu --headless --no-cpu-trace --stop-at-frame 115 2>/dev/null | grep PMMU
cp /tmp/boot0_lcii_stock.rom ../releases/boot0.rom   # restore
```

## Key references

- `rtl/tg68k/tg68k.v` — walker bus master `:54-93`, servicing FSM `:323-360`,
  main bus s_state machine `:114-171` (wait-DTACK at s_state 4 `:151`),
  `PMMU_TRACE` probe at end of module.
- `verilator/sim.v` — DTACK gen `:254-308`, fetch capture `:466-506`.
- `rtl/addrController_top.v` — busPhase/busCycle + `cpuBusControl`/`memoryLatch`
  `:86-118`.
- Patched ROM: `releases/boot0-nomemcheck.rom`; raw probe log: `/tmp/lcii_pmmu_stdout.log`.
