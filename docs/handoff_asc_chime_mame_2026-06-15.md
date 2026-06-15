# Handoff: Mac LC II startup-chime ASC hang — check against MAME

**Date:** 2026-06-15
**Branch:** `030_LCii`
**Status:** Boot reaches the startup chime and then hangs polling the ASC FIFO
status. Need MAME `maclc2` ground truth for the ASC FIFO drain rate and IRQ
cadence before changing the shared `rtl/asc.sv` (which the LC core relies on).

---

## TL;DR

After the 68030 berr double-fault fix (commit `c050221`), boot now runs the real
ROM all the way to the **startup chime**, then **hangs** in a 4-PC loop polling
ASC FIFOSTAT (`$50F14804`) for "FIFO half-empty":

```
$A45E3A: move.b ($804,A6),D0   ; A6 = $50F14000 (ASC), read FIFOSTAT
$A45E3E: andi.b #$1,D0          ; bit0 = STAT_HALF_FULL_A ("half-empty")
$A45E42: beq $a45e3a            ; spin while NOT half-empty
$A45E44: jmp (A1)               ; exit when half-empty
```

It is **not** a different ASC and **not** a CPU-wiring bug (both ruled out, see
below). It is an **ASC FIFO feed-vs-drain / IRQ-pacing** issue in `rtl/asc.sv`,
exposed by the LC II chime. We must match `asc.sv` to real-hardware behavior,
which means capturing MAME `maclc2`'s ASC timing and comparing.

---

## What is already ruled out (don't re-litigate)

1. **"Different ASC in the LC II" — NO.** MAME `src/mame/apple/v8.cpp` instantiates
   the same `ASC_V8` for both `maclc` and `maclc2` (line 119 / 644). Same chip,
   same `rtl/asc.sv`. `$804` = FIFO IRQ status; bit0 = "ch A 1/2 full"
   (`src/devices/sound/asc.cpp:27`).

2. **CPU access path — CORRECT.** Instrumented the live 030 bus accesses:
   - Bus address is `$50F14804` ✓, **A0 = 0** ✓ (decodes `$804`, not `$805`).
   - Byte-lane is fine — `sim.v:284 ascDataOut_full = {asc_data_in, asc_data_in}`
     replicates the byte on both lanes.
   - FIFO **writes work** — `count_a` increments cleanly per CPU write; the
     `we_stb` one-shot is not mis-firing on the 030.

3. **Status-bit polarity — CORRECT.** MAME sets `STAT_HALF_FULL_A` when the FIFO
   drains to 511 (`asc.cpp:225`) and clears it at cap≥512 (`asc.cpp:388`) — same
   threshold/polarity as our `asc.sv` (`count_a < 512`).

## The precise mechanism (measured in the Verilator sim)

- `count_a` reaches **exactly 511** intra-frame (the FIFO does momentarily hit
  half-empty), but only for ~16 clocks before a write refills it.
- At the poll's actual read instants, `count_a` is **557–562 and slowly climbing**
  — the FIFO is **fed faster than the 22257 Hz drain**, so it never *sustains*
  half-empty.
- The feed is **interrupt-driven**: the stuck loop is only 4 PCs (it isn't doing
  the writes). Path: `asc_irq → pseudovia IFR bit4 (gated by main IER $13) →
  CPU`. The chime ISR keeps refilling while the main poll waits forever.

So the polling CPU never observes `bit0=1` long enough, and boot never leaves the
chime loop.

## Tried and rejected

- **Latched half-empty bit** (set on drain-through-512, hold until refill, à la
  MAME `STAT_HALF_FULL_A`). Correct behavior, but **insufficient**: the IRQ-driven
  feed refills `count_a` past 512 (clearing the latch) before the polling CPU can
  sample it. Reverted (was also unverified against the working LC chime).

---

## The two hypotheses MAME must discriminate

**H1 — drain rate too slow.** `asc.sv:53 SAMPLE_DIV = 16'd1460` → 22257 Hz
(32.5 MHz / 1460). If the real V8 ASC FIFO drains faster than our pop rate, the
FIFO would actually reach/sustain half-empty between feeds and the poll would
pass. Need MAME's **actual FIFO pop cadence** (samples/sec at this boot point).

**H2 — IRQ pacing / clear-on-read.** `asc.sv:162` clears the ASC IRQ on **any**
`$804` read. MAME notes the original ASC clears status on read **but the V8 may
not** (`asc.cpp:326` "only on original ASC"). Combined with our IRQ-storm
workaround ("re-assert only on sample tick", `asc.sv:156-165`), this likely
mis-paces the chime ISR so it over-feeds. Need MAME's **IRQ assert/clear cadence**
and whether reading `$804` clears it on the V8.

---

## MAME plan — capture `maclc2` ground truth

