# RESUME — MacLCii 10MB boot Sad Mac: the motherboard 2MB bank doesn't persist the PMMU page table (2026-06-24)

## TL;DR / where we are RIGHT NOW
- **Root cause (definitive):** The MacLCii **10MB** boot Sad Mac (`$0000000F / $00007FFF`) is NOT a PMMU
  bug. The PMMU walk, A5/jmp-target (`$40A0010E`), TC (`$80F05750`), CRP (`$9FEE00`) are ALL CORRECT
  (= MAME `maclc2` "Config A"). The bug: in the **10MB** RAM map, the **motherboard 2MB bank**
  (CPU `$800000-$9FFFFF` → SDRAM words `$000000-$0FFFFF`) **does not persist** the PMMU page-table
  write at CPU `$9FEE40` (= SDRAM word `$0FF720`). Build #7 (HW JTAG, frozen at derail) proved:
  exactly **1** write of the correct `$000B` to `$0FF720` (`cw_cnt=1`), but it **reads back `$0000`**.
  The PMMU then walks a zeroed `root[8]` → derail → Sad Mac. 4MB config avoids the derail entirely
  (proving it's 10MB-map-specific) but hits a SEPARATE, pre-existing `#3` reboot loop.
- **BUILD #8 RESULT (decisive, captured 2026-06-24):** `we_fired=1` (strobe fired, data `$000B`, word
  `$0FF720`, `cw_cnt=1`) yet `$9FEE40` reads back `$0000`, and the read targets the SAME word `$0FF720`.
  ⇒ the write COMMITS to the controller but the **low SDRAM region loses it** (not a dropped write, not
  a read-mismatch, not an overwrite). The walker reads other descriptors fine (boot reaches `$A416B2`),
  so the read path works — it's specific to the motherboard bank's SDRAM region `$000000-$0FFFFF`.
  `rtl/sdram.v` is a correct MT48LC16M16 (32MB) controller, but ties row bit **A12=0** ⇒ only the LOWER
  16MB is addressed; the **upper 16MB is unused**.
- **FIX IMPLEMENTED + HW BUILD RUNNING (2026-06-24):** relocate the motherboard bank to the unused upper
  16MB (see "THE FIX" below). Files changed: `rtl/sdram.v`, `rtl/addrController_top.v`, `MacLC.sv`,
  `verilator/sim.v`. A clean Quartus build is compiling (background watcher task; ~27 min).
- **Next concrete steps:** (1) wait for the build; (2) deploy (`--push`) + launch (10MB config);
  (3) JTAG-read probes — the build #8 capture now VERIFIES the fix: `CPU $9FEE40 reads back` should be
  `000B` (was `0000`); (4) the user confirms boot past `$A416B2` to System 6 Finder on the MiSTer.
  If it still reads `0000`/Sad-Macs: revisit the ≥32MB-module assumption first (see "THE FIX").

