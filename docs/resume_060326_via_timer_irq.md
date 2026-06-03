# RESUME — MacLC boot: march-clobber FIXED; next blocker = VIA Timer-1 IRQ POST test (post-march $0 never re-mapped) (2026-06-03)

Branch `new-video-on-fix-egret` (local, **don't push**). Build rules: `CLAUDE.md`.
Memory: [[phantom-bank-simm-physical-fix]], [[ram-config-2mb-vs-10mb]],
[[moves-berr-fix-landed]], [[candidate-b-phantom-bank-fix]],
[[verilator-top-is-sim-v]], [[mame-ground-truth-maclc]], [[feedback-sim-foreground]].

Focus = **2MB config only** (`configRAMSize=$24`). 10MB ($E4 = 2MB board + 4MB+4MB
SIMM) is unverified — see [[ram-config-2mb-vs-10mb]], validate vs `mame -ramsize 10M`
later.

## What was fixed this session (committed)
**`0b57f5e` fix: size SIMM from PHYSICAL config, not the ROM-written reg.** Resolves
the march-clobber HANG that was the prior resume's open blocker (`docs/
resume_060326_phantombank.md`). Root cause: `addrController_top.v`/`addrDecoder.v`
decoded `simm_byte_size` from the ROM-written pseudovia reg (`pvia_ram_config_out`),
which transiently = `$C4` (bits[7:6]=11 ⇒ "8MB SIMM") during the RAM probe → fabricated
a phantom 8MB SIMM at `$0` → `$0` routed to the SIMM SDRAM region ($100000+) as a
SEPARATE bank instead of a true `$800000` mirror → bank scan recorded a phantom `$0`
descriptor → march clobbered `$9FFFEC`. FIX: new `ram_config_phys` input (= top-level
`configRAMSize`) used for SIMM sizing in both files; also wired `pvia_ram_configured`
into `sim.v`'s addrController (was unconnected). VERIFIED: descriptor table now SINGLE
entry `{$800000,$200000}` @ `$9FFFEC`, SP=`$807FFC`, march `$800000→$9FFFEC` with NO
clobber, no hang — matches `mame maclc -ramsize 2M`.

`f8fcf95 docs:` clarified the 10MB config wording (cosmetic).

## Clarification (the "STM" is not one bug)
STM = the ROM's POST self-test **failure-reporting** path (`$A498xx`). ANY failed
subtest jumps there. Last session fixed the FIRST STM (MOVES/pseudovia-A0) and reached
the RAM-test screen, then ended on the march-clobber HANG (no STM). This session fixed
the hang; the boot now progresses FURTHER and hits a NEW, later STM at F276 from a
DIFFERENT test. Not a regression — forward progress.

## THE NEXT BLOCKER (open) — VIA Timer-1 interrupt POST test fails at F276
Boot now reaches the **VIA1 Timer-1 interrupt-timing self-test** at `$A47170-$A471AC`
(configures ACR for T1 continuous, IER=`$e2` enabling T1, starts T1/T2; ISR at
`$A472CC` increments D3 per level-1 interrupt). The wait loop `$A471BC↔$A471C2`
(`cmpi.w #$a,D3 / subq.l #1,D0`) needs **D3==10**; D3 stays 0 → fail path →
`$A462AA` (err `$11xx`) → `$A4638C` (`bset #$18,D7`) → STM at `$A498xx`. After STM it
spins at `$A49FCC` (Op=8000). MAME never executes `$A462C4`/`$A4638C`/`$A498xx`.

### Root-cause chain (DIAGNOSED this session — fix not yet done)
1. Test fails ⇐ level-1 ISR `$A472CC` runs **0×** (confirmed: 0 hits in cpu_trace;
   MAME hits it 10×).
2. ISR never runs ⇐ the level-1 autovector ($19→vector addr `$64`) reads garbage:
   the **interrupt vector table at `$0-$3FF` is UNMAPPED** at F276.
3. `$0` unmapped ⇐ our config is `$C4` (bits76=11) ⇒ `addrDecoder` `mb_present=0` ⇒
   `in_motherboard_low=0` ⇒ `$0` not RAM (and physical SIMM=0 ⇒ no SIMM either).
4. `$0` should be MAPPED here ⇐ MAME aliases `$0`↔`$800000` permanently from **frame
   232** (after the march), via the **relocation trampoline `$A4A87C` / config write
   `$A4A8A4`** (`move.b D5,(A2)` to pseudovia reg $01, D5 sets bits76≠11 ⇒ ram_size
   maps `$0`). Our core **NEVER executes `$A4A87C`** (0 hits) ⇒ `$0` never re-mapped.

The VIA + IRQ path itself is FINE (ruled out): VIA T1 counts, IFR bit6 sets, IER bit6
enabled, `viaIrq` asserts, `_cpuIPL`=6 (level 1), `iplnr`=1, SRmask=0, `setinterrupt`
fires, `fc7_iack` asserts (IACK recognized, autovector glue OK). The ONLY break is the
unmapped `$0` vector table.

### NEXT STEP
Trace **why our post-march execution path skips the `$A4A87C` relocation trampoline**
that MAME runs to re-map `$0`. I.e. find where our path diverges from MAME right after
`[MARCH] *** DONE $A4694C` (F232). MAME: march → `$A4A87C` (trampoline, relocates
`$800000`→`$0`, maps `$0` at frame 232) → … → timer test `$A471xx`. Ours: march →
(skips `$A4A87C`) → timer test. Tap both PCs in MAME, dump regs at the march-exit
branch, and compare the branch our core takes. Likely an earlier register/flag
divergence decides whether the trampoline runs.

KEY TENSION to respect: `$0` must be UNMAPPED during the march (else the table clobber
returns) but MAPPED after (vector table + low-mem globals). MAME does this purely via
the config register (bits76=11 during march → `$0` off; bits76≠11 after `$A4A8A4` →
`$0` on). Our `addrDecoder` already keys `in_motherboard_low` off `mb_present =
(written ram_config[7:6]!=11)`, so IF our core executed `$A4A8A4` with bits76≠11, `$0`
would map correctly. So the real fix is to make our core reach/execute that write —
likely by fixing whatever upstream divergence skips the trampoline.

## MAME ground truth (how to)
```
cd /Users/dani/repos/mame && /opt/homebrew/bin/mame maclc -rompath /private/tmp/goodroms \
  -ramsize 2M -autoboot_script /tmp/X.lua -seconds_to_run 8 -nothrottle -video none -sound none 2>/dev/null
```
- Tap PCs: `pgm:install_read_tap(a&~3,(a&~3)+3,name,fn)`, in fn check
  `(cpu.state["PC"].value & 0xFFFFFF)==a`. Taps fire reliably on branch-target PCs.
- Read regs: `cpu.state["D3"].value`, mem: `pgm:read_u32(a)`.
- Full maincpu trace: `mame ... -debug -debugscript /tmp/t.cmd` with `t.cmd` =
  `trace /tmp/mame_pc.tr,maincpu` + `go`. Trace PCs are 8-digit `00A4xxxx:`.
- Confirmed MAME facts: `$0` aliases `$800000` from frame 232 (poll: `/tmp/poll.lua`);
  ISR `$A472CC` hit 10×; trampoline `$A4A87C` IS on MAME's post-march path; MAME never
  hits `$A462C4`/`$A498xx`.

## Build / run / gotchas
- VHDL is source of truth → `cd rtl/tg68k && ./convert_to_verilog.sh` (only if touching
  the CPU) → `cd ../../verilator && make clean && make`.
- **Verilator builds `verilator/sim.v` (module emu), NOT MacLC.sv** — duplicate CPU/bus
  logic, keep in sync. [[verilator-top-is-sim-v]]. NOTE: `sim_frame_count` (sim.v) ≠
  `video.count_frame` (sim_main.cpp) — use the C++ `video.count_frame` for frame gating.
- Probing inlined signals: reference a Verilator net in code to keep it un-inlined.
  Useful exposed nets: `emu__DOT__dc0__DOT__viaIrq`, `emu__DOT__pseudovia_irq`,
  `emu__DOT__dc0__DOT__via__DOT__{acr,irq_mask,irq_flags,timer_a_count,timer_a_may_interrupt}`,
  `emu__DOT__tg68k__DOT__tg68k__DOT__{ipl_nr,srin,setinterrupt}`,
  `emu__DOT__cpuFC`, `emu__DOT__fc7_iack`, `emu__DOT__pvia_ram_configured`,
  `emu__DOT__pvia__DOT__ram_cfg`. (`_cpuIPL`/`cpuAddr` get inlined unless referenced.)
- Foreground sim only; run once, analyze logs. [[feedback-sim-foreground]].
- Interrupt/autovector glue: `tg68k.v` `auto_iack=(fc==7&&!vpa_n)`,
  `auto_vector={4'h1,1'b1,addr[3:1]}` (level1→$19→vector $64); `IPL_autovector=1'b0`.
  `sim.v` `fc7_iack=(cpuFC==7)&&(cpuAddr[19:16]==4'hF)` gates `_cpuVPA`. IPL mux in
  `dataController_top.sv:243` (level1=VIA, level2=pseudovia, level4=SCC).

## Done-when (next session)
- Our core executes the `$A4A87C` trampoline (or otherwise re-maps `$0` after the
  march like MAME at frame 232); `$0` aliases `$800000` at the timer test.
- ISR `$A472CC` runs, D3 reaches 10, the `$A471xx` test passes, no STM at `$A498xx`.
- Boot proceeds toward the `$A148xx`/`$A149xx` floppy "?" loop; screenshot grey
  desktop + blinking "?".
