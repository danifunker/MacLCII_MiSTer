# RESUME PROMPT — Mac LC II boot (68030 core being shelved)

**Date:** 2026-06-16   **Branch:** `030_LCii` (MacLC_MiSTer)
**Read first:** this file, then `docs/findings_pmmu_translated_fetch_2026-06-16.md`
and `docs/handoff_lcii_egret_pmmu_2026-06-16.md`.

> Paste-to-resume: *"Resume the Mac LC II 68030 boot. The Egret SR, the PMMU
> walk-stall, and PMMU bug #3 (post-pmove-TC prefetch derail) are all fixed; the
> boot now executes MMU-translated code past the $a416 PMMU-enable stage. Find the
> NEXT downstream blocker. The 68030 core is shared byte-for-byte with
> ../MacIIvi_MiSTer/rtl/tg68k — fix in MacLC, re-copy. Start by reading
> docs/handoff_lcii_resume_2026-06-16.md."*

---

## State in one paragraph

The LC II boot reaches and **passes** the 68030 cache+MMU enable sequence at
`$a416xx`. Three real blockers were found and fixed this campaign: (1) the Egret↔VIA
shift-register transaction (byte-perfect vs MAME), (2) the PMMU table-walk DTACK
stall (bus-FSM phi-parity, `tg68k.v`), and (3) the PMMU "translated-fetch" derail
(actually the post-`pmove TC` prefetch of the unmapped ROM PC — fixed with an
instruction-prefetch grace in the kernel). The boot now runs MMU-translated code
(low-RAM + VASP I/O). **Next task: find the first blocker AFTER the PMMU stage.**

## The shared core (CRITICAL — read before touching the CPU)

`MacLC_MiSTer/rtl/tg68k/` and `../MacIIvi_MiSTer/rtl/tg68k/` are **one MC68030**,
kept byte-identical. **MacLC `030_LCii` is the source of truth** (it's the one that
boots). After any CPU change here: re-copy the 8 core files to MacIIvi and regenerate
(`rtl/tg68k/convert_to_verilog.sh`, ghdl 6.0.0), verify `diff -q` clean. The fix for
a CPU bug applies to both machines. Validate with MacIIvi's
`SingleStepTests/tg68k` bench (gate: 714/719 architecturally correct, 5 known
PRM-CCR diffs). See MacIIvi memory `shared-68030-core-with-maclc`.

## Solid / do NOT re-litigate

- **Egret/VIA SR** — byte-perfect vs MAME (CB2 pull-up + XPRAM seed, `b0d8af7`).
- **PMMU walk-stall** — bus-FSM phi-parity, `tg68k.v` (`findings_pmmu_walk_stall_2026-06-15.md`).
- **PMMU bug #3** — post-`pmove TC` prefetch of unmapped ROM PC `$00a416b6`; fixed
  with prefetch-grace in `TG68KdotC_Kernel.vhd` (`0590605`,
  `findings_pmmu_translated_fetch_2026-06-16.md`). NOT a walker/limit bug — the
  limit=9 page table is correct; the fetch just shouldn't have been re-translated.
- **cmp flag-race / null-RAM-table** — earlier measurement artifacts (disproven).
- **Sim speed ~0.6 FPS is inherent** (memory `maclc-verilator-sim-speed`).

## Next blocker — where to look

After the PMMU stage the boot runs translated code. To find the next stop, run the
**stock or fast-mem ROM** (full RAM init — the `nomemcheck` ROM has a zeroed-low-RAM
artifact and is only for *reaching* the PMMU fast). Watch for: a new `trap_berr`
(grep `PMMU trap`), a wedged `kpc` (HB heartbeat repeating one PC), or a polling
loop on a device register (`$50fxxxxx` VASP/VIA/IO). Compare against the MAME
maincpu trace at the same PC (oracle below). Candidate areas from prior handoffs:
the welcome-screen wedge, warm-boot loop, 256-color video — see the other
`docs/handoff_*` files.

