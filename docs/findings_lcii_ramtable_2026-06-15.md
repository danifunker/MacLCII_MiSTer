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

## Recommended next step

Get the one missing fact: trace the **bank-scan `$A4A590…$A4A8FA` window** (it runs
at ~F94 with `boot0-fastmem.rom`) and watch for **writes with `@9FFFExx`/`@1FFFExx`**
— i.e. does the enumeration ever write a *valid* descriptor table, or push a
non-zero pointer? That distinguishes "never built" from "built-then-clobbered".
A focused detector (log CPU writes to SDRAM word `$0FFFF0`, plus the value pushed
at the `$A4657E` table-pointer load) is cheaper than a full chime-through trace.
Then fix the probe/enumeration so the 4 MB-no-SIMM config builds a real table —
which should fix the slowness **and** the crash together.

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
