# RESUME — 7.1 F-line bomb FIXED; chase the NEW "error type 7" at Finder launch (2026-07-02)

Read cold to continue. The multi-day "bad F-Line instruction" bomb is FIXED and
committed. System 7.1 now boots all the way to **Finder launch**, where it hits
a *new, separate* crash: **"Sorry, a system error occurred. Finder — error type
7."** Your job: root-cause and fix that one, using the exact method that cracked
the F-line bomb (the Verilator sim now reproduces the real boot deterministically).

## ★ ONE-LINE
7.1 boots past the whole ROM + System and dies at **Finder launch with "error
type 7"** (classic Mac SysError ID 7 = **privilege violation / vector 8** — but
CONFIRM the real faulting vector from the sim/trace; do NOT trust the code-table
from memory). The box wedges hard on it (HTTP/JTAG dead → power-cycle). This is a
DIFFERENT, much later failure than the F-line bomb — real progress, new problem.

## ★★ WHAT WAS JUST FIXED (context — do not re-chase, it's committed)
`HEAD = 40c8f43` "fpga: fix System 7.1 bad-F-Line bomb — bsr return-push torn by
PC-redirect during a PMMU walk stall." Root cause: a `bsr.w/bsr.l` whose
extension word is the LAST word of a mapped page (MMU/TC on) tore its
return-address push — the next-page prefetch walk froze `clkena_lw` while the
`TG68_PC_brw` branch redirect (left ungated by `pmmu_busy` in the PMMU retrofit)
advanced `TG68_PC` before the frozen push sampled it → rts popped garbage →
vector-table-as-code → `$100`=`$FFFF` F-line. Fix = two lines in
`rtl/tg68k/TG68KdotC_Kernel.vhd` (uniform `pmmu_busy` gate on the brw arm +
`data_write_tmp` hold during a stalled data access). Shipped as
`releases/MacLCii_flineFix_v7_20260702.rbf` (md5 `46cdae05`, STA clean). HW
confirmed: F-line bomb GONE, boot reaches Finder launch. This is SOLID; the
type-7 is downstream and unrelated to the (now-correct) push path.

## ★★★ THE METHOD THAT WORKS — USE THIS FIRST (the session's real breakthrough)
**The Verilator sim reproduces the real 7.1 boot deterministically.** CLAUDE.md's
"no hard drive in the sim" was only about the default; `--scsi0 <disk>` mounts a
real image. This gives FULL instruction-level visibility — it is how the F-line
bomb was cracked (sim bombed at trace frame [F1412]; `cpu_trace.log`'s @data-addr
annotations handed over the whole corruption chain).

Boot 7.1 in the sim (headless — WSLg-proof; `--headless` is now wired, 2026-07-02):
```bash
wsl bash -lc "cd verilator && ./obj_dir/Vemu --headless --no-cpu-trace \
  --rom ../releases/boot0-nomemcheck.rom --scsi0 ../scratch/sim71.hd \
  --screenshot 1450,1800,2200,2600,3000,3500,4000 --stop-at-frame 4200"
```
(`scratch/sim71.hd` = a fresh copy of `/media/fat/games/MacLCii/MacLC_7-1.hda`;
re-copy via scp if stale. `boot0-nomemcheck.rom` md5 `dcc7c7ac` = what the MiSTer
boots. 10 MB is the default. Sim runs ~80 min per 1000 video-frames.)

To capture the fault: once you know the crash frame, re-run WITH `cpu_trace.log`
(drop `--no-cpu-trace`) and `--trace-frames A,B` bracketing it, then:
```bash
grep -n ' 00000100: FFFF' verilator/cpu_trace.log   # F-line site (should now be ABSENT)
# find the type-7: search for the privilege-violation vector fetch / SR change /
# the first execution at a garbage or user-mode-privileged PC near Finder launch
```

## ★★★ NEXT STEPS (in order)
**A. Confirm the F-line fix in sim + find where type-7 lands (no trace, fast).**
A headless run is ALREADY in flight from this session (screenshots at
1380/1420/1450/1600/2000/3000, stop 3100). Check `verilator/screenshot_frame_*.png`
timestamps: fresh 1420/1450 showing boot PROGRESS (not the bomb dialog) = F-line
fix confirmed in sim. If it exits at 3100 still booting, relaunch with the wider
`--screenshot` set above to locate the type-7 crash frame (Finder launches late —
well after the old F-line point). NOTE: the sim's zero-latency SCSI may let it
boot CLEAN past where HW hits type-7 — if so, type-7 is HW-timing-class (see C).

**B. If the sim REPRODUCES type-7 → trace + MAME-diff (the winning play).**
1. Trace-bracket the crash frame; find the FAULTING instruction and the REAL
   vector (confirm "type 7" = which exception; privilege-violation = vec 8 = the
   CPU took a supervisor-only op in user mode, or the S-bit is wrong).
2. Diff the divergence vs MAME's healthy trace. The full-boot maincpu trace of a
   HEALTHY 7.1 is at `~/m71nmc.tr` in WSL home (7.2 GB, matched config:
   nomemcheck ROM + same disk + 10 MB; format `PC OPWORD`). Regenerate with
   `verilator/mame/trace_nmc2.dbg` if gone. Find the last common PC then the
   branch input that diverges — that's the hardware value to chase.
3. Prime suspect **H1**: another instance of the SAME walk-stall control-flow
   corruption class we just fixed — a torn push/pop or a **mis-restored SR during
   an exception/RTE that overlaps a PMMU walk**, landing the CPU in user mode on a
   privileged op. Privilege-violation-at-Finder-launch fits an S-bit/SR handoff
   bug. Look at RTE/trap SR restore + the `pmmu_busy & state(1)` hold you just
   added — is there a sibling path (SR/CCR/A7) that also needs the hold?
   **H2**: a genuinely separate MemMgr/SCSI/video issue only now reachable.
   **H3**: SR supervisor-bit handling in exception dispatch specifically.

