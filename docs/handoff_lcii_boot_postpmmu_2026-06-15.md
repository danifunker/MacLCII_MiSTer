# Handoff: Mac LC II boot — past the PMMU fix, still no visible `?` disk icon

**Date:** 2026-06-15
**Branch:** `030_LCii` (MacLC_MiSTer)
**Status:** The 68030 core now boots the real LC II ROM through the startup chime
**and** past the PMMU/cache-enable stage (a real bus-FSM bug was fixed this
session). But the stock ROM run to **frame 1000 is still the uniform startup-gray
screen** — it never visibly reaches the `?`-disk-icon / Sad-Mac. The dev's read
is **"something else is wrong" downstream**, and that's what the next session
should chase. The blocker to *seeing* it is that we have **no PC visibility past
the slow POST**, and both boot paths are obstructed (stock = too slow; no-memtest
= runs off into zeroed RAM).

---

## TL;DR / where we are

1. **FIXED this session (committed `35aa11b`):** a genuine RTL bug in
   `rtl/tg68k/tg68k.v` — the bus micro-sequencer's `s_state`↔`phi` **parity flip**
   that deadlocked the first PMMU page-table walk at `$A416xx`. After the fix the
   walks complete (20/20, sane multi-level descriptors) and the CPU runs
   MMU-translated code. **This is solid** (validated via the no-memtest ROM).
2. **Open question:** does the LC II actually reach the boot-device search
   (`?` icon) — or is there a *second* bug after PMMU-enable? We could not answer
   it: the stock POST is too slow to sim that far, and the no-memtest shortcut is
   broken in a different way.
3. The dev is **fairly sure something else is wrong** (not just "slow"). Trust
   that instinct; the gray-at-1000 result is *ambiguous*, not exculpatory.

---

## What is solid (don't re-litigate)

- **Startup chime works.** It was a `check_boot.sh` false positive, not an ASC
  bug — confirmed against MAME `maclc2` ground truth (chime is poll-driven, drains
  at the same 22257 Hz). See `docs/findings_asc_chime_mame_2026-06-15.md`.
- **PMMU table-walk deadlock fixed.** `tg68k.v`: AS is asserted at `s_state 1`
  in the **phi1** branch / deasserted at `s_state 6` in **phi2** (odd s_state ⟷
  phi1, even ⟷ phi2). The variable-length `s_state 4` DTACK wait (slot-aligned →
  can last an *odd* number of phi edges) and PMMU walks (clkena suppressed) flip
  that parity, so a later cycle passes `s_state 1` on a phi2 edge, AS is never
  asserted, the access never gets DTACK → deadlock. Fix: only **leave `s_state 0`
  on phi2** (`s_state != 0` in the phi1 advance). Full writeup +
  `+define+PMMU_TRACE` probe: `docs/findings_pmmu_walk_stall_2026-06-15.md`.
- **Sim speed is ~0.6 FPS and that's inherent.** `-O2`/`-O3` are SLOWER (Verilated
  eval = giant functions, `-Os` is I-cache-optimal); Verilator `-O3` and dropping
  `--trace` both prune the internal signals `sim_main.cpp` pokes (incl.
  `ram__DOT__mem` for ROM load) → build breaks; `--threads` is slower. **Don't
  re-attempt build-flag speedups.** The Makefile carries NOTE comments; see memory
  `maclc-verilator-sim-speed`.

---

## The two boot paths and why each is blocked

### A. Stock ROM (`releases/boot0.rom`, the real LC II ROM, sha `d5786182…`)
- Boot order: early init → **POST RAM test** (`StartTest1` @ `$A46558`) → chime
  (`$A45Exx`) → **PMMU/cache enable** (`$A416xx`) → boot continues.
- The POST is a **12-test memory suite** (dispatcher table @ `$46806`; shared
  clear+march engine @ `$A46850`, the slow `eor.l` march loop @ `$A468xx`). Each
  test marches all of RAM (4 MB) with multiple patterns. One 4 MB pass ≈ **25
  frames** (measured from the frame-150 trace), so the whole POST plausibly takes
  **~600–1200+ frames** of sim by itself.
