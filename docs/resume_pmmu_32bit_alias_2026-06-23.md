# Resume: MacLCii boot Sad Mac = TG68 PMMU 32-bit-alias mistranslation (2026-06-23)

Read cold to continue. The boot `0000000F/00007FFF` Sad Mac is **root-caused** (MAME-confirmed): a
TG68 **PMMU mistranslation of the 32-bit ROM alias** during the 24→32-bit MMU-mode switch. The whole
fix+validate loop runs **locally in WSL** (no MacBook). Just need to pin the exact bad line in the
PMMU walk and fix it. Companion (full evidence chain): **`docs/findings_berr_hw_pctrace_2026-06-22.md`**
(read UPDATE 4 first). Memory: **`maclcii-sadmac-0f-is-pmmu-mistranslation`**, **`maclcii-mister-hardware-access`**.

## TL;DR — what the bug IS (and what it is NOT)
- **NOT** the Format-$B continue-past RTE bug that `docs/resume_berr_hw_continue_past_2026-06-21.md`
  chased — that whole thread was a wrong detour. The FC7 `moves.w $22000` faults are a red herring
  (they recover). The uncommitted continue-past `berr_setup_*` edit in `TG68KdotC_Kernel.vhd` is a
  NO-OP for this Sad Mac (keep or drop; not load-bearing).
- **IS:** at ROM `$A416B2` the boot runs `pmove (A3),tc` (enable/reconfig the MMU into 32-bit mode),
  then `jmp (A5)` where `A5=$40A0010E` (a 32-bit ROM alias). MAME translates `$40A0010E`→ROM and
  **boots on**; TG68 **mistranslates it to high-RAM `$9FEE40`** (10M) / `$3FExxx` (4M) → derail → Sad Mac.
- This is the **June 15–18 PMMU bug**, one layer deeper. Two fixes from that work are ALREADY in the
  kernel: bsr.w PMMU-stall push (`c8895d8`, in HEAD) + instruction-prefetch grace across MMU enable
  (`mmu_fetch_grace`, `TG68KdotC_Kernel.vhd:~748/1147`). The grace fix lets the prefetched `jmp`
  execute; the REMAINING bug is the **jmp-target alias translation** (the next page after the grace
  window ends). The June work wedged earlier (first `pmove TC` `$A03F12`); grace advanced it to `$A416B2`.

## THE root cause (MAME oracle — the correct walk)
HW capture (JTAG, `scripts/read_probes.sh`): at the derail, `exe_pc`=ROM (`$A416B6`) but the program
fetch's PHYSICAL bus addr = `$9FEE40` (10M) — CPU logically in ROM, MMU sends the fetch to high-RAM.
MAME `maclc2` (run in WSL — see below) page table (`verilator/mame/pt_root10.lua`):
```
4M:  CRP @ $3FE820 ; TC=$80F84500 (E=1, IS=8, PS=32K, TIA=4) ; TT0=TT1=0
     root[10] @ $3FE870 = 7FFFFC19 / 00A00000  DT=01 early-term page descr -> ROM base $00A00000
10M: CRP @ $9FE820 ; root[10] @ $9FE870 = 7FFFFC19 / 00A00000  (same; CRP base scales with RAM)
=> $40A0010E --(IS=8 strips $40)--> $A0010E --TIA=$A=root[10] early-term--> physical $00A0010E (ROM)
```
**Smoking gun:** TG68's wrong target (`$9FEE40`/`$9FE876`/`$3FExxx`) sits INSIDE/just-past the root
table — it mis-extracts the early-term descriptor for the alias (outputs near the descriptor's
ADDRESS region, not its base field `$00A00000`; root[13]/[15] are indirect DT=2 → `$xFE8xx`). The
static functions look correct (`get_table_index` returns 10; `calc_effective_page_shift`=PS+TIB=20;
`phys_base_from_desc` takes `desc(31:8)` — all in `rtl/tg68k/TG68K_PMMU_030.vhd`), so it's a
**runtime** divergence in the walk state machine (`W_ROOT`/`W_ROOT_LOW` @ ~`:2853/3059`, DT dispatch,
early-term completion) — likely which descriptor it reads or how it assembles the early-term physical.

