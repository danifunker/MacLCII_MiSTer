# FINDINGS — the post-F-line "type 7 / bad-F-line" Finder-launch bomb (2026-07-03)

## TL;DR
The Verilator sim **reproduces the Finder-launch bomb deterministically** (two
independent runs both bomb identically). On the sim it presents as **"'Finder'
bad F-Line instruction"** at video frame ~1770; on HW the same-point crash
presents as **"error type 7"** (privilege violation). Same crash POINT (Finder
actively drawing the desktop), different surface vector — consistent with a
**control-flow corruption** that lands the CPU on different garbage opcodes
depending on timing (sim's zero-latency SCSI vs real HW). Leading root-cause
hypothesis (**H-A**, unconfirmed): the RTS/RTE/JMP-indirect PC restore
(`exec(directPC)`/`exec(ea_to_pc)` → `TG68_PC <= data_read`/`addr`,
TG68KdotC_Kernel.vhd ~line 3452-3455) is **ungated by `pmmu_busy`** — the exact
sibling of the just-fixed bsr-brw tear — so a stack-pop that walks the page table
(ATC cold because the MMU-mode-swap routine keeps flushing it) can tear the
restored PC → return to garbage → bad opcode → bomb. NEXT: verify in berr_bench.

## What the sim showed (solid)
- Post-fix binary (bsr-brw fix active): clean Welcome (F800), Finder menu bar
  drawn (F1450), desktop being drawn through F1770, then bomb by F1800. The
  pre-fix binary bombed at ~F1412 (torn bsr push at $1FFFC, BEFORE Finder), so
  **reaching Finder-draw proves the bsr fix is live** and this is a distinct,
  downstream crash.
- **Deterministic**: run#1 (scratch/sim71.hd) and run#3 (~/lc, trace-armed) both
  bomb "bad F-Line" at F1800. => logic bug, reproducible, not a timing artifact
  in-sim (though the sim/HW vector difference IS timing-sensitive).
- The bomb dialog's poll loop and the normal SystemTask/VBL idle loop are the
  SAME code (A0A2FA trap-dispatch / A0A332 counters / A06Exx VIA poll / A4B9Cx),
  running ~23x/frame from F1400 to F1906 — so "where the idle loop starts" does
  NOT mark the crash, and neither does the heartbeat "PC lock" (the box keeps
  taking interrupts after the bomb; SysError uses the normal VBL loop to poll
  Restart).

## Ruled OUT
- **Pre-fix bsr-push race** — fixed; reached Finder; no exec below $400
  (vector-table-as-code march ABSENT, unlike pre-fix).
- **A pmove/pload fault** — the MMU-mode-swap routine at $A03EFC-$A03F2A
  (`pload #0,($8,A0)`; `pmove ($c/$10,A0),srp/crp`; `pmovefd (A0),crp`;
  `pmove ($8,A0),tc`; `movec CACR`; `rts`) executes 154x and the LAST one before
  the crash completes cleanly and `rts`es. No pmove trapped.
- **The VIA-interrupt RTEs near the crash** — handler at $A09B40 (VIA L1 IRQ:
  saves D0-D3/A0-A3, dispatches via IFR/IER at $A09BE0, `rte` at $A09B88). Its
  real return targets in F1768-1771 are all SANE ($A14878 spin, $A385AE, Finder
  RAM $045366, etc.). So these specific RTEs are not the torn op.

## Trace-method caveats (IMPORTANT — cost me a lot of false leads)
1. **cpu_trace.log logs prefetch GHOSTS.** After a redirecting instruction
   (bra/rts/rte/jmp) the sim logs the *sequential* next word (PC+2) even though
   it's fetched-and-discarded. So `$5F55C:FF00`, `$9D78:F620`, `$E3FFFC:0000`
   are all ghosts, NOT executed instructions. **Never conclude an opcode executed
   from an opword grep** — verify the next real line isn't a redirect target.
   Corollary: the "recurring F-line" hits were all ghosts or the legit PMMU
   routine; there is no recurring real F-line trap.
2. **MAME's maincpu trace does NOT capture interrupt-handler execution** (or logs
   it on a different stream). So the "sim-only PC" diff vs ~/mame_pcs.txt (94,481
   distinct healthy PCs) flags every interrupt-context ROM PC (e.g. $A09B40) as
   "sim-only" — false. The MAME PC-set oracle is unreliable for IRQ code.
