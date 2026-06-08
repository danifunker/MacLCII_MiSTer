# Handoff: bpp video cut FIXED; color (CLUT) bug root-caused, fix pending

Branch `video-new-technique`. Continues `docs/handoff_video_bram_2026-06-07.md`
and `docs/video_oracle_maclc.md`. Self-contained cold-resume context.

---

## 0. TL;DR

Two separate video bugs at >2bpp. **Bug 1 (the "video cut" / white bar) is FIXED
and committed.** **Bug 2 (color renders as greyscale) is fully root-caused; the
fix is designed but NOT yet implemented** (ran out of session). The tree builds
and is ready for an FPGA build to verify Bug 1.

- **Bug 1 — bpp video cut (FIXED, commit `8126f91`):** an 11-bit overflow in
  `words_per_line`. `assign words_per_line = (h_active*bits_per_pixel)>>4;` with
  `words_per_line` only 11 bits → the multiply wrapped mod 2048 *before* the >>4,
  corrupting 4bpp@640 (→32 words, ~128px+white), 8bpp@640 (→64), **4bpp@512 (→0 =
  ALL WHITE)**, 16bpp@512 (→0). 1/2bpp (≤1280) never wrapped → always worked.
  Fix: full-width product first. Verified in Verilator: 4bpp@640 now renders
  full-width (160 words).

- **Bug 2 — color shows as greyscale (NOT FIXED):** the Ariel CLUT palette-write
  strobe **fires multiple times per CPU write** (multi-fire), so `color_comp`
  advances R→G→B within ONE CPU write and the single byte is stored into all
  three components → every entry collapses to grey (R=G=B). Root cause proven
  (see §3). Fix design in §4.

---

## 1. Current committed state (branch `video-new-technique`)

- `8230e30` docs(video): **MAME oracle** + tooling (`docs/video_oracle_maclc.md`,
  `verilator/mame/{vram_extent,set_montype}.lua`, `run_mame_windowed.sh`).
- `8126f91` **video(v8): fix words_per_line 11-bit overflow** (Bug 1). The headline fix.
- `40e207f` test: default egret PRAM to 4bpp (`rtl/egret/egret.pram` byte 0x58=0x82)
  so the core boots straight into 16-color mode. **Revert byte 0x58 → 0x80 for a
  1bpp release default.**

Working tree: `releases/boot0.rom` is modified (your local skip-RAM-test patch —
pre-existing, leave it). All diagnostics have been reverted; RTL is clean.

---

## 2. Build / test scenarios (FPGA)

Build is expected to be Quartus-clean (the fix is plain single-driver Verilog).
Boots **4bpp @ 640×480** by default now (the 4bpp PRAM). Scenarios to check:

1. **4bpp @ 640×480 (primary):** desktop should now fill the **full width** (no
   white bar / no ~128px cut). This is the Bug-1 fix. ✅ = full width.
   - The Apple logo (top-left) will still be **grey, not rainbow** — that's Bug 2.
2. **Set 512×384 via Monitors → 16 Colors:** previously **ALL WHITE**; should now
   draw the full 512-wide desktop. (4bpp@512 words_per_line was 0, now 128.)
3. **8bpp @ 640×480 (256 Colors):** previously cut; should now be full width
   (words_per_line was 64, now 320).
