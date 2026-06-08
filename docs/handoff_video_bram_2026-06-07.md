# Handoff: VRAM-in-BRAM landed, but a bpp-dependent video cut remains (NOT bandwidth)

Branch `video-new-technique`. Self-contained cold-resume context. Continues
`docs/plan_060726.md` (move VRAM into on-chip BRAM).

---

## 0. TL;DR — the big reframe

We moved the Mac LC framebuffer **entirely into on-chip dual-port BRAM** (Phases
0–2 of `docs/plan_060726.md`). The build is **clean**: A&S OK, framebuffer inferred
as **M10K (457/553 blocks)**, timing **closed** (all STA slacks positive), rbf
deployed to HW.

**But the video shows the SAME partial-screen cut as the earlier shared-SDRAM and
HPS-DDR3 attempts.** Three completely different memory backends — slow/shared,
latency-bound, and infinite-bandwidth on-chip — give the **identical** result.
⇒ **The bottleneck was never memory bandwidth.** (The whole DDR3 effort and our
Phase 2 were attacking the wrong layer.) It is a **bpp-dependent cut in the shared
display/data path.**

A **gradient diagnostic (commit `eddab6c`, MUST BE REVERTED)** is being built to
split "pipeline vs data." Resume from its result (Section 6).

---

## 1. Exact symptom (current HW build)

- **1bpp and 2bpp: FULL width**, both 512×384 and 640×480. Correct.
- **4bpp (16-color): 640×480 ≈ 20%** filled (left ~128 px / ~32 words), rest white;
  **512×384 = ALL WHITE** (nothing draws).
- 8bpp: also cut.
- "White" = the display reading **unloaded/blanking** data (historically the shift
  reg's `0xFFFF`; see commit `16996cd`, a prior white-screen bug from a fetch/pix_en
  timing mismatch).
- **Identical across the SDRAM, DDR3, and BRAM backends** ⇒ backend-independent.

## 2. What the symptom rules IN / OUT (the load-bearing logic)

- Anything **bpp-INDEPENDENT cannot be the cause** (1/2bpp work and 4bpp doesn't at
  the *same* clock/monitor/scaler): this **rules OUT** the pixel clock, the monitor
  timings/geometry, the ascal scaler, `CE_PIXEL`/`DE`, and the RetroTink (screenshots
  are the core's internal framebuffer, pre-HDMI, RT4K-independent).
- The cause **must be bpp-VARYING logic**: `words_per_line` (= h_active*bpp/16),
  `px_per_word`, fetch fill-vs-consume timing, the CPU-write packing multiply
  (`vram_line * words_per_line`), or the pixel extraction.
- The **512-white vs 640-20% asymmetry at the same depth** ⇒ mode/timing-specific,
  **not a flat word-count cap** (640 shows *more* words than 512, the opposite of a
  fixed cap).

## 3. The gradient diagnostic in flight (`eddab6c`) — **REVERT AFTER READING IT**

`rtl/maclc_v8_video.sv` fetch write was changed to:
```
linebuf[{fetch_buf_d, fetch_wr_idx[8:0]}] <= {4{fetch_wr_idx[3:0]}};   // was: vram_rdata
```
This fills the line buffer from the **word index via the fetch loop**, bypassing the
BRAM data **and** the CPU-write/packing path. On-screen extent == how many words the
**fetch loop itself** fills per scanline. Interpretation at 4bpp:

- **FULL WIDTH at both 512 & 640** → fetch + display + scaler are fine → the cut is in
  the **DATA** (BRAM content / CPU packing / read addressing). Next: instrument the
  CPU-write extent or read back BRAM at a high column (ISSP Probe 1); compare to MAME
  (does `maclc` draw a full-width 4bpp desktop? it should).
- **SAME 512-white / 640-20%** → the **fetch/display TIMING is mode-broken** → scrutinize
  `words_per_line` at 4bpp, fetch completion vs `h_total`, the ping-pong parity, and the
  BRAM read-latency pipeline (`fetch_pend`/`fetch_wr_idx`/`fetch_buf_d`).

**REVERT** = restore `... <= vram_rdata;` (the original line is preserved as a comment
in `eddab6c`).

## 4. Architecture as it stands

- **`rtl/vram_bram.sv`** — two byte-wide simple-dual-port M10K RAMs (lower/upper lane),
  `DEPTH=196608` words (384 KB = 16bpp@512×384, the max supported mode). Port A = CPU
  write (byte-masked), Port B = video read, both `clk_sys` (coherent, no CDC). Byte-lane
  + plain write-enable is what finally infers as M10K — a 16-bit *byte-enabled* array did
  NOT infer (A&S ballooned to ~20 GB building it in logic; that was the "hang").
- **`rtl/addrController_top.v`** — mirrors CPU VRAM writes into BRAM with packed addressing:
  `packed = vram_line*words_per_line + vram_colw`, gated by `vram_colw < words_per_line`
  (drops the fixed 1024-byte stride padding so 640-wide fits 384 KB). Still ALSO writes the
  SDRAM VRAM region (Phase 1 left that mirror; can be removed once BRAM is trusted).
- **`rtl/maclc_v8_video.sv`** — ping-pong `linebuf[0:1023]` (512/half). Fetch side reads
  BRAM port B 1 word/clk into the next line's buffer (`packed_row_start` accumulator,
  `fetch_buf = ~v_count[0]`). Display side reads at pixel rate, extracts bpp pixels →
  Ariel CLUT → RGB. **This display logic looks correct on inspection — no width cap found.**