## The local WSL toolchain (NO MacBook — this was the key unblock)
Ubuntu-24.04 WSL has it ALL: MAME 0.264 (`/usr/games/mame`, has `maclc2`!), Verilator 5.020, GHDL 4.1.0,
and `/mnt/c/Temp/mistercore/MacIIvi_MiSTer` (PMMU SST corpus). Gotchas (all already worked out):
- **MAME `maclc2` ROMs** (already built): `verilator/mame/roms/maclc2/` (CRC-valid, from `boot0.rom`
  split into 4 byte-lanes [hh,mh,ml,ll]=bytes[0,1,2,3] + Egret ROMs from `rtl/egret/`) and
  `verilator/mame/roms_nomemcheck/maclc2/` (force-loaded `boot0-nomemcheck.rom` lanes, BAD-CRC, runs).
  Run: `wsl.exe -- bash -lc "cd /mnt/c/Temp/mistercore/MacLCII_MiSTer && mame maclc2 -rompath verilator/mame/roms_nomemcheck -ramsize 4M -video none -sound none -seconds_to_run 5 -nothrottle -skip_gameinfo -autoboot_delay 1 -autoboot_script verilator/mame/pt_root10.lua"` (REG_OUT=<winpath> for the output file).
  MAME gotchas: debugger default CPU is the Egret HC05 (`focus maincpu`); 030 PC breakpoints DON'T fire
  (use data `wpset`+`wpclear` or it hangs headless); `printf` has no headless sink (Lua→file).
  Ready Lua: `verilator/mame/{pt_root10,mame_pagetable,mmu_state}.lua`.
- **GHDL `.v` regen** (`rtl/tg68k/convert_to_verilog.sh`): GHDL's LLVM backend wants `libLLVM-18.so.18.1`
  but Ubuntu ships `libLLVM.so.18.1` — shim it: `mkdir -p ~/ghdllib && ln -sf /lib/x86_64-linux-gnu/libLLVM.so.18.1 ~/ghdllib/libLLVM-18.so.18.1`, run with `LD_LIBRARY_PATH=$HOME/ghdllib`. Strip CRLF first: `sed -i 's/\r$//' convert_to_verilog.sh`. (No sudo on WSL.)
- **Verilator sim build:** rsync repo to WSL-native `~/lc` (exclude output_files/db/.git/obj_dir) — 9p
  `/mnt/c` is too slow. In `~/lc/verilator/Makefile`: `V_OPT = --public-flat-rw` ONLY (the original
  `--x-assign fast --x-initial fast --noassert` are INVALID on Verilator 5.020 — drop them; without
  `--public-flat-rw`, g++ errors "no member ...cb2_i"). PMMU trace: `V_DEFINE += +define+PMMU_TRACE=1`
  (already set). After ANY `.vhd` edit: re-run `convert_to_verilog.sh` (LLVM shim) else `tg68k.v` pins
  mismatch the stale kernel `.v` (PINNOTFOUND). Build: `cd ~/lc/verilator && make obj_dir/Vemu.cpp && (cd obj_dir && rm -f *.o && make OPT_FAST=-Os OPT_SLOW=-Os -f Vemu.mk)`. **A built Vemu exists at `~/lc/verilator/obj_dir/Vemu` (with --public-flat-rw + PMMU_TRACE + regenerated .v) as of this session.**

## IMMEDIATE next step — get TG68's PMMU walk of the alias (then fix)
**The full-boot Verilator sim is impractically SLOW to reach `$A416B2`.** With `--public-flat-rw`
(needed for the `cb2_i` C++ taps) it managed only ~F34 (`$A45EE8`) in a 25-min run; `$A416B2` is much
later than the old F156 wedge. So a boot-sim trace is NOT the fast path. Captured 6 `make_berr` early
(the FC7 red-herring probes), 0 PMMU REQ in the `$3Fxxxx` gate — the alias walk wasn't reached.
Faster ways to pin the walk, in preference order:
1. **MacIIvi PMMU SST harness** (`/mnt/c/Temp/mistercore/MacIIvi_MiSTer/SingleStepTests/tg68k/`,
   Verilator) — isolated single-translation tests, no boot, FAST, and the regression validator you
   need anyway. Either run the maciivi-pmmu corpus (extract JSONs — the `prebuilt/*.tgz` are `.hda/.dsk`
   boot fixtures, NOT the SST JSONs; fetch the TomHarte 68030 set) to find the failing early-term/alias
   pattern, OR craft a targeted JSON for the exact case (TC=`$80F84500`, CRP→a root table with
   root[10]=`7FFFFC19/00A00000` DT=01, translate `$40A0010E`, expect phys `$00A0010E`). Build it like
   the docs say: `cd SingleStepTests/tg68k && make` (it links `../../rtl/tg68k/TG68KdotC_Kernel.v` —
   regen first with the LLVM shim). This both reproduces the bug AND validates the fix.
2. **HW JTAG capture** — plumb the PMMU walk signals (`debug_pmmu_walker_addr`/`saved_addr`/`crp_lo`/
   `tc`/`wstate`, sim-only behind `ifdef PMMU_TRACE` in the kernel) out to JTAG like `dbg_tg68_pc` was
   (tg68k.v output + MacLC.sv wire + dbg_probes PFR capture at the first high-RAM fetch), FPGA build,
   read at the derail with `read_probes.sh`. Proven infra; ~24-min build.
