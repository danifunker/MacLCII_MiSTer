# FINDINGS — 7.1 F-line bomb: continued-past TST/BTST flags come from JUNK BUS DATA (v5 CCR-from-DIB fix) — 2026-07-02

## ✅ v7 HW RESULT: F-LINE BOMB IS GONE — boot now reaches FINDER LAUNCH (new: error type 7)
Deployed `releases/MacLCii_flineFix_v7_20260702.rbf` (md5 46cdae05, STA all
positive) + hygiene + cold-boot 7.1. **The "bad F-Line instruction" bomb is
GONE.** New dialog: **"Finder — error type 7"** = a privilege violation (classic
Mac SysError ID 7 = vector 8) at FINDER-LAUNCH — i.e. the boot now runs the
whole ROM + System and gets all the way to loading the desktop app, a massive
advance from the early-boot ROM wild-jump. The v7 boundary-bsr push-race fix
resolved the primary crash. The box then WEDGED on the type-7 fault (HTTP API
down, JTAG reads all-FF = can't-clock signature) → needs a power-cycle.
NEXT: characterize error type 7. Is it (a) sim-reproducible (extend the
headless run past Finder launch → full-trace the privilege fault, same method
that cracked the F-line bomb) or (b) HW-timing-only (SCSI/latency — sim has
zero-latency SCSI; then [[timing-bugs-use-hw-not-ideal-sim]] applies, chase on
the power-cycled box). Confirm the exact faulting vector from the sim/trace —
do NOT assert the error-code meaning from memory. Candidate: a residual
control-flow-corruption of the SAME class (torn push / mis-restored SR during a
walk stall) landing the CPU in user mode on a privileged op — but unproven;
could equally be a separate Finder/SCSI/video issue only now reachable.

## ★★★★ ROOT CAUSE FOUND + FIXED (v7): bsr PUSH TORN BY THE PC-REDIRECT BYPASSING THE WALK-STALL GATE
The sim trace (frame 1412, line 34,824,076 of cpu_trace.log) shows the fatal
chain verbatim: `bsr $205ba` at $1FFFC (return = $00020000, exactly a 64K/page
boundary) → ONE ghost fetch executing AT THE STACK SLOT ($3EEBA0) → helper runs
→ its `rts` pops $00000000 → executes the vector table from $0 → $100=$FFFF →
F-line bomb. The only such ghost fetch in 34.8M instructions.

**berr_bench probe #13 reproduces it in 2k ticks** (bsr.w whose displacement
word is the LAST word of a 32K page, MMU on): the return-address push is
torn/lost. Discriminators: #13b same boundary MMU-OFF = PASS; #13c cold-page
target mid-page MMU-ON = PASS ⇒ trigger = ext-word-at-page-end + TC on: the
SEQUENTIAL next-page prefetch is already walk-stalling when micro-state bsr2
fires its push.

**Mechanism:** `TG68_PC_brw` (branch redirect) is combinational from the
micro-state; the PMMU retrofit gated the TG68_PC update `(state="00") AND
pmmu_busy='0'` but left `OR TG68_PC_brw='1'` UNGUARDED (upstream TG68 had no
walks). During a walk stall clkena_lw freezes micro_state + data_write_tmp
while clkena_in keeps firing for the walker — so the redirect moved TG68_PC to
the branch target (or a mid-update value) BEFORE the frozen push machinery
sampled it: data_write_tmp (writePC → live TG68_PC) captured garbage. Stall
depth selects the symptom: fall-through no-push (bench, zero-latency walks) or
redirect-with-lost-push + ghost fetch (real walk latency; the 7.1 boot).

**Fix (TG68KdotC_Kernel.vhd, two lines + comments):**
1. Uniform gate: `ELSIF (((state="00") OR TG68_PC_brw='1') AND pmmu_busy='0')`
   — the redirect waits out the stall like the fetch arm; brw persists (comb
   from frozen micro_state) so it commits on the first non-busy edge, the same
   edge the push samples — the designed atomic handoff restored.
2. data_write_tmp hold while `pmmu_busy='1' AND state(1)='1'` (stalled CPU
   data access) — a stalled two-beat push can't re-sample a moving source.
   Mirrors the June memaddr/use_base address-hold.

