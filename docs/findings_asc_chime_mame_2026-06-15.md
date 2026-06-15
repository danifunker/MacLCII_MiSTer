# Findings: LC II startup-chime ASC — MAME `maclc2` ground truth

**Date:** 2026-06-15
**Branch:** `030_LCii`
**Resolves:** `docs/handoff_asc_chime_mame_2026-06-15.md`

## Verdict (TL;DR)

**The LC II startup chime is NOT hung. There is no ASC bug. No `asc.sv` change is
needed.** The MAME `maclc2` ground truth the handoff asked for actually
*vindicates* `rtl/asc.sv`: the drain rate (22257 Hz), the poll-driven feed, and
the FIFOSTAT semantics all match MAME's `asc_v8_device`.

The handoff's "hang" was a **measurement artifact**: `check_boot.sh --run 90`
stops at frame 90, which is *in the middle of the chime*. The chime feeds the
FIFO by polling FIFOSTAT in a 3–4-PC wait loop that legitimately spins tens of
thousands of times per refill (MAME does **792,298** such reads, only **34** of
which catch the half-empty edge). Sampling that wait-spin trips check_boot's
"≤3 unique PCs in the last 1000 instructions ⇒ LOOP" heuristic. Run to frame
**150** and the LC II core sails past the chime and into the RAM test.

- **H1 (drain rate too slow): ruled out.** Both drain at 22257 Hz.
- **H2 (status/IRQ semantics wrong): not a bug.** Our `$804`-read clears the IRQ
  more aggressively than MAME's V8, but the chime is poll-driven and never
  depends on the ASC interrupt (MAME never even touches the pseudovia IFR/IER
  during the chime), so the difference is benign.

The handoff's own instrumentation was *correct but misread*: it measured
`count_a` = 557–562 at the poll reads and concluded "never reaches half-empty."
But MAME shows the identical picture — the FIFO sits above 512 for ~99.996% of
the poll reads and only dips below 512 momentarily ~34 times. Those rare dips
are exactly what drive the chime, and our core catches them the same way.

---

## How the ground truth was captured

- **MAME:** `/opt/homebrew/bin/mame` 0.288 (the in-tree `~/repos/mame/mame` is a
  0.287 build that does **not** know `maclc`/`maclc2`).
- **Romset:** assembled `/private/tmp/goodroms/maclc2/` from Ample's `maclc2.zip`
  (LC II split ROMs `341-0473..0476`) + egret device romset
  (`344s0100/341s0850/341s0851`); `mame -verifyroms maclc2` = good.
- **Runner:** `verilator/mame/run_mame_maclc2.sh` (new; `run_mame.sh` hardcodes
  `maclc`). System `maclc2`, `-ramsize 4M`.
- **Trace:** `verilator/mame/asc_trace.lua` (new). Taps the CPU-visible ASC
  window `$F14000-$F15FFF` (V8 base `$a00000` + internal `$514000`, under
  `maclc_map` `global_mask(0x80ffffff)`): every FIFOSTAT `$F14804` read
  (value + PC), every FIFO-A write `$F14000-$F143FF`, register writes — annotated
  against the chime PC range. `SOUND=none` (streams still advance; drain measured
  at 22257 Hz). Pseudovia cross-check via `tap.lua` on `$F26000-$F27FFF`.
- Raw logs: `/tmp/asc_trace_none.txt` (841k lines), `/tmp/pvia_tap.txt`.

---

## What MAME does at the chime (the correct behavior)

Two ROM loops, **both pure polling — no ASC ISR:**

```
fill:  write 1 sample to FIFO A   ; PC $A45F26   (writes A and B; V8 ignores B)
       read FIFOSTAT $804         ; PC $A45F2C   andi #$2 -> fill until bit1=FULL
wait:  read FIFOSTAT $804         ; PC $A45E3A   andi #$1 -> spin until bit0=HALF-EMPTY
       (half-empty -> jmp (A1) back to synthesize+refill)
```