3. **Boot-sim (last resort):** to drop `--public-flat-rw` (much faster sim), #ifdef-guard the Egret
   debug taps in `verilator/sim_main.cpp` that reference `emu__DOT__dc0__DOT__via__DOT__cb2_i` (and
   scc/egret) so the build doesn't need every signal public; use `boot0-fastmem.rom` (NOT nomemcheck —
   it stalls around `$A45-A46xx`); even then reaching `$A416B2` may take a long run.
4. With the walk in hand, diff vs the oracle (root[10]@`$3FE870`→`$00A0010E`), fix the divergent line
   in `TG68K_PMMU_030.vhd`, then VALIDATE LOCALLY: `convert_to_verilog.sh` (LLVM shim) → rebuild sim →
   re-run → boot must run PAST `$A416B2` (no derail; toward the desktop checkerboard, ~F200+). Then
   regression: MacIIvi PMMU SST corpus (`/mnt/c/Temp/mistercore/MacIIvi_MiSTer/SingleStepTests/`,
   Verilator harness in `tg68k/`; corpus JSONs need extracting from `prebuilt/*.tgz` — the `.hda/.dsk`
   tarballs are boot fixtures, NOT the SST JSONs; fetch the TomHarte 68030 set if needed).
3. Then FPGA: `rm -rf db incremental_db && bash scripts/build.sh` (compiles `.vhd` directly, ~24 min),
   deploy `python tools/misterdeploy/launch_unstable_core.py --push output_files/MacLCii.rbf`, confirm
   the HW boots to the System 6 Finder (not Sad Mac) via `bash scripts/grab.sh` + Read the PNG.

## Dead-ends — do NOT repeat
1. The continue-past RTE fix (resume_berr_..._2026-06-21) — wrong bug for THIS Sad Mac.
2. `docs/MacLC_ROM_disasm.txt` is MIS-ALIGNED at `$A416xx` (shows `bsr.w`; the real bytes `$F0134000`
   = `pmove (A3),tc`). capstone renders cpid-0 PMMU ops as bogus `fmove` — use MAME or `m68k-elf-objdump -m m68k:68030`.
3. PEXC `$A0DBFC vec-2` is a FALSE POSITIVE (the ROM's `movea.l $8.w,a2` trips the vec_fetch detector).
4. HW JTAG can't read the RAM MMU table directly (no RAM-read probe); use MAME for the table/oracle.
5. The `$A46AF6` DTACK wedge appears with `boot0-nomemcheck.rom` in the sim — use `boot0-fastmem.rom`.

## Key addrs/constants
- Derail: `pmove (A3),tc` @ `$A416B2`; `jmp (A5)` @ `$A416B6`, A5=`$40A0010E` (32-bit ROM alias).
  Sad Mac `0000000F/00007FFF`. MMU on from `$A0006E`/`$A03EB2` (earlier `pmove tc`s).
- ROM↔addr: 32-bit alias `$40A00000`+off ; 24-bit `$00A00000`+off ; ROMdoc `$40800000`+off ; SD ROM
  offset = runtime & 0x7FFFF.  ROMs: `releases/boot0{,-nomemcheck,-fastmem,-lc}.rom`.
- TC `$80F84500`: E=1, PS=$F(32K), IS=8, TIA=4, TIB=5, TIC=TID=0  (IS+PS+TIA+TIB=32).

## Working-tree state (branch `fix/tg68-format-b-continue-past`, all UNCOMMITTED)
- `TG68KdotC_Kernel.vhd`: continue-past `berr_setup_*` fix (no-op for THIS bug) + debug taps
  (`debug_berr_frame_pc`/`exe_opcode`/`berr_opcode`, `debug_TG68_PC`→`kernel_tg68_pc`).
- `tg68k.v`/`MacLC.sv`/`dbg_probes.sv`/`scripts/cpu_state.tcl`: PFR0-3 now a bus-txn/logical-vs-physical
  derail trace + the `dbg_tg68_pc` tap (the HW capture that proved the mistranslation).
- `verilator/Makefile`: `PMMU_TRACE` enabled + (in `~/lc` copy only) `V_OPT=--public-flat-rw`.
- New docs: this file, `findings_berr_hw_pctrace_2026-06-22.md`, `handoff_mame_pmmu_mistranslation_2026-06-22.md`.
- `~/lc` (WSL) holds the rsync'd repo + built sim + regenerated `.v`. `releases/boot0.rom` is the stock
  LC II ROM (its 4 byte-lanes match maclc2's CRCs — that's how the MAME setup was built).