## FIRST, READ THESE (in order)
1. `docs/findings_pmmu_walk_correct_2026-06-23.md` — the FULL evidence chain (builds #2/#4/#6/#7,
   the 4MB test, the analytical rulings, the build #8 plan + corrected fix branches). **288 lines.**
2. This file.
3. Memory note `maclcii-sadmac-0f-is-pmmu-mistranslation.md` (current description = the persistence
   root cause). Also `maclcii-pmmu-sim-harnesses.md`, `maclcii-mister-hardware-access.md`,
   `prefers-autonomous-driving.md`.
- The OLD `docs/resume_pmmu_32bit_alias_2026-06-23.md` premise ("PMMU mistranslation of the alias") is
  **DISPROVEN** — do not act on it. Likewise do NOT "fix the PMMU walk", "fix TC/CRP loading", or
  "fix A5" — all verified correct on HW + in two sim harnesses.

## HOW TO RESUME BUILD #8 (it may already be done)
- Build runs via Git Bash (Bash tool). Background task id this session was `bjk9zcwp3`; log at
  `output_files/auto_compile_*.log` (newest). Check completion:
  ```bash
  ls -la output_files/MacLCii.rbf output_files/MacLCii.sof
  tail -n 5 output_files/auto_compile_*.log   # look for "Compile exit=0"
  tasklist | grep -iE "quartus_(fit|asm|sta|sh)"   # empty == done
  ```
- If build #8 was lost/needs redo: `rm -rf db incremental_db && bash scripts/build.sh` (~33 min).
  `scripts/build.sh` sources `scripts/local.env` for `$QUARTUS_BIN` (`/c/intelFPGA_lite/17.0/quartus/bin64`).

## DEPLOY + CAPTURE PROCEDURE (after build #8)
1. **Ensure 10MB config.** MiSTer core config `/media/fat/config/MacLCii.CFG` (16 bytes; first 8 = LE
   status). **byte0 = `$08` = 10MB** Memory option (`O23`: 4MB=`$04`/2MB=`$24`/10MB=`$E4`; the stored
   status byte0 is `$08` for 10MB). If you switch configs, set this and reboot the core.
2. **Deploy the RBF.** `python tools/misterdeploy/launch_unstable_core.py` (source `scripts/local.env`
   first so it inherits `MISTER_HOST`/key/port; if backgrounded, env may not inherit — run foreground
   or export explicitly). `MISTER_HOST=192.168.99.143`, key `~/.ssh/mister_only`, web port `8182`.
3. **Reach the derail + freeze.** The probes freeze at the `hiram_pf` derail (`pc_frozen`). The core
   boots, mistranslates, and freezes itself — just let it run to the Sad Mac.
4. **Read probes over JTAG (USB-Blaster):**
   ```bash
   "$QUARTUS_BIN/quartus_stp_tcl" -t scripts/cpu_state.tcl   # (use the wrapper the prior session used)
   ```
   The build #8 decode prints the `BUILD#8 write-STROBE commit ...` block.
- MiSTer health (verified reachable at handoff: ping 0% loss, SSH up, web `8182 LISTEN`). If the web
  service dies after many reboots (HPS stress — happened ~8× this session): SSH in and
  `/media/fat/Scripts/remote.sh -service restart` (then confirm port 8182 LISTEN + HTTP 200).
- **Tcl gotcha:** `root[8]`/`root[10]` in `puts` strings trigger command substitution → write `root#8`.

## BUILD #8 CAPTURE — exact layout + interpretation
Probes (in `rtl/dbg_probes.sv` ~lines 338-369; wiring at the `cp_ps*` instances):
- `wr720 = AS-fall & !cpuRW & selectRAM & (cpu_memaddr==23'h0FF720)` — a CPU **write cycle** to the word.
- `we720 = (cpu_memaddr==23'h0FF720) && !cpu_ramwe_n` — **`_ramWE` actually asserted** for that word
  (the SDRAM write strobe ⇒ `sdram_we`). `we_fired`/`we_cnt`/`we_data` latch it.
- `rd40  = AS-fall & cpuRW & cpuAddrHi==0 & cpuAddr[23:1]==23'h4FF720` — the CPU read of `$9FEE40/41`.
  `rd_data`/`rd_seen`/`rd_memaddr`(= the read's SDRAM word) latch it.

Probe map (all 32-bit altsource_probe):
| probe | contents |
|---|---|
| `PSCS` | `c0` = newest write `{cpuAddr[15:0], data}` (expect `{EE40, 000B}`) |
| `PSC2` | `c0_cpa` = newest write full cpuAddr (expect `9FEE40`) |
| `PSC6` | `{16'd0, cw_cnt}` = count of write CYCLES to `$0FF720` (expect 1) |
| `PSWL` | **BUILD#8** `{we_data[31:16], we_cnt[15:0]}` — strobe DATA + strobe COUNT |
| `PSNC` | **BUILD#8** `{8'd0, we_fired[23], rd_memaddr[22:0]}` — strobe fired? + READ's SDRAM word |
| `PDRD` | `{rd_data[31:16], 15'd0, rd_seen[0]}` — value read at CPU `$9FEE40` |

`scripts/cpu_state.tcl` already decodes all of this (the `BUILD#8 write-STROBE commit ...` block,
~line 246; the stale SCSI-era `PSWL irq/defer` + `PSC6 rst/opcode` decodes were removed).

### FIX BRANCHES (decide from build #8) — note: `ram_sdram_word` sets the SDRAM *destination*, it does NOT control whether `_ramWE` fires
| `we_fired` | `rd_memaddr` | meaning | FIX LOCUS |
|---|---|---|---|
| **0** | — | write **DROPPED**: `selectRAM=1` (build #7) but strobe never asserted ⇒ `cpuBusControl` low at that write (bus not granted) | `rtl/addrDecoder.v` / the `cpuBusControl` (bus-arbitration) path for `$800000-$9FFFFF`. **Linear-map change would NOT help.** |
| **1** | `$0FF720` | committed but SDRAM loses it ⇒ SDRAM backing of `$000000-$0FFFFF` is bad | relocate the bank in `ram_sdram_word` and/or `rtl/sdram.v`. Linear 1:1 viable ONLY if `$000000-$0FFFFF` is actually good — if it's the bad region, **shift the whole RAM map UP** off `$000000-$0FFFFF` instead. |
| **1** | `$5xxxxx` | derail **read hit ROM overlay** (overlay stuck on; ROM is at SDRAM `$500000`) | overlay-clear path (Egret/VIA SR). See CLAUDE.md "VIA Shift Register" + the suspected FPGA overlay-stuck bug. (Unlikely — boot reaches `$A416B2` so stack/low-RAM reads work ⇒ overlay generally off — but this confirms it.) |
| **1** | other | read maps elsewhere than the write | addrController READ path / address presentation |

## THE 10MB MEMORY MAP (verified this session) — key to the fix
`rtl/addrController_top.v` `ram_sdram_word` (lines 187-190):
```
motherboard_high ? {3'b000, cpuAddr[20:1]} :          // CPU $800000-$9FFFFF → SDRAM words $000000-$0FFFFF
in_simm          ? (23'h100000 + {1'b0, cpu_word}) :  // CPU $000000-$7FFFFF → SDRAM words $100000+
                   {2'b00, mb_mirror_offset};         // motherboard mirror (dead for 10MB)
```
- `motherboard_high = (cpuAddr[23:21]==3'b100)` (`$800000-$9FFFFF`); `cpu_word = cpuAddr[22:1]`.
- `rom_sdram_word = {5'b10100, cpuAddr[18:1]}` = SDRAM word **$500000** (must match download map in
  `MacLC.sv` + `verilator/sim.v`). `vram_sdram_word = $580000+`. Floppy = `$600000`/`$700000`.
- **For 10MB:** `ram_config_phys[7:6]=11` (8MB SIMM) ⇒ `simm_byte_size=$800000`; `mb_present=0` ⇒ NO
  `motherboard_low` ($0) placement, so NO `$0↔$800000` SDRAM mirror. ONLY `motherboard_high` uses SDRAM
  `$000000-$0FFFFF`. `board_is_4M = ram_config_phys[5]==0` (10MB→2MB board→`board_is_4M=0`).
- So byte map: SDRAM `$000000-$1FFFFF` = motherboard (2MB); `$200000-$9FFFFF` = SIMM (8MB);
  `$A00000` = ROM; `$B00000` = VRAM; `$C00000`/`$E00000` = floppy.
- **Candidate linear fix** (if `we_fired=1`+real-SDRAM, AND `$000000-$0FFFFF` is good): replace the whole
  `ram_sdram_word` with the 1:1 map `ram_sdram_word = cpuAddr[23:1]` (CPU `$000000-$9FFFFF` → SDRAM word
  `$000000-$4FFFFF`; does NOT collide with ROM at word `$500000`). **DANGER:** this puts low RAM (CPU
  `$0`) at SDRAM `$000000` — if that region is the bad one, the boot dies immediately. Only safe if
  build #8 shows `$000000-$0FFFFF` works (i.e., the failure was a *destination collision/relocation*
  issue, not a dead region). Otherwise shift everything up (e.g. RAM → `$100000-$AFFFFF`, ROM/VRAM/disk
  even higher) — a coordinated change across `addrController_top.v` + the download map in `MacLC.sv` +
  `verilator/sim.v`.

`rtl/addrDecoder.v` (selectRAM decode):
- `in_motherboard_range = (address[23:21]==3'b100)` → selectRAM for `$9FExxx`.
- Overlay: `if (memoryOverlayOn && _cpuRW) selectROM=1; else if (in_*range) selectRAM=1;` → **writes
  bypass overlay (go to RAM); reads during overlay go to ROM.** Boot reaches `$A416B2`, so overlay is
  off by MMU-setup time (stack reads work).
- `_ramWE = ~(cpuBusControl && (selectRAM||selectVRAM) && !_cpuRW)` (addrController:129) — NOT
  range-gated, asserts for any selectRAM write given `cpuBusControl`.

## ANALYTICAL RULINGS established this session (so you don't re-derive)
- **Download is NOT the overwriter:** dio writes SDRAM `$500000`(ROM)/`$600000`(Fd1)/`$700000`(Fd2)
  (`MacLC.sv:1400-1402`); none in `$000000-$0FFFFF`. SDRAM writes come ONLY from `download_cycle?dio:CPU`
  (the `sdram_we`/`sdram_addr` mux in `MacLC.sv` ~1425-1432) — no third writer.
- **No SDRAM aliasing:** `rtl/sdram.v` decodes bank=`addr[21:20]`, row=`addr[19:8]`,
  col=`{addr[22],addr[7:0]}` over `addr[22:0]` (24-bit word input, bit23 unused) → every word unique.
  `$0FF720` → bank0/row`$FF7`/col`$020`.
- **`_ramWE`/`_ramOE` not range-gated** ⇒ decode permits the motherboard write.
- **RAM test argues against a dead region:** the boot reaches the MMU switch (no RAM Sad Mac), so the
  motherboard bank likely passed its RAM test ⇒ `we_fired=1`+real-SDRAM-loss is the *less* likely
  branch; `we_fired=0` (dropped) or read-mismatch/overlay more likely. (Build #8 settles it.)

## UNCOMMITTED WORKING TREE (branch `fix/tg68-format-b-continue-past`) — KEEP ALL OF IT
Modified (debug instrumentation + the no-op continue-past edit):
- `rtl/dbg_probes.sv` — build #8 capture (~338-369) + `PSWL`/`PSNC` repurposed (`cp_pswl`/`cp_psnc`).
- `scripts/cpu_state.tcl` — build #8 decode (~246); stale PSWL/PSC6 SCSI decodes removed.
- `rtl/tg68k/tg68k.v` — `dbg_pmmu_log`/`dbg_pmmu_phys`/`dbg_pmmu_tc_o`/`crp_o`/`wda_o`/`wdd_o`/`st_o`
  outputs un-`ifdef`'d (FPGA-available); = `cache_addr_log`/`cache_addr_phys` etc.
- `MacLC.sv` — wires `cpu_pmmu_log/phys/tc/crp/wda/wdd/st`, `cpu_dout`(=tg68_dout),
  `cpu_memaddr`(=memoryAddr), `cpu_ramwe_n`(=_ramWE) threaded tg68k → dbg_probes.
- `rtl/tg68k/TG68KdotC_Kernel.vhd` — the Format-$B continue-past edit (no-op for THIS bug; keep).
- `verilator/Makefile` — sim build tweaks.
Untracked (keep): `docs/findings_pmmu_walk_correct_2026-06-23.md`, this resume, the other docs/resume_*,
`verilator/pmmu_bench/`, `verilator/ksw_bench/`, `verilator/mame/*.lua` + `*.txt` + `*.dbg` + `roms*/`,
`verilator/pt10_4m.txt`, `cr_ie_info.json`.

## DATA-FLOW for the probes (how cpu_* reach dbg_probes)
`tg68k.v` (`dbg_pmmu_*` outputs) → `MacLC.sv` (`cpu_pmmu_log/phys/tc/crp/wda/wdd/st`, plus
`cpu_dout`=tg68_dout, `cpu_memaddr`=memoryAddr, `cpu_ramwe_n`=_ramWE) → `dbg_probes` inputs, latched in
the `hiram_pf` derail freeze. `derail_pmmu_log`(PFR2) / `derail_pmmu_phys`(PRT3) hold A5/jmp-target
LOGICAL and the mistranslated PHYSICAL at the derail.

## ENVIRONMENT / TOOLCHAIN
- This session = **Windows** (win32, PowerShell + Git Bash via the Bash tool). Quartus 17.0.2 Lite.
  HW-build + JTAG + deploy loop only.
- The prior session's MAME `maclc2` (0.264) / Verilator 5.020 / GHDL 4.1.0 + MacIIvi corpus ran in
  **WSL** (the `verilator/pmmu_bench` + `verilator/ksw_bench` validators, MAME oracle). If you need the
  oracle page table: `verilator/pt10_4m.txt`, `verilator/mame/pt10_out.txt`,
  `verilator/mame/tables_10m.txt`. MAME oracle MMU configs: Config A `TC=$80F05750` CRP=`$9FEE00`
  (root[8]@`$9FEE40` = `000BFC0A/009FEDA0` DT=2); Config B `TC=$80F84500` CRP=`$9FE820`.
- Memory tooling caveat (memory note): the MiSTer has no GHDL/Verilator; `load_core` is unfaithful —
  always JTAG-deploy the freshly built RBF.

## USER PREFERENCES
- **Drive autonomously, minimize check-ins** — reserve them for HW-test steps, genuinely blocking
  design decisions, or after ~2 failures. The user runs/observes the physical MiSTer screen and
  confirms the final boot ("you drive the builds; I confirm the final boot").
- User already approved the direction: **"Pin the SDRAM collision, then fix the 10MB map."** (We then
  found it's not a *collision* — it's a persistence/commit failure; build #8 pins the exact mechanism.)

## OPEN / SEPARATE ITEMS
- **#3 reboot loop** on the 4MB config (pre-existing, NOT this bug) — full boot eventually needs both
  fixed. SCSI-abort trail + boot-init-entry probes for it are in `dbg_probes.sv` (PRC0/PRT1-3) but were
  not the focus.
- After the 10MB fix boots: re-verify the VIA SR / Egret handshake didn't regress (CLAUDE.md warns SR
  changes break boot — but we touched none).

## THE FIX (implemented 2026-06-24) — relocate motherboard bank to the unused upper 16MB
The chip is MT48LC16M16 = **32MB**, but `sdram.v` tied row bit **A12=0** so only the lower 16MB was
used and the motherboard bank's `$000000-$0FFFFF` region (which loses writes, per build #8) lived there.
Drive A12 from `addr[23]` and move only the motherboard bank up:
- `rtl/sdram.v` (~line 164): `sd_addr <= { addr[23], addr[19:8] };`  (was `{1'b0, addr[19:8]}`)
- `rtl/addrController_top.v`: new `output mb_hi;` and
  `assign mb_hi = !dskReadAckInt && !dskReadAckExt && selectRAM && motherboard_high;`
  (`memoryAddr` stays 23-bit / unchanged)
- `MacLC.sv`: `wire mb_hi;` + `.mb_hi(mb_hi)` on `ac0` + `sdram_addr = download ? {2'b00,dio_a} :
  {1'b0, mb_hi, memoryAddr[22:0]};`
- `verilator/sim.v`: `wire mb_hi;` + `.mb_hi(mb_hi)` + `ram_addr = ... {1'b0, mb_hi, memoryAddr[22:0]}`
  (sim_ram indexes only `addr[22:0]`, so harmless/ignored in the ideal-RAM sim — wired for parity).
Net effect: motherboard CPU `$800000-$9FFFFF` → SDRAM `$800000-$8FFFFF` (upper half, A12=1); page table
CPU `$9FEE40` → SDRAM `$8FF720`. Everything else keeps bit23=0 → **byte-identical, no regression**.
Worst case on a <32MB module: A12=1 wraps to the old region (no worse than today). **First thing to
revisit if it doesn't boot: confirm the physical SDRAM module is ≥32MB** (the comment in `sdram.v` and
the MiSTer standard both say MT48LC16M16/32MB).

To REVERT: restore the four hunks above (git diff on `rtl/sdram.v rtl/addrController_top.v MacLC.sv
verilator/sim.v`). The build #8 JTAG instrumentation in `rtl/dbg_probes.sv` + `scripts/cpu_state.tcl`
is independent and can stay (it now reports reads-back=`000B` on success).
