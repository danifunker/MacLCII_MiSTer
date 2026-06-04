# RESUME — MacLC boot: VIA-timer POST FIXED (boot now F1454, no STM); next blocker = $A009CE register-poll loop; plus 3 hardware-fidelity checks (2026-06-03)

Branch `new-video-on-fix-egret` (local, **don't push**). Build rules: `CLAUDE.md`.
Memory: [[pseudovia-irq-ier-fix]], [[phantom-bank-simm-physical-fix]],
[[ram-config-2mb-vs-10mb]], [[moves-berr-fix-landed]],
[[verilator-top-is-sim-v]], [[mame-ground-truth-maclc]], [[feedback-sim-foreground]].
Refs: `docs/post_diagnostics_and_irq_levels.md`, `docs/diagnostic_mode_reference.md`.

Focus = **2MB config only** (`configRAMSize=$24`). 10MB ($E4) unverified — see
[[ram-config-2mb-vs-10mb]].

## What was fixed this session (committed)
**`bb47b54` fix: gate pseudovia IRQ by main IER ($13); ASC is IFR bit4.** The VIA1
Timer-1 interrupt-timing POST self-test (`$A47170-$A471C6`) was failing into STM
(`$A498xx`). Root cause: pseudovia (level 2) asserted a continuous spurious IRQ
that preempted the level-1 VIA1 timer the test counts. Two deviations from MAME
`pseudovia_recalc_irqs()`: (1) `asc_irq` was folded into `slot_status[4]` (gated
by slot IER `$12=$7f`) instead of being IFR bit 4; (2) `irq_out` ignored the main
IER `$13`. Fix: remove ASC from `slot_status`; `irq_pending = |(ifr_live & ier &
8'h1B)`. VERIFIED: ISR `$A472CC` runs (0→346×), test passes via `$A471C6`, no
`$A462AA`/STM anywhere, **boot now runs to frame 1454** (was 360); frame 350 shows
an active video test pattern. The prior resume's "$0 vector table unmapped" theory
was WRONG — the LC is a 68020 and TG68K uses VBR correctly (`use_vbr_stackframe =
CPU[0]`, `cpu=11`).

`d2afbde` / `7c90a81` docs only (diagnostic-mode reference + old resume).

## THE NEXT BLOCKER (open) — infinite poll loop at $A009CE (F1454)
At F1454 the core is stuck in this loop (MAME passes it in **ONE** iteration):
```
A00134: bsr   $a009c0
A009C0: btst  #$5, $dd3.w        ; low-mem flag $DD3 bit 5
A009C6: beq   $a00a04            ; (rts) if clear — MAME path may differ here
A009C8: movea.l $1e0.w, A0       ; A0 = low-mem global $01E0  (a VIA-style base)
A009CC: moveq #$17, D0
A009CE: move.b #$be, ($c00,A0)   ; reg 6  (offsets are $200-spaced VIA regs)
A009D4: move.b #$f8, ($c00,A0)   ; reg 6
A009DA: tst.b ($1c00,A0)         ; reg 14
A009DE: tst.b ($1000,A0)         ; reg 8
A009E2: tst.b ($1a00,A0)         ; reg 13
A009E6: move.b ($1c00,A0), D2    ; reg 14 -> D2
A009EA: btst  #$5, D2            ; test bit 5
A009EE: bne   $a009ce            ; LOOP while bit5 set   <-- WE SPIN HERE
A009F0: and.b D0, D2
A009F2: cmp.b D0, D2
A009F4: beq   $a00a00
```
Facts gathered:
- Our data address in the loop is `@50F17C00`, so **A0 = `$50F17000`**. Our
  `addrDecoder.v` routes `$F16000-$F17FFF` to **`selectIWM`** (SWIM/IWM, the
  floppy controller). The $200-spaced "VIA register" access pattern at a SWIM
  base is suspicious.
- MAME hits `$A009CE` exactly **once** (`grep -c "^00A009CE:" /tmp/mame_pc.tr` = 1)
  then falls through to `$A009F0/F2` — i.e. on MAME's first read, `($1c00,A0)`
  **bit 5 is already CLEAR** so the `bne` is not taken.
- This is reached via the boot's disk/IWM path; it may be near the EXPECTED
  floppy "?" loop, but our IWM/SWIM stub leaves the polled bit stuck → hard spin.

### NEXT STEP (decide between two hypotheses)
1. **Wrong base in `$01E0`** — does MAME's A0 also equal `$50F17000`? If MAME's
   `$01E0` points elsewhere (e.g. the real VIA1 `$50F00000` or SWIM at a different
   offset), our peripheral-init wrote the wrong base. Tap MAME: read low-mem
   `$01E0` and `$0DD3` just before `$A009C8`, and dump A0 at `$A009CE`.
2. **Right base, stuck status bit** — if MAME's A0 is also `$50F17000`, then our
   device there returns reg-14 bit 5 = 1 forever while MAME returns 0. Identify
   the device (IWM/SWIM vs something V8 maps differently than our decoder) and
   make the polled bit read back like MAME (likely a SWIM handshake/sense line).

Concretely: in MAME run a debugscript that watchpoints `$A009C8`/`$A009CE`, prints
`A0`, `dword($1e0)` (sign-extended .w), `byte($dd3)`, and `byte(A0+0x1c00)`. Then
compare to our Verilator probe (log `tg68_a`, `dataControllerDataOut` on the read
of `A0+$1c00`, and which `selectXXX` fires).

## CHECKS REQUESTED (hardware-fidelity thread comments)
A reviewer flagged the three classic LC early-boot hang-ups. Verify each against
the current core; fold findings into `docs/post_diagnostics_and_irq_levels.md`.

### 1) Egret (68HC05) must exist or it won't chime
- Status: present. RTL: `rtl/egret/egret_wrapper.sv`, `rtl/egret.sv`,
  `rtl/egret/m68hc05_core.sv` (+ behavioral `rtl/egret_behavioral.sv`).
  `USE_EGRET_CPU` selects real HC05 vs behavioral (Makefile/QSF). Egret protocol
  is RESOLVED (see [[pseudovia-irq-ier-fix]] history; 68 txns, boot proceeds).
- CHECK: confirm chime path actually runs — does the ASC get programmed and does
  the boot reach the sound/`*APPLE*` startup? Verify Egret real-HC05 build
  (`USE_EGRET_CPU`) still boots to F1454 like the behavioral one (sim default).
  Watch the VIA SR caveat in `CLAUDE.md` — re-verify frame-350 screenshot after
  ANY `via6522.sv` SR change. Do NOT re-add `cb2_latched`/`ext_fall_edge_pending`
  reasoning blind.

### 2) V8 bank-sizing registers must behave or memory sizing "gets angry fast"
- Status: addressed. `addrDecoder.v:81-99` sizes the SIMM from the **physical**
  config (`ram_config_phys`, = top-level `configRAMSize`), NOT the ROM-written
  pseudovia reg — see [[phantom-bank-simm-physical-fix]] (commit `0b57f5e`). The
  `ram_configured` latch (pseudovia) gates the `$0` motherboard mirror until the
  ROM programs the V8 config (MAME-faithful, [[candidate-b-phantom-bank-fix]]).
  Bits `[7:6]`: 00=0MB, 01=2MB, 10=4MB, 11=8MB SIMM.
- CHECK: re-validate the descriptor table is still single-entry `{$800000,
  $200000}` @ `$9FFFEC` and the march completes with no clobber on the CURRENT
  build (the IRQ fix shouldn't have touched this, but confirm). For 10MB ($E4)
  validate against `mame -ramsize 10M` + `v8.cpp ram_size()` before trusting
  `ram_config_phys` there (MAME: `m_baseIs4M`, `simm_sizes[4]={0,2M,4M,8M}`).

### 3) 24/32-bit switch (blocks A31 from the '020 in 24-bit mode) — LIKELY GAP
- Status: **no explicit 24/32-bit / A31 logic found** anywhere (`grep -rni
  "a31|\[31\]|24.bit|32.bit|mode32"` → nothing in `addrController_top.v` /
  `addrDecoder.v` / `MacLC.sv`). `sim.v` carries `cpuAddr[31:0]` but the decoder
  only ever looks at `address[23:0]`, so the core is effectively ALWAYS 24-bit.
- Reviewer's note: "the 24/32 switch just blocks the A31 line from the '020 for
  24-bit mode. The motherboard ignores A24-A30 (NOT A31 if enabled); most of those
  lines are available to PDS cards."
- CHECK: (a) Find how V8 exposes the 24/32-bit mode bit (MAME v8.cpp — look for a
  config/overlay reg that gates A31; note `m_overlay` is the ROM overlay, a
  different thing). (b) Decide whether our always-24-bit decode is sufficient for
  the LC boot + System (LC ships 24-bit by default; A/UX & 32-bit-clean apps need
  32-bit). (c) If the boot ever drives A31=1 expecting a 32-bit window, our decode
  would alias it into the 24-bit map — confirm `cpuAddrFullHi`/`HIGH_ADDR` probe
  (sim.v) never fires during a healthy boot. This is the most likely *future*
  hang once past the SWIM loop; document the gap even if not fixing now.

## MAME ground truth (how to)
```
cd /Users/dani/repos/mame && /opt/homebrew/bin/mame maclc -rompath /private/tmp/goodroms \
  -ramsize 2M -debug -debugscript /tmp/t.cmd -seconds_to_run 8 -nothrottle -video none -sound none
# /tmp/t.cmd:  trace /tmp/mame_pc.tr,maincpu   then   go
```
- macOS has **no `timeout`** — rely on `-seconds_to_run`. Run MAME directly.
- 68020 opcode-fetch **taps do NOT fire** (prefetch/cache); use a debugscript
  `trace` (8-digit `00A0xxxx:` PCs) or `bp ADDR,1,{printf ...; go}`.
- Existing trace at `/tmp/mame_pc.tr` (Jun 3) covers this boot; reuse it.
- Confirmed: `$A009CE` hit 1× in MAME; ISR `$A472CC` 4× (D4/D5, not all D3); MAME
  never hits `$A462xx`/`$A498xx`.

## Build / run / gotchas
- Verilator builds `verilator/sim.v` (module emu), NOT MacLC.sv — duplicate
  CPU/bus logic, keep in sync. [[verilator-top-is-sim-v]].
- `cd verilator && make && ./obj_dir/Vemu --stop-at-frame N` (foreground only;
  run once, analyze `verilator/cpu_trace.log`). [[feedback-sim-foreground]].
- Frame-350 screenshot must show the video test pattern (orange dither + grey
  band), not black/uniform — current PASS after the IRQ fix.
- VHDL is source of truth for the CPU → `cd rtl/tg68k && ./convert_to_verilog.sh`
  only if touching it.
- Probing inlined nets: reference them to keep un-inlined. Useful:
  `emu__DOT__pseudovia_irq`, `emu__DOT__dc0__DOT__viaIrq`,
  `emu__DOT__pvia__DOT__{ifr,ier,slot_ier}`, `emu__DOT__cpuFC`,
  `emu__DOT__fc7_iack`, `emu__DOT__pvia_ram_configured`.

## Done-when (next session)
- Determine whether `$01E0`/A0 base matches MAME at `$A009C8`; either fix the
  base or make the polled SWIM/IWM bit-5 read back like MAME so `$A009CE` runs
  once and falls through (no spin).
- All three fidelity checks above answered in writing (Egret chime path verified;
  bank-sizing table re-confirmed; 24/32-bit/A31 gap characterized).
- Boot proceeds toward the floppy "?" loop / desktop; screenshot the result.
