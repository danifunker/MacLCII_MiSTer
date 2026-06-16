# Findings: LC II boot — the POST "slowness" and the downstream crash are ONE bug (null RAM descriptor table)

**Date:** 2026-06-15 (session 2, continues `handoff_lcii_boot_postpmmu_2026-06-15.md`)
**Branch:** `030_LCii`
**TL;DR:** The dev's instinct was right on both counts. (1) The memory test is **not**
inherently slow — given a valid region it finishes in **~56 frames** (F94→F150,
all 11 handlers). (2) "Something else is wrong" downstream: the RAM-region
**descriptor table is null/garbage** (`A4=0`), which makes the *unclamped* POST
march a garbage range (= the apparent 600–1200-frame "slowness") **and** makes the
post-POST boot crash by jumping through garbage pointers. Same root cause.

---

## New tooling this session

- **`verilator/patch_fast_ramtest.py`** + **`releases/boot0-fastmem.rom`** — a
  *better* no-memtest ROM. Instead of forcing the warm-start path (the old
  `patch_skip_ramtest.py`, which bypasses the cold bookkeeping → `A2=0` →
  `jmp(a5=0)`), it keeps the **entire cold framework running** and only clamps the
  shared fill+march+verify engine to ~240 B/test. One 4-byte, same-length swap at
  ROM offset `0x46858`: `suba.w #$78,a1` (`92fc0078`) → `lea $78(a0),a1`
  (`43e80078`). Header checksum recomputed. With it, the full cold POST runs and
  reaches the post-POST boot in ~150 frames instead of hanging.

## The boot timeline with `boot0-fastmem.rom` (headless, `--no-cpu-trace --verbose`)

| Frames | What | PC |
|---|---|---|
| F9–F28 | **ROM checksum** (sum 0x3FFFE words of the 512 KB image) — legitimately ~0.5 s @16 MHz, *not* a bug | `$A46AF2` loop |
| F30–F89 | **Startup chime** poll/drain (known-good) | `$A45E3A` |
| F94–F150 | **All 11 POST RAM-test handlers** run + `[MARCH] DONE` ×2 | `$A46F5A…$A48468` |
| F151 | V8 RAM-config **finalize** write (`ram_cfg 84→04`, bits[7:6]→00) | `$A4A8FA` |
| **F155+** | **CRASH** — `jmp (a3=a5=garbage)` → PC walks `$FFFFFFAA→A4` (exception frame on a wrapped SP≈0) → wedges looping at **`$00007FF8`** | — |

Screens at F100/F150/F200 are all one identical uniform color (no `?` icon).

## The root cause: the RAM-region descriptor table is null

The shared march engine `$A46850` is driven by `(A0=start, length)` pairs read
from a descriptor table whose pointer the cold path loads at `$A4657E`
(`movea.l (a7),a4`). In our run that pointer is **`A4=0`**, so the march reads
descriptors from address `$0` (zeroed RAM) and gets garbage:

```
[TBL]   $A46584 A0(start)=00000003 A4=00000000 A5=CC000D07   ; chunk start = 3 (!)
[TBL]   $A4658A D0(len)=00007FFC   A0=00000003 A4=00000000
[TBLMEM] CPU$9FFFE0: 00000000 00000000 … 00005061           ; table itself = zeros
[MARCH] PASS#3  A0=00000097 A1=00000000 A4=FFFFFFFF          ; marching garbage
```

**Why this *is* the "slowness":** with `A0=$97, A1=$0`, the engine's
`suba.w #$78,a1` makes `A1 = $FFFFFF88`, so the **unclamped** march sweeps `$97 →
$FFFFFF88` — essentially the whole address space. That, not slow per-access
timing, is why the stock POST never finishes inside 300 frames. The clamp bounds
it (`A1 = A0+$78`), so it completes — exposing the next failure.

