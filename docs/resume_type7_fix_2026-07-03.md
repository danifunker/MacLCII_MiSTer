# RESUME — 7.1 "type 7 / bad F-Line" at Finder launch: v8 FIX FAILED (inert) — MECHANISM REVISED, PCRING RUN IN FLIGHT (2026-07-03 ~09:30)

> ★★ **RESOLVED-PENDING-VALIDATION (2026-07-03 ~12:50): TRUE ROOT CAUSE
> CAPTURED CYCLE-EXACT + v9 FIX APPLIED.** PCRING caught it: during the PMMU
> walk of an INSTRUCTION-FETCH ($378000, first word of a cold page), the
> address-datapath registers (use_base/memaddr_delta) are NOT held (the June
> hold covers only data accesses state(1)='1'), recompute to garbage
> ($FFFFFFFC = cleared base + pending -(A7) delta), and the post-walk REPLAYED
> fetch reads from that corrupted address -> open-bus garbage enters the
> DECODE STREAM as an opcode -> $FFFF-class = F-line (sim) / privileged
> garbage = type-7 (HW). TG68_PC was CORRECT throughout; no push/redirect tear.
> **v9 fix** = widen the :~3117 hold to `(state="00" OR state(1)='1')`,
> mirroring the June memmask-hold widening. See findings doc FINAL sections.
> ★★★ **v9 SIM VALIDATION COMPLETE (16:25 2026-07-03): FULL PASS.** Boot ran
> to F2500: **ZERO [EXC], ZERO PCRING dumps in the entire run**; Finder
> desktop stable at F1800/F2000/F2400 (archived
> scratch/desktop_f1800_v9_2026-07-03.png; FAIL ref
> scratch/bomb_f1800_excrun_2026-07-03.png); benches passed pre-boot.
> **v9 RBF READY: output_files/MacLCii.rbf (16:01, STA core-clean, hdmi-domain
> −0.355 = usual fit noise, better-class than the running v7's −0.523).**
> **WAITING ON USER GO for the MiSTer deploy** (explicit user gate ~08:00).
> Deploy steps when go: power-cycle the box first (it sits wedged at the v7
> type-7 bomb, JTAG dead), then launch_unstable_core.py --push
> ./output_files/MacLCii.rbf --core MacLCii.rbf --delay 0.12, verify
> coreRunning+md5, hygiene (refresh_disks.sh + restore MacLCii.nvr from .bak),
> cold-boot 7.1, HDMI screenshot = desktop, no type 7. Commit AFTER HW PASS
> (user's call): intended files = TG68KdotC_Kernel.vhd (+regen .v +
> TG68K_Cache_030.v) + sim_main.cpp/tg68k_debug.vlt (instrumentation) + docs;
> git add ONLY those (line-ending M-noise tree-wide; no -A); rm/ignore
> rtl/tg68k/*.o + work-obj93.cf.
>
> The v8 story below is kept for history — v8 was INERT, not wrong-but-active.

> ⚠⚠ **SUPERSEDED MID-DAY 2026-07-03: the v8 fix below DID NOT FIX IT.** The
> arbiter boot bombed IDENTICALLY ([EXC] F1768 opcode_pc=00378004, bit-for-bit
> = pre-fix ⇒ the gate never engaged). Root discovery: `clkena_lw` ≠
> `NOT pmmu_busy` (it also gates on memmaskmux(3)), every clkena_lw edge has
> pmmu_busy=0 by construction, AND run#3's "correct execution" of the jsr was a
> prefetch-ghost misread — the jsr at $378002 executed ONCE EVER and F-lined
> immediately: it **fell through into its own displacement word** ($FD48 @
> $378004 decoded as an opcode). $378002 = one word past a 32K page boundary;
> the cold-page fetch walk hits the jsr's own decode. See the two new sections
> at the END of `docs/findings_type7_sim_2026-07-03.md` (v8-inert + run#3
> re-read + candidate mechanisms A/B/C + PCRING instrument).
> **IN FLIGHT:** rebuild + instrumented boot (PCRING taps) →
> `verilator/sim_ring.log`, stop F1775 (~12:30 ETA). ON RESUME: grep
> `[PCRING]` dumps there; OK-PUSH+F-line ⇒ redirect/decode-slip (mech A/B),
> TORN-PUSH ⇒ push-sample tear (mech C). The v8 .vhd gates are still in the
> tree (harmless, benches pass) — decide keep/revert at commit time. RBF from
> the v8 tree is at output_files/MacLCii.rbf but DO NOT deploy (fix inert; user
> also said hold off + tell them when ready).

Read cold to continue. The multi-day "bad F-Line" bomb chain has advanced again:
the F-line push-race (v7, committed `40c8f43`) fixed the EARLY-boot bomb, exposing
a LATER crash at **Finder launch** ("Finder — error type 7" on HW / "bad F-Line"
in sim). This session **root-caused that** and **applied a fix**; it now needs
**validation** (a berr_bench regression pass + a full 7.1 sim boot — the arbiter).

Full technical writeup (READ THIS): **`docs/findings_type7_sim_2026-07-03.md`**.

## STATUS AT HANDOFF (2026-07-03)
- ✅ Root cause found (torn jsr/rts PC via ungated ea_to_pc/directPC).
- ✅ Fix applied to `TG68KdotC_Kernel.vhd`; `.v` regenerated (131583 lines, fix
  present).
- ✅ **berr_bench PASSES** with the fix ("PASS: all probe forms continue past…",
  A7 drift +0) → the gate does NOT break normal RTE/RTS returns.
- ⏳ **BOOT ARBITER IN FLIGHT — RELAUNCHED 06:57 2026-07-03** (the first attempt
  died at F12 when its session ended; Vemu rebuild had completed at 06:52, so the
  relaunch reuses the fixed binary + a FRESH disk copy). Booting 7.1 to F2500
  (screenshots 1800/2000/2400) → `verilator/sim_fix.log`. **This is the decisive
  test.** PASS = no bomb at ~F1768, screenshot 1800 shows Finder desktop, ZERO
  `[EXC]` F-LINE lines. FAIL = bomb persists / new hang. A Monitor tails
  sim_fix.log ([EXC]/crash/HB-per-100f). ETA ~3.5-4h from launch (~10:30-11:00).
  FAIL reference: `scratch/bomb_f1800_excrun_2026-07-03.png` (the archived bomb
  screenshot from the instrumented run — the new run overwrites
  `verilator/screenshot_frame_1800.png`).
  → **First thing on resume: check `verilator/sim_fix.log` + `screenshot_frame_1800.png`.**
- ✅ **ksw_bench + pmmu_bench also PASS** post-fix (alias-translate + walker
  S4 both green) — full bench sweep is clean, not just berr.
- ✅ **RBF PRE-BUILT + STA-CHECKED**: `output_files/MacLCii.rbf` (07:39
  2026-07-03, exit 0). Setup slack: core domains CLEAN (emu|pll +0.636/+0.830 —
  the kernel fix's paths meet timing); the only violation is pll_hdmi −0.228
  (framework scaler domain) = pre-existing fit-lottery noise, BETTER than the
  v7 build now on HW (−0.523) and same class as all recent builds. Deployable.
- ⬜ If sim PASSES: **DO NOT AUTO-DEPLOY — user said (2026-07-03 ~08:00) to hold
  off on the MiSTer and tell them when ready.** Report sim verdict + "RBF ready",
  then WAIT for the user's go before any deploy/HW step (step 4 below).

## ★ ONE-LINE
The Finder-launch crash is a **torn jsr/rts return PC during a PMMU walk stall** —
the SAME class as the fixed bsr bug, but on the arm v7 didn't cover. Fix applied
to `rtl/tg68k/TG68KdotC_Kernel.vhd` (gate `exec(directPC)` + `exec(ea_to_pc)` on
`pmmu_busy='0'`). NEXT: regen `.v` (running) → berr_bench must still PASS → full
7.1 sim boot must pass Finder launch with NO bomb → then FPGA build + HW validate.

## ★★ ROOT CAUSE (definitive — via CPU instrumentation, not trace archaeology)
The Verilator sim reproduces the bomb DETERMINISTICALLY at Finder launch (~video
frame 1768-1770). Boot-trace forensics were defeated by (a) prefetch GHOSTS in
cpu_trace.log and (b) MAME not logging interrupt handlers — so I instrumented the
CPU directly (an `[EXC]` exception logger; see findings doc + "gotchas" below).
It caught the fault unambiguously:
```
[EXC] F1768 F-LINE vec11 opcode_pc=00378004 SRhi=20[S=1 IPL=0] svmode=1
```
`$378004` is **mid-instruction**: the displacement word (`$FD48`) of `jsr
(-$2b8,PC)` at `$378002` (4-byte instr; correct return `$378006`). So a transfer
landed **2 bytes early** and executed `$FD48` as an F-line → bomb. Supervisor
mode (S=1) ⇒ HW "type 7" (privilege violation) is the SAME torn-PC garbage
execution landing on a privileged opcode instead of an F-line — same root, diff
surface vector by timing. TIMING-SENSITIVE (the walk-race tell): run#3 (old
binary) returned to `$378006` correctly and bombed at a *different* site; the
instrumented binary tore at `$378004`. Site shifts with tiny timing changes,
exactly like the bsr bug's 1-in-16k alignment.

MECHANISM: jsr/jmp (kernel ~5683-5716) assert `writePC` (return-address push) AND
`set(ea_to_pc)` (PC redirect). The redirect commits via `exec(ea_to_pc)='1' ->
TG68_PC <= addr` at kernel ~line 3454, which — unlike the v7-gated brw arm — was
**NOT gated by pmmu_busy**. When the push's stack write / prefetch stalls on a
PMMU walk, `clkena_lw` freezes the push while `clkena_in` keeps firing the ungated
redirect → `TG68_PC` advances one prefetch word before the frozen `writePC`
samples it → torn return address. (Cold page: the MMU-mode-swap routine
`$A03Exx` writes SRP/CRP/TC constantly at Finder launch, flushing the ATC, so the
next stack access walks.) v7 gated only the brw arm (which bsr uses); jsr's
`ea_to_pc` and rts/rte's `directPC` were left ungated.

## ★★★ THE FIX (APPLIED to the .vhd — needs regen + validation)
`rtl/tg68k/TG68KdotC_Kernel.vhd` ~line 3465-3468 (the TG68_PC-update ELSIF chain
inside `IF clkena_in='1'`): added `AND pmmu_busy='0'` to two arms, mirroring the
v7 brw gate:
```vhdl
ELSIF exec(directPC)='1' AND pmmu_busy='0' THEN   -- rts/rte/jmp-abs pop
    TG68_PC <= data_read;
ELSIF exec(ea_to_pc)='1' AND pmmu_busy='0' THEN   -- jsr/jmp-indirect redirect
    TG68_PC <= addr;
```
Rationale: during a walk (pmmu_busy='1') both arms hold TG68_PC; on the first
non-busy edge (walk done, data_read/addr valid — the same edge the frozen push
samples) they commit. Non-walk path unaffected (pmmu_busy≡0). Low risk, but the
walk-completion edge race is why the **full boot is the arbiter**.

## ★★★ EXACT NEXT STEPS (in order)
**0. Regen DONE + fix verified in the .v (2026-07-03).** `scratch/do_regen.sh`
regenerated `TG68KdotC_Kernel.v` (131583 lines) + `TG68K_Cache_030.v` (9747)
cleanly; the fix is present (the diff vs HEAD shows extra `~pmmu_busy` gating
terms feeding the TG68_PC arms — the rest of the whole-file diff is CRLF↔LF
line-ending noise, see tree note). If you ever need to re-regen: `wsl bash -lc
'tr -d "\r" < scratch/do_regen.sh > ~/do_regen.sh && bash ~/do_regen.sh'`.
do_regen.sh mirrors `rtl/tg68k/conv_lf.sh` (analyze Pack→ALU→**PMMU_030→
Cache_030**→Kernel; entity DEFAULTS no -g; libLLVM shim) — the OLD
`scripts/regen_tg68k.sh` FAILS ("TG68K_PMMU_030 not found"), it predates the PMMU
retrofit. GHDL 4.1.0 in WSL; ~5-8 min.

**1. berr_bench regression (fast, ~2-3 min) — does the gate break normal RTE?**
`cd verilator/berr_bench && make && ./obj_dir/Vberr_top` → must print
`PASS: all probe forms continue past with correct register AND CCR effects`.
(Probes #1-13 exercise RTE/continue-past; a PASS = the gate didn't break normal
returns. #13 bsr is INFORMATIONAL — bench freeze model distorts walk interleave;
don't gate on it.) Also `cd verilator/ksw_bench && make && ./obj_dir/*` and
`pmmu_bench` should PASS.

**2. Rebuild Vemu (re-verilate — the .v changed → ~10-15 min).**
`cd verilator && make`. (NOT the fast C++-only rebuild; the .v changed.)

**3. Full 7.1 sim boot = THE ARBITER (~2.5h).** Boot a FRESH disk copy past the
crash and check for the bomb:
```
cd verilator && cp ../scratch/MacLC_7-1.hda ../scratch/sim71_fix.hd
./obj_dir/Vemu --headless --no-cpu-trace --heartbeat \
  --rom ../releases/boot0-nomemcheck.rom --scsi0 ../scratch/sim71_fix.hd \
  --screenshot 1800,2000,2400 --stop-at-frame 2500 > sim_fix.log 2>&1
```
Run it as a TRACKED background Bash call (run_in_background), NOT nohup (WSL VM
kills nohup jobs when wsl.exe exits). PASS = screenshot_frame_1800/2000 show
Finder DESKTOP (or continued boot), NO "bad F-Line" dialog. FAIL = bomb still
present (fix wrong/incomplete) OR a NEW hang (gate broke a return → re-examine
the walk-completion edge). The `[EXC]` logger is still compiled in (frame-gated
F>=1600, A-line excluded) — grep `[EXC]` in sim_fix.log; ZERO F-LINE lines near
1768 = fixed.

**4. If sim PASSES → FPGA build + HW validate.**
`QUARTUS_BIN=/c/intelFPGA_lite/17.0/quartus/bin64 bash scripts/build.sh` (~15-22
min, Quartus compiles the .vhd DIRECTLY — the .vhd fix is what matters for FPGA;
the .v is only for Verilator). Deploy via `launch_unstable_core.py --push
./output_files/MacLCii.rbf --core MacLCii.rbf --delay 0.12`, confirm
coreRunning='MacLCii' + md5, hygiene (`refresh_disks.sh` + `cp MacLCii.nvr.bak
MacLCii.nvr`), cold boot 7.1. PASS = reaches Finder desktop, no "type 7". (HW
JTAG is DEAD at the type-7 wedge — rely on the HDMI screenshot; power-cycle if it
wedges.)

## STATE OF TREE / TOOLING / HW
- **Tree:** branch `video-performance`. **The intentional fix = ONLY
  `rtl/tg68k/TG68KdotC_Kernel.vhd` (+ regenerated `TG68KdotC_Kernel.v` /
  `TG68K_Cache_030.v`).** Instrumentation (kept, harmless): `verilator/sim_main.cpp`
  ([EXC] logger), `verilator/tg68k_debug.vlt` (trap signal taps). Docs:
  `CLAUDE.md` (sim flags/cwd section), `docs/findings_type7_sim_2026-07-03.md`,
  this file. ⚠ **The working tree has WIDESPREAD line-ending M-noise** (.gitattributes
  + many docs + ALU/PMMU/Pack.vhd + tg68k.v/.qip show as Modified but I never
  touched their content — CRLF↔LF). When committing the fix, `git add` ONLY the
  intended files; do NOT `git add -A` (would sweep in the line-ending churn).
  Also gitignore/rm the GHDL work artifacts (`rtl/tg68k/*.o`, `work-obj*.cf`,
  `*.v.tmp`).
- **v7 "fix #2" is INERT dead code** (data_write_tmp hold in a clkena_lw-gated
  block where pmmu_busy≡0) — safe to remove at the next kernel edit; not required.
- **HW:** MiSTer 192.168.99.143 (`scripts/local.env`). Currently running the v7
  core (`46cdae05`), sitting at the type-7 bomb (power-cycle before next cold boot).
- **Sims this session:** 7.1 scout/trace (run#1/run#3, DEAD; run#3 trace persists
  at `~/lc/verilator/cpu_trace.log`, F1400-1827); 7.5.5 control (DONE — no bomb,
  hangs at menu-bar-draw ~F2500 = separate 7.5.5 issue, but proves the F-line is
  7.1-specific); instrumented [EXC] run (DONE, caught the fault).

## GOTCHAS (all verified this session)
- **[EXC] logger MUST exclude A-line (trap_1010, vec10)** — it's the Toolbox
  trap-dispatch, fires hundreds/frame, floods the cap. sim_main.cpp already
  excludes it. Trust `opcode_pc` + the vector LABEL (from trap_1111 etc.); NOT
  `exe_opcode` (lags — holds the prefetched next instr) and NOT `trap_vector`
  (stale at the sample edge; read $028 for an F-line).
- **cpu_trace.log logs PREFETCH GHOSTS** (post-branch/rts/jmp PC+2 words that
  never execute). Never conclude an opcode ran from an opword grep.
- **MAME maincpu trace omits interrupt handlers** → sim-only-PC diff unreliable
  for IRQ code. MAME oracle `~/m71nmc.tr` is DISASSEMBLY format, not "PC OPWORD".
- **Regen: use conv_lf.sh's flow (scratch/do_regen.sh), NOT regen_tg68k.sh**
  (latter omits PMMU_030 → "not found"). GHDL needs the libLLVM-18 SONAME shim.
- **wsl.exe mangles inline `$()`/nested quotes/awk `$N`** — ALWAYS run via a
  script file (`tr -d '\r' < scratch/X.sh > ~/X.sh && bash ~/X.sh`).
- **nohup jobs DIE when wsl.exe exits** (WSL VM idle-terminates ~60s later) — run
  long sims/builds as TRACKED background Bash calls (run_in_background) so wsl.exe
  stays attached. /mnt/c survives; /tmp + ~/ jobs die.
- **Instrumentation perturbs timing** (Heisenbug): the instrumented binary tore
  at a different site than run#3. Adding cpu_trace can MOVE the tear — so trace
  the fix's PASS/FAIL by the BOMB (screenshot + [EXC]-absence), not by chasing a
  specific PC in a fresh trace.

## RELEVANT MEMORY
[[maclcii-fline-continue-past-root]] (full F-line→type-7 story; UPDATE when the
fix is HW-validated) · [[maclcii-mister-hardware-access]] (HW loops, WSL/GHDL,
[EXC]/.vlt instrumentation method) · [[maclcii-pmmu-sim-harnesses]] ·
[[timing-bugs-use-hw-not-ideal-sim]] · [[prefers-autonomous-driving]].