3. Sim & MAME also diverge EARLY for known reasons (7.1 routes into the $A0DBxx
   hardware-probe path MAME's maclc2 never runs) + heap-layout differences put
   Finder app code at different RAM addresses. So a raw PC-stream diff near the
   crash is swamped (15k sim-only PCs in a 14-frame window, almost all noise).
4. MAME oracle format is **disassembly** (`PC: mnemonic`), not "PC OPWORD" as an
   earlier note claimed. Healthy full-boot trace: `~/m71nmc.tr` (6.8 GB).

## The H-A hypothesis (to verify next)
Static audit of TG68KdotC_Kernel.vhd (the PC-update process, `IF clkena_in='1'`
block ~line 3410-3472): after the 2026-07-02 fix, the `TG68_PC_brw` branch
redirect is gated by `pmmu_busy='0'`, but **`exec(directPC)` (line ~3452,
`TG68_PC <= data_read`) and `exec(ea_to_pc)` (line ~3454, `TG68_PC <= addr`)
remain UNGATED**. These implement RTS / RTE / JMP-(indirect) / computed returns —
the PC is loaded from the just-read stack/EA word. During a PMMU table walk,
`clkena_lw` freezes the micro-state while `clkena_in` keeps firing; if the
directPC/ea_to_pc arm commits mid-walk it can latch a torn/stale `data_read` into
TG68_PC (identical failure shape to the fixed bsr-brw tear).
Cold-page trigger: the MMU-mode-swap routine writes SRP/CRP/TC every switch,
which **flushes the ATC**, so the very next stack-pop (RTS/RTE) or indirect jump
walks — and at Finder launch mode-swaps are frequent (mixed 24/32-bit code).
This explains: (a) why it's at Finder launch, (b) sim "bad F-line" vs HW "type 7"
(garbage lands on different bad opcodes), (c) why it's the same class as the
bsr fix, (d) matches the resume's independent H1/H3 prediction.
Structurally SAFE (clkena_lw-gated, frozen through a walk): FlagsSR, SVmode,
preSVmode, trap_SR, regfile, data_write_tmp — so a direct SR/S-bit register tear
is excluded; if HW really is a privilege violation it must come from garbage
*execution* after a torn PC (S-bit inherited wrong via the garbage path), not a
torn SR register.
NOTE the 2026-07-02 "fix #2" (data_write_tmp hold under `pmmu_busy & state(1)`)
is INERT dead code — it sits in a clkena_lw-gated block where pmmu_busy is always
0. The bsr fix worked entirely via fix #1 (the brw gate).

## Verification plan (berr_bench — the method that cracked the bsr bug)
verilator/berr_bench/{berr_top.v, berr_bench.cpp}. Add a probe:
  1. Enable MMU (identity table, like the existing PMMU probes / ksw_bench).
  2. `pmove tc` (or pflush) to flush the ATC so the target page is cold.
  3. Execute an RTS/RTE whose return address is popped from a stack slot on a
     cold page (force the pop to walk), with the walk latency straddling the
     directPC commit edge (mirror probe #13's setup).
  4. Assert the restored PC == the correct return address; a tear = FAIL.
  Controls (like #13b/#13c): MMU-off = PASS; hot-page (no walk) = PASS.
Caveat (from the bsr work): the bench's freeze model can distort walk interleave;
the **full Vemu boot is the ultimate arbiter**. If the bench confirms, the fix is
to gate `exec(directPC)`/`exec(ea_to_pc)` on `pmmu_busy='0'` (wait out the stall,
commit on the first non-busy edge — same shape as the brw fix), then re-verify
berr_bench + ksw + pmmu + a full 7.1 sim boot, then HW.

## Tooling built this session (scratch/, deployed to ~/ in WSL)
- `crashtrace.sh` — trace forensics (frames/window/tailframe/ctx/lastpc/
  pmovebefore/framespan/rtes/lit/flines). Run via `tr -d '\r' < scratch/X > ~/X`.
- `build_mame_pcs.sh` -> ~/mame_pcs.txt (MAME distinct-PC set; ~5 min).
- `diff_crash.sh` / `romdiv.sh` — sim-only PC diff vs MAME (noisy — see caveat 2/3).
- `simcheck.sh` — 3-sim status.
Sim run logs: verilator/sim_run71_postfix.log (run#1), sim_run755_postfix.log
(run#2 7.5.5 control), ~/lc/verilator/{cpu_trace.log,sim_run71_trace.log} (run#3,
trace-armed, crash captured through F1827).

## H-A mechanical analysis (RTL read, 2026-07-03 — pending [EXC] confirmation)
Traced the RTE micro-sequence: `rte1` (TG68KdotC_Kernel.vhd:7643) does
`setstate<="10"; set(postadd); setstackaddr; set(directPC)` — i.e. it starts the
stack read of the return-PC longword from A7 and arms directPC. `exec(directPC)`
(the registered set) then commits `TG68_PC <= data_read` at line 3452, inside the
`IF clkena_in='1'` block and **NOT gated by pmmu_busy**.
If A7's page is cold in the ATC (the MMU-mode-swap routine writes SRP/CRP/TC which
flush the ATC, and it runs constantly at Finder launch), rte1's read WALKS:
clkena_lw freezes, the micro-state holds in the directPC-commit phase, and
`exec(directPC)` stays asserted across the stall while `clkena_in` keeps firing →
`TG68_PC <= data_read` latches the STALE data_read every edge (the walker fills
its own pmmu_walker_data port, not data_read). Final-value correctness depends on
the exact walk-completion edge ordering (does TG68_PC latch data_read's PRE- or
POST-update value at the clkena_lw edge that ends the walk) — the same 1-cycle
skew that made the bsr push tear. => the sampled RTEs looking "sane" does NOT
exonerate directPC; a tear needs specific walk-latency alignment (bsr's was
1-in-16k word positions), so only the ONE mis-aligned RTS/RTE bombs.
This mirrors the June holds (memaddr/use_base at :3117 and the memmask/memread
counter at :3439 are both held under `pmmu_busy AND state(1)`) — TG68_PC via
directPC/ea_to_pc is the analogous quantity that is NOT held.
FIX SHAPE (apply only after [EXC]+bench confirm a torn PC): gate
`exec(directPC)` and `exec(ea_to_pc)` on `pmmu_busy='0'` so TG68_PC holds through
the stall and commits on the first non-busy edge — which is exactly the walk-done
edge where data_read/addr is valid. Non-walk case unaffected (pmmu_busy≡0).
CAVEAT: verify in berr_bench (RTS/RTE with cold-stack-page walk) AND a full 7.1
sim boot before shipping — the bench freeze model can distort walk interleave
(per the bsr probe #13 caveat), so the full boot is the arbiter.

## [EXC] logger v1 lesson + v2 (2026-07-03)
v1 included A-line (trap_1010, vec10) — MISTAKE: A-line IS the Mac Toolbox
trap-dispatch mechanism ($Axxx opcodes = every Toolbox/OS call), so it fires
HUNDREDS of times per frame during Finder's desktop draw and filled the 400 cap
in the first frame, missing the F-line crash. v2 removes A-line; the bomb is a
"bad F-Line" (vec11), and F-line/priv/illegal/addr-err/format are all rare.
CONFIRMED from the v1 flood: the logger works and `opcode_pc` is RELIABLE
(opcode_pc == exe_pc, live_pc = opcode_pc+2 for the A-line instr). BUT
`exe_opcode` LAGS — it holds the prefetched NEXT instruction, not the trapping
opcode (e.g. an A-line trap showed exe_opcode=3F3C/7000/2040, not $Axxx). So at
the F-line crash: trust opcode_pc for WHERE, trust the vector for WHAT; don't
trust exe_opcode as the faulting opcode (read the real opcode from run#3's trace
at opcode_pc instead). Also: F1600-1612 A-line traffic was all normal Finder
Toolbox activity in $40Axxxxx ROM + $6xxxx/$Bxxx/$Dxxxx RAM (32-bit-mode traps),
no anomaly — boot healthy there; crash is later (~F1770).

## ★★★★ ROOT CAUSE CONFIRMED (2026-07-03): torn jsr/rts PC via UNGATED ea_to_pc/directPC
[EXC] instrumentation caught the fault definitively:
  [EXC] F1768 F-LINE vec11 opcode_pc=00378004 SRhi=20[S=1 IPL=0] svmode=1
$378004 is MID-INSTRUCTION — the displacement word ($FD48) of `jsr (-$2b8,PC)`
at $378002 (a 4-byte instr; correct return = $378006). So a control-flow
transfer landed **2 bytes early** ($378006-2), executed $FD48 as an F-line →
"bad F-Line". (trap_vector read $028 at the sample edge is STALE — the label
from trap_1111 is authoritative; opcode_pc is reliable, exe_opcode lags.)
TIMING-SENSITIVE (proves the walk-race class): run#3 (old binary, cpu_trace)
executed $378002→$378006 CORRECTLY and bombed at a *different* site; the
instrumented binary tore at $378004. A tiny binary/timing change moves the tear
site — identical to the bsr bug's 1-in-16k alignment sensitivity.
MECHANISM: jsr/jmp (kernel :5683-5716) assert `writePC` (return-address push,
:5706) AND `set(ea_to_pc)` (PC redirect to target, :5715). The redirect commits
via `exec(ea_to_pc)='1' -> TG68_PC <= addr` at :3454, which — unlike the v7-gated
brw arm — is **NOT gated by pmmu_busy**. When the push's stack write (or the
prefetch) stalls on a PMMU walk, clkena_lw freezes the push machinery while
clkena_in keeps firing the ungated ea_to_pc redirect → TG68_PC advances one
prefetch word before the frozen `writePC` samples it → the pushed return address
is torn ($378004) → the callee's rts returns 2 bytes early → mid-instruction
F-line. This is the SAME class as the bsr push tear (v7), but v7 gated only the
brw arm (bsr); jsr's ea_to_pc and rts/rte's directPC were left ungated.
Supervisor mode at fault (S=1) => HW "type 7" (privilege violation) is the same
torn-PC garbage-execution landing on a privileged opcode instead of an F-line.
FIX (applying next): add `AND pmmu_busy='0'` to the exec(directPC) (:3452) and
exec(ea_to_pc) (:3454) arms, mirroring the v7 brw gate — the redirect/pop waits
out the walk and commits on the first non-busy edge (data_read/addr valid, same
edge the push samples). Non-walk case unaffected (pmmu_busy≡0). VALIDATE:
berr_bench (existing RTE probes must still PASS = no normal-return regression) +
full 7.1 sim boot (must pass Finder launch) — the boot is the arbiter.

## ★★★★★ 2026-07-03 LATER: v8 gate INERT — arbiter FAILED IDENTICALLY; mechanism REVISED
The v8 fix (pmmu_busy gates on exec(directPC)/exec(ea_to_pc), .vhd :3465/:3467)
was applied, regenerated, bench-swept (berr+ksw+pmmu ALL PASS) and boot-tested:
**the arbiter boot bombed at the IDENTICAL site — [EXC] F1768 F-LINE
opcode_pc=00378004 — bit-for-bit the same as pre-fix.** Binary freshness chain
verified (.v 06:37 → verilate 06:44 → link 06:52 → run 06:57), so the gate is
in the binary and NEVER ENGAGED. Two structural reasons, both now verified in
the RTL:
1. **`clkena_lw ≢ NOT pmmu_busy`** (the equivalence claimed earlier is WRONG).
   :1575: `clkena_lw <= clkena_in AND memmaskmux(3) AND NOT pmmu_busy` — it is
   ALSO low during the first word(s) of every longword transfer. Consumers in
   the clkena_lw domain freeze during plain multi-word cycles with pmmu_busy=0
   — edges a pmmu_busy gate cannot see. AND on every clkena_lw edge pmmu_busy
   is 0 BY CONSTRUCTION, so a pmmu_busy gate can never re-order a clkena_lw-
   domain consumer against a same-edge producer.
2. The push-data register samples in that domain: :2472 `ELSIF clkena_lw='1'`,
   :2545 `ELSIF writePC='1' THEN data_write_tmp <= TG68_PC` — reads the
   PRE-edge TG68_PC on the same edge the seq arm (:3482, clkena_in domain)
   commits TG68_PC<=TG68_PC_add. Same-edge producer/consumer, gate-immune.

## ★★★★★ RUN#3 RE-READ: the jsr NEVER RETURNED — it F-LINED IMMEDIATELY (ghost misread corrected)
`grep ' 00378002: ' ~/lc/verilator/cpu_trace.log` → **exactly 1 execution, at
F1768**, and the context shows the truth (earlier "run#3 executed 378002→378006
correctly" was a PREFETCH-GHOST misread — the `378006: addq` line after the jsr
is the standard post-redirect ghost):
```
[F1768] 00377FF8: 7000  moveq   #$0,D0
[F1768] 00377FFA: 302C  move.w  ($10,A4),D0
[F1768] 00377FFE: 2F00  move.l  D0,-(A7)
[F1768] 00378002: 4EBA  jsr     (-$2b8,PC); ($377d4c)
[F1768] 00378006: 508F  addq.l  #8,A7          <- GHOST (post-redirect artifact)
[F1768] 00015882: 0C6F  cmpi.w  #$2c,($6,A7)   <- F-LINE HANDLER (vec offset $2C!)
[F1768] 00015898: 0C40  cmpi.w  #$200,D0 @378004  <- $F2xx FPU-emulation check on the
[F1768] 000158B6: 4EF9  jmp     $40a02702.l        faulting word -> not FPU -> SysError
[F1768] 00A026AA: 48F8  movem.l D0-D7/A0-A7,$c30.w <- SysError register dump = the bomb
```
=> The failure is **NOT a torn return address popped later**. The jsr at
$378002 **fell through into its own displacement word** — $FD48 @ $378004
executed as an opcode -> F-line -> bomb. Both binaries (run#3 old, instrumented
new, v8-gated new) fail at this same site: FULLY deterministic.

## THE GEOMETRY (why this site): 32K-page-boundary cross AT the jsr
$378002 is ONE WORD past the $378000 32K page boundary. The stream ran at
$377FF8-$377FFE (old page), crossed into $378000-page at the jsr opcode, and
the jsr target $377D4C is BACK in the old page. With the MMU-mode-swap routine
flushing the ATC constantly at Finder launch, the new page is COLD: the jsr's
own opcode/displacement/prefetch fetches WALK mid-decode. Same boundary-
alignment family as the v7 bsr bug (displacement = last word of a page), a
different failure arm: the decode/redirect stream slips instead of the push.

## Candidate micro-mechanisms (PCRING run in flight discriminates)
A. **Redirect lost**: exec(ea_to_pc)'s TG68_PC<=addr commit is overwritten or
   never lands; the walk-completing STALE sequential fetch (issued for 378004
   before the redirect) feeds the decode queue -> $FD48 decoded as next opcode.
B. **skipFetch lost across the walk**: jsr d(PC) sets skipFetch at ld_dAn1
   (:5715); if the walk stall drops it, the displacement stays in the decode
   stream as an opcode.
C. Push-sample tear (the earlier story) — now UNLIKELY (the fall-through means
   the F-line fires before any rts; the push may well be correct).

## PCRING instrument (in flight -> verilator/sim_ring.log, stop F1775)
tg68k_debug.vlt taps added: data_write_tmp, writepc, clkena_lw, clkena_in,
pmmu_busy, state, memaddr, tg68_pc_add, tg68_pc_brw (+ existing tg68_pc etc.).
sim_main.cpp [PCRING]: 16384-deep delta-sampled ring of {t,F,pc,add,dwt,ma,
wpc,lw,cin,busy,st,brw}; dumps: (a) full ring at first F-line >=F1600
(site-independent), (b) TORN-PUSH trigger on a state="11" write carrying
$00378004 (cap 4, 128-entry mini-dump), (c) OK-PUSH one-liners on $00378006
pushes (cap 8) — OK-PUSH + immediate F-line => mechanism A/B (redirect side);
TORN-PUSH => mechanism C. (d) SITE-SAMPLE-END: writepc falling edges with pc in
[$377FF0,$378010].
Discriminator matrix: busy pulses with ma=378002/378004 in the dump confirm the
fetch-walk trigger; pc ever becoming 377D4C shows the redirect landed then was
overwritten (A2) vs never landed (A1/B).

## ★★★★★★ ROOT CAUSE CAPTURED CYCLE-EXACT (PCRING, 2026-07-03 ~12:45): memaddr clobbered during a FETCH walk
The PCRING dump (verilator/sim_ring.log, FLINE dump tail) shows the complete
tear, cycle by cycle, at F1768:
```
t=...112  pc=378000 ma=00390380 busy=1 st=0   <- prefetch of $378000 issues; walk starts
t=...114  pc=378000 ma=00378000 busy=1        <- walker translating the CORRECT addr
t=...116  pc=378000 ma=FFFFFFFC busy=1        <- 2 ticks in: datapath recompute CLOBBERS
          (use_base cleared + pending -(A7) delta: addr = 0 - 4 = $FFFFFFFC)
t=...116-324  ~200 ticks walk, ma stays FFFFFFFC (walker fine — it latched its own copy)
t=...387  lw=1: the post-walk REPLAYED fetch completes — issued at $FFFFFFFC!
          -> delivers open-bus garbage as "the word at $378000"
t=...388-431  move.l D0,-(A7) retires normally (writes D0=0 to $3902B8/BA; st=3)
t=...432-447  fetch of $378002 ($4EBA) proceeds normally
t=...448  the decoder consumes the garbage word as the next opcode -> F-LINE
          dispatch (opcode_pc mis-booked +4 = $378004 by the slipped window)
```
KEY EXONERATIONS: pc/add stayed CORRECT the whole time (v7 TG68_PC gates work);
NO jsr push ever happened (no OK-PUSH/TORN-PUSH before the trap — the "jsr at
378002" never got to execute at all; the real next instruction was at $378000
and the ENGINE READ IT FROM THE WRONG ADDRESS). The two TORN-PUSH hits after
the trap are the exception frame stacking $00378004 (expected).
WHY THE HANDLER SAW $FD48: it reads mem[stacked_pc=378004] = the jsr's real
displacement word — an innocent bystander. Garbage-in (wrong stacked PC),
garbage-out (FPU-check on a non-F-line word) -> SysError.
WHY HW SAYS "type 7": the corrupted-address fetch returns DIFFERENT garbage on
real bus/SDRAM -> lands on a privileged opcode instead of $FFFF-class F-line.
WHY $E3FFFC ghosts: same artifact class — transient garbage memaddr at walk
boundaries leaking into the fetch stream logger.

## ★★★ THE v9 FIX (2026-07-03): widen the memaddr/use_base walk-hold to FETCH walks
`TG68KdotC_Kernel.vhd` ~:3117 (the June "PMMU-stall address hold"):
```vhdl
-- was: IF pmmu_busy='1' AND state(1)='1' THEN
IF pmmu_busy='1' AND (state="00" OR state(1)='1') THEN
    use_base           <= use_base;
    memaddr_delta_rega <= memaddr_delta_rega;
    memaddr_delta_regb <= memaddr_delta_regb;
END IF;
```
Mirrors the memmask hold (:~3439) which was ALREADY widened to "ANY access
(fetch state="00" OR data state(1)='1')" in June — the memaddr hold simply
never got the same widening. Third member of the walk-hold family (data-addr
hold June, memmask hold June pt2, TG68_PC brw gate v7). The v8 directPC/
ea_to_pc gates stay in (inert for this bug but upstream-consistent hardening).
FOLLOW-UP (post-validation): audit ALL clkena_in-domain registered assignments
in the kernel for walk exposure — this family now has 3 confirmed members and
the pattern (clkena_in fires during walks, clkena_lw doesn't) is systemic.
VALIDATION: v9_pipeline (regen -> berr/ksw/pmmu benches -> Vemu rebuild ->
full 7.1 boot to F2500 w/ screenshots) -> verilator/sim_v9.log. PASS = Finder
desktop at F1800+, ZERO [EXC], no PCRING dumps. Then RBF rebuild + HW (user
gate: hold MiSTer deploy until they say go).
