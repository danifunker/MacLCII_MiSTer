# Handoff: core runs slow (~1/2–1/3 real-LC speed)

Branch `new-video-technique-part-2`. Self-contained cold-resume context for the
**performance / "core runs slow"** issue. Separate from the reboot issue
(`docs/handoff_warmboot_reset_2026-06-08.md`) and the (done) video-color work.

---

## 0. TL;DR

A game on the FPGA core runs at roughly **1/2–1/3 the speed of a real Macintosh
LC** (user-observed, real LC vs YouTube capture of the core) — slow enough to be
unusable. Root cause is **not** one thing; it's a stack of compounding factors.
The single most actionable, RTL-grounded win:

> **The CPU only gets 2 of 4 SDRAM bus slots, and one of the other two — the
> video slot — is now WASTED because video moved to on-chip BRAM but the SDRAM
> arbitration was never updated. Reclaiming it for the CPU is a ~+50% memory-
> bandwidth win (potentially up to ~2× if the idle "extra" slot is reclaimed too).**

This is exactly the "I thought we use BRAM for everything" intuition: the
*framebuffer* is BRAM, but the SDRAM bus schedule still reserves a slot for a
video fetch that no longer happens.

---

## 1. Symptom

- Real Mac LC vs this core (same game): the core runs ~1/2–1/3 speed. Noticeable,
  not subtle. Confirmed by comparing a real-hardware video to a YT capture of the
  core. No specific game named here — applies generally.
- Video *renders correctly* (all depths/resolutions) — this is a throughput/timing
  problem, not a rendering bug.

---

## 2. Verified clocking facts

