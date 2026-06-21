# Resume: MacLCii bus-error frame bug (boot + games + sound) — 2026-06-20

**Read this to resume the investigation cold.** Self-contained: assumes no memory of the
session that produced it. Companion deep-dive: `docs/findings_berr_probe_replay_2026-06-20.md`.

## TL;DR

The core was renamed `MacLC` → `MacLCii` and its FPGA fit re-closed (both committed, below).
Everything else the user is hitting traces to **ONE central, unresolved CPU bug**:

> **TG68 mishandles the 68030 Format-$B bus-error stack frame on `RTE`.**

Mac OS constantly does **bus-error-protected probes** (install temp BERR handler → touch a
maybe-bad address → catch → `RTE` to continue). TG68's Format-$B `RTE` derails (returns to a
garbage/null PC), which manifests as:

| Symptom | What you see |
|---|---|
| Intermittent boot failure | Sad Mac (`0000000F` / `00007FFF`) **or** a black-screen ROM hang-loop |
| Game crash | "bus error" bomb |
| Choppy sound / "CPU hijacked" | intermittent derail+recover during play |

Secondary/independent issues: an **Egret reset-release freeze** (68k never leaves reset on
some boots) and a **cosmetic MHz misreport**. Details below.

## What is DONE and committed (on `master`, NOT pushed)

