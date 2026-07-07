# RESUME — pixel-clock video import BLACK-SCREENS on hardware (2026-07-07)

Read cold to continue. Yesterday's v9 type-7 fix is HW-validated and shipped.
Today imported four fixes from the sibling `../MacLC_MiSTer`; three are safe,
**the fourth (per-monitor pixel-clock video) black-screens the MiSTer** and is
the open blocker. The kernel walk-audit follow-up is done and sim-clean.

## CURRENT HW-GOOD STATE — do not lose this
- **Running / last-known-good: v9** = `releases/MacLCii_flineFix_v9_20260703.rbf`
  (md5 `143d902b`), on the box as `_Unstable/MacLCii.rbf`. Boots 7.1 to a
  stable, usable Finder. This is the fallback; the user is on it now.
- **PoP is slow on v9 — that is EXPECTED, not a regression.** v9 predates the
  System-Tick fix (commit `9375c9f`, after v9's `e4f783e`). The Tick fix is in
  the new build that black-screens, so its PoP-speed fix is NOT yet HW-proven.

## WHAT'S COMMITTED (branch video-performance, all sim-verified)
- `9375c9f` System Tick half-rate fix (PoP speed) — CPU/VIA timing domain.
- `5e3742f` registered VPA SCSI read (fit-independent) — peripheral read.
- `7cfa483` **per-monitor pixel-clock video import** — THE BLACK SCREEN.
- `d0f78ab` retire stale F350 gate + VIDDBG/RAWVID sim taps — sim/docs only.
- `a254a02` kernel walk-exposure audit fixes (2 fixes + hardening + dead-code
  removal) — sim-clean to F2231, 0 [EXC], benches PASS. **Not HW-validated**
  (blocked behind the video black-screen; independent of it).

## WHAT'S UNCOMMITTED
- `MacLC.sv` — the "static clock" diagnostic: strips the runtime-reconfig FSM,
  hard-ties the pll_cfg write strobe LOW, `clk_vid` = static 25.175 MHz VGA in
  all modes. **This variant ALSO black-screens** → keep as evidence, do not
  commit as-is. It proves the bug is NOT the reconfig FSM.

## THE BUG
New video build on HW: **boot chime plays (CPU alive), screen is BLACK from
power-on.** First deploy (reconfig variant) showed a CORRECT desktop for a few
seconds, then artifacted → `clk_vid` died (JTAG PVID vbl_cnt froze ~74–225
while the Mac ran on blind), and it was **immune to core reset** (the pll_video
domain lives outside the core reset). Removing the reconfig (static variant)
did not help → black from power-on.

### Root hypothesis (why sim is green but HW is black)
The Verilator sim is **structurally blind** to this failure: `verilator/sim.v`
ties `b_clk`/`clk_pix` to `clk_sys` and drives a /2 `pix_ce` — it NEVER
instantiates `pll_video`, the CDC synchronizers, or the `vidrst`
reset-until-locked gate (all FPGA-only, documented in
`docs/verilator_differences.md`). So a `pll_video` that doesn't lock, or a
CDC/`vidrst` that never releases, is invisible to every sim run. On HW,
`vidrst_s` holds the scanout in reset until `pll_video_locked`; if that lock
never asserts (or drops) → permanent reset → **black screen**. The reconfig
variant DID lock once (desktop appeared) then lost it (reconfig glitch); the
static variant apparently never locks/produces usable video on our board at
all. Prime suspects, in order:
1. `pll_video` integration mismatch: it was authored for `../MacLC_MiSTer`'s
   clock tree. Verify the **refclk** (`CLK_50M`?) is the right source on
   MacLCii, and that `sys/pll_cfg.qip` is wired the way MacLC.sv assumes.
   Compare MacLC's top-level pll_video instantiation refclk vs ours.
2. `vidrst` reset-until-lock holding forever (bad/again-dropped lock).
3. Fit-marginal DPRIO/reconfig interaction even with the strobe tied low.

## RECOMMENDED PATH (the unblock) — decouple video from the safe subset
The three non-video fixes are all CPU/timing-domain and have NOTHING to do with
the pixel clock. Ship them WITHOUT the video import so the user gets the PoP
speed fix on a working screen NOW, and treat the pixel-clock import as its own
HW bring-up:
1. Build a "safe subset" RBF = v9 + `9375c9f` + `5e3742f` + `a254a02` kernel
   fixes, **reverting/holding `7cfa483` (video)**. Easiest: branch off, `git
   revert 7cfa483` (and drop the uncommitted MacLC.sv). This deploys the Tick
   fix (PoP), the SCSI read, and the walk fixes — all sim-clean — on the proven
   static video path v9 already uses. HIGH value, LOW risk.
2. Separately, bring up `pll_video` on HW with careful JTAG forensics (PVID
   deck: is `pll_video_locked` high? does `clk_vid` toggle? is `vidrst_s`
   released?). ONE probe read at a time — rapid JTAG has crashed this box.
3. Only re-land the video import once `pll_video` locks and holds on HW.

## NEXT STEPS
- [ ] Confirm with the user: ship the safe subset now (recommended), or keep
      debugging video first? (They were frustrated at being stuck on v9 — the
      safe subset is the fastest way off it.)
- [ ] Safe-subset build + HW deploy + PoP speed check (the user's own eyeball
      test — v9 felt slow; the Tick fix should fix it).
- [ ] Video PLL HW bring-up (suspect #1: refclk/pll_cfg integration vs MacLC).
- [ ] After safe subset passes HW: that's also the HW validation for the kernel
      walk fixes (`a254a02`) — mark [[maclcii-fline-continue-past-root]]
      follow-up #1 HW-confirmed.

## GOTCHAS (all bit this session)
- **Screenshot API returns the SIBLING core's stale image.** `grab.sh` picked
  the newest file by mtime and got `MACLC/…Disk605.png` (a MacLC desktop) while
  MacLCii sat black — a false "it's working" reading. Filter the screenshot
  path by the running core name.
- **Rapid JTAG probing crashes the whole MiSTer** (shared HPS JTAG). The first
  video deploy's death was likely a probe, not the RTL. Single spaced reads
  only; never poll while wedged. (See [[maclcii-mister-hardware-access]].)
- **The sim cannot see FPGA video-clock bugs** — pll_video/CDC/vidrst are all
  tied off in sim.v. "Boots in sim" ≠ "video works on HW" for this class. This
  is the SDRAM-timing lesson again, one domain over.
- The `scripts/build.sh` CRLF/`set -e` syntax error under WSL bash: run the
  Quartus build from **Git Bash** (`QUARTUS_BIN=… bash scripts/build.sh`), not
  `wsl.exe bash`. GHDL regen `conv_lf.sh` must run FROM `rtl/tg68k/` (it cd's to
  its own BASH_SOURCE dir).
- A tooling ("classifier unavailable") outage repeatedly blocked mid-deploy
  hygiene commands this session; the only completed calls were read-only v9
  md5 checks, which LOOKED like "reverting to v9" but never re-flashed anything.

## RELEVANT MEMORY
[[maclcii-mister-hardware-access]] · [[maclcii-fline-continue-past-root]]
(follow-up #1 = the a254a02 kernel fixes, HW pending) ·
[[maclcii-video-blank-alignment-class]] · [[mister-sharing-lock-protocol]] ·
[[maclcii-disk-corruption-from-hard-restarts]]
