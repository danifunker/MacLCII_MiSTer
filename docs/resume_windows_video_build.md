# Resume (Windows/Quartus box): build & HW-test the video-color work — 2026-06-05

**Branch: `video-fixes`** (pushed to origin; it is a linear superset of `master`,
so it ALSO contains the 10MB-RAM, 16MHz-VIA, and sound-parked work). This box
has Quartus + a real MiSTer but no working Verilator — so the loop here is
**build RBF → deploy → test on hardware**, not simulate.

## What this build contains (new since the last HW build)
1. **Video color path (Phase 1a/1b).** The old fetch was bandwidth-limited to
   ~2bpp and faked deeper modes by stretching pixels → no usable color. Now:
   - `c273246` scanline ping-pong **line buffer** (parity-selected, async read):
     1bpp is full-res again (**single sharp cursor**, not doubled); every depth
     renders true horizontal resolution.
   - `60cc424` video borrows the idle **"extra" bus slot** when its prefetch is
     hungry → **16-color (4bpp) has enough bandwidth** (verified full-width in
     sim). CPU's two bus slots untouched; 1/2bpp bit-identical to before.
   - `7d00917` pseudovia video-config **readback = montype<<3** (MAME-faithful;
     stops the OS misclassifying the display).
2. Already on `master`, in case this is the first HW build with them:
   `02b6d3c` 10MB RAM fix, `1850a7f` VIA timer /2 (TattleTech 16MHz). Confirmed
   on HW last session: 10MB✓, 16MHz✓, kbd/mouse✓.

## Build
- Open `MacLC.qpf` in Quartus 17.0.2, compile, deploy `output_files/*.rbf` to
  the MiSTer SD root.
- Expect ONLY the known TG68 `332081` combinational-loop critical warning.
- The line buffer is `(* ramstyle="MLAB,no_rw_check" *) reg [15:0] linebuf[0:1023]`
  — if Quartus refuses MLAB at that depth it will fall back to logic/M10K
  (resource cost, not an error). All new regs are single-driver (no Error 10028).
- `MacLC.qsf` still has `USE_ADB_ISSP` + `USE_AUDIO_ISSP` enabled — LEAVE THEM
  (the AUD probe is needed for the sound re-read below). Comment both out only
  for a final release build.

## ⚠️ PRAM does NOT persist (depth resets every boot)
The core has **no nvram/save mechanism**. `egret_wrapper.sv` inits PRAM via
`$readmemh("rtl/egret/egret.pram", pram)` in an `initial` block — a SYNTHESIS-time
init baked into the bitstream (default `egret.pram` = all zeros = 1bpp). The OS's
depth/date writes land in live BRAM (`intram[0x70..0x16F]`) and are LOST on
reset/power-off. The SCSI disk is writable & persists, but depth lives in PRAM,
not on disk. So on HW you must re-set Monitors → N Colors **every boot**.
Two fixes (future work):
1. Quick: bake a color PRAM into `rtl/egret/egret.pram` before building (FPGA
   always boots that depth; carries a stale RTC if sourced from MAME).
2. Proper: HPS-backed PRAM save (save slot in CONF_STR + `ioctl` save/load +
   save-on-change) so PRAM persists to SD like a normal core. NEW TASK.

## HW test plan (the point of this build)
Color depth comes from **PRAM**, so set it natively on the Mac (instant on HW):
**Apple menu → Control Panels → Monitors** (re-set each boot — see warning above).

1. **Default boot (B&W/1bpp):** confirm single sharp cursor, full-res, no
   regression vs the last build. Desktop dither clean to all four edges.
2. **Monitors → 16 Colors (Colors, not Grays):** EXPECT real color, full screen.
   This is the headline result of this build. Try a colored desktop pattern
   (General Controls) for a vivid check.
3. **Monitors → 256 Colors:** EXPECT a colored strip on the LEFT and black on
   the RIGHT — this is the **known 8bpp bandwidth limit** (one extra slot isn't
   enough for 320 words/line; the fix is SDRAM burst, task/Phase 3). Not a bug,
   just not done yet. Note how far right the color reaches.
4. **White border:** the prior "white border moving around" is the unaddressed
   pre-first-word/edge-pixel issue (Phase 1c). Note if it's better/worse/same.
5. **640x480 refresh:** still ~38.7Hz (pixel clock = clk_sys/2), so the RT4K /
   scaler may still complain. True 60Hz needs a 25.175MHz PLL tap (Phase 2).
6. **Sound (still dead):** re-read the **AUD JTAG probe on THIS build**
   (`quartus_stp_tcl -t scripts/read_adb_aud.tcl`). The `asc_wr=0/asc_rd=0`
   evidence predates all recent fixes — this is the decisive datum. asc_wr>0 →
   output-path hunt; asc_wr=0 → ROM-level. Full plan: `docs/continue-audio-fixing.md`.

## Read for context
- `docs/plan_060526.md` — the full video overhaul plan + color-depth ceiling
  (V8 max = 256@640x480, thousands@512x384; NO "millions"/24bpp).
- `docs/continue-audio-fixing.md` — the parked FPGA sound hunt.
- Memory: `video-line-buffer-color`, `rom-sdram-overlap-10mb-fix`,
  `via-timer-prescaler`, `asc-fpga-sound-and-mame-memtest-findings`.

## Open work (priority order)
1. **8bpp (256-color) bandwidth** — SDRAM burst reads (2 words/access) or a 3rd
   bus slot. Phase 3 / task #6. The clean path to full 256-color.
2. **White border** — force RGB=0 (palette-independent) for undrawn/pre-first-word
   pixels. Phase 1c.
3. **True 60Hz 640x480** — 25.175MHz PLL tap + re-clock the line-buffer read
   side (it's already dual-clock-ready). Phase 2.
4. **Sound** — see the audio doc; gated on the AUD probe re-read.

## Verilator note (for when back on the Mac)
The Mac side proved 16-color bandwidth works by FORCING `v8_video_mode` in
`sim.v` (content is garbage since the OS framebuffer is 1bpp, but it shows
fetch/starvation). To see REAL color content in sim, transplant a color PRAM:
set depth in MAME (`-nvram_directory <dir>`, Monitors → N Colors, quit), then
`for b in mame_egret: egret.pram` hex (the load path is `$readmemh` at runtime,
no rebuild). VERIFIED the transplant loads + boots clean; just slow to reach the
Finder (~F2400 ≈ 20min). `--skipramtest` does NOT help (spins at the WarmStart
check). The MAME egret PRAM maps 1:1 to our `intram[0x70..0x16F]`.
