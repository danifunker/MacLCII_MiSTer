# RESUME PROMPT — Mac LC II boot: post-MMU derail ROOT-CAUSED to the CPU (32-bit addr)

**Date:** 2026-06-17   **Branch:** `030_LCii_rebased` (MacLC_MiSTer)
**Read first:** this file, then the **"LATEST / MOST ACCURATE"** section at the top of
`docs/findings_postpmmu_divergence_2026-06-17.md` (that doc also keeps two SUPERSEDED
framings — "missing I-cache" and "SP-clobber" — for history; ignore them).

> Paste-to-resume: *"Resume the Mac LC II 68030 boot. The post-MMU derail is root-caused
> to the CPU: the shared TG68 '030 kernel drops the $40 ROM-alias bit (A30) from the PC/EA
> — `jmp (A2=$40A0010E)` sets `TG68_PC=$00A0010E` (verified: regPC==busPC==bare $00A). The
> boot's $40A alias execution collapses to the unmapped $00A and derails; that's why no
> desktop checkerboard. PMMU walker, video, Egret, chime, A7/SP are all confirmed correct.
> Implement the fix: make the '030 PC/jmp/EA paths keep the full 32-bit address (stop
> masking A30) so the $40A alias TRANSLATES like MAME. Core is shared with
> ../MacIIvi_MiSTer/rtl/tg68k — fix here, re-copy, gate on its SingleStepTests bench.
> Start by reading docs/handoff_lcii_resume_2026-06-17.md."*

---

## State in one paragraph

