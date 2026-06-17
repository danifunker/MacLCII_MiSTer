# Findings: LC II post-PMMU divergence — MAME-validated downstream bug

**Date:** 2026-06-17   **Branch:** `030_LCii_rebased`
**Supersedes the open question in** `handoff_lcii_resume_2026-06-16.md` ("find the
NEXT downstream blocker") and confirms the dev's instinct in
`handoff_lcii_boot_postpmmu_2026-06-15.md` ("something else is wrong, not just slow").

## CONFIRMED REAL BUG (fastmem, 2026-06-17) — not a nomemcheck artifact

A fastmem run (faithful full-POST ROM, F700 cap) **also derails post-MMU**:
```
F150 pc=A4A452  (Egret/ADB region)  F152 pc=A41C2A  F153 pc=A41AEE  (MMU descriptor region)
F154 pc=FFFFDE  (derail to high mem)  ...  F161 pc=000008  (the BUS-ERROR vector $8) ... $FFFFxx wedge
```
So the bug is REAL on the faithful ROM. **Unified root cause:** post-MMU the boot executes
`$00Axxxxx` ROM code that is logically **unmapped** (root table-desc limit=9). Real HW /
MAME serve it from the 68030 **I-cache** (enabled by `movec D5,CACR` just before
`pmove(A3),tc`); our uncached TG68 re-translates → **limit fault** → (VBR=0) vector
through zeroed `$8` → `$FFFFxx` → `$7FF8` wedge. The bug-#3 grace only covers the single
MMU-enable page (`$00A`) until execution leaves it; the *extended* post-MMU ROM routine
(descriptor parse `$A41Axx-$A41Dxx`) faults once the grace disarms. (nomemcheck derails
too, but to low RAM via a clobbered `rts` — same post-MMU-unmapped-ROM problem, different
surface, compounded by its skipped SP-setup.) **MAME runs the same `$A41Dxx` descriptor
code straight through from I-cache.**

**FIX direction (shared `rtl/tg68k`):** make post-MMU instruction fetches of the
cache-resident ROM routine bypass translation — either (a) broaden the grace to cover the
whole post-MMU ROM execution window (not just one page until first branch-away), or
(b) model enough of the 68030 logical I-cache to serve fetches that hit unmapped logical
ROM after the cache was filled MMU-off. Sync to MacIIvi, gate on its SST bench.

## Bottom line

The 68030 + PMMU works through the cache/MMU-enable stage (no traps, no derail, no
`$7FF8` wedge). But there IS a real downstream bug: **after MMU-enable our core
diverges into low RAM and never reaches the boot-device screen.** Proven by a
direct MAME comparison on the *same* ROM.

## The MAME comparison (ground truth)

MAME `maclc2` 0.288, our nomemcheck ROM split into the 4 chips (interleave
**byte0..3 = hh,mh,ml,ll**, confirmed by reconstructing `releases/boot0.rom` =
genuine LC II ROM):

- **MAME boots our nomemcheck ROM cleanly to the blinking "?" floppy icon** (no
  boot disk) by ~video-frame 900. Screenshot: light-gray desktop + mouse cursor + `?`.
- **MAME runs the post-MMU boot ENTIRELY from ROM** `$00A4xxxx` (1.26M instrs in a
  6 s trace; **0** instrs in `$40xxxxxx` alias; only 198 in low RAM `$0000xx`).
  At 6 s it is parsing memory/page descriptors in a `$00A41Dxx` loop (`bfextu`/`cmp`
  on bitfields), then continues in ROM.
- The `$00A41B52` jump-table dispatcher (`jmp ($2,PC,D5.w)`) resolves to **`$00A41B66`
  (ROM)** in MAME.

Our core, on the identical ROM:

- chime `$A45E40` (F49-94) → MMU-enable `$A416xx`/`$A41B54` (F95-96) — matches MAME's code.
- **then drops into low RAM `$0002AA-$002364` and stays there** (156+ consecutive
  frames), running a multi-pattern memory **march** (`ffff`/`0000`/`409f`, ~3500
  writes/frame, ~1.3M writes, address marching *down* `$1fe000→$1ae000`), then drifts
  down to the `$0000xx` vector-table region. **Never returns to ROM, never reaches `?`.**
  Screen stays uniform startup-gray through F1000.

**MAME never executes our low-RAM march range (`$000200-$002400`): 0 hits.** This is
the divergence.

## The "dots" ARE expected on LC II — and our video path is CORRECT

The LC II desktop background IS a 1-pixel black/white **checkerboard** ("dots"); a
downsampled 640x480 snapshot aliases it to flat gray, which fooled an earlier read of
these screenshots. Pixel analysis (center 30x30) settles it:

| frame | MAME (real ROM) | our core |
|---|---|---|
| 150, 300 | **uniform luma 127** | uniform luma 127 ✅ (byte-identical) |
| ~360 (MMU-enable) | — | diverges to low RAM |
| 450, 600, 750, 900 | **CHECKERBOARD (luma 0 + 255, ~50/50)** | uniform 127 forever |

So MAME draws the checkerboard **right around/after MMU-enable (between video-frame
300 and 450)**. Before that MAME shows the *exact same uniform-127 gray our core shows*
— i.e. **our video path renders correctly** (matches MAME's pre-desktop state). The
missing "dots" are NOT a video bug: our CPU diverges post-MMU and never reaches the
post-MMU desktop-fill. The real target is the checkerboard desktop (then the `?` icon).

## EXACT mechanism (PMMU_TRACE + cpu_trace, confirmed 2026-06-17)

**It is NOT a bus fault.** All 18 PMMU walks at MMU-enable succeed; the only
`trap_berr`s are early (`$00a03a92`, pre-MMU — the boot's normal hardware probes).
It is a **control-flow derail** from a clobbered return address:

```
00A416B6: jmp (A5)  ->  00A0010E         ; A2 alias continuation ($40A0010E ≡ $00A0010E)
00A0010E: ... ; 00A0012C: bsr $a00910    ; return $00A00130 pushed at SP (~$000C06, LOW RAM)
00A00910: feature-scan; manipulates low-mem globals $c04/$c08
00A00936: move.l $c08.w,$c04.w           ; writes $c04-$c07  -> OVERWRITES [$c06]
00A00942: move.l $c04.w,$c08.w  @000C06   ; writes $c08-$c0b  -> the stacked return addr
00A00948: rts             @000C06         ; SP=$000C06 -> pops CLOBBERED return -> garbage
00A0094A: ori.b #0,D2                     ; runs the data table as code
00000000: ...                             ; DERAIL -> low-RAM march -> stuck, gray
```

The stack (`SP≈$000C06`) **overlaps the `$c04-$c08` low-mem globals** the routine writes,
so the routine destroys its own return address. MAME does NOT hit this: it sets
`SP=$2600` at `$00A4639A` (`movea.w #$2600,A7`, in the POST region) and runs a different
post-MMU path; in MAME's 6 s window it executes `$00A4639A` but **never** `$00A0010E`
(its MMU-enable is ~frame 360, the continuation comes later). Our core, by contrast,
**never executes `$00A463xx` (the POST/SP-setup)** in the post-MMU window and reaches the
continuation with the low/overlapping SP.

**Leading interpretation:** the `nomemcheck` warm-skip bypasses the POST SP-setup
(`$00A4639A movea.w #$2600,A7`) that the continuation relies on; MAME tolerates it
(its SP is valid from elsewhere), our core doesn't → derail. **This may be a
`nomemcheck` *artifact*, not a bug that hits the real/stock boot.** MUST confirm on
stock/fastmem (long sim) before treating it as the real downstream blocker. If it
reproduces on stock, the divergence is upstream (where our SP/path first differs from
MAME through the POST) — trace BOTH from reset through `$00A4639A` with aligned windows.

## (Earlier hypothesis — now refined by the above)

On real HW / MAME the post-MMU ROM routine executes from the **68030 instruction
cache** (enabled by `movec D5,CACR` just before `pmove (A3),tc`); logical `$00Axxxxx`
is intentionally **unmapped** (root table-desc limit=9, maps only `$000-$009FFFFF` +
the `$40xxxxxx` alias), so an uncached refetch would limit-fault.

The bug-#3 fix added an instruction-prefetch **grace** (TG68KdotC_Kernel.vhd ~L1071-1127)
that bypasses translation for fetches in the **single 1MB page** the CPU was in at
MMU-enable (`$00A`), disarming on the first fetch that leaves that page. Two ways this
still breaks downstream:

1. **Fault path:** the grace disarms (a fetch leaves page `$00A`, e.g. `jmp (A5=A2=$40A0010E)`),
   then a later `$00Axxxxx` fetch translates → limit-fault → BERR. With VBR=0 the
   vector-2 fetch goes through zeroed `$08` → PC=0 → executes low RAM. (This is the
   exact bug-#3 symptom; the grace only postponed it one page.)
2. **Mis-jump path:** a computed/register value differs from MAME so the dispatcher/jmp
   targets low RAM directly (no fault).

No `trap_berr` was seen — BUT that logging is gated behind `+define+PMMU_TRACE`, which
was OFF in these runs, so "no fault" is NOT yet established. **Next step: enable
PMMU_TRACE, rebuild -Os, run nomemcheck to ~F110, grep `PMMU (make_berr|trap_berr|REQ)`
around F96.** If it faults → the real fix is to model enough of the 68030 I-cache (or a
broader grace) so the *entire* post-MMU ROM routine runs without re-translating
unmapped `$00Axxxxx`. The fix lives in the **shared** `rtl/tg68k` core (sync to
`../MacIIvi_MiSTer`, gate on its SingleStepTests bench).

## Tooling added this session (sim-only, in `verilator/`)

- `--rom <path>` (sim_main.cpp) — boot any ROM without clobbering shared `boot0.rom`.
- `--heartbeat` (sim_main.cpp) — per-frame 68k PC print (progress without `--verbose` flood).
- `EGRET_VERBOSE` gate (egret_wrapper.sv) — silences the ~92k-line/run HC05 idle spam
  (`COMM`/`SESSION` handlers + TIP dump); opt-in via `+define+EGRET_VERBOSE`.

## Build-speed gotcha (cost real time)

Plain `make` compiles the Verilated model at **`-O0` → ~15× slower** (a boot crawls and
looks hung). The repo `make fast` target uses **GCC-only `-f` flags that crash clang on
macOS**. Workaround that restores ~0.5 fps:
```
make                                  # re-verilate
cd obj_dir && rm -f *.o *.gch && make OPT_FAST=-Os OPT_SLOW=-Os -f Vemu.mk
```
(Consider fixing the `fast` target to use plain `-Os`/`-O2` on clang.)

## Repro

```bash
# our core (needs the -Os binary above):
cd verilator
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat \
  --rom ../releases/boot0-nomemcheck.rom --screenshot 400 --stop-at-frame 401 > x.log 2>&1
grep '\[HB\]' x.log    # PC stuck in 00xxxx low RAM after ~F97

# MAME on the same ROM (chips: byte0..3=hh,mh,ml,ll into /tmp/patchroms/maclc2/;
#   egret 341s0850.bin copied into the egret rompath):
ROMPATH="/tmp/patchroms;/private/tmp/goodroms" SOUND=none \
  verilator/mame/run_mame_maclc2.sh -debug -debugscript verilator/mame/trace.dbg -seconds_to_run 6
grep -c '^00A4' /tmp/maincpu.tr   # ~all; grep -cE '^0000(0[2-9A-F]|1|2[0-3])' = 0
```
NB: 68020 opcode-PC breakpoints don't fire (prefetch) — use full `trace.dbg`, not `bpset`.