### Build / run
- MAME tree: `~/repos/mame`, driver `src/mame/apple/maclc.cpp`, V8 `v8.cpp`,
  ASC `src/devices/sound/asc.cpp`. Build per `mame-build.md`.
- Runner: `verilator/mame/run_mame.sh` (headless wrapper). **Target `maclc2`**
  (not `maclc`) and the LC II system ROM. Lua tap pattern: `verilator/mame/tap.lua`,
  `scsi_trace.lua` (uses `install_read_tap`/`install_write_tap`,
  `register_periodic`, m68k `PC`/`An` state).

### New trace script: `verilator/mame/asc_trace.lua`
Tap the **CPU-visible ASC window** and the chime poll. (CPU-visible base is
`$F14000`–`$F15FFF` in 24-bit; confirm the exact address MAME's maincpu drives —
the SCC tap used `$f04000`–`$f05fff`.) Capture, as CSV:

1. **Every `$804` read**: machine-time, PC, value returned (esp. bit0/bit1).
2. **Every FIFO write** (`$F14000`–`$F143FF`): time, PC — to get the **feed rate**.
3. **ASC IRQ edges**: hook `pseudovia_device::asc_irq_w` (v8.cpp:120/647) or watch
   the `asc` device — to get **IRQ assert/clear cadence** and whether a `$804`
   read clears it.
4. Optionally the ASC's internal FIFO occupancy if reachable via the device state,
   to get the **true half-empty dwell time** and **pop cadence**.

Window the capture to the `$A45Exx` chime loop (gate on `PC` in `$A45E00`–`$A45F40`).

### What to compute / compare
| Question | MAME ground truth → | Decides |
|---|---|---|
| FIFO pop (drain) rate at the chime | samples/sec | H1: vs our `SAMPLE_DIV=1460` |
| Does `$804` read clear status/IRQ on V8? | yes/no | H2: vs `asc.sv:162` |
| IRQ assert→clear cadence | µs | H2: ISR feed pacing |
| `$804` bit0 dwell (how long half-empty before refill) | µs | whether a live vs latched bit can be polled |
| Feed burst size per half-empty | bytes | feed-vs-drain equilibrium |

---

## Candidate fixes (apply only after MAME confirms)

- **If H1:** correct `SAMPLE_DIV` (drain rate) to match MAME's V8 FIFO cadence so
  the FIFO actually reaches sustained half-empty between feeds.
- **If H2:** make `$804` read NOT clear status on the V8 (match `asc.cpp:326`),
  and/or re-work the IRQ assert so the chime ISR is paced like hardware. Re-check
  the IRQ-storm note (`asc.sv:156-165`) — the storm workaround was added for a
  reason; the fix must not reintroduce it.
- The **latched half-empty bit** is likely still part of a correct fix; re-apply
  it together with the rate/IRQ fix, not alone.

**Risk:** `rtl/asc.sv` is shared with the **Mac LC** core, which currently boots
its chime fine. Any change MUST be verified against both:
- LC II: `configRAMSize=$04` (current), LC II ROM — must clear the `$A45Exx` poll.
- LC: `configRAMSize=$24`, LC ROM — chime must still play / boot unaffected.

---

## Reproduce the sim hang

```bash
cd verilator
make
./obj_dir/Vemu --headless --stop-at-frame 90 --no-cpu-trace   # ~4 min
./check_boot.sh                                                # last PC ~ $00A45E44, "4 unique PCs"
```
Instrumentation pattern used this session (revert after): read
`VERTOPINTERN->emu__DOT__asc_inst__DOT__count_a` (and `wptr_a`/`rptr_a`/
`half_empty_a` if re-added) in the `sim_main.cpp` eval loop; gate on
`debug_selectASC`/`debug_cpuRW`/`debug_cpuBusControl` and `video.count_frame`.

## Key file references

- `rtl/asc.sv` — ASC model. `SAMPLE_DIV` :53, FIFOSTAT wire :99-101, IRQ
  clear-on-read/re-assert :156-165, FIFO push/pop/count :129-144.
- `verilator/sim.v` — ASC instance :633-650, byte replicate :284,
  `.addr({cpuAddr[11:1], tg68_a[0]})` :640.
- `rtl/pseudovia.sv` — `asc_irq` → IFR bit4 (gated by main IER $13) :88,135.
- MAME: `src/devices/sound/asc.cpp` (read :296-365, FIFOSTAT update :225-228 /
  388-401, "clears … only on original ASC" :326), `src/mame/apple/v8.cpp`
  (ASC_V8 + irqf_callback :92,119-121,644-647).
- This session's CPU fixes (context): `43043ea` (030 core), `178c008` (PMMU
  walker), `c050221` (berr double-fault fix).