**Measured 2026-06-16 (post-fix, fast-mem ROM, F185):** 0 PMMU walks, 0 `trap@a416`,
0 `$7FF8` wedge — but the boot is still **pre-PMMU** (`kpc=$00a45exx`, chime/early-IO
region, polling VASP `$50f14804`). The full-RAM-init path grinds the RAM/ROM
checksum for a long time; it does NOT reach the `$a416` PMMU stage by F185 (the old
"~F155" estimate was with a different setup). So to study the post-PMMU blocker on a
clean path you must either (a) run fast-mem well past F185, or (b) use the
`nomemcheck` ROM (reaches PMMU ~F96, bug #3 confirmed fixed there) and fix its
zeroed-low-RAM artifact. Bug #3 itself is verified fixed on the nomemcheck path
(jmp target translates, execution continues — see the findings doc).

## How to run / debug (gotchas that cost time)

- **Run from `verilator/`.** The ROM path is hard-coded `../releases/boot0.rom`
  (`sim_main.cpp:1235`); launching from the repo root silently loads NO ROM (boot
  does nothing, zero PMMU activity). This bit me — don't repeat it.
- **ROM choice** (`releases/`, runtime-loaded, no rebuild needed):
  - `boot0.rom` committed = **stock** (sha `d5786182`) — full boot, slowest.
  - `boot0-fastmem.rom` (`7edb1a10`) — full RAM init, clamps the slow march; still
    grinds a ROM checksum (`$a46af0`) for many frames before the PMMU stage.
  - `boot0-nomemcheck.rom` (`2e14f196`) — skips the RAM test, reaches PMMU ~F96
    (best for PMMU work), but then hits zeroed low RAM (a skip artifact).
  - `cp releases/boot0-<x>.rom releases/boot0.rom`; **restore stock before committing**.
- **Build/run:** `cd verilator && make` (~36s re-verilate + compile); macOS has no
  `timeout`, bound with `--stop-at-frame N`.
  `./obj_dir/Vemu --headless --no-cpu-trace --stop-at-frame N > x.log 2>&1`
- **PMMU trace:** uncomment `+define+PMMU_TRACE=1` in `verilator/Makefile:23`,
  rebuild; logs `PMMU REQ/ACK/make_berr/trap_berr` + a heartbeat. The committed
  `tg68k.v` probe logs walker addr/data + berr edges. (Richer taps — fault status,
  saved VA/FC, TT0/TT1, grace state — were added temporarily during the bug #3 hunt
  and reverted; re-add from `findings_pmmu_translated_fetch_2026-06-16.md` if needed.)
  **Revert the Makefile line after.**
- **MAME oracle (boots the fast-mem ROM):** split `releases/boot0-fastmem.rom` into
  4 byte-interleaved chips in `/tmp/patchroms/maclc2/`, then
  `/opt/homebrew/bin/mame maclc2 -rompath '/tmp/patchroms;/private/tmp/goodroms' -ramsize 4M -nothrottle -video none -nowindow -sound none -skip_gameinfo -autoboot_delay 0 -seconds_to_run 4`.
  Target the `maincpu` (not the Egret HC05). Details in MacIIvi memory
  `mame-debugger-and-cmpl-bug` and `mame-maclc-oracle-setup`.
- **Disassemble:** `unidasm <bin> -arch m68030 -basepc <cpuaddr>`; build a
  CPU-addr-aligned bin with `dd if=releases/boot0-fastmem.rom bs=1 skip=$((cpuaddr-0xA00000)) ...` (ROM is at CPU `$A00000`).

## Key files
- CPU core (shared): `rtl/tg68k/TG68KdotC_Kernel.vhd` (+ PMMU_030, ALU, Pack,
  Cache, TG68K.vhd) → `convert_to_verilog.sh` → `TG68KdotC_Kernel.v`. Mac-bus
  wrapper: `rtl/tg68k/tg68k.v` (walker bus master + s_state FSM + berr_hold).
- Chipset: `rtl/dataController_top.sv`, `rtl/addrController_top.v`, `rtl/egret/`.
- Sim: `verilator/sim.v`, `verilator/sim_main.cpp`, `verilator/sim_ram.v`.

## Key addresses (bug #3, for orientation)
- Cache/MMU enable: `$a41682 movec D5,CACR`; `$a416b2 pmove (A3),tc`;
  `$a416b6 jmp (A5=$40A0010E)`. Page tables: root walked at `$003fee00`
  (table-desc limit=9 → maps `$000–$009FFFFF` + the `$40xxxxxx` alias); ROM exec
  region `$00Axxxxx` intentionally unmapped; `TT0=TT1=0`; `VBR=0`.
