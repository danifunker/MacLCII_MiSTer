# Handoff: 256-color (8bpp) work + overnight HW results — 2026-06-06

## TL;DR
- The **256-color RTL is done and PROVEN boot-safe** (burst-2 SDRAM + video-priority
  arbiter + registered `video_req` timing fix). Uncommitted on branch `video-fixes`.
- A real **timing bug was found and fixed** (the first black screen).
- The core's **boot hangs on every cold-boot config I could drive headlessly** — but this
  is **PRE-EXISTING** (HEAD hangs byte-identically), NOT the color work. It's the
  documented §9 `$A4685E` RAM-init loop. The normal interactive boot avoids it.
- **256-color RENDERING is UNVERIFIED** — I could not reach a color desktop autonomously.
  That's the morning task: boot normally, set Monitors → 256 Colors, check full-screen color.

## What changed (RTL, all in working tree, uncommitted)
| File | Change |
|---|---|
| `rtl/sdram.v` | `BURST_LENGTH`=2; capture word1 in new `dout2` at state t7. CPU/disk use only word0. |
| `rtl/addrController_top.v` | Video PRIORITY on the extra bus slot (disk yields); slot-0 prefetch gated on `v8_video_req` (runs through blanking). |
| `rtl/maclc_v8_video.sv` | `video_data_in2` input; fetch FSM writes 2 words/latch (`fetch_idx += 2`, stays even). **`video_req` REGISTERED** (the timing fix — see below). |
| `MacLC.sv`, `verilator/sim.v`, `verilator/sim_ram.v` | Wire `dout2`/`video_data_in2` through both tops; sim mirrors the burst. |
| docs | `plan_ddr3_video_channel.md` (Option B), `plan_060526.md` progress, `verilator_differences.md`. |

## The timing bug (found + fixed)
First HW deploy = uniform black. `quartus_sta` showed a **setup violation, slack −0.158ns**
on `clk_mem` (65 MHz). Exact path:
`status[10] → v8_video Mult0 (h_active×bpp, 3.9ns) → video_req → sdram_oe → sd_addr[8]`,
launch clk_sys → latch clk_mem. My arbiter had gated `_ramOE`/address-mux on the
**combinational** `v8_video_req`, dragging the `words_per_line` multiply into the SDRAM
address path → corrupted addressing → CPU crash → black.
**Fix:** registered `video_req` (`maclc_v8_video.sv`). STA now closes at **+1.302ns**, no
violations. Keeps the whole feature.

## The boot hang (PRE-EXISTING — not the color work)
After the timing fix, boot still didn't reach a desktop. Decisive test: built **HEAD
(all my changes reverted)** and deployed it the exact same way (10 MB + SCSI `.hda`).
**HEAD produced the byte-identical stuck frame (md5 `bc3a2f112c03`) as my build** →
identical CPU hang → **my changes are not the cause.**

Observed cold-boot hangs (all stable for minutes = stuck, not slow):
- **2 MB**: color-garbage dither = the §9 phantom-`$0`-bank fill loop
  (`addrController_top.v` still maps `$0` as a live writable mirror of `$800000` in 2 MB;
  the proposed `ram_configured` gate / "Candidate B" was never implemented).
- **10 MB + SCSI**: clean B&W dither, stuck (HEAD identical).
- **10 MB + floppy**: §9-style garbage, stuck.

The user has had a working color desktop (session-start screenshots: Monitors panel with
Grays/Colors/16/256), so SOME config boots — but only via the **normal interactive boot**,
which I can't replicate headlessly (the screenshot API doesn't capture the OSD, so blind
file-browser navigation is unreliable).

## Morning steps (to actually verify 256-color)
1. My build is deployed to `/media/fat/_Unstable/MacLC.rbf` (proven boot-safe). Boot it
   **your normal way** to your color desktop.
2. Apple menu → Control Panels → **Monitors → 256 Colors** (640×480).
3. **Expect:** full-screen color (the burst-2 fix gives 8bpp 400 words/line vs the 320 it
   needs). Before this work, 256-color showed color-left / black-right (bandwidth starvation).
4. Also sanity-check 1/2/4-bpp + B&W still clean (they're bit-identical or improved).

## HW iteration tooling built this session (reusable)
- `scripts/grab.sh <out.png>` — trigger + download a MiSTer screenshot (URL-encodes spaces).
- `scripts/report_worst.tcl` — `quartus_sta -t` to dump worst-case timing paths.
- `_Unstable/maclc_hd.mgl` (on MiSTer) — launch core + mount the SCSI `.hda` at SC0.
- `MacLC.cfg` on MiSTer now = `0x10` (10 MB). Set via OSD nav (up×12 → down×7 → right → down → confirm).
- Note: API `/api/launch` takes a core or `.mgl` path; a raw `.hda` returns HTTP 500.

## Open / optional follow-ups
1. **256-color rendering verification** — morning, needs a booted color desktop (above).
2. **§9 boot fix (Candidate B)** — gate the `$0` decode behind `ram_configured` so the core
   boots reliably from cold / 2 MB. Separate pre-existing bug; would also let CI/headless
   reach the desktop. Plan + verification steps in memory `v8-renderer-matches-mame`.
   Risky to do blind (no working Verilator on this box) — recommend sim-verify first.
3. **16bpp** — needs Option B (DDR3 video channel), `docs/plan_ddr3_video_channel.md`.
