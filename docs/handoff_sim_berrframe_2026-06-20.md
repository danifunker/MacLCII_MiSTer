# Handoff: ground-truth the TG68 Format-$B "continue-past" bug in the Verilator sim

**For a fresh session on the MacBook (native Verilator — much faster than the Windows/WSL box this was set up on).** Self-contained. Companion deep-dives: `docs/resume_lcii_berr_frame_2026-06-20.md` and `docs/findings_berr_probe_replay_2026-06-20.md`.

---

## TL;DR — the one thing to find out

Mac OS constantly does **bus-error-protected probes**: install a temp BERR handler → touch a maybe-bad address → on fault the handler **clears DF (SSW bit 8), stuffs a Data-Input-Buffer value, and `RTE`s to *continue past* the faulted access**. The suspected core bug: **TG68 mishandles that continue-past `RTE` on a 68030 Format-$B frame**, resuming at a wrong PC → derail → bus-error storm → Sad Mac on boot / "bus error" bomb in games / choppy sound.

A continue-past engine **already exists** in the kernel (`rte_mmu_fix_*`: writes the destination register from the stacked DIB and bumps PC) but is **gated off** by a non-standard requirement that the stacked **SSW bit 9 = 1** — which **no real Mac OS handler sets** (bit 9 is reserved on a real 68030). So the engine never fires for OS probes, and the plain `RTE` resumes at the stacked PC with no instruction completion.

**What I need the sim to tell me (run it, paste the `[BERRFRAME]` lines back):**

1. For a **continue-past** Format-$B fault (handler does `andi.w #$feff,$a(a7)` then `rte`): does the replay gate ever fire — **`fix_write = 1`** — or is it always **0**?
2. Where does that `RTE` **land**? The correct next-instruction (continue-past works) or a garbage/derailed PC (the bug)?
3. Confirm the frame fields: built `ssw` has **DF=1, bit9=0**; post-handler stacked `ssw` has **DF=0, bit9=0**; `long=1`.

If `fix_write` is **always 0** and the `RTE` lands somewhere other than the instruction after the faulting probe → bug confirmed, and the fix is about the continue-past path (see "Fix hypotheses").

---

## Build + run (macOS)

