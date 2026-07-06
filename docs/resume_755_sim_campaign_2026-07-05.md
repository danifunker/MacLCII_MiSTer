# RESUME — 7.5.5-to-desktop sim campaign, macOS machine (2026-07-05 ~23:40)

Mission (user, 2026-07-05): get **System 7.5.5 booting to the Finder desktop
in the Verilator sim**, autonomously; validate 7.1 (v9 fix) along the way;
commit + push progress. **MiSTer is DOWN** — sim-only, no deploys, no HW steps.

## Environment (NEW — first session on this Apple M1 Mac)
- Fresh checkout at `/Users/dani/repos/MacLCII_MiSTer`, branch
  `video-performance`. Old WSL/Windows tooling notes in docs are stale here.
- Verilator 5.048 + SDL2 + GHDL 6.0.0 + MAME via homebrew, all verified.
- Sim rebuilt **1.53x faster** (commit `83ccf91`): no `--trace`/`--timing`,
  `OPT_FAST=-O3`, keep-alive `.vlt` rule (see CLAUDE.md note). ~5.4 s/frame
  single-run; ~6.5 s/frame with two parallel runs.
- Disk masters: `scratch/MacLC_7-1.hda`, `scratch/MacLC_7-5-5.hda`
  (unzipped from ~/Downloads; 7.5.5 md5 f2d4b662… matches MAME ground-truth
  docs). Sims boot COPIES only.

## IN FLIGHT (launched ~22:47, ~5-6 s/frame)
1. **7.1 GUI run** (user-visible window; CWD `verilator/`):
   `./obj_dir/Vemu --no-cpu-trace --heartbeat --rom
   ../releases/boot0-nomemcheck.rom --scsi0 ../scratch/sim71_gui.hd
   --screenshot 1800,2000,2400` → `verilator/sim_gui.log`, NO stop frame
   (stop it manually after F2400 verdict). PASS = Finder desktop shots,
   zero [EXC] F-LINE (logger arms at F>=1600). This re-validates v9 on this
   machine/toolchain.
2. **7.5.5 headless run** (CWD `sim755run/`):
   `../verilator/obj_dir/Vemu --headless --no-cpu-trace --heartbeat --rom
   ../releases/boot0-nomemcheck.rom --scsi0 ../scratch/sim755_v9.hd
   --screenshot 800,1400,1800,2200,2600,3000,3400 --stop-at-frame 3500`
   → `sim755run/sim755_v9.log`. THE investigation run: pre-v9 control (old
   machine, 2026-07-03) hung at menu-bar draw ~F2500; v9 (fetch-walk address
   hold) may change that. Both runs HB-identical through F400+ (common ROM
   phase — expected per MAME ground truth).

Monitors tail both logs (HB every 100f + [EXC]/PCRING/EXIT). Timeline @~5.5
s/f: F800 Welcome ≈ 00:05, 7.1 F1800 ≈ 01:30, 7.5.5 F2500 ≈ 02:30, F3500
end ≈ 04:00.

## DECISION TREE on the 7.5.5 verdict
- **Reaches desktop** (screenshots 2600+ show menu bar + icons): v9 fixed it
  too → jump to "wrap-up" below; consider a longer confirm run.
- **Wedges** (HB PC parked in a loop; screenshots frozen): grab the loop PCs
  from `[HB]` lines. If ≈ `$A0DE04` → the HW MemMgr free-walk wedge
  reproduced in sim (GREAT — deterministic repro). Then:
  1. Relaunch overnight with `--trace-frames <wedge-300>,<wedge+100>`
     (bounded cpu_trace forensic capture; CWD sim755run, fresh disk copy).
  2. MAME ground truth for the SAME window: data-read taps on the heap
     range the walk traverses (see gotchas below — do NOT use fetch taps or
     headless debugger printf). `verilator/mame/memwalk_755.lua` needs the
     data-tap refit first.
  3. Suspects, in order (docs/audit_clkena_walk_2026-07-05.md): wrong loaded
     VALUE → `last_data_read`/`last_data_in` mid-fetch-walk pollution
     (:1738); spurious format-error → `rte_format_word` (:1767); else a
     PMMU translation/32-bit addressing bug (resume_755_desktop_32bit_pmmu
     doc's hypothesis) — compare walked addresses vs MAME.
- **Bombs** ([EXC] lines): vector + opcode_pc point the way; compare against
  the type-7 family playbook in findings_type7_sim_2026-07-03.md.

## Ground truth / oracle (ALL VERIFIED TODAY on this Mac)
- **MAME maclc2 boots this exact 7.5.5 image to full Finder desktop at BOTH
  10M and 4M** (sim's hardwired config is 4MB — `sim.v:192`). So any sim
  wedge is core logic, not memory pressure. Goal-state PNG:
  `scratch/mamesnap755_4m/maclc2/f0000.png` (menu bar File/Edit/View/Label/
  Special + Mac7-5-5 disk + Trash).
- Romset: `verilator/mame/roms/maclc2/` rebuilt from `releases/boot0.rom`
  byte-lanes (0476=hh=byte0 … 0473=ll=byte3) + `rtl/egret/*.bin`. boot0.rom
  = pristine LC II ROM; boot0.rom.stock is a Mac LC ROM (WRONG for maclc2);
  boot0-nomemcheck.rom = patched (sim boots with it, MAME must not).
- `mame_headless.sh <disk> 4M <frame> <outdir> <secs>` works as documented.
- Benches berr/ksw/pmmu ALL PASS on this Mac (committed kernel). They also
  pass on a GHDL-6.0.0-regenerated kernel (`scratch/*.ghdl6`) — regen flow
  usable if a .vhd fix is needed, but requires full boot revalidation
  (output differs textually from the committed WSL-era .v; committed .v
  RESTORED in tree, do not commit the .ghdl6 files).

## Hard-won macOS/MAME gotchas (do not relearn)
- MAME `-debug -debugger none -debugscript`: bp/printf output is DISCARDED.
  Windowed debugger = Cocoa window (don't, user's desktop).
- MAME Lua `install_read_tap` NEVER sees opcode fetches (direct path) — tap
  DATA reads instead; range end needs low 2 bits set (…23) or install fails.
- Foreground `sleep` is blocked in this harness — Monitors/background tasks.
- zsh nomatch aborts on unmatched globs — quote or use grep -r.
- Benign every boot: `[BERRFRAME] F0 live_pc=00000004` + F9 `faddr=00022000`
  pair (reset artifact + ROM hw-probe, continue-past by design).

## State of tree
Commits today: `83ccf91` (sim speedup), `115dcea` (walk audit doc). Pushed.
Untracked junk to never commit: `sim755run/`, `scratch/`, `verilator/*.log`,
`verilator/bench_*.log`, `verilator/build*.log`, mame roms dir.
`verilator/mame/memwalk_755.{lua,dbg}` uncommitted — refit before commit.

## Wrap-up checklist when 7.5.5 reaches desktop (eventually)
1. Full-boot confirm run with screenshots to F3500+, zero [EXC].
2. Commit any fix (kernel .vhd edit ⇒ regen via rtl/tg68k/conv_lf.sh ⇒
   re-verify benches + BOTH OS boots) with findings doc; push.
3. Update memory files (see MEMORY.md index) + this resume doc.
4. Leave HW validation parked until the user revives the MiSTer (explicit
   deploy gate stands).