**Why 7.1 and not 6.0.8/7.5.5/MAME:** needs a bsr.w/bsr.l with its extension
word as the LAST word of a mapped page (1-in-16k word positions) executed with
TC on and that page boundary cold in the ATC — 7.1's System-file code layout
happens to place one exactly there ($1FFFC); other OS versions don't. MAME's
68030 has no such stall interleave. Deterministic per layout ✔ (identical ring
on every HW cold boot; identical sim frame).

## ★★★ BREAKTHROUGH (late session): THE VERILATOR SIM REPRODUCES THE 7.1 BOMB
`--scsi0` disk boot works in the sim (CLAUDE.md's "no hard drive" just meant no
default image). Booting the SAME disk (`scratch/sim71.hd` = MacLC_7-1.hda) with
the SAME ROM (`releases/boot0-nomemcheck.rom`, md5 dcc7c7ac = what the MiSTer
boots) at 10MB: **the sim shows the identical "bad F-Line instruction" bomb at
~frame 2500** (user-witnessed). ⇒ DETERMINISTIC LOGIC BUG — *not* an SDRAM/fit
timing artifact — fully reproducible in-house with complete visibility. A
full-trace run (boot → frame 2650, screenshots 2450/2550/2600) is capturing:
(1) the wild rts + its popped garbage, (2) the stack-slot address from the
trace's @data-addr annotations, (3) the WRITER of that slot, (4) the diff vs
MAME's matched-config healthy trace (`~/m71nmc.tr` in WSL home, 7.2GB).
Also eliminated today by MAME A/B: ROM patch (stock + nomemcheck both boot),
disk image (same .hda boots), PRAM (MAME boots even with the MiSTer's garbage
walking-pattern PRAM transplanted; our HW bombs even with zeroed PRAM).
Housekeeping: MiSTer .nvr/.nvr.bak were CORRUPT (walking-bit pattern from the
Jun-29 incident enshrined as "pristine") — both replaced with the sane
rtl/egret/egret.pram seed; MAME's healthy egret nvram restored from backup.

## ⚠ v5 HW RESULT + v6 (same day, read this first)
- **v5 on HW: 7.1 STILL BOMBS** (identical "bad F-Line" dialog ~175s into a
  cold boot). The v5 probe read was UNREADABLE: the deck had grown to 64 ISSP
  instances which **corrupts the sld hub** (enumeration shows 6 phantom nodes
  with garbage widths; every read returns all-ones). The v4-era ~41-instance
  deck read fine. ⇒ never grow the deck past ~40; use WIDE probes instead
  (ISSP supports up to 511 bits/instance).
- **v6 (built this session):**
  1. **EA-mode widening** — bench proved v5's (An)/(d16,An)-only gate lets an
     `move.l abs.L,Dn` probe complete with **D2=$DEADDEAD raw junk bus data in
     the destination register** (and junk CCR): the register-flavored twin of
     the CCR bug, a garbage handle DIRECTLY. v6 allows every side-effect-free
     source mode for the MOVE/MOVEA writeback ((An), (d16,An), (d8,An,Xn),
     abs.W/L, PC-rel; excludes (An)+/-(An)/register-direct) and drops the mode
     gate entirely for the CCR-only TST/BTST classes.
  2. **PMMU-dispatch stale-opcode fix** — `berr_capture_opcode/pc` were only
     latched at EXTERNAL-BERR first-fire, so PMMU-dispatched fault frames
     stacked a stale +$14 opcode (wrong RTE-side decode). Now latched at the
     PMMU dispatch site too.
  3. **Probe consolidation** — ring + F-line capture packed into 5 wide
     instances (PFA0/PFA1/PFW0/PFJX/PFLX), deck 64 → 36. cpu_state.tcl slices
     right-anchored hex substrings (rdhex/wslice).
  berr_bench extended to 10 probes (adds abs.L→Dn, abs.L TST, (d8,An,Xn)→Dn):
  v6 = **10/10 PASS** (v5 fails the three new ones), ksw+pmmu PASS.

## ⚠⚠ v6 HW RESULT + ring readout (later again, same day)
- **v6 on HW: 7.1 STILL BOMBS.** The consolidated deck reads perfectly. The
  frozen ring (cause=lowjump) finally shows the fatal mechanism — and it is
  NOT a computed jump: an `rts` chain (`$5DEF4` → `$205C8`:
  `move.l (A7)+,D0; beq.s` → `$205D6`: `rts`) pops a return address of
  **$009FE820 — inside the boot stack**, executes stack junk
  ($7FFF/$FC19/$0000…), then jumps to $00000000 and marches up the vector
  table to $100=$FFFF → F-line. The earlier "$40C2→$24" was this same class
  seen through the old 8-deep keyhole. PFR shows an EARLIER surviving episode
  (IF=$9FEE40, also stack) — the boot corrupts return slots repeatedly.
