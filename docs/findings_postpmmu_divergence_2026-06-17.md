# Findings: LC II post-PMMU divergence — MAME-validated downstream bug

**Date:** 2026-06-17   **Branch:** `030_LCii_rebased`
**Supersedes the open question in** `handoff_lcii_resume_2026-06-16.md` ("find the
NEXT downstream blocker") and confirms the dev's instinct in
`handoff_lcii_boot_postpmmu_2026-06-15.md` ("something else is wrong, not just slow").

## LATEST / MOST ACCURATE (2026-06-17, MAME A7/PC diff) — read this first

Two earlier root-cause framings in this doc are WRONG and kept only for history:
the "missing I-cache" framing and the "stack-pointer overlaps `$c04/$c08`" framing
(the latter relied on the cpu_trace `@`-annotation, which is buffered/lagged and does
NOT reliably show SP). What actually holds, verified by a per-frame PC+A7 diff of our
core vs MAME (`verilator/mame/pc_sp_hb.lua` vs our `--heartbeat` fullpc/a7):

- **Confirmed working:** 68030+PMMU through MMU-enable (walks succeed, NO fault), the
  video path (our screen == MAME's pre-desktop uniform-127), Egret, chime.
- **A7 is NOT the bug:** our A7 relocates `$2600 → $7FFx → $1CFExx → $1FF3xx` — i.e.
  the post-MMU stack relocation to high RAM — which MAME does **identically**
  (MAME A7: `$2600 → $7FFx → $1CFEE2 → $1FF3xx → $20FDxx`). Same trajectory.
- **The real divergence is control-flow in the post-MMU continuation:** MAME runs it at
  the `$40Axxxxx` ALIAS (e.g. `40A0089E`, `40A07A5A`, `40A14908`); our core runs the
  same code at the bare `$00Axxxxx` (fullpc `00A41C2A`/`00A41AEE`, no `$40` bit) and
  then **derails** (`rts` in the `$a00910` routine returns to garbage `$00A0094A`
  instead of `$00A00130`) → `$0`/`$FFFFxx` wander → wedge. No bus fault is involved.
- **Open (the real remaining question):** WHY does our `rts` (in `$a00910`, reached from
  the `$00A0010E`/`$40A0010E` continuation) return to the wrong address? It is a
  control-flow/return divergence, tied to the `$40A`-alias vs `$00A` address handling.

### REFINED (2026-06-17) — our core strips the `$40` alias bit (A30) from the FETCH ADDRESS

- `debug_pc` (our heartbeat `fullpc`) = `last_fetch_pc` = the **address driven on the CPU
  bus** during a fetch (`verilator/sim.v:506,529`), NOT the `TG68_PC` register.
- Our fetch address is `$00Axxxxx` (e.g. `00A41AEE`); MAME's PC/fetch is `$40Axxxxx`
  (`40A0089E`, `40A07A5A`, …). So **our core drives `$00A` on the bus — the `$40` alias
  bit (A30) is stripped** — while MAME runs the `$40A` alias. The post-MMU boot is
  *designed* to run at the `$40A` alias (translated via the alias root entry); running it
  at the bare `$00A` (served by the bug-#3 grace's identity bypass instead of translating
  the alias) derails the control flow → the `$a00910` `rts` lands at `$00A0094A`.
- A7/SP is balanced+normal (bsr `SP=$1FF3C8` → rts `SP=$1FF3C4`, routine net-neutral), so
  it is NOT a stack/SP fault. (A stack-memory dump was inconclusive — the SDRAM word index
  for the high stack didn't account for the mapping; reverted.)

**CONFIRMED (2026-06-17): the `$40` bit is lost in the `TG68_PC` REGISTER — it's the CPU.**
Temporarily wired `debug_TG68_PC` out (`tg68k.v`→`emu`, reverted after) and compared per
frame to `last_fetch_pc`:
```
F152: busPC=00A41C2A  regPC=00A41C2C   (regPC=busPC+2 prefetch; BOTH bare $00A, no $40)
F153: busPC=00A41AEE  regPC=00A41AF0   (both $00A)
```
`TG68_PC` itself is `$00A41xxx` — two independent signals (the kernel's PC register and
the bus address) agree, so it is NOT a bus/glue/decode strip. `jmp (A2=$40A0010E)` set
`PC=$00A0010E`, dropping A30. `A2` is also inconsistent (`$40A0099C` vs `$00A40F4A`), so
some address loads keep the high bits and others strip them — i.e. the 68000→68030
conversion's 32-bit address handling is incomplete in the PC/EA paths. **The dev's
instinct was right: it's the CPU core, not the chipset.** (Tried to find a non-CPU cause
— bus mask, decode, a memory-stored pointer — every path routes back to a CPU
store/load/jmp masking the address.)

**Sub-question CLOSED. Remaining = the fix (NEXT):**
1. (answered: PC register, in the kernel)
2. The fix is then either (a) stop masking A30 in the PC/address path so the `$40A` alias
   *translates* like MAME, or (b) narrow the bug-#3 grace so the alias `jmp` target runs
   translated (not graced/identity at `$00A`). Shared `rtl/tg68k`; SST-bench + MAME re-check.

**Tooling walls hit (for the next session):** MAME's `-debug` trace **dies at `pmove tc`**
(`00A416B6: dc.w $ffff` is the last line) — it can't follow execution past MMU-enable, so
the MAME-side instruction trace of the continuation needs a Lua single-stepper, not
`trace.dbg`. The per-frame `pc_sp_hb.lua` DOES run past MMU (use it for register/PC diffs).

Repro for the A7/PC diff:
```
# ours: ./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom ../releases/boot0-fastmem.rom --stop-at-frame 156
#   -> grep '\[HB\]' ; fields: pc(masked) fullpc(32-bit) a7 a2
# MAME: HB_OUT=/tmp/mame_hb.txt SOUND=none verilator/mame/run_mame_maclc2.sh -skip_gameinfo \
#         -autoboot_delay 0 -autoboot_script verilator/mame/pc_sp_hb.lua -seconds_to_run 14
#   -> grep '\[MHB\]' /tmp/mame_hb.txt ; fields: pc a7  (MAME runs the $40Axxxxx alias)
```

## (OBSOLETE — kept for history) "stack-pointer overlaps $c04/$c08" framing — superseded; A7 matches MAME

**Supersedes the "missing I-cache" conclusion below (that was a mis-read of the HB).**
A cpu_trace of the fastmem derail (`--trace-frames 148,156`) shows the EXACT SAME
failure as nomemcheck:
```
00A0012C: bsr $a00910                 ; pushes return $00A00130 at SP = $000C06 (LOW RAM)
00A00910: feature-scan; reads D0=[$dd0], scans table @$a0094a, conditionally:
00A00936: move.l $c08.w,$c04.w        ; writes $c04-$c07  -> overwrites [$c06] (the return!)
00A00942: move.l $c04.w,$c08.w @000C06; writes $c08-$c0b  -> overwrites [$c06] (the other half)
00A00948: rts            @000C06       ; SP=$000C06 -> pops CLOBBERED return -> $00A0094A garbage
00A0094A: ori.b #0,D2 ; 00000000: ... ; 00000006: bls $ffffffa2  -> $FFFFxx wander (NOT a vector!)
```
**Mechanism:** our stack pointer is `SP=$000C06`, which **overlaps the `$c04-$c08`
low-memory globals** the `$a00910` routine writes, so the routine destroys its own
stacked return address → `rts` derails. The earlier "vector through `$8`" reading was
wrong: `pc=000008` in the HB was the CPU *executing through* low-mem garbage, not a
bus-error vector fetch. NO bus fault is involved (PMMU walks all succeed).

**Root:** `SP=$000C06` vs MAME's `SP=$2600` (set at `$00A4639A: movea.w #$2600,A7`).
Identical on fastmem AND nomemcheck, so it is a real bug, not a ROM-hack artifact, and
**NOT the I-cache / not the grace.** Both ROMs run the `$00A0010E` alias continuation +
`$a00910`; MAME's stack ($2600) clears the globals, ours ($c06) doesn't.

**NEXT (the real hunt):** find where our `A7`/SP becomes `$000C06` instead of `~$2600`.
Either (a) a control-flow divergence skips the `$00A4639A` SP-setup, or (b) a TG68
stack-pointer-select bug (USP/ISP/MSP per SR S+M bits) leaves the wrong A7 active. Get an
SP-per-frame trace (add A7 to the heartbeat, or trace the POST window) and compare to
MAME's SP through `$00A4639A`. The fix is likely small once located.

## (OBSOLETE — mis-read, kept for history) "missing I-cache" framing

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
