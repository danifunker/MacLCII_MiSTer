# RESUME — Trace where the Mac LC ROM draws the rounded desktop corners; our framebuffer lacks them (2026-06-03)

Branch `new-video-on-fix-egret` (local, **don't push**). Build rules: `CLAUDE.md`.
Memory: [[desktop-stage-open-issues]], [[swim-upper-byte-fix]],
[[pseudovia-irq-ier-fix]], [[mame-ground-truth-maclc]],
[[verilator-top-is-sim-v]], [[feedback-sim-foreground]].
Focus = **2MB config only** (`configRAMSize=$24`, `v8_monitor_id=4'h6` 640x480).

## Where we are (boot + video both much further than before)
- Boot reaches the **grey desktop** (~frame 634) and parks in an early
  drive-poll/wait loop (`$A01484`/`$A014CA` + disk A-traps `$A07D/$A084/$A07F`).
- **Video is now clean and matches MAME**: 640x480 (commit `8c24623`), single
  correctly-sized cursor, true per-pixel checkerboard (1bpp render fixed via
  fetch-dedup + the sim `CE_PIXEL` fix `6775d8d` — `CE_PIXEL` had been hardwired
  to 1, doubling every pixel; FPGA was never affected).
- Recent landed fixes: SWIM upper-byte (`973824b`), VIA Timer-1 IRQ
  (`bb47b54`), phantom-bank SIMM (`0b57f5e`). See MEMORY.md.

## THE TASK: rounded desktop corners
The real Mac LC draws the gray desktop with **rounded corners** — the ROM writes
black (`0xFFFF`, all-1 = black in 1bpp) quarter-circles into the 4 screen
corners. **Our framebuffer has NONE of this** (our right corners render a clean
`.W.W.W` checker = `0xAAAA`, i.e. the ROM never wrote the black corner pixels).
The user says the corners are drawn early ("right after the video initializes"),
NOT at the disk stage.

### Evidence already gathered (this session)
- MAME ground-truth snapshots (recipe below):
  - **Frame ~450**: corners SQUARE (`BWBWBWBW`), no "?" icon — gray dither
    already present.
  - **Frame ~1000**: corners ROUNDED (black quarter-circles, all 4) + "?" icon.
  - So in MAME the rounding appears AFTER the initial gray fill. (Whether it is
    an early desktop-draw vs the disk-search stage is the open question — the
    user believes early; the snapshot timeline is ambiguous. Resolve by PC.)
- Our `screenshot_frame_0800.png` corners: top-left `B....WWWWW`, top-right
  `.W.W.W.W` (clean checker, NO black). The left `B....` band on EVERY row is a
  SEPARATE fetch-latency bug (see below), not rounding.

### NEXT STEP — find the routine, then check our boot
1. In MAME, watchpoint the top-left VRAM word and capture the PC + frame + data
   of the write that turns the corner BLACK. VRAM CPU base = **`$F40000`**
   (maclc.cpp maps `$a00000-$ffffff` to v8; v8.cpp `map(0x540000,0x5bffff)`
   vram = CPU `$F40000`). Top-left corner word = `$F40000`; top-right of row 0 ≈
   `$F40000 + (640/8 - 2)` = `$F4004E` (but stride is 1024 B/line, MAME
   v8.cpp). The rounding write stores a value with the high bits set (black)
   vs the `0xAAAA` dither.
   - MAME debugger gotchas ([[mame-ground-truth-maclc]]): default debug CPU is
     the **Egret HC05** — switch focus to `maincpu`. 68020 opcode-PC breakpoints
     DON'T fire (prefetch/cache); **data watchpoints do**. `printf` in a
     wp action was reported working in a prior session but was flaky for me this
     session — if no console output, fall back to the `dump` command (writes a
     file) or `trace`-to-file. macOS has no `timeout`; use `-seconds_to_run`.
   - Headless snapshot recipe (lua) is in [[mame-ground-truth-maclc]]; use
     `-video opengl -nowindow` (NOT `-video none`, which gives no snapshot).
2. Grep our `verilator/cpu_trace.log` for that PC. Two outcomes:
   - **PC never executes in our boot** → the rounding draw is downstream of our
     parked drive-poll loop → it comes with the floppy "?" work (boot progress).
   - **PC executes but writes don't land** → a VRAM-write / QuickDraw / region /
     addressing bug in our core → fix that.
3. Decide the fix based on which.

## SEPARATE known video bug (minor): left-edge fetch latency
The first ~5 px of EVERY scanline render stale data (the constant `B....` left
band; `pixel_shift=0` until the line's first word arrives — the bus grants 1
video fetch/16 clk and there's no hblank prefetch). A 1-word hblank prefetch was
attempted in `rtl/maclc_v8_video.sv` and REVERTED (it garbled the edge worse;
pipeline alignment is finicky — would need a small word-FIFO). Overscan-level;
fix later. This is NOT the rounded corners (those are framebuffer content).

## Other open work (not this task)
- **Floppy "?"**: boot parked in drive-poll loop; our SWIM/IWM likely doesn't
  report the right no-disk sense. MAME refs: `swim1`/`swim2`. Likely delivers
  rounded corners + "?" if rounding is downstream.
- **ADB (mouse+kbd)**: Egret's ADB bus is stubbed (`dataController_top.sv:684-686`
  `.adb_data_in(1'b1)`). Need a line-level ADB device (mouse=3, kbd=2) to the
  ADB spec; MAME's device side is a I8048 MCU (not portable) + a stub HLE, so
  implement to spec. User has a working Mac II ADB device-side impl to reference
  (Mac II doesn't go through Egret, but device behavior is the same spec).
  Decided: mouse+keyboard, spec-accurate.

## Build / run / gotchas
- Verilator builds `verilator/sim.v` (module emu), NOT MacLC.sv — keep glue in
  sync. [[verilator-top-is-sim-v]].
- `cd verilator && make && ./obj_dir/Vemu --screenshot N --stop-at-frame N+1`
  (foreground; run once, analyze logs). Desktop visible ~frame 650+.
- Pixel/screenshot analysis: use PIL in python3 to dump B/W/. per-pixel; compare
  to MAME snapshot at `/private/tmp/goodroms/snap/maclc/`.
- MAME: `cd /Users/dani/repos/mame && /opt/homebrew/bin/mame maclc -rompath
  /private/tmp/goodroms -ramsize 2M ...` (see [[mame-ground-truth-maclc]]).

## Done-when
- Identified the ROM PC/stage that writes the black rounded corners, and
  determined whether our boot reaches it; documented the cause and the fix path
  (boot-progress vs VRAM-write bug). Bonus: corners render rounded+black.