- PLL (`rtl/pll.v`): `clk_mem` (outclk_0) = **65 MHz**, `clk_sys` (outclk_1) =
  **32.5 MHz**. (Some stale comments say clk_sys ~65 MHz — wrong; it's 32.5.)
- `CLK_VIDEO = clk_sys` (`MacLC.sv:357`); pixel clock = `clk_sys/2` = 16.25 MHz.
- Bus timing (`rtl/addrController_top.v:94-121`):
  - `busPhase` (2-bit) increments every `clk_sys` → wraps every 4 (8.125 MHz).
  - `busCycle` (2-bit) increments each `busPhase` wrap → full round every **16
    clk_sys ≈ 492 ns (~2.03 MHz round rate)**.
  - One memory transaction commits per `busCycle` at `memoryLatch` (`busPhase==3`).
  - **Slot allocation per round:** `00`=`videoBusControl`, `01`=`cpuBusControl`,
    `10`=`extraBusControl` (disk/dio), `11`=`cpuBusControl`.
- **CPU clock-enable** `cpu_en_p = clk16_en_p` = **16.25 MHz** (`MacLC.sv:522`) —
  so the CPU is at the "16 MHz" setting, NOT 8 MHz. CPU clock is correct.
- **CPU memory-transaction rate** = 2 slots / 16 clk_sys = **~4.06 M xfers/s**
  (16-bit each). The CPU logic ticks at 16.25 MHz but can only touch memory ~4 M
  times/s.

---

## 3. Root-cause analysis (prioritized, RTL-grounded)

### H1 — CPU bus-slot starvation; the video slot is now WASTED (LEADING, fixable)
- Video moved to on-chip BRAM (`rtl/vram_bram.sv`): the video module now drives
  `video_req = 1'b0` and `video_addr = 22'd0` (`rtl/maclc_v8_video.sv:230-232`,
  "SDRAM video path retired in Phase 2"), reading the framebuffer via
  `vram_raddr`/`vram_rdata`.
- BUT `addrController_top.v` still allocates `busCycle==00` to video
  (`videoBusControl`, line 120) and still issues an SDRAM access for it
  (`addr_mux = video_slot ? vid_sdram_word : …`, line 245) — a **dead read at a
  stale address every round**. `video_extra` is also always 0 (it needs
  `v8_video_req`, which is 0).
- ⇒ The CPU gets only slots `01` + `11` (2 of 4). **Slot `00` is reclaimable for
  the CPU right now (3/4 = +50% CPU memory bandwidth).** Slot `10`
  (`extraBusControl`) is also idle except during disk reads
  (`dskReadAckInt/Ext`; "extra_slot_count==2 is now idle, legacy sound DMA
  removed", line 253) — reclaimable when no disk read pending → up to ~2×.
- This directly raises the ~4 M xfers/s ceiling that throttles all memory-bound
  CPU code.

### H2 — TG68K has no instruction cache (the real LC 68020 has a 256B I-cache)
- `grep -i cache rtl/tg68k/*` → nothing. The TG68K is a 68000-class core: every
  instruction fetch hits memory. The real LC's 68020 caches instructions, so tight
  loops fetch at ~0 wait while ours pay the 16-bit memory latency every fetch.
- On the LC's 16-bit memory bus this is the classic "68020 cache hides the narrow
  bus" effect — our un-cached core can't hide it. This is likely a large fraction
  of the gap and compounds with H1 (no cache ⇒ even more memory-bound ⇒ even more
  sensitive to slot starvation).
- Harder to fix: would need an I-cache in front of the CPU fetch path, or a
  different/faster core, or overclocking (H4) to compensate.

### H3 — frame/VBL/Tick rate too slow ("Bug B", separate known issue)
- `pix_en = clk_sys/2 = 16.25 MHz` fixed for all modes (`maclc_v8_video.sv`):
  640×480 runs **38.7 Hz**, 512×384 **~62 Hz** (vs real ~66.7 / 60.15 Hz). The
  Mac's VBL interrupt and the 60.15 Hz system Tick derive from the video refresh,
  so **time-paced games run at refresh_rate/real ≈ 0.6×** independent of CPU speed.
- Contributes to "feels slow" but does NOT explain CPU-bound slowness. Fix = real
  per-mode pixel clock (PLL taps), tracked separately.

### H4 — Overclock the CPU (pragmatic compensation, optional)
- `cpu_en_p` is hard-wired to `clk16_en_p` (16.25 MHz). If H1+H2 still leave a gap,
  raising the CPU's effective rate (more/looser slots, or a faster CPU clock-enable
  decoupled from the 32.5 MHz video-locked `clk_sys`) can brute-force it. Note
  `clk_sys` itself is constrained by the pixel clock, so prefer slot/enable changes
  over raising `clk_sys`.

**Why ~1/2–1/3:** H1 caps memory-bound code at ~4 MHz xfers; H2 makes the CPU
heavily memory-bound (no cache); H3 adds ~0.6× on time-paced titles. Stacked,
that lands in the observed range.

---

## 4. Proposed plan (do in this order; MEASURE between steps)

0. **Establish a benchmark.** The user already has **Speedometer 3.23**,
   **TattleTech**, and CPU test suites on the HD (visible on the desktop). Run
   Speedometer on a real LC and on the core to get a quantitative ratio, and
   re-run after each change. Also time a known game loop from the YT capture.
1. **H1 — reclaim the wasted video slot for the CPU.** In
   `rtl/addrController_top.v`: since `video_slot`/`v8_video_req` are dead, give
   `busCycle==00` to the CPU (extend `cpuBusControl` to include `00`, and drop the
   dead video SDRAM access from `addr_mux`/`_ramOE`). Verify: (a) video still
   fetches from BRAM correctly (screenshots unchanged), (b) disk reads still work
   (slot `10`), (c) Quartus-clean + boots. Expected ~+50% CPU memory bandwidth.
   - Stretch: also lend slot `10` to the CPU when no disk read is pending → ~2×.
2. **Re-measure.** If the gap is largely closed, H1 was the main culprit. If not,
   proceed.
3. **H3 — pixel clock / refresh** (helps time-paced games + general feel). Needs
   per-monitor PLL taps (25.175 MHz for 640×480, 15.667 MHz for 512×384) and a
   pixel-clock mux. Tracked in the video plan (`docs/plan_060526.md`, "Bug B").
4. **H2 — instruction cache (big lift) or H4 overclock (pragmatic).** Only if 1–3
   don't close it. An I-cache in front of the CPU fetch path is the "correct" fix
   (mirrors the real 68020) but is a substantial RTL effort; overclocking the CPU
   enable is the cheap stopgap.

---

## 5. Validation / risk notes

- **Bus-slot changes are high-sensitivity** (like the VIA-SR caveats). After any
  `addrController` arbitration change: rebuild Verilator and verify the
  frame-350/400 screenshots still render full-width and the core boots
  (`docs` boot checks), AND confirm disk/SCSI still reads (the `extra` slot).
- The Verilator sim shares `addrController_top.v` with the FPGA, so slot changes
  CAN be validated in sim (unlike the SDRAM-controller reboot issue). Use the
  existing screenshot + `check_boot.sh` flow.
- Watch Quartus single-driver rules on any new `busCycle` decode.

---

## 6. Key files / line numbers

- `rtl/addrController_top.v:94-131` — `busPhase`/`busCycle`, slot allocation
  (`videoBusControl`/`cpuBusControl`/`extraBusControl`), `video_extra`/`video_slot`.
- `rtl/addrController_top.v:144-149` — `_ramOE`/`_ramWE` (gated by the slots).
- `rtl/addrController_top.v:230,245` — `vid_sdram_word` + `addr_mux` (the dead
  video SDRAM access to remove).
- `rtl/addrController_top.v:251-253` — `extra` slot disk-read / idle decode.
- `rtl/maclc_v8_video.sv:228-232` — `vram_raddr` (BRAM read) and
  `video_req=0`/`video_addr=0` (proof video left SDRAM).
- `MacLC.sv:522-523` — `cpu_en_p/n = clk16_en_p/n` (CPU at 16.25 MHz).
- `MacLC.sv:357` — `CLK_VIDEO = clk_sys`; `rtl/pll.v` — 65/32.5 MHz.
- `rtl/tg68k/` — the CPU core (no instruction cache).
- `rtl/maclc_v8_video.sv` (pix_en) — "Bug B" fixed 16.25 MHz pixel clock.

---

## 7. Open questions to resolve early

- **Compute-bound vs memory-bound split:** before investing in H1, a quick sim
  experiment can estimate how much the CPU stalls waiting for `cpuBusControl`
  (count CPU-wait cycles vs active cycles). If the CPU rarely waits on memory,
  H1's ceiling isn't the bottleneck and H2 (cache) dominates.
- **Which game / how slow exactly:** a precise ratio (Speedometer score core vs
  real LC) turns "1/2–1/3" into a target and tells us when we're done.
- Confirm `clk_mem`=65 MHz headroom for any CPU overclock (H4) and Fmax of the
  TG68 path in the current Quartus timing report.