Deps: `brew install verilator sdl2` (the Makefile's Darwin branch links the macOS SDL2/OpenGL frameworks). Then:

```bash
git pull                                   # gets the instrumentation below
bash verilator/berrframe_build.sh          # clean verilate + parallel compile (~minutes)
bash verilator/berrframe_run.sh 1200 ../releases/boot0.rom
```

`berrframe_build.sh` passes **`--public-flat-rw`** — this is required (see the script's header comment: without it, g++ fails on pre-existing `[SR]`/SCC/Egret debug taps that read internal signals Verilator optimizes away). It does **not** slow the sim noticeably (it boots hundreds of frames/sec).

`berrframe_run.sh [frames] [rom] [extra Vemu args]` runs headless, stops at `frames`, and prints the `[BERRFRAME]` trace + counts. Full log: `verilator/berrframe_run.log`.

---

## What's instrumented (already committed)

- **`verilator/tg68k_debug.vlt`** — `public_flat_rd` taps for the kernel bus-fault signals (`berr_frame_pc`, `berr_ssw`, `make_berr`, `berr_long_frame`, `berr_fault_addr`, `trap_berr`, `trap_mmu_berr`, `tg68_pc`, `rte_format_word`, `rte_mmu_fix_ssw/write/commit/opcode`).
- **`verilator/sim_main.cpp`** — a `[BERRFRAME]` per-cycle block (just before the `[SR]` trace). Three line types:

```
[BERRFRAME] DISP berr#<n> F<frame> frame_pc=<stacked PC> live_pc=<TG68_PC> ssw=<hex>[b9 DF RW] long=<0/1> faddr=<addr> opc=<faulting opcode> tberr=<ext-berr> tmmu=<mmu-berr>
[BERRFRAME] RTE  F<frame> stacked_ssw=<post-handler hex>[b9 DF] fmt=<format word> fix_write=<0/1> fix_commit=<0/1> fix_opc=<hex>
[BERRFRAME]      landed_pc=<resume PC> opc=<hex>
```

- `DISP` fires when `berr_frame_pc` changes = a fault was dispatched (frame built). `berr#0` with all-zeros is a harmless power-on artifact — ignore it.
- `RTE` fires when the kernel captures the **stacked** SSW during a Format-$B `RTE` (i.e., what the handler left) and shows whether the continue-past replay (`fix_write`) fired.
- `landed_pc` = the first instruction fetch after that `RTE`.

**Gap to be aware of:** the `RTE` line only fires when the kernel's `rte_mmu_fix` capture path runs (any Format-$B `RTE`). If a handler recovers *without* an `RTE` of the $B frame (e.g., abort-recover via SP restore), you'll see `DISP` but no `RTE`. For those, use the cpu-trace method below to see the actual resume.

---

## What I want you to capture — experiments, in order

### A. (Fast, do first) Characterize the guaranteed early fault with a CPU trace
The stock `boot0.rom` RAM-sizing test throws a reproducible Format-$B fault at **frame 9** (`frame_pc=0x3A92`, `faddr=0x22000`, `ssw=0x167` → DF=1/RW=1/bit9=0, `long=1`, `tberr=1`). I believe it's *abort-recover*, not continue-past — confirm by watching the instruction flow:

```bash
./verilator/obj_dir/Vemu --headless --trace-frames 8,11 --stop-at-frame 14 --rom ./releases/boot0.rom 2>verilator/berrframe_run.log
# then inspect the instruction trace around the fault:
grep -nE '3A92|3A94|4E73| rte | bus' verilator/cpu_trace.log | head
sed -n '/003A92/,+60p' verilator/cpu_trace.log     # fault -> handler -> RTE/jump -> landing
```
**Report:** the handler it jumps to, whether it ends in `rte` ($4E73) or an abort/jump, and the PC it resumes at. (If this fault turns out to be a continue-past `rte` that lands wrong, that alone may be the bug.)

### B. Catch the OS continue-past probes (the real bug locus)
These fire during OS init / runtime, not the RAM test. Boot **further**, and attach a disk so the OS actually runs (more handle-validation probes):

```bash
# boot deep with the stock ROM, no disk:
bash verilator/berrframe_run.sh 1500 ../releases/boot0.rom
# with a boot floppy or HD (paths are on your Mac; examples):
bash verilator/berrframe_run.sh 2000 ../releases/boot0.rom --floppy0 ../MacOS71-boot.dsk
bash verilator/berrframe_run.sh 2500 ../releases/boot0.rom --scsi0  ../HD20SC-With-Benchmarking-and-CDROM.vhd
```
**Report:** the full `[BERRFRAME]` block (DISP/RTE/landed). I'm looking specifically for any **RTE with DF cleared** (continue-past) and its `fix_write` + `landed_pc`.

### C. Trace any derailing continue-past
If a continue-past `RTE` lands somewhere wrong (storm of repeated DISP at nearby PCs, or `landed_pc` far from the fault), re-run that frame window with `--trace-frames` (as in A) and paste the fault→handler→RTE→landing instruction flow.

### The decisive questions (please answer explicitly)
- **Does `fix_write=1` ever appear?** (My prediction: never — bit 9 is never set, so the replay engine is dormant.)
- **Does any DF-cleared continue-past `RTE` resume at the wrong PC?** (My prediction: yes — it resumes at the stacked faulting-instruction PC with no completion, so it re-runs the faulting read or derails.)
- Sanity: are these frames `long=1` (Format $B), built `DF=1 b9=0`, post-handler `DF=0 b9=0`?

---

## Triggering notes (what I already learned this session)
- **Stock `boot0.rom` boots fine and is fast** (hundreds of frames/sec). Its frame-9 RAM-test BERR is a clean Format-$B fault but looks abort-recover (no `RTE` line in 250 frames).
- **`boot0-nomemcheck.rom` hangs at startup diskless** — no video frames advance, only the power-on `berr#0`. That's the *separate* "Egret reset-release freeze" (68k never leaves reset), **not** the frame bug. Don't chase it for this task; use the stock ROM (optionally with a disk).
- No disk is built into the sim by default; the desktop won't fully load without one. Use `--floppy0`/`--scsi0`.

## Data captured so far (stock ROM, 250 frames)
```
[BERRFRAME] DISP berr#1 F9 frame_pc=00003A92 live_pc=00003A94 ssw=0167[b9=0 DF=1 RW=1] long=1 faddr=00022000 opc=0E79 tberr=1 tmmu=0
[BERRFRAME] DISP berr#2 F9 frame_pc=00A03A92 live_pc=00A03A94 ssw=0167[b9=0 DF=1 RW=1] long=1 faddr=00022000 opc=0E79 tberr=1 tmmu=0
```
(Same fault, overlay vs non-overlay PC view. Confirms the *build* side: Format $B, DF set, bit 9 clear, stacked PC = faulting instruction, TG68_PC already +2.) No `RTE`/`fix_write` captured → need experiment A/B to see a continue-past return.

## Fix hypotheses (where this is heading, once ground truth lands)
- **If `fix_write` is always 0 and continue-past derails:** the lever is the gate at `rtl/tg68k/TG68KdotC_Kernel.vhd:1574` (`rte_mmu_fix_ssw(9)='1'`). Real 68030 continues whenever DF was cleared, regardless of the (reserved) bit 9. Candidate: fire the replay on a DF-cleared continuable Format-$B frame independent of bit 9 — **but** the engine only handles `MOVE/MOVEA (An)` (2-byte) reads (gate at 1580-1589), so `(d16,An)` probes like `move.l $38(a6),d0` at ROM `$A0DC1A` need the engine extended (length-correct PC advance + writeback). Scope that from the *distribution of faulting opcodes* the trace shows.
- **Don't** just disable the replay (`rte_mmu_fix_write<='0'`) — that was tried and **breaks the boot** (the boot's genuine MMU faults rely on it). See dead-ends in the resume doc.

## Key files / references
- Instrumentation: `verilator/tg68k_debug.vlt`, `verilator/sim_main.cpp` (`[BERRFRAME]` block), `verilator/berrframe_build.sh`, `verilator/berrframe_run.sh`.
- Kernel (source of truth; `.v` is GHDL-generated): `rtl/tg68k/TG68KdotC_Kernel.vhd` — gate 1569-1591, arming at rte4 1765-1777, stacked-SSW capture 1781, frame build (Format-$B PC) 2531-2536, `berr_frame_pc<=TG68_PC` 3668, RTE PC restore 3307-3310, register writeback 1964-1990.
- ROM mechanism (offset = runtime `$A0xxxx & 0x7FFFF`): handlers `$A0DB50` (DIB:=0) / `$A0DB5C` (DIB:=$FFFFFFFF) / `$A0D566`; probes `$A0DB92 movea.l (a1),a0` (2-byte, engine-eligible) and `$A0DC1A move.l $38(a6),d0` (`(d16,An)`, NOT eligible). Disasm with capstone `CS_ARCH_M68K`/`CS_MODE_M68K_030`.
- Deep dives: `docs/resume_lcii_berr_frame_2026-06-20.md`, `docs/findings_berr_probe_replay_2026-06-20.md`.