4. **1bpp / 2bpp:** regression check — must remain full width (they always worked;
   the fix doesn't touch the <2048 path).
5. **Color sanity (expected to FAIL until Bug 2 is fixed):** any color element
   (Apple logo, color icons) renders in greyscale. Confirms Bug 2 still present.

Ground truth for every mode is in `docs/video_oracle_maclc.md` (MAME draws all
depths full-width; 4bpp/8bpp/16bpp Apple logo is the rainbow).

---

## 3. Bug 2 root cause — PROVEN (the color/greyscale bug)

**Symptom:** 4bpp desktop is full-width (after Bug-1 fix) but everything is
greyscale; the menu-bar Apple logo is grey instead of rainbow. Same on FPGA (you
set Colors in the UI → B&W) and in the Verilator repro.

**Method:** baked a 4bpp PRAM, booted the Verilator sim from the SCSI HD image
(`/Users/dani/Downloads/HD0-Official-6.0.8-500M.hda`), and tapped every Ariel CLUT
write. Compared against MAME tapping `$F24000-3` with the **identical** PRAM.

**Findings:**
- MAME loads the classic 16-color Mac palette into the 4bpp-visible slots
  (`CLUT[0x_F]`): [1F]=yellow fc/f6/10, [2F]=orange, [3F]=red e7/17/13, [5F]=purple,
  [6F]=blue, [7F]=cyan, [8F]=green, [0F]=white, [FF]=black, etc. First color write
  at **frame 283** (so a ≤200-frame run is too early to see color — use ≥320).
- Our core's `CLUT[0x_F]` come out **grey**, and crucially our **R value exactly
  matches MAME's R** for every slot (e.g. ours [3F]=e7/e7/e7 vs MAME e7/17/13).
  → the OS sends the right data; we collapse G,B to R.
- Per-write tap with an LDS-falling-edge access counter showed the 3 R/G/B writes
  of one entry share the **same** `lds_access` value (one CPU access) but produce
  three `color_comp` steps (0,1,2) with the **same** `data_in`:
  ```
  addr=3f comp=0 data_in=e7 lds_access=7447
  addr=3f comp=1 data_in=e7 lds_access=7447   <- same access
  addr=3f comp=2 data_in=e7 lds_access=7447   <- same access
  ```
  ⇒ **ONE CPU write is processed THREE times.** `req_stb = req && mem_latch`
  (`rtl/ariel_ramdac.sv:104`) fires once per *bus cycle*, but a 68k CPU write to
  the Ariel spans **multiple** bus cycles, so it fires ~3×. The DAC auto-increments
  R→G→B on each, writing the single byte into all three → grey.

This is the same multi-write class as the old comment at `ariel_ramdac.sv:96-103`
(and `asc-audio-fix`); the `memoryLatch` gating was assumed to make it "exactly
once" but it does NOT — it only looked right at 1bpp because 1bpp is grey anyway.

---

## 4. Bug 2 — proposed fix (implement + verify next session)

Make the Ariel register action fire **exactly once per CPU access**, not once per
bus cycle. Cleanest: a one-shot armed by the CPU access strobe.

Recommended approach (needs `_cpuAS` wired into `ariel_ramdac` from both tops):
```verilog
// One advance per CPU access. mem_latch pulses several times across a single
// (multi-bus-cycle) CPU access; act on the FIRST only, re-arm when _AS releases.
reg fired;
always @(posedge clk_sys)
    if (cpu_as_n)            fired <= 1'b0;   // access ended -> re-arm
    else if (mem_latch)      fired <= 1'b1;   // consumed this access
wire req_stb = req && mem_latch && !fired;
```
Wire `.cpu_as_n(_cpuAS)` in **both** `verilator/sim.v` and `MacLC.sv` (keep them in
sync — see `docs/verilator_differences.md`).

CAVEATS / alternatives:
- A prior note (`memory: ariel-clut-inversion-fix`) says an "_AS-armed one-shot
  didn't work (addr+data writes share one _AS window)." Verify `_cpuAS` actually
  *deasserts between* consecutive Ariel byte writes in our bus model; if back-to-back
  accesses keep `_AS` low, use the per-byte strobe instead: re-arm on the rising
  edge of the relevant strobe (`uds_n` for the address reg @even, `lds_n` for
  palette data @odd — `ariel_ramdac` already has `uds_n`/`lds_n`).
- Keep capturing `data_in` at `mem_latch` (data is stable there) — only the
  *count* of advances is wrong, not the data timing.
- Watch the address-register write too (it also uses `req_stb`); a multi-fire there
  would re-write the address harmlessly but verify.

**Verify in sim before any FPGA build:** rebuild, run
`./obj_dir/Vemu --scsi0 /Users/dani/Downloads/HD0-Official-6.0.8-500M.hda --stop-at-frame 400`,
then confirm `CLUT[0x_F]` match the MAME 16-color values in §3 (re-add the simple
`$display` in the `color_comp==2` branch to dump entries; it was reverted). Then a
screenshot ~frame 400 should show the **rainbow Apple logo**.

---

## 5. Diagnostic recipe (reusable)

- **Bake depth into the sim:** `rtl/egret/egret.pram` byte 0x58 = QuickDraw
  DepthMode (0x80=1bpp/0x82=4bpp/0x83=8bpp/0x84=16bpp); byte 0x5A = montype
  (0x06=640×480, 0x02=512×384). No PRAM checksum — single-byte patch works (proven
  in MAME). For 512×384 in sim also set `verilator/sim.v` `v8_monitor_id` 6→2.
- **Boot the sim with the System:** `--scsi0 /Users/dani/Downloads/HD0-Official-6.0.8-500M.hda`.
  Color CLUT loads ~frame 283 → run to **≥320–400** (NOT ≤200).
- **MAME oracle (same PRAM):** `python3` write `egret.pram`→`nvram/maclc/egret`,
  then `verilator/mame/run_mame.sh -hard /private/tmp/goodroms/hd608.chd ...`.
  Tap CLUT: `TAP_LO=0xf24000 TAP_HI=0xf24003 TAP_MODE=w ... tap.lua`; lanes:
  mask FF000000→addr reg (0xf24000), mask 00FF0000→palette data (0xf24001).
- **macOS has no `timeout`**; the sim self-stops at `--stop-at-frame`. Run ONE sim
  at a time (two instances split the CPU and each crawls — looks "stuck").

---

## 6. Still open / separate (not this work)

- **Bug B — clocks:** `pix_en = clk_sys/2 = 16.25 MHz` fixed for all modes
  (`maclc_v8_video.sv`); 640×480 wants 25.175 MHz, 512×384 wants 15.667 MHz. Needs
  PLL taps + per-monitor pixel-clock mux. bpp-independent; unrelated to Bugs 1/2.
- The `eddax`/gradient diagnostic and all tap probes are reverted; tree is clean.
- For release: revert `egret.pram` 0x58→0x80 (1bpp default) unless a color default
  is desired.