The 68030+PMMU boots through cache+MMU-enable (walks succeed, NO fault), the V8 video
path is byte-correct (our screen == MAME's pre-desktop uniform-127), and Egret/chime
work. The remaining blocker is a **CPU bug**: the shared TG68 '030 kernel's 32-bit
address handling is incomplete — `TG68_PC` (and some EA/register loads) **drop the A30
"$40" alias bit**. After MMU-enable the boot `jmp`s to the **$40A ROM alias** (the page
tables map $40xxxxxx → ROM; $00Axxxxx is intentionally unmapped, root table-desc
limit=9). Our CPU collapses that to the bare **$00A**, which only survives via the bug-#3
grace's identity bypass — so it runs at the **wrong logical address** and derails (the
`$a00910` routine's `rts` lands at `$00A0094A` → `$0`/`$FFFFxx` wander → wedge), never
reaching the post-MMU desktop-fill (hence "no dots"). **Next task: fix the 32-bit PC/EA
addressing in `rtl/tg68k`.**

## The fix (the actual next task)

Make the MC68030 keep the **full 32-bit address** on the PC / `jmp (An)` / EA-load paths
(do not mask A30 / 24-bit). Target: `jmp (A2=$40A0010E)` must set `TG68_PC=$40A0010E`, so
the PMMU translates the $40A alias root entry → physical ROM (exactly as MAME does), and
the boot runs the alias instead of the bare $00A.
- Find where the kernel masks the PC/address. `TG68_PC` is `std_logic_vector(31 downto 0)`
  (`TG68KdotC_Kernel.vhd:330`) so the *register* is 32-bit; the strip is in a PC-load /
  EA-compute path (likely a cpu-type-gated mask, or a path that only widened to 24-bit for
  the 68000). A2 is also inconsistently masked ($40A0099C vs $00A40F4A across frames), so
  more than one path is affected — fix them coherently.
- Once the alias runs translated, the **bug-#3 prefetch grace may become unnecessary**
  (it was a band-aid for the same unmapped-$00A access); re-evaluate / consider removing
  it once A30 is preserved.
- VALIDATE: (a) MacIIvi `SingleStepTests/tg68k` bench (gate: no ISA regression vs the
  714/719 baseline, 5 known PRM-CCR diffs); (b) re-run the MAME A7/PC diff (below) — our
  post-MMU PC trajectory should now match MAME's `$40Axxxxx` and reach the checkerboard.
- Core is shared: after the fix, re-copy the 8 tg68k files to `../MacIIvi_MiSTer` and
  regenerate (`rtl/tg68k/convert_to_verilog.sh`, ghdl 6.0.0); `diff -q` clean.

## Solid / do NOT re-litigate (all verified this session)

- **It IS the CPU, not the chipset.** Wired `debug_TG68_PC` out (reverted after): regPC
  and busPC AGREE at bare `$00A41xxx` — the PC register itself drops the $40 bit.
- **NOT a bus fault** (PMMU walks at MMU-enable all succeed; trap_berrs are early/pre-MMU
  hardware probes only).
- **NOT the I-cache and NOT the grace** per se (those were earlier WRONG framings).
- **NOT the stack/SP.** A7 relocates `$2600→$7FFx→$1CFExx→$1FF3xx` IDENTICALLY to MAME;
  bsr/rts SP is balanced. (The "SP overlaps $c04/$c08" reading relied on the buffered
  cpu_trace `@`-annotation, which does NOT show SP — disproven.)
- **Video path is correct** (matches MAME pre-desktop). **There ARE "dots"** on LC II —
  the desktop is a 1px black/white checkerboard, drawn post-MMU; we just never reach it.
- **Egret/VIA SR, PMMU walk-stall, bug-#3 prefetch grace** — all still fixed/solid.

## How to run / debug (gotchas that cost time)

- **Run from `verilator/`.** Build is slow unless optimized: plain `make` = `-O0` (~15×
  slower, looks hung). `make fast` uses GCC flags that **crash clang on macOS**. Use:
  ```
  cd verilator && make && cd obj_dir && rm -f *.o *.gch && \
    make OPT_FAST="-Os" OPT_SLOW="-Os" -f Vemu.mk
  ```
- **ROM via `--rom` (don't clobber `releases/boot0.rom`, which is stock):**
  `./obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom ../releases/boot0-fastmem.rom --stop-at-frame 156`
  - fastmem reaches MMU-enable ~F152 and derails to `$FFFFxx` by F154 (the repro).
  - `--heartbeat` prints `[HB] F.. pc fullpc a7 a2` (per-frame). To also see the PC
    REGISTER, re-add the temp `debug_TG68_PC` wiring (see the findings doc; revert after).
  - `+define+EGRET_VERBOSE` gates the ~92k-line/run HC05 idle spam (off by default).
- **CAP sims at ≤700 frames** (dev constraint; ~0.5 FPS, no `timeout` on macOS).
- **MAME oracle:** `verilator/mame/pc_sp_hb.lua` gives per-frame PC+A7 and **runs PAST
  MMU-enable** (use it for the diff). The `-debug`/`trace.dbg` instruction trace **DIES at
  `pmove tc`** (can't follow past MMU-enable) — use a Lua single-stepper if you need
  MAME's post-MMU instruction stream. MAME runs the continuation at `$40Axxxxx` and reaches
  the `?` floppy screen; chips: byte0..3 = hh,mh,ml,ll into `/tmp/patchroms/maclc2/`, egret
  `341s0850.bin` in the rompath. See the findings doc Repro block.

## Key addresses
- MMU-enable: `$A41682 movec CACR`; `$A416B2 pmove (A3),tc`; `$A416B6 jmp (A5)`.
- Continuation (the alias): `$40A0010E` ≡ bare `$00A0010E`; `bsr $a00910` @ `$00A0012C`
  (return `$00A00130`); the derailing `rts` @ `$00A00948` → `$00A0094A` (garbage).
- Page tables: alias `$40xxxxxx` mapped; `$00Axxxxx` (index 10) unmapped (limit=9); VBR=0.

## Commits this session (on `030_LCii_rebased`)
- `57e20a6` verilator `--rom`/`--heartbeat` + `EGRET_VERBOSE` gate
- `235adc3` heartbeat fullpc/a7/a2
- `a10754d`→`32a36fe`→`723793b`→`e5328f3`→`fe1130c` findings (later commits CORRECT the
  earlier ones; `fe1130c` = the confirmed CPU root cause). Plus `verilator/mame/pc_sp_hb.lua`.
- Working tree clean; `boot0.rom` stock; diagnostic `debug_TG68_PC` wiring reverted.