| Quantity | Value |
|---|---|
| FIFO-A writes (feed), all from PC `$A45F26` | 24,546 bytes |
| FIFOSTAT reads from wait loop `$A45E3A` | 792,298 |
| …returning **bit0=1** (half-empty caught) | **33** + 1 final |
| FIFOSTAT reads from fill loop `$A45F2C` | 24,546 (720 with bit0=1) |
| ASC accesses with PC outside the chime, during chime | **0** |
| pseudovia accesses during the chime (frames 33–96) | **0** (no IFR/IER touch) |

**Refill cadence:** the 33 `$A45E3A` bit0=1 events are evenly spaced **32.44 ms**
apart, **722 samples** fed per cycle → **722 / 0.03244 s = 22,257 samples/s**.
33 cycles × 722 ≈ 24,546 = the ~1.07 s boot chime. Chime spans MAME frames
**33–97**.

---

## What our LC II core does (Verilator, configRAMSize=$04, LC II ROM)

Identical structure, identical outcome:

- Chime feed comes from the **polling PC `$A45F2C`** — **no ISR** (the handoff's
  "interrupt-driven feed" was from before the `pseudovia.sv` ASC-IRQ-gating fix).
- Fill/wait loops interleave every frame **28–94** (chime plays, ~1.1 s — matches
  MAME's 33–97).
- Chime ends at **frame 94**; boot then proceeds: post-chime sound cleanup
  (`$A467x`), RAM config (`$A030-A032`), bank scan (`$A4A5xx`), memory clear
  (`$A4685E`, hit 34,953×), into the 4 MB RAM march (`$A468xx`).
- **Frame-150 trace:** RAM march address climbs `$01A7A6` (F95) → `$398B66`
  (F120, ~3.7 MB) → wraps for the next pass → `$12E96E` (F150). No error handler
  (`$A48CD0`) fired. `check_boot.sh` on the frame-150 trace: **all stages ✓,
  Status ADVANCING, Result PASS.**

Drain rate cross-check: `SAMPLE_DIV=1460` ⇒ 32.5 MHz/1460 = 22,260 Hz ≈ MAME's
22,257 Hz. ✓

---

## Why the handoff concluded "hang" (and why it's wrong)

- `check_boot.sh --run 90` ⇒ last PC `$00A45E44`, "4 unique PCs", "Status: LOOP".
  But frame 90 is mid-chime; the FIFO wait-spin is *supposed* to be a tight 3–4-PC
  loop. The heuristic can't tell a normal FIFO wait from a hang.
- "count_a 557–562 at the poll reads, never < 512" — true, but MAME is the same
  (FIFO above half for ~99.996% of reads). The chime is driven by the rare dips,
  which our core catches just like MAME.

---

## Actions taken

1. **No change to `rtl/asc.sv`** — it is MAME-faithful; changing it would only
   risk the shared LC core for no benefit.
2. **`verilator/check_boot.sh`** patched so the ASC chime wait-spin (`$A45E3A`)
   is reported as "CHIME WAIT (normal — run more frames)" instead of "LOOP", and
   reaching memory-clear/RAM-test is treated as past-the-chime progress. Prevents
   this exact false alarm in future sessions.
3. New MAME tooling kept: `verilator/mame/asc_trace.lua`,
   `verilator/mame/run_mame_maclc2.sh`.

## Follow-ups (separate from the chime)

- The boot is healthy through the RAM march at frame 150; whether it reaches the
  desktop/Sad-Mac is a *later* boot question, out of scope for the chime.

## Key references

- MAME V8 ASC: `src/devices/sound/asc.cpp` — `asc_v8_device::sound_stream_update`
  :802-841, `::read` :843-876 (FIFOSTAT :859-865), `::write` :878-903. V8 map
  v8.cpp:92 (`0x514000`); `maclc_map` maclc.cpp:179 (`global_mask 0x80ffffff`,
  V8 @ `a00000-ffffff`); maclc2 reuses it (maclc.cpp:461).
- Ours: `rtl/asc.sv` (SAMPLE_DIV :53, fifo_stat :99-101, IRQ :156-165),
  `rtl/pseudovia.sv` (asc → ifr[4] :135-138, gate :92), `verilator/check_boot.sh`.
- New tooling: `verilator/mame/asc_trace.lua`, `verilator/mame/run_mame_maclc2.sh`.