- **Both tops** (`MacLC.sv`, `verilator/sim.v`) instantiate `vram_bram` and are kept in sync.

## 5. Key commits (branch `video-new-technique`)

- `29e1f69` TG68 `MacLC.sdc` multicycle (timing-closure prereq, cherry-picked from fix-pram)
- `5f08ed3` phase1: mirror CPU VRAM writes into BRAM (additive)
- `77c0978` phase2: video fetch from BRAM
- `951a2ca` → `c4729ee` vram_bram → simple-dual-port → **byte-lane** (M10K inference fixes)
- `eddab6c` **gradient diagnostic [REVERT]**
- `d8b2b93`/`180773f` disabled then re-enabled the ADB/AUD ISSP probes — **probes are ON**
  per user preference (they predate this work; `docs/plan_060726.md` Phase 4 wants them OFF
  for the eventual release).

## 6. Resume decision tree

1. Read the gradient (`eddab6c`) result at 4bpp for **both** 512 and 640, then **REVERT `eddab6c`**.
2. **Gradient FULL** → it's the DATA path. Instrument the CPU-write extent / read back BRAM at a
   high column (ISSP). Check whether the OS actually draws full-width 4bpp (MAME `maclc` oracle,
   `docs/mame_compare.md`). Suspect the packing or an OS-draw/rowbytes assumption.
3. **Gradient CUT (same)** → it's fetch/display timing. The 512-white/640-20% asymmetry is the
   tell — focus on `words_per_line` and fetch-vs-display completion as a function of `h_total`.
4. Independently, plan **Bug B (clocks)** — see Section 7.

## 7. Bug B (separate, real, NOT the cause of the cut): clocks/refresh

`pix_en = clk_sys/2 = 16.25 MHz`, **fixed for all modes** (`maclc_v8_video.sv`). Wrong for
both monitors: 640×480 VGA needs **25.175 MHz** (so it runs ~38.7 Hz, not 60) and 512×384
RGB needs **15.6672 MHz**. This is why the user needs a *custom* RetroTink-4K profile for
512×384. Fix = PLL taps + a per-`monitor_id` pixel-clock mux (and likely a dual-clock line
buffer). **bpp-INDEPENDENT**, so it does NOT explain the 4bpp cut — do it as its own task.
The RT4K profile is best used as post-fix *verification* (a standard profile should then lock).

## 8. Build / deploy / test loop (Windows box)

- Repo: `C:\Temp\mistercore\MacLC_MiSTer` (mounted on the Mac at `/Volumes/Temp/...`).
  `git pull` (upstream is set on `video-new-technique`).
- **Build:** `bash scripts/build.sh` (Git Bash or WSL with Windows `quartus_sh` on PATH; ~16 min).
  Verify A&S "successful", Fitter successful, **all** slacks positive
  (`grep -i slack output_files/MacLC.sta.summary`), and a fresh `output_files/MacLC.rbf`.
  - **Runaway signature** (Quartus 17 Lite): the log **stops growing** (frozen mid-line) and/or
    `quartus_map` memory balloons (it hit **20 GB** when the BRAM was building in logic). A healthy
    A&S keeps memory modest and finishes in ~4–6 min. The Fitter's core-placement phase is
    legitimately silent for several minutes — don't mistake that for a hang.
  - Fast A&S-only check: `quartus_map MacLC -c MacLC`.
- **Deploy:** `bash scripts/deploy_cmd.sh 150 out.png` (MiSTer `192.168.99.87` via
  `/dev/MiSTer_cmd`; ~150 s boot on stock ROM). Screenshots = the core's internal framebuffer.
- Device PRAM is set to **4bpp** (don't reset).

## 9. Sim notes (Verilator)

- `cd verilator && make && ./obj_dir/Vemu --screenshot 400 --stop-at-frame 401`.
- Boots **1bpp** by default (PRAM all-zero); reaches the no-disk floppy desktop ~frame 400 using
  the **locally-patched skip-RAM-test `releases/boot0.rom`** (NOT committed; stock backup at
  `releases/boot0.rom.stock`; patcher `verilator/patch_skip_ramtest.py`).
- Sim captures video **directly (no ascal scaler)** → it cannot reproduce scaler/clock issues, but
  CAN reproduce data-path bugs. Reproducing 4bpp in sim needs a 4bpp PRAM + a SCSI-HD boot (slow);
  not yet done. At 1bpp the BRAM path renders the full no-disk desktop correctly.

---

## RESUME PROMPT (paste into a fresh session)

> Resume the Mac LC video debug on branch `video-new-technique`. Read
> `docs/handoff_video_bram_2026-06-07.md` first — it is the full cold-resume context.
> Summary: we moved VRAM entirely into on-chip BRAM (builds clean, M10K confirmed,
> timing closed), but the video still shows the SAME bpp-dependent cut as the prior
> SDRAM and DDR3 attempts (1/2bpp full; 4bpp@640 ≈ 20%, 4bpp@512 all-white) — which
> proves it was never memory bandwidth. A gradient diagnostic (commit `eddab6c`, which
> MUST be reverted) is built to split pipeline-vs-data: if 4bpp fills full width it's the
> data path, if it shows the same cut it's fetch/display timing. Pick up from the gradient
> screenshot per the handoff's Section 6 decision tree. Don't chase the pixel-clock issue
> for this bug — it's bpp-independent (Section 7).