- **Continue-past is EXONERATED in sim**: berr_bench extended with (a) A7
  stamps — zero drift across 9 external fault+RTE cycles, (b) a full PMMU
  phase (MMU on via ksw-style identity table, entry $D invalid → walk faults
  → SSW-bit9 frames → same DF-clear/DIB/RTE): both PMMU probes resume
  correctly with right registers/CCR and zero A7 drift. 12/12 forms PASS.
- **No spurious TC-enable fault**: three successive "anomalous" traps were MY
  program-address miscounts (each was probe #11's intended walk fault after
  the layout shifted). Negative control: the first data access after
  `pmove TC` (tst.b of a valid page) inside a fatal-catcher window does NOT
  fault. Lesson: recompute emit-stream addresses after EVERY bench edit.
- MAME never executes $205C8/$5DEF4/$9FExxx — the visible neighborhood is
  already off the healthy path; the corruption origin is upstream of the ring.
- Cosmetic loose end: the bench FIXWRITE debug print shows a one-behind
  opcode for PMMU-path frames while the architectural outcomes (register
  choice, CCR rule, sizes) are provably right — print-sampling artifact to
  tidy, not a functional bug.
- NEXT DISCRIMINATOR: cold-boot determinism. Same frozen-ring addresses on a
  second cold boot ⇒ deterministic code-path bug (MAME-diff the writer of the
  bad slot). Wandering addresses ⇒ timing race (prime suspect: interrupt
  arriving inside the long Format-$B RTE-unwind window corrupting the resume
  continuity — testable in berr_bench by pulsing IPL during the handler RTE).

## One-line
H1 from `resume_fline_wildjump_2026-07-02.md` is REPRODUCED IN SIM and FIXED:
after a Mac OS BERR-probe "continue past" (DF cleared + DIB stuffed + RTE),
TG68 left the CCR computed from the **junk bus data of the aborted read cycle**
— not from the handler-stuffed DIB like a real 68030's replay — so the
validator's following `beq` took a near-deterministically WRONG direction for
DIB=0 handlers ⇒ wrong hardware verdict ⇒ garbage handle ⇒ the wild jump
`$40C2 → $24` ⇒ vector table executes as code to `$100` = `$FFFF` ⇒ the
"bad F-Line instruction" bomb.

## Evidence chain

### MAME mining (healthy-boot oracle, scratch/m71_trace.tr.gz)
- `$0040C2` **never executes** in a healthy 7.1 boot (0 hits). PCs ending
  `40C2` are `$000140C2` (628×, a doubly-linked ring walk off low-mem global
  `$378`, prev@+0/next@+4, unlink helper at `$14188`), `$009C40C2` (30×),
  `$000B40C2` (1×). Our core was already off-path at the jump source.
- MAME executes below `$400` **only on trace lines 1–12** — the reset-overlay
  path (`$2A → $8C → movec/pmove → jmp $2E00`). After ROM-home, never.
  (This shaped the new fetch-ring arming, below.)

### Sim repro (verilator/berr_bench, extended with CCR checks)
Pre-fix result with flags forced OPPOSITE before each probe:
- `tst.b (A0)` / `btst #6,(A0)` with DIB=-1 handler: flags "passed"
  **coincidentally** — the bench feeds `$DEAD` on BERR'd reads and byte `$DE`
  (N=1, bit6=1) mimics DIB=-1. Proof the flags come from the aborted cycle's
  bus data, not from stale pre-instruction CCR.
- Same probes with DIB=0 handler: **FAIL** (Z stays 0 — junk ≠ 0).
On real HW the aborted cycle returns bus noise ⇒ every DIB=0-verdict probe
answers wrongly. That's not a coin flip; it's a near-deterministic wrong path.

## The v5 fix (rtl/tg68k/TG68KdotC_Kernel.vhd, on top of v4)
Class-gated `rte_mmu_fix` (all still require SSW DF=0/RM=0/RW=read + EA mode
(An)/(d16,An) + Format $B at rte5):
- `is_move` (MOVE→Dn / MOVEA→An): register writeback + MOVE-rule CCR for Dn
  destinations — unchanged behavior.