**Why this is the crash:** the same null/garbage structures feed the post-POST
continuation. `$A4A8FA` is `jmp (a3)` where `a3` has been reloaded to `a5` (the
bank-scan loop's exit continuation); `a5` is garbage, so it jumps to `$FFFFFFxx`,
takes an exception with SP≈0, and wedges at `$7FF8`. This is the same *family* as
the warm-skip's `jmp(a5=0)` — a garbage continuation pointer, just a different
garbage value.

## Where the table SHOULD come from — the suspect

The descriptor table + its pointer are produced by the **bank-scan / RAM
enumeration at `$A4A590`** (the `[RAMCFG]` writes `C4`→`84`→`04` are its MAME-style
"try 8 MB SIMM / 4 MB SIMM / none" probe; physical config is correct: MacLC.sv
`configRAMSize=$04` = 4 MB soldered, no SIMM). The enumeration is finishing
(`ram_cfg` settles on `04`) but the table it builds is **null at `$9FFFE0`**, so
something in the probe/build diverges from what the ROM expects. Prime suspects,
in order:

1. **Bank-probe pass/fail semantics.** `[PROBE]` shows one bank `absent`
   (`$A467F6`) and one `present` (`$A467FE`). During the `C4`/`84` probes the
   written `ram_cfg` bits[7:6]=11/10 turn `mb_present` off so CPU `$0–$3FFFFF` is
   `selectUnmapped`; what an **unmapped read returns** (and the DTACK/bus-error
   behavior) decides the probe result and therefore the table. This is the most
   likely divergence from MAME.
2. **The `$0 ↔ $800000` SDRAM mirror.** Confirmed aliasing: CPU `$9FFFE0`
   (table) and CPU `$1FFFE0` both map to SDRAM word `$0FFFF0`
   (`addrController_top.v` §RAM translation). The `ram_configured` gate in
   `addrDecoder.v` was added to stop a phantom-`$0`-bank march from clobbering the
   table; verify it actually holds for the 4 MB-base case and that the table isn't
   being zeroed through the alias.
3. The table-pointer push itself (whoever sets `[SP]` before `$A4657E`).

## Update — the bank-scan probe, traced to ground truth

Added `--trace-frames A,B` to `sim_main.cpp` (gate trace writes to a frame window,
so the bank-scan window stays small without the chime). Traced F88–96 of
`boot0-fastmem.rom`. The trace (`@data_addr` is the reliable signal; a register-dump
detector's `rf[]` indexing proved **unreliable** for this core — trust the trace):

1. `$A4A5D2`: writes `'PanD'` to CPU `$1FFFFE`, reads it back OK (motherboard-low is
   mapped here, `ram_cfg=$04`), takes the success path. Fine.
2. `$A4A5EC`: `ram_cfg → C4` (bits[7:6]=11). In our `addrDecoder` that makes
   `mb_present=false`, and `in_simm` is false (physical config `$04` = no SIMM), so
   **all of CPU `$0–$7FFFFF` is `selectUnmapped`.**
3. `$A4A6C4` top-of-RAM probe then walks **`@7FFFFE → @6FFFFE → … → @3FFFFE →
   @2FFFFE → @1FFFFE → @0FFFFE`**, stepping down 1 MB, and **every readback fails** —
   including `$0–$3FFFFF`, the real 4 MB, because it's unmapped under `ram_cfg=C4`.
   Probe concludes "no RAM," `ram_cfg → 84`.
4. The data-bus-width test `$A4A6E6` then runs at **CPU `$400000`** (writes `@400000…
   @400006`). `$400000` is the *exclusive* top of the 4 MB motherboard region
   (`[0,$400000)`), so it's `selectUnmapped` too (and `addrController` would *wrap*
   it to SDRAM `$0` if `selectRAM` were ever asserted there).

Net: RAM is never correctly detected, the region list / table-base pointer comes out
garbage, `A4=0`, the table is null.

**Whether each of these matches real V8/MAME is the open question.** The C4 probe
finding nothing is *plausibly* correct (no 8 MB SIMM). The divergence that yields the
null table is somewhere in the `84`/`04` phase or the `$400000` boundary handling —
our `addrDecoder`/`addrController` V8 RAM-config decode vs MAME `v8.cpp ram_size()`.

## Ruled out this session (so the next pass doesn't re-chase them)

- **68030 caches** — not the cause: they're *not instantiated* in this core
  (`rtl/tg68k/tg68k.v:328` "the kernel runs uncached"), so no stale write-then-read.
- **PMMU translation** — not active during the bank-scan: TC.E isn't set until the
  PMMU-enable at `$A416xx`, which is *after* the POST (bank-scan is ~F94). So the
  probe addresses are physical = logical.
- **Address mapping** — matches MAME `v8.cpp ram_size()`: the `$800000-$9FFFFF`
  first-2 MB mirror is always installed; with `config=84` on a 4 MB machine
  `simm_size=0` (no SIMM) so motherboard sits at `$0-$3FFFFF` and `$400000` is
  unmapped — exactly our `addrDecoder` (`mb_present`, `in_motherboard_low`).
- **Unmapped-read constant** — doesn't flip the `$400000` bus-width test: it compares
  read bytes against the `'Tina'` pattern bytes, which equal neither `0x00` nor
  `0xFF`, so the test reads "absent" either way. (The `0x0000→0xFFFF` change in
  `dataController_top.sv:304` fixed a *different* probe; both are consistent here.)

So the divergence is subtler than a single decode/const — it needs the oracle's
*actual values* to localize. Strong remaining candidates: a misaligned-longword data
path (the `'PanD'` write to `$1FFFFE` and the table-ptr load `movea.l (a7),a4` with an
ODD `a7=$773F` both cross a 2 MB SDRAM-word boundary), or the `84`/`04`-phase reprobe
of mapped RAM that this F88–96 window didn't reach.

## Recommended next step

Run the **MAME `maclc2` oracle** (see memory `mame-maclc-oracle-setup`) with a CPU
trace over the same bank-scan window and **diff it against our F88–96 trace** to find
the first address where the RAM-presence / bus-width result diverges. That pinpoints
exactly which V8 decode case (the `ram_cfg` C4/84 remap, the `$400000` boundary, or an
unmapped-read return value) to fix in `addrDecoder.v` / `addrController_top.v`. Fixing
it so the 4 MB-no-SIMM config is correctly enumerated should fix the slowness **and**
the crash together.

Tooling: `./obj_dir/Vemu --trace-frames 88,96 --verbose --stop-at-frame 97` with
`boot0-fastmem.rom` swapped in produces the ~1.8k-line window used above
(`cpu_trace.log`); grep `'] 00A4A5'`/`'] 00A4A6'` for the probe.

## Repro / state

```bash
cd verilator && make            # ~0.6 FPS, don't tune build flags (see NOTEs)
python3 patch_fast_ramtest.py ../releases/boot0.rom ../releases/boot0-fastmem.rom
cp ../releases/boot0.rom /tmp/stock.rom
cp ../releases/boot0-fastmem.rom ../releases/boot0.rom
./obj_dir/Vemu --headless --no-cpu-trace --verbose --screenshot 100,150,200 \
    --stop-at-frame 200 2>fast.log
grep -aE '\[STATE\]|\[MARCH\]|\[TBL\]|\[RAMCFG' fast.log    # the evidence above
cp /tmp/stock.rom ../releases/boot0.rom    # RESTORE (stock sha 18c3de07…)
```

- `boot0.rom` was restored to stock this session; the working tree carries two new
  untracked files: `verilator/patch_fast_ramtest.py`, `releases/boot0-fastmem.rom`.
- The handoff's `d5786182…` stock sha was a different hash convention; the
  committed LC II ROM is **`18c3de07…`** (matches HEAD `a8ad155`).
