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

## MAME `maclc2` oracle result — the table is CORRECT in MAME; our enumeration fails

Tool added: `verilator/mame/bankscan_trace.lua` (taps the RAM-probe address windows
`$X0FFF0..$X0FFFF` + `$400000` and logs read/write VALUES + PC). Run:
`verilator/mame/run_mame_maclc2.sh -autoboot_script verilator/mame/bankscan_trace.lua
-seconds_to_run 8`. **The ROM is byte-identical** — MAME's `maclc2` 4-chip romset
(`341-047{3,4,5,6}`, interleaved hh,mh,ml,ll) assembles to exactly our `boot0.rom`
(sha `18c3de07…`).

What MAME does at those windows (the decisive data; lua read/write taps DO see data
accesses — only opcode *fetches* bypass them):

```
W pc=00A4685E addr=0FFFF0 data=6DB6DB6D   ; march FILL — REAL RAM
W pc=00A46862 addr=1FFFF0 data=B6DB6DB6
R pc=00A468CA addr=0FFFF0 data=6DB6DB6D   ; march eor.l reads back the pattern
W pc=00A468CA addr=0FFFF0 data=DB6DB6DB   ; …correctly. RAM works.
```

- **MAME's POST march sweeps REAL RAM** (`$0FFFFx, $1FFFFx, $2FFFFx, …`) with correct
  `$6DB6DB6D` pattern read-back ⇒ in MAME the **descriptor table is built correctly**
  (real 4 MB chunks). Our core's march instead runs on garbage (`A0=$3/$97`, null table).
- **MAME does ZERO of the extensive-probe writes our core does** — no `'PanD'`→`$1FFFFE`,
  no `'Tina'`/top-of-RAM walk `$7FFFFE..$0FFFFE`, no `$400000` bus-width test. (Data
  writes are caught by the working write-tap; only ~85 accesses total, all from the
  march `$A468xx`.) So MAME's RAM enumeration **succeeds without** the extensive probe;
  our core **falls into** that probe (and it fails) → null table.

**Conclusion:** same ROM, but our core's RAM enumeration diverges from MAME's and fails.
MAME proves a correct 4 MB-no-SIMM table is buildable here; our core mis-enumerates and
takes the failing extensive-probe branch (~`$A4A5C2 btst #7,d1`, where `d0/d1` come from
a hardware-config subroutine). So the bug is a **hardware-response difference** our
chipset presents during enumeration — NOT the ROM, NOT the march, NOT a fundamental
algorithm gap.

## CORRECTION + refinement (later same session)

The "MAME does ZERO probe writes / doesn't run the bank-scan" reading above was an
**artifact of lua read-taps not seeing opcode fetches**. A deduped capture of VIA1 +
pseudovia **data** reads (which taps DO see) proves **MAME runs the bank-scan**:
pseudovia reads occur from `pc=$A4A5CC, $A4A5E6, $A4A61A, $A4A620` (and `$A467DA/E0/FE`)
— and `$A4A5E6` is the path *after* the `'PanD'` check passes. So both cores run
`$A4A5xx`; the divergence is in the VALUES read / branches taken, not "MAME skips it".

Registers checked at the enumeration — **all MATCH MAME**, so none is the bug:
- pseudovia **config reg 1** = `ram_cfg|$04` = `$04` (MAME `via2_config_r` = `m_config|0x04`)
- pseudovia **port B reg 0** = `$00` (our `port_b` inits `$00`; MAME reads `$00`)
- VIA1 reads = `$00`; address mapping, unmapped-const, cache, PMMU (above).

So the divergence is subtle (the RAM-probe data responses, or the `d0/d1` subroutine
at `$A4A5A4`→`~$A03F18` which reads neither VIA nor pseudovia in the capture). It needs
an **instruction-level diff**, which is currently **blocked**: MAME's headless debugger
breakpoints do NOT fire — neither `-debug -debugscript bpset` nor gdbstub `Z1` (even a
bp at `$A468CA`, the march, *known-executed*, missed in 60 s); and lua taps can't see
opcode fetches. `g` over gdbstub returns `E01` at the initial halt.

## Recommended next step

Two viable routes (the lua I/O-read taps and the FPGA `--trace-frames` both work; only
MAME *instruction* tracing is blocked):

1. **Get MAME breakpoints to fire** — run MAME *windowed* (`-video soft`, not
   `-video none`) with the internal debugger, or find the gdbstub `Z1`/`g` quirk; then
   trace `$A4A5A0`→`$A4A638` and read `D0/D1` at the `$A4A5C2` branch.
2. **Instrument our core's enumeration read SEQUENCE** (every VIA/pseudovia/RAM read in
   the bank-scan, value+PC) via a sim_main.cpp detector, and diff it against MAME's
   deduped lua capture (`bankscan_trace.lua`, already written). First divergent
   (PC, register/address, value) is the bug.

Then fix the chipset response our enumeration reads wrong → fixes slow POST + crash.

## Strongest lead — the `d0/d1` subroutine is a hardware loopback/presence test

From our FPGA `cpu_trace.log`, the subroutine called at `$A4A5A4` is at **`$A02F18`**,
and it calls a routine at **`$A03124`** that does a byte **read-modify-write loopback /
presence test** on `(A2)` with stride `D2=$20000`:

```
$A03128: move.b (A2),D1     $A0312E: move.b D1,(A2)     ; write pattern
$A03130: neg.b D1           $A03132: move.b D1,(A2)     ; write complement
$A0313A: cmp.b (A2,D2.l),D1 ; compare against (A2 + $20000)  <- alias/presence check
$A03140: cmp.b (A2),D1
```

The `@data_addr` lands on I/O space — `$F01C00`, `$F21C00` (= `$F01C00 + $20000`), and
`$F26001` (pseudovia). So `d0/d1` (hence the whole RAM-enumeration path, incl. the
`$A4A5C2 btst #7,d1` branch) are decided by **how our chipset answers this register
loopback/aliasing test** — likely a hardware-variant/slot probe. `A2 = [A0+8] + $1C00`
(set at `$A03064`). **This is the most specific divergence candidate**: compare what our
RTL returns for the write-then-read-back + the `(A2)` vs `(A2+$20000)` comparison at
those addresses against MAME's V8/VIA. If the loopback or the `$20000`-stride alias
behaves differently, `d1` bit7 flips and we take the failing extensive-probe path.

## CONFIRMED via MAME maincpu trace (2026-06-16) — the exact first divergence

How to run MAME for ground truth (the gotchas that cost the gdbstub detour): **always
`-skip_gameinfo`** (else with `-debug` the CPU is frozen on the info/warning screen);
the debugger/gdbstub **defaults to the Egret HC05, not the 68030** — target it:
`trace /tmp/x.tr,maincpu`. Tools added: `verilator/mame/maincpu_regs.lua`,
`loopback_vals.lua`. (See memory `mame-debugger-and-cmpl-bug` + sibling-repo
`MacLC_MiSTer:mame-ground-truth-maclc`.)

`trace …,maincpu` of MAME's bank-scan, diffed against our FPGA `cpu_trace.log`, shows
the **first divergence at the `$A03124` loopback test**:

```
            MAME                              OURS
$A0313A cmp.b (A2,D2.l),D1  reads $F21C00     reads $F21C00
   MAME: $F21C00 = $00  -> $00 vs $FE  NEQ    OURS: reads == D1 ($FE)  -> EQUAL
$A0313E bne $a03144        TAKEN               FALLS THROUGH to $A03140
```

MAME's captured values (`loopback_vals.lua`): writes `$FF`/`$01` to `$F01C00` (VIA1
reg $C / PCR, which reads back the device value), but **`$F21C00` reads a clean `$00`**
every time — it is *unmapped and separate*. Our core's `$F21C00` instead returns the
written/aliased pattern (so the byte equals `D1`), making the loopback see **false
aliasing at stride `$20000`** → wrong `d0/d1` → wrong RAM-enumeration path → null table.

Our `addrDecoder.v` correctly decodes `$F21C00` (`address[19:12]=$21`) to
`default: selectUnmapped`, and `dataController_top.sv:304` muxes `16'hFFFF` for
`selectUnmapped` — but the CPU does NOT see `$FF` there (it sees the aliased pattern).
So the bug is that **our unmapped I/O read does not actually deliver a distinct constant
to the CPU** (stale/last-bus-value or a missing-DTACK read), unlike MAME's clean `$00`.

### CORRECTION (2026-06-16) — it's a CPU bug, not the chipset value
A `[LOOPBACK]` detector (`sim_main.cpp`, logs `debug_cpuDataIn` at the `$F_1C00`
loopback addresses) shows our core **reads `$F21C00 = $00`** (`din=00000000`) — exactly
like MAME. So the read value is CORRECT; the unmapped-value theory above is WRONG.

```
pc=003128 addr=F21C00 RW=1 din=00000000   ; $A03124 tst.b reads $F21C00 = $00
pc=00313E addr=F21C00 RW=1 din=00000000   ; $A0313A cmp.b reads $F21C00 = $00
```

`D1=$FE` at `$A0313A` is deterministic (`st`→`$FF`, neg→`$01`, add→`$02`, neg→`$FE`), so
`cmp.b $00,$FE` is unambiguously **not-equal** → the `bne` MUST be taken (it is in MAME)
— but our core **falls through**. With correct operands AND a correct read, the only
thing left is the CPU: the `cmp.b`/`Bcc` at `$A0313A`/`$A0313E` mishandles the flags (a
**flag-commit-vs-branch race** / stale-flag), the SAME CLASS as the documented `tg68k`
`cmp.l (An)` race fixed on the OLD core in `MacLC_MiSTer` `42ae7a6` (`ld_An1` defer) but
NEVER ported to our `030_LCii` TG68K.C 030_mmu core. Confirms the dev's CPU instinct.

### Fix direction
Audit the 030 kernel's `cmp`/`Bcc` flag-commit timing for the analogous race (the
`(An)`/EA immediate-read path pushing the flag commit one cycle late so the following
`Bcc` samples stale flags), and port the `ld_An1`-style one-cycle defer. To confirm the
exact mechanism, expose the kernel's flags (`debug_FlagsSR`/`exe_condition` are internal,
`=> open` at `TG68K.vhd:507` — wire them up like the old-core debug did) and watch
`Z`/`cond` across `$A0313A→$A0313E`. Fixing it fixes the enumeration, slow POST, crash.

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