- **Result:** stock to frame 1000 = gray screen, all screenshots identical. This
  is *ambiguous* — gray persists through the entire POST + RAM-clear, so it's
  consistent with "still grinding the POST," not necessarily a hang. We had **no
  PC visibility** (`--no-cpu-trace`, and the march/STM/ERR DLOG markers need
  `--verbose`).
- **What we DO know is healthy:** the frame-150 cpu_trace showed the march address
  *climbing* ($01A7A6 → $398B66, wrapping) — the POST is progressing, not stuck at
  150. Whether it stays healthy to completion is unverified.

### B. No-memtest ROM (`releases/boot0-nomemcheck.rom`, fast iteration)
- `verilator/patch_skip_ramtest.py` patches `cmpi.l #'WLSC',d3` @ ROM offset
  `0x46558` → `bra.s` onto the **warm-start path** (`clr.w d7; bra $46630`),
  skipping the whole POST. Reaches `$A416xx` (PMMU-enable) by **frame ~96**.
- **It then runs off into zeroed low RAM** and loops forever executing `$0000`
  (`ori.b #0,d0`) from `$0` upward. **Root-caused:** at the MMU-enable hand-off
  `$A416B6: jmp (A5)`, `A5 = A2 = $00000000`. The continuation pointer **A2 is
  null** because the warm-skip bypasses the cold-POST code that computes it (it's
  not a vector-table issue — it's the missing continuation address). Confirmed by
  trace: `…pmove (A3),tc → jmp (A5) → 00000000: ori.b #0,d0 …`.

So: stock = correct but too slow to see the `?`; no-memtest = fast but the
warm-skip is unsound for cold boot (A2=0).

---

## Hypotheses for "something else is wrong" (for the next session)

Pick based on what the visibility experiments (below) reveal:

1. **A real downstream hang/fault** — boot reaches PMMU-enable, runs translated
   code, then stalls/faults in post-POST init (video bank setup, SCSI/ADB/Egret
   handshake, PRAM, slot probe). The no-memtest run *did* run translated code at
   `$001ff36e`/`$000025a6` before the A2=0 jump, so there's real post-MMU
   execution to inspect.
2. **The POST itself fails/loops** on our chipset (a memory test that never
   passes because RAM/decode behaves subtly wrong), so it never *finishes* — gray
   forever, not just slow. The frame-150 trace argues against an early stall, but
   a *later* test in the 12-suite could trip.
3. **The PMMU fix is incomplete** — more parity-flip edge cases, or the
   translation is subtly wrong for some address (descriptors looked sane, but only
   the first few were inspected). Re-run with `PMMU_TRACE` over a longer window
   and check for `make_berr`/`trap_berr` or repeated/garbage descriptors.
4. **A2 is *supposed* to be set earlier and isn't** even on the stock path (i.e.,
   the same null-continuation bug bites the real boot too, not just the warm-skip)
   — would explain a stock stall at `$A416xx` after the (slow) POST.

---

## Diagnostic plan (do these first — they unblock everything)

The core problem is **no visibility past the POST**. Two ways to get it:

### Plan 1 (highest leverage): fix the no-memtest ROM so it boots cold correctly
Find **where the cold POST path sets `A2`** (the post-MMU continuation), and make
a smarter patch that skips the *slow march* but preserves the A2 setup (+ RAM
sizing / low-mem init). Then the no-memtest ROM reaches the post-POST boot in ~96
frames and we can iterate fast on the *real* downstream behavior.
- Disassemble around the MMU-enable setup to find A2's source. Capstone recipe:
  ```python
  import capstone; d=open("releases/boot0.rom","rb").read()
  md=capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_000)
  for i in md.disasm(d[off:off+n], off): print(hex(0xA00000+i.address), i.mnemonic, i.op_str)
  ```
  MMU-enable code is at file offset `0x41680`–`0x416c0` (logical `$A41680`+). A2
  is loaded *earlier* — grep the disasm/`docs/MacLC_ROM_disasm.txt` for writes to
  A2 in the boot path between the POST exit (`$46630`) and `$A416xx`.
- The warm path is `clr.w d7; bra $46630`; the cold path runs the 12 tests then
  reaches the same continuation. Diff what the cold path does that sets A2.