- `is_tst` (TST.B/W/L `$4Axx`, size≠11): MOVE-rule CCR from DIB (N/Z by size,
  V=C=0, X preserved). No register write.
- `is_btst` (**static** `BTST #imm,<ea>` `$0800` family only): Z = NOT
  DIB[bit], N/V/C/X keep the fault-time values (live `Flags` at rte5 = the
  frame-restored CCR; directSR ran at rte1). No register write.
- **Regfile writeback is now gated on `is_move`** — critical: TST `$4A10` /
  BTST `$0810` decode bits 11:9 as "dest" and would smash D5/D4 otherwise.
- BTST bit number: `sndOPC(2:0)` latched at fault FIRST-FIRE (external-BERR
  and PMMU-dispatch sites; sndOPC still holds the immediate — nothing
  refetches it between ext-word fetch and the EA read), stacked into frame
  `+$14` HIGH word bits 18:16 (was `last_opc_read` cosmetics; nothing consumes
  it), recovered at rte5 alongside the opcode ⇒ round-trips through the frame,
  nesting-safe.
- Dynamic `BTST Dn,<ea>` deliberately NOT fixed: its bit number lives in a
  register that isn't reliably re-readable at RTE time, and no ROM/OS
  validator uses that form.

## Validation
- `verilator/berr_bench` (extended: 7 probes, resume + CCR markers for both
  DIB polarities, BTST N/C-preservation check): **PASS 7/7** post-fix,
  FAIL (CCR) pre-fix. This is the regression gate for berr/RTE/frame changes.
- `verilator/ksw_bench` (mode-switch alias): PASS.
- `verilator/pmmu_bench` (walker): PASS, 0 failures.
- Full-sim boot check + FPGA build: launched this session (see resume notes).

## Fetch-ring v2 (MacLC.sv probes — the "if v5 isn't it" instrument)
16-deep ring of {full 32-bit fetch addr, fetched word} (PFH0-F + PFO0-7).
Freezes on the FIRST code fetch below `$400` AFTER arming (armed by the first
ROM-home `$Axxxxx` code fetch, so the legit reset-overlay path at `$2A-$B4`
can't false-trigger); F-line freeze kept as fallback. PFJS/PFJT = full-width
wild-jump pair, PFJO = their fetched words, PFJM = cause/armed/frozen/wp/jumps.
Decoder updated in `scripts/cpu_state.tcl`. If the bomb persists, the frozen
ring shows the killing fetch + the 15 fetches (with opcodes) leading to it.

## Open questions
- Why does OUR boot run the `$A0DBxx` validators (PEXC fires=5) when MAME's
  maclc2 never calls them? Some earlier hardware-state divergence routes 7.1
  into the probing path. Benign if the probes now answer correctly, but worth
  understanding if symptoms persist.
- The `$378` ring-walk divergence ($140C2 in MAME vs $40C2 here) may just be
  heap-layout noise between machines — do not chase unless the ring implicates
  it.

## ADDENDUM (late 2026-07-02, type-7 session): fix #2 is inert (dead code)
Static re-audit while chasing the type-7: the `data_write_tmp` hold added as
"fix part 2" sits inside the `ELSIF clkena_lw='1'` block of its process
(~line 2472 of TG68KdotC_Kernel.vhd), and `clkena_lw <= clkena_in AND
memmaskmux(3) AND NOT pmmu_busy` (line 1575) — so `pmmu_busy='1'` can never be
true where the hold is evaluated. The bsr-push fix therefore came ENTIRELY
from fix #1 (the TG68_PC brw gate). Harmless to leave in (shipped + validated
as a pair); remove at the next kernel-touching commit for clarity.

Sibling-audit map for the type-7 hunt (clkena_in-domain arms that can fire
during a walk stall — exec strobes stay held because micro_state is frozen):
- `exec(directPC)` -> `TG68_PC <= data_read` (~3452) — RTE/RTS PC pops. UNGATED by pmmu_busy.
- `exec(ea_to_pc)` -> `TG68_PC <= addr` (~3454) — jmp/jsr (ea). UNGATED.
- Walker read data does NOT flow through data_read (dedicated pmmu_walker_data
  port, ~171): mid-stall re-assignments re-sample a STABLE stale value, so the
  exposure is confined to stall-EXIT latch ordering and page-straddling pops.
- FlagsSR/SVmode/trap_SR/data_write_tmp/regfile writes all live in
  clkena_lw-gated processes — frozen through stalls, structurally safe.