- **`d9138fa` — rename `MacLC` → `MacLCii`.** CONF_STR (`MacLC.sv:58`), Quartus project
  (`MacLCii.qpf/qsf/sdc/srf`, `PROJECT_REVISION`), build/deploy/JTAG scripts, `releases/MacLCii.nvr`,
  docs. Intentionally NOT renamed: `MacLC.sv` (module is `emu`), `maclc_v8_video.sv`/`cuda_maclc.sv`,
  MAME `maclc`/`maclc2`, `MacLC_HardwareConfig.md` (it's about the *original* LC).
- **`3230bea` — fit-closure** in `MacLCii.qsf` (a clean from-scratch fit otherwise FAILS
  routing congestion). Three assignments: `FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS`,
  `PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF`, `ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION OFF`.
  `SEED` stays 2 (SEED 3 broke CPU-domain setup). Clean timing: worst setup **+0.166** (pll_hdmi),
  hold +0.244. Verified reproducible from a wiped `db/`.
- **PRAM mount fix (NOT a repo change — done on the MiSTer SD).** `config/MacLCii.s2` was
  **missing** after the rename → the boot fell through to the **~60-second backstop** at
  `MacLC.sv:273-275` (`pram_rdy_cnt >= 3_900_000_000` ≈ 60 s @ ~65 MHz) before releasing the 68k.
  **That was the "extended black screen, never finishes."** Created `config/MacLCii.s2` →
  `games/MacLCii/MacLCii.nvr` (1024-byte path, NUL-padded; matches old `MACLC.s2` format). 68k now
  starts in seconds. `scripts/deploy_screenshot.sh` seeds it for future deploys.

## The central bug — diagnosis (verify line numbers against current file)

**Evidence (JTAG, `bash scripts/read_probes.sh` → `scripts/cpu_state.tcl`):**
```
PEXC last fatal : faulting IF=A0DBFC vec=2 (BUSERR)        # OS probe site
PFR recorder    : frozen=1 cause=BERR-NEAR-DEATH  berr_trigs up to 255 (storm)
  faulting IF=A08D18
  handler RTE landed at: A09B8A then 000000 (or A092A8/A092AE)  # garbage/null
```

**ROM mechanism (`releases/boot0.rom`; runtime `$A0xxxx` = ROM offset `addr & 0x7FFFF`):**
- `$A0DBF8` Memory-Manager handle validation; `$A08D14` dispatch — both: save `[$8]`, install
  temp BERR handler, touch a maybe-bad addr, restore.
- Recovery handler `$A0DB50`: `andi.w #$feff,$a(a7)` (clear **SSW bit 8 / DF**) ; `clr.l $2c(a7)` ;
  `rte` — i.e. "don't re-run the cycle, continue past." Offsets `+$0A`(SSW)/`+$2C` ⇒ 68030 **Format-$B**.

**Root cause in `rtl/tg68k/TG68KdotC_Kernel.vhd` (the SOURCE OF TRUTH; `.v` is GHDL-generated):**
- The `rte_mmu_fix` "software-fixed MMU data-fault replay" (WinUAE-derived, from the 030_mmu2
  merge) is **opt-in via SSW bit 9** ("software-fix request"). Gate (~`1569-1590`) needs
  `ssw(9)=1 AND ssw(8)=0`. SSW is built with `bit9<=0` (~`3716`/`3743`, "reserved for software-fix")
  and `bit8<=1` (DF) for data faults (~`3681-3760`). The **boot's** MMU handler SETS bit 9 to
  request the replay (so it *needs* the replay); the **OS probe** handler does NOT set bit 9.
- ⇒ **The replay is NOT the bomb's cause.** (A prior subagent analysis missed the bit-9 gate.)
- The bomb is the **plain Format-$B `RTE` "continue-past"**: TG68 just resumes at the stacked PC
  (`TG68_PC <= data_read`, ~`3309`) with **no mid-instruction continue engine**, so the probe's
  "continue past" derails → garbage PC. **This is the thing to fix.**
- Secondary suspect: `berr_frame_pc` consistency — PMMU-fault path freezes `TG68_PC` at the faulting
  instruction (~`3668`); external `make_berr` is registered one cycle late. Confirm both paths stack
  the PC the OS expects.

**To fix this you NEED ground truth** (don't keep guessing — see dead-ends). Capture, at the derail:
the stacked **format word, SSW, PC(+$02), SR**, and what `RTE` pops / where it lands. The kernel
already captures `rte_mmu_fix_ssw` internally (~`1781`); `debug_rte_mmu_fix_write` exists (~`9335`)
but is **not wired to a probe** (`tg68k.v` only wires `debug_make_berr`/`debug_trap_berr`, ~`401-402`).
Add probes, or do it in sim. Cross-check against **MAME `maclc2`** (the correct 68030 frame/RTE).

## Dead-ends — do NOT repeat

1. **Disabling the replay (`rte_mmu_fix_write <= '0'`) BREAKS THE BOOT.** The boot's genuine MMU
   faults need it (opt-in via bit 9). This was tried and reverted. Don't.
2. **`echo "load_core …" > /dev/MiSTer_cmd` is NOT a faithful boot** — it reconfigures the FPGA but
   skips the framework ROM-download/Egret init, so the 68k comes up frozen with no ROM (`PACT=0`).
   Use `python tools/misterdeploy/launch_unstable_core.py --core MacLCii.rbf` (full reboot + OSD select).
3. **Static guessing on this kernel is error-prone.** Get probe/sim ground truth first.

## Toolchain constraints (important)

- **GHDL is NOT installed** on the build box → cannot regenerate `TG68KdotC_Kernel.v` from the
  `.vhd`. The **FPGA build works anyway** (Quartus compiles the `.vhd` directly via `TG68K.qip`),
  but the **Verilator `.v` goes stale** after a `.vhd` edit. Before committing a kernel fix, regen
  the `.v` (GHDL 6.0.0; see `../MacLC_MiSTer/scripts/regen_tg68k.sh` or `rtl/tg68k/convert_to_verilog.sh`).
- **Verilator is NOT on PATH** here either → can't run the sim on this box.
- ⇒ **Develop the frame-bug fix in the sim/ModelSim loop** (where GHDL/Verilator/ModelSim live),
  using this doc + the findings doc as the map. Blind hardware iteration hit its limit.
- Build: `QUARTUS_BIN=/c/intelFPGA_lite/17.0/quartus/bin64 bash scripts/build.sh` (~15-22 min,
  Quartus 17.0.2). Force a clean fit by removing `db/ incremental_db/` first.

## Hardware access (set up this session)

- `scripts/local.env` (gitignored, created this session): `MISTER_HOST=192.168.99.143`,
  `MISTER_SSH_KEY=~/.ssh/mister_only`, `MISTER_HTTP_PORT=8182`, `RBF_NAME=MacLCii.rbf`.
- SSH: `ssh -i ~/.ssh/mister_only root@192.168.99.143` (`-o BatchMode=yes -o StrictHostKeyChecking=accept-new`).
- JTAG probes: `bash scripts/read_probes.sh` (USB-Blaster DE-SoC; decodes the `dbg_probes` deck — see
  `scripts/cpu_state.tcl` for field meanings: PACT/PIFA/PADR/PSTA/PEXC/PFR/PRC0/PRST/PSCx/PVID).
- Screenshot (HDMI): `POST http://192.168.99.143:8182/api/screenshots`; then GET newest by `modified`
  (pattern in `../MacLC_MiSTer/scripts/grab.sh`). NOTE: captures HDMI framebuffer only.
- Faithful cold boot: `python tools/misterdeploy/launch_unstable_core.py --core MacLCii.rbf` (~4 min).
- **Deployed rbf:** `/media/fat/_Unstable/MacLCii.rbf` = the GOOD `3230bea` fit-closure build (boots,
  games bomb). **WARNING: local `output_files/MacLCii.rbf` is a STALE/BROKEN build** (the reverted
  pass-1 disable). **Rebuild from current source before deploying.**
- SD layout: `games/MacLCii/` (boot0.rom = nomemcheck `dcc7c7ac` = `releases/boot0-nomemcheck.rom`;
  stock = `releases/boot0.rom` `9575cd95`; HDs: `MacLC_6-0-8.hda`, `MacLC_7-1.hda`, MacsBug variants).
  `config/MacLCii.cfg` byte0 = memory: `0x08`=10MB, `0x04`=2MB, `0x00`=4MB (O23 bits[3:2]).
  `config/MacLCii.s2` = PRAM mount (created).
- ROM disasm: capstone (`CS_ARCH_M68K`, `CS_MODE_M68K_030`); offset = `runtime & 0x7FFFF`. Example
  script: `scratch/disasm_faults.py`.

## Secondary issues

- **Egret reset-release freeze** (separate from the frame bug): on some boots the 68k never leaves
  reset (`PACT=0`, `ifcnt=0`, all black). `reset_680x0 = reset_680x0_latched | ~pram_loaded`
  (`egret_wrapper.sv:562`). The PRAM fix handled the `pram_loaded`/60 s side; a *pure* Egret freeze
  (firmware not releasing) would be the **CB1/VIA-SR handshake** (`CLAUDE.md`: `ext_fall_edge_pending`
  edge-coalescing; suggested fix is to **rate-limit `cuda_cb1 = pb_out[4]`** at `egret_wrapper.sv:478`,
  NOT to touch the VIA SR path). **Re-confirm whether it still freezes now that boots start promptly.**
- **MHz misreport (Tattle Tech), cosmetic.** +3.7% clock skew (32.5 vs 31.3344 MHz) CANCELS in a
  ratio-based speed calibration, so the wrong number is most likely the **cache-disabled** CPU's
  tight-loop throughput vs a real cached 68030 (`USE_68030_CACHE=0` at `tg68k.v:52`). Low priority;
  the actual reported number was never captured.

## Recommended next steps (priority order)

1. **Frame bug (master blocker).** Instrument the exact Format-$B frame (format/SSW/PC/SR) + `RTE`
   behavior at the derail (probe or sim), confirm vs MAME `maclc2`, then fix the "continue-past" `RTE`
   so a DF-cleared, non-software-fix (`bit9=0`) Format-$B frame resumes correctly instead of derailing.
   This single fix should resolve the boot Sad-Mac/hang, the game bombs, AND the choppy sound.
2. **Re-confirm the Egret freeze** post-PRAM-fix; if still present, the CB1 rate-limit above.
3. **Add `set_false_path` for the `dbg_probes` capture path to `MacLCii.sdc`** — only matters once a
   kernel edit perturbs the fit (the reverted pass-1 build showed a `-0.267` on `sdram→dbg_probes
   sr_entry`, a debug-only CDC). The committed `3230bea` is clean without it.
4. **MHz:** get the actual Tattle Tech reading; expect it's cache-related, not a clock bug.

## Key files

- `rtl/tg68k/TG68KdotC_Kernel.vhd` — frame bug (SSW build ~3681-3760; `rte_mmu_fix` gate ~1569-1590;
  arming ~1745-1802; RTE PC restore ~3309; `berr_frame_pc` ~3668; `debug_rte_mmu_fix_write` ~9335).
- `rtl/egret/egret_wrapper.sv` — Egret (`cuda_cb1=pb_out[4]` :478; `reset_680x0` :562).
- `MacLC.sv` — `CONF_STR` :58; PRAM-ready backstop :273-275; CPU/bus glue.
- `rtl/dbg_probes.sv`, `scripts/cpu_state.tcl` — the JTAG probe deck.
- `docs/findings_berr_probe_replay_2026-06-20.md` — detailed root-cause writeup.
- `tools/misterdeploy/launch_unstable_core.py` — faithful core launch.