### Plan 2 (definitive but slow): run stock with progress visibility
- `./obj_dir/Vemu --headless --no-cpu-trace --verbose --stop-at-frame 3000 2>err.log`
  then `grep -E 'A46910|A4694C|A4A590|STM_ENTRY|\[ERR\]' err.log`. The DLOG
  detectors (sim_main.cpp ~line 313, *independent of cpu_trace gating*) fire on:
  `$A46910` inner-march-pass, `$A4694C` march-done, `$A4A590` bank-scan,
  `$A48CD0/$A48CDA` fatal-error handler, STM entry. This shows the boot stage
  over time **without** a giant cpu_trace. ~2 hr wall at 0.6 FPS — run in the
  background. If `$A4694C`/`$A4A590` fire, the POST finished and the stall (if any)
  is later; if only `$A46910` repeats forever, the POST is looping; if `[ERR]`
  fires, capture the failed-test registers it dumps.

### Plan 3 (targeted): cpu_trace the stall, tail it
If a stall PC is suspected, run with cpu_trace to the stall frame and `tail` the
(large) `cpu_trace.log` for the last PCs + `@data_addr`. Used this all session;
the file is huge but only the tail matters.

---

## Key references

- **The fix:** `rtl/tg68k/tg68k.v` (~:126 parity-resync `s_state != 0`; walker FSM
  :337; `ifdef PMMU_TRACE` probe at end). DTACK probe in `verilator/sim.v` (~:280,
  `ifdef PMMU_TRACE`). Enable both with Makefile `V_DEFINE += +define+PMMU_TRACE=1`.
- **ROM addresses:** chime `$A45E3A`/`$A45F26` (works); PMMU-enable `$A416xx`
  (`pmove srp/crp/tc`, `jmp (A5=A2)` @ `$A416B6`); POST `StartTest1` `$A46558`,
  test table `$46806`, march engine `$A46850`, march loop `$A468xx`; warm rejoin
  `$46630`; fatal handler `$A48CD0`.
- **Tooling:** `verilator/check_boot.sh` (chime-aware now), `patch_skip_ramtest.py`,
  `verilator/mame/run_mame_maclc2.sh` + `asc_trace.lua` (MAME `maclc2` oracle —
  use `/opt/homebrew/bin/mame` 0.288, romset `/private/tmp/goodroms/maclc2/`).
- **Findings docs:** `findings_asc_chime_mame_2026-06-15.md`,
  `findings_pmmu_walk_stall_2026-06-15.md`. ROM disasm:
  `docs/MacLC_ROM_disasm.txt` (LC ROM, but same framework offsets as LC II).

## Repro / gotchas

```bash
cd verilator && make            # ~0.6 FPS, DON'T try to speed up (see NOTE comments)
# stock boot, screenshots:
./obj_dir/Vemu --headless --no-cpu-trace --screenshot 300,600,900 --stop-at-frame 1000
# no-memtest fast path (swap ROM, ALWAYS restore after):
cp ../releases/boot0.rom /tmp/stock.rom
cp ../releases/boot0-nomemcheck.rom ../releases/boot0.rom
./obj_dir/Vemu --headless --stop-at-frame 110   # reaches $A416xx ~frame 96
cp /tmp/stock.rom ../releases/boot0.rom          # RESTORE
```
- macOS has no `timeout`; bound runs with `--stop-at-frame`.
- Screenshots → `verilator/screenshot_frame_NNNN.png` (gitignored). Startup-gray
  sha is `0d3b26f6…` — if a shot differs, boot progressed past gray.
- Repo is **clean**; 3 session commits on `030_LCii` (`a8ad155` mem config,
  `b02b956` ASC/tooling, `35aa11b` PMMU fix). The current `obj_dir/Vemu` is a
  mixed-`-O` build — `make clean && make` for a pristine `-Os` binary if in doubt.
- MacIIvi_MiSTer shares the 68030 but uses a *different* bus wrapper
  (`cpu030_wrapper.v`, MMU currently bypassed `TC.E=0`); the `tg68k.v` parity fix
  does **not** port directly — re-derive if/when MacIIvi enables its MMU.