**C. If the sim BOOTS CLEAN past Finder (type-7 is HW-only) → chase on HW.**
Then it's timing-class ([[timing-bugs-use-hw-not-ideal-sim]]): power-cycle the
box, re-run hygiene + cold boot v7, and read the probes at the type-7 wedge. The
fetch-ring v2 (PFA0/PFA1/PFW0/PFJX wide probes) + PFLX capture the pre-crash
instruction stream. Add a targeted probe for the SR/S-bit + the faulting vector
if the ring doesn't pin it. SCSI-timing is a live suspect (sim can't see it).

## STATE OF HW / TREE / TOOLING
- **HW:** MiSTer at 192.168.99.143 (`scripts/local.env`). This session it WEDGED
  on type-7 (HTTP/JTAG dead), was **power-cycled**, and the v7 core was relaunched
  (`coreRunning='MacLCii'`, RBF `46cdae05` in `/media/fat/_Unstable/`). It is
  currently cold-booting 7.1 → will re-hit type-7 and likely wedge again. Reboot
  freely; the tripwire is RAPID JTAG (single spaced `read_probes.sh` only), and
  the wedge signal is HTTP/SSH going unresponsive. Run hygiene before every cold
  boot: `ssh … "cd /media/fat/games/MacLCii && bash refresh_disks.sh && cp
  MacLCii.nvr.bak MacLCii.nvr"`.
- **Tree:** branch `video-performance`, `HEAD=40c8f43` (the F-line fix, committed
  clean). Working tree has only intentionally-excluded items left (Apple ROM dirs
  `verilator/mame/roms*`, Quartus crash `cr_ie_info.json`, `conv_lf.sh`, `scratch/`).
- **A headless sim run is LIVE** (see step A) — check its screenshots first.
- **PRAM baseline REPAIRED this session:** the MiSTer `.nvr`/`.nvr.bak` were a
  corrupt walking-bit pattern (Jun-29 fallout, wrongly enshrined as "pristine");
  both replaced with the sane `rtl/egret/egret.pram` seed. MAME `~/.mame/nvram/
  maclc2/egret` restored from `.healthy_backup`. Do NOT re-transplant the garbage.

## TOOLING GOTCHAS (all verified this session — heed them)
- **Sim `--headless`** (now wired): use it for ALL long boots so WSLg display
  outages can't kill the run. Windowed only for short interactive viewing.
- **WSLg display drops** ("lost the screen"): `wsl --shutdown` (PowerShell) BEFORE
  relaunching any GUI app when the display is suspect. Shutdown kills WSL jobs +
  wipes /tmp; WSL-home `~/` (ext4) survives — keep multi-GB traces there.
- **ISSP probe deck >~40 instances corrupts the sld hub** (all-ones reads). The
  fetch-ring/F-line probes are already consolidated into wide instances
  (PFA0/PFA1/PFW0/PFJX/PFLX). Do NOT add many narrow probes; pack wide (≤511b).
- **All-`FFFFFFFF` probe reads** = JTAG can't clock (box wedged) OR deck too big —
  NOT real state. Corroborate with HTTP liveness + a screenshot.
- **MAME oracle:** `verilator/mame/mame_headless.sh` for snapshots; `-debug
  -debugscript` for traces (opens a debugger WINDOW under WSLg — that was the
  "mystery window"; expect it). Use `roms_nomemcheck` to match the MiSTer's ROM.
  End debug scripts with `go` + `-seconds_to_run` (a `quit` can segfault). The
  bad-CRC red warning overlay has NO suppress flag in MAME 0.264 — it self-passes.
- **berr_bench probe #13** (page-cross bsr) is INFORMATIONAL: the bench's
  full-freeze clkena model distorts the walk interleave, so the boundary-bsr
  result there does not track the real integration — **the full Vemu boot is the
  arbiter** for walk-interleave timing bugs. #13b/#13c (no-overlap controls) DO
  gate. Same caveat applies to any type-7 walk-race repro you add.
- **Disk corruption from hard restarts** ([[maclcii-disk-corruption-from-hard-restarts]]):
  refresh_disks.sh restores pristine each boot, but don't hard-restart mid-write.

## DO-NOT-RE-CHASE
- **The F-line bomb / the bsr push race** — FIXED + committed (`40c8f43`), HW +
  sim + bench confirmed. type-7 is downstream and unrelated to the push path.
- **Continue-past CCR/register (v4-v6)** — correct and shipped in v7; not the
  type-7 cause (those validators ran fine on the way to Finder launch).
- **ROM / disk / PRAM** — all exonerated by MAME A/B this session (healthy MAME
  boots our exact nomemcheck ROM + same disk + even the corrupt PRAM).

## RELEVANT MEMORY
[[maclcii-fline-continue-past-root]] (the full F-line story + v7 fix; UPDATE it
when type-7 is understood) · [[maclcii-mister-hardware-access]] (HW loops, WSLg,
`--headless`, ISSP-deck limit) · [[maclcii-pmmu-sim-harnesses]] ·
[[timing-bugs-use-hw-not-ideal-sim]] (if type-7 won't repro in sim) ·
[[maclcii-disk-corruption-from-hard-restarts]] · [[prefers-autonomous-driving]].
Full technical writeup of the whole hunt: `docs/findings_fline_ccr_junkdata_2026-07-02.md`.
