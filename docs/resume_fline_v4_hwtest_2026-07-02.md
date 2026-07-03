# RESUME — v4 continue-past fix built + sim-validated; BLOCKED on HW power-cycle (2026-07-02)

## ONE-LINE STATE
The 7.1 "bad F-Line" bomb is root-caused and FIXED (Format-$B continue-past,
v4); the fix is **sim-proven** (berr_bench 5/5 + ksw + pmmu all PASS) and
**built** (`releases/MacLCii_flineFix_v4_20260702.rbf`, md5 `5953ba4d`,
STA all-positive incl. HDMI +0.025). The ONLY remaining step is HW validation,
which is **blocked: the MiSTer wedged** (pings but SSH:22 + HTTP:8182 both dead
across retries → needs a physical power-cycle by the user).

## THE MOMENT THE BOX IS BACK — do exactly this
```bash
cd /c/Temp/mistercore/MacLCII_MiSTer && source scripts/local.env
# confirm it's back:
curl -s -m5 -o /dev/null -w "%{http_code}\n" "http://$MISTER_HOST:$MISTER_HTTP_PORT/api/status"   # want 200
# hygiene (pristine disks + PRAM) and confirm 7.1 is the mount:
ssh -i "$MISTER_SSH_KEY" root@$MISTER_HOST "cd /media/fat/games/MacLCii && bash refresh_disks.sh && cp MacLCii.nvr.bak MacLCii.nvr && xxd /media/fat/config/MacLCii.s0 | head -1"  # expect games/MacLCii/MacLC_7-1.hda
# deploy v4:
python tools/misterdeploy/launch_unstable_core.py --push releases/MacLCii_flineFix_v4_20260702.rbf --core MacLCii.rbf --delay 0.12
# wait ~170s for cold boot, then:
bash scripts/grab.sh scratch/hw71_v4_boot.png
bash scripts/read_probes.sh 2>&1 | grep -E "PFLx|first:|last :|PFJM|last jump|PACT|PEXC"
```
**PASS signal:** no "bad F-Line" bomb; PFLx count=0 with NO wild jump; boot
proceeds toward Welcome/desktop (or wedges somewhere NEW = progress, chase next).
**Then the 2 follow-ups (same deployed build, just swap .s0 + reboot):**
1. **6.0.8 regression** (must still reach Finder — same validator code path):
   `sed -i 's/MacLC_7-1.hda/MacLC_6-0-8.hda/' /media/fat/config/MacLCii.s0` (via ssh),
   relaunch, screenshot. (Both mount strings differ in length — use the equal-length
   `MacLC_6-0-8.hda` vs `MacLC_7-1.hda.`? NO — pad: safest is OSD swap or rewrite the
   whole .s0 line. `printf 'games/MacLCii/MacLC_6-0-8.hda\0\0\0' | dd of=... seek=0 conv=notrunc`.)
2. **7.5.5** (THE GOAL — its MemMgr free-walk wedge $A0DE04 is likely the same
   continue-past class): swap .s0 to `MacLC_7-5-5.hda`, relaunch, screenshot.

## THE FIX (what changed, why)
Root cause (HW-captured + berr_bench-proven, NOT a guess): the 68030 Format-$B
**continue-past** RTE resumed at the WRONG PC. Mac OS pointer validators
($A0DBxx family) deliberately BERR on candidate pointers, clear SSW.DF at
frame+$0A, stuff the DIB at +$2C, and RTE to resume PAST the probe. The v2/v3
code reconstructed the resume PC from the faulting instruction's EA mode length
— WRONG for two-word opcodes: **`btst #$6,(A0)` = `$0810 $0006` (4 bytes, EA
mode 010)** → v3 stacked +2 → resumed on the `$0006` immediate word → decoded
garbage → **wild jump into the vector table → run up to $100 → `$FFFF` F-line
bomb.**

v4 (`rtl/tg68k/TG68KdotC_Kernel.vhd`): stop reconstructing length. Capture the
**prefetch pointer `TG68_PC` at external-BERR first-fire** (`berr_capture_nextpc
<= TG68_PC`, same latch point as berr_external_rw/fc/addr) and stack
`berr_capture_nextpc - 2`. Measured: TG68_PC at first-fire == next-instr + 2 for
EVERY validator read form (2/4/6-byte: move.l(d16,An)/movea.l(An)/tst.b(An)/
btst #imm,(An)/abs.L) → one `-2` replaces the fragile per-EA decode.
`berr_capture_opcode` still feeds the `rte_mmu_fix` register writeback.
`.v` regenerated via GHDL (both toolchains in sync). Quartus compiles the .vhd.

## VALIDATION HARNESS (new, reusable — the regression gate for berr/RTE work)
`verilator/berr_bench/` — byte-exact ROM validator handlers ($A0DB50 DIB=0,
$A0DB5C DIB=-1) drive the real kernel through 5 probe forms; PASS = all 5
markers + D0←DIB + no derail + exactly 5 faults. Run:
`cd verilator/berr_bench && make && ./obj_dir/Vberr_top` (add `-v` for frame
dump). v4 = PASS; v3 = FAIL on probe#4 (btst). ksw_bench + pmmu_bench also
re-run clean on v4.

## KNOWN RESIDUAL RISK (only chase if a NEW symptom appears — do NOT pre-fix)
The `rte_mmu_fix` writeback only completes MOVE/MOVEA to Dn/An. TST/BTST
continue-past now RESUME correctly (PC fixed) but their CCR is NOT set from the
DIB. If a validator's post-probe `beq/bmi/btst` needs those flags and 7.x shows
a NEW (non-F-line) wrong-verdict symptom, extend the gate to set CCR from DIB
for TST/BTST. Unproven; the PC derail was the confirmed bomb cause. Ship first.

## HW GOTCHAS THIS SESSION
- MiSTer wedged after ~5 deploys + spaced probe reads over a long session
  (pings, SSH+HTTP dead). Power-cycle to recover. Reboots weren't rapid-JTAG
  abuse this time — likely just long-uptime service rot; not diagnostic of the fix.
- Capture-build note: PFLx clears on CPU reset, so a bomb-then-reset boot reads
  PFLx=0 even though the bomb fired — corroborate with the PFJ fetch-ring
  (freezes on the F-line trap) and PEXC, and a fresh screenshot.

## COMMIT WHEN HW-VALIDATED
Branch `video-performance`. Changed: TG68KdotC_Kernel.vhd (+.v regen),
TG68K_Cache_030.v (regen), MacLC.sv + tg68k.v + scripts/cpu_state.tcl (F-line
capture probes PFLA-E/PFH0-7/PFJx), verilator/berr_bench/ (new). Findings:
docs/findings_fline_71_oracle_2026-07-01.md. Memory:
maclcii-fline-continue-past-root.
