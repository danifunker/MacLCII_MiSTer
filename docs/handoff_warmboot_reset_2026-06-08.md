# Handoff: warm-boot / reset hang (R0 + OS restart stick grey)

Branch `new-video-technique-part-2`. Self-contained cold-resume context for the
**reset/reboot** issue. (The video work — all depths/resolutions render correct
color — is DONE and HW-validated; see `docs/handoff_video_color_2026-06-08.md`
and memory `ariel-clut-multifire-color-fix`. This doc is only about reboot.)

---

## 0. TL;DR

On the FPGA, **any warm boot hangs on a grey screen and only a full bitstream
reconfig recovers.** "Warm boot" = the OSD **R0 "Reset & Apply CPU+Memory"**
(`status[0]`) *and* a Mac OS **Special → Restart** (Egret-driven 68k reset). All
video modes otherwise work.

**UPDATE 2026-06-08 (HW result): the SDRAM-init-on-warm-reset approach is a DEAD
END — BOTH commits regressed COLD boot and are now REVERTED.** `d88c098`
(`.init(!pll_locked || ~n_reset)`) and `50d0c32` (`.init(!pll_locked ||
status[0])`) each broke cold boot to grey/black, because both `~n_reset` and
`status[0]` are active during the cold-load ROM download → the download writes get
swallowed while init is held. Working tree is reverted to `.init(!pll_locked)`
(the known-good baseline; uncommitted). **Do NOT re-attempt gating `sdram.init` on
any system-reset signal.** H1 was never confirmed as the real cause anyway — it
was just the hypothesis those commits chased. **NEXT ACTION: pursue H2 (force the
cold-boot path / scrub the warm-start flag, §3 + plan #2 in §5), which is the
leading lead, OR add a real HW probe before writing more code.**

**UPDATE 2026-06-08 #2 (H2 force-cold-boot IMPLEMENTED, working tree, uncommitted):
patch the ROM's warm-vs-cold branch on-the-fly so EVERY boot runs the full cold
RAM march.** The boot ROM picks the path with `bne.w $46576` at ROM byte **$4655E**
(SDRAM word **$52322F**): `d3 != 'WLSC'` → full RAM march (cold); on a warm reset
RAM is preserved so `d3 == 'WLSC'` → warm path → hang. We force that branch
UNCONDITIONAL as it is fetched: opcode `0x6600` (`bne.w`) → `0x6000` (`bra.w`).
Added `sdram_out_patched` in `MacLC.sv` and `ram_do_patched` in `verilator/sim.v`,
guarded `!_romOE && memoryAddr==23'h52322F && <word>==16'h6600` (catches both the
overlay `$0004655E` and direct `$A4655E` fetches — addrDecoder maps both to
`selectROM`/`$52322F`). **Key safety property: no-op on a cold boot** (the branch is
already taken since `d3 != 'WLSC'`), so unlike the reverted `.init` hacks it CANNOT
regress cold boot, and the opcode guard leaves any other ROM untouched. Trade-off:
a Mac OS Restart now runs the full RAM march (slower, like a cold boot) instead of
the fast warm-start — acceptable. PENDING: sim cold-boot screenshot check (frame
350 pattern) + HW test of cold boot AND R0/OS-Restart. The on-the-fly RTL patch
keeps the stock `boot0.rom`; the equivalent baked-ROM patch would be a 1-byte
`0x66`→`0x60` at offset `$4655E` + checksum refix (cf. `patch_skip_ramtest.py`).

---

## 1. Symptom (hardware)

- Cold boot (full FPGA reconfig): **works** — boots to desktop, all depths/res.
- Warm boot (R0 `status[0]` OR OS Restart): **sticks grey, hangs early.**
  - The MiSTer **OSD still appears** over the grey ⇒ HDMI/video output is alive;
    it is NOT an ascal/display-lock problem.
  - The **mouse cursor never initializes** ⇒ the boot is stuck *early*, before the
    OS draws the cursor. So the **68k is hung early in the warm boot**, not a
    display issue.
- Only a **full MiSTer power-cycle / reconfig** recovers it.
- User is **NOT** using the skip-RAM-test "bypass memory" ROM on hardware (full
  POST RAM march runs every cold boot).

---

## 2. What is CONFIRMED / RULED OUT

- **Reset logic is sound.** On R0 (`status[0]` → `n_reset`/`_systemReset`): the
  Egret HC05 re-inits (`egretReset`, `egretBootCounter`→0 then re-release), the
  68k is re-held (`_cpuReset = minResetPassed && !egret_reset_680x0`), and the ROM
  overlay re-arms (`rom_overlay<=1` on `!_cpuReset`, `addrController_top.v:322`).
- **Peripheral resets match** between `verilator/sim.v` and `MacLC.sv`
  (pvia/ariel/asc all `~n_reset` in both) — no top-level divergence there.
- **Monitor sense** the ROM reads = `monitor_id<<3` via `pseudovia.sv:258`, and
  `monitor_id` = `status[10]` (live). So R0 reads the correct sense.
- **SDRAM ROM is NOT lost on a warm reset:** `sdram .init(!pll_locked)`
  (`MacLC.sv:1097`); a warm reset keeps the PLL locked, so the controller is not
  re-init'd and the ROM persists in SDRAM.
- **The warm-boot LOGIC is correct in Verilator.** A new `--reset-at-frame N` flag
  (see §4) pulses a warm reset mid-run with the ROM kept in the SDRAM model — a
  faithful R0 proxy. Result on 640×480/4bpp + SCSI HD:
  **desktop (F398) → warm reset (F400) → flat-grey reboot (F430/620) → desktop
  again (F790).** It warm-boots fine, even with a mounted SCSI disk and an
  OS-modified PRAM.

⇒ The bug is in the **FPGA-only domain** that Verilator does not model. The sim
uses an idealized `sim_ram.v` in place of the real `rtl/sdram.v` controller, and
has no ascal/HDMI (already ruled out anyway).

---

## 3. Root-cause hypotheses (NOT fully separated — sim can't reproduce either)

**H1 — SDRAM controller not resynced on a warm reset (LEADING; fix in flight).**
The real `sdram.v` controller only runs its init at config (`!pll_locked`), never
on a warm reset, so after R0 the CPU reboots against an un-resynced controller
that mis-serves the first ROM reads → hang. The sim's ideal memory hides this.

**H2 — preserved-RAM warm-start path.** A full reconfig stops `SDRAM_CLK` →
DRAM refresh stops → RAM decays/clears → the boot ROM finds no valid warm-start
marker → full COLD boot → works. A warm reset keeps SDRAM refreshed → RAM is
PRESERVED, including the `'WLSC'` warm-start signature the ROM checks
(`cmpi.l #'WLSC',d3` at ROM offset **$46558**; d3 is loaded from the warm-start
flag stored **4 bytes below the RAM chunk table**, near the top of RAM — config
dependent, e.g. ~`$9FFFE8` for the 2MB/overlay layout). So the ROM takes its
warm-start path, which hangs on our core. See `verilator/patch_skip_ramtest.py`
and memory `rom-skipramtest-patch`.

Both are FPGA-specific and consistent with "only a reconfig recovers" and "hangs
early." H1 is addressed by the committed candidate; H2 is plan #2 below.

---

## 4. The Verilator warm-reset diagnostic (`--reset-at-frame`)

Committed `e7a1cb1`. Added to `verilator/sim_main.cpp`:
```
./obj_dir/Vemu --scsi0 /Users/dani/Downloads/HD0-Official-6.0.8-500M.hda \
    --reset-at-frame 400 --screenshot 398,430,620,790 --stop-at-frame 800
```
Pulses the top-level `reset` for `WARM_RESET_LEN` (4000) ticks at frame N WITHOUT
reloading the ROM (it stays in the `sim_ram` model) — a faithful R0 proxy. Note
`sim_ram.v` does NOT clear memory on reset (line 34 "writes allowed during
reset"), so RAM is preserved across the pulse, like the FPGA. Despite that, the
sim warm-boots cleanly (so neither H1's controller nor H2's path reproduces in
sim — expected, since the sim lacks the real SDRAM controller).

---

## 5. Candidate fix in flight + DECISION TREE

**Committed `50d0c32`** (supersedes the regressing `d88c098`). `MacLC.sv:1097`:
```
.init( !pll_locked )            // before
.init( !pll_locked || status[0] )   // after — re-init the controller on R0 too
```
Re-running SDRAM init is **precharge + load-mode-register only — it does NOT erase
ROM/RAM**, and is timing-safe (init runs when `status[0]` clears, ~16 cycles,
while the CPU stays held ~`resetDelay`/~1M cycles more).

**GOTCHA — already cost one regression (`d88c098`):** do **NOT** tie `.init` to
`~n_reset`. The cold-boot ROM download holds `n_reset` low
(`dio_download && dio_index==0` is an `n_reset` source, `MacLC.sv:109`), so
`~n_reset` forces `init=1` *during the download* → ROM writes never land → black
screen. Must use `status[0]`, which is never asserted during the download. Also do
NOT use `~_cpuReset`: it releases init and the CPU simultaneously → the CPU hits
an un-ready SDRAM (init needs to finish *before* the CPU runs).

**After building `50d0c32`, you land in one of these:**

| Cold boot | R0 reset | Meaning → next step |
|-----------|----------|---------------------|
| ✅ works | ✅ boots | **H1 confirmed.** If OS-Restart still hangs, do the follow-up below. |
| ✅ works | ❌ grey | **H1 wrong.** Move to plan #2 (force cold-boot path / H2), or add a HW probe. |
| ❌ black | — | Cold-boot regressed again — revert `.init` to `!pll_locked` and rethink. |

**OS-Restart follow-up (only if R0 works but OS Restart still hangs):** an OS
restart resets the 68k via the Egret (`egret_reset_680x0 → _cpuReset`) and does
**not** pull `status[0]`/`n_reset`, and has no built-in hold window
(`minResetPassed` stays 1). To resync SDRAM there you must (a) detect the
Egret-initiated reset, (b) trigger the SDRAM init, AND (c) hold `_cpuReset`
asserted until the init completes. That means wiring an "sdram_ready" gate into
the `_cpuReset` generation in `rtl/dataController_top.sv:181` — more invasive than
the one-liner.

**Plan #2 (if H1 is wrong — force the cold-boot path / H2):** on a warm reset,
scrub the warm-start flag (the long the ROM compares at $46558; identify its exact
low-mem address by disassembling around $46558) or zero a few KB of low RAM during
the reset hold, so the ROM always runs its full cold path — mirroring the reconfig
that already works. Requires injecting an SDRAM write at reset time (reuse the
existing download write path).

**Discriminating HW test (cheap, optional):** run the skip-RAM-test "bypass
memory" ROM on the FPGA and warm-reset — helps separate the RAM-path (H2) from the
hardware-state (H1) cause.

---

## 6. Key files / line numbers

- `MacLC.sv:1097` — `sdram .init(...)` (the candidate fix).
- `MacLC.sv:93-121` — `n_reset` always block; sources at :109 (incl. the ROM
  download `dio_download && dio_index==0`).
- `MacLC.sv:694` — `v8_monitor_id = status[10] ? 4'h2 : 4'h6`.
- `rtl/dataController_top.sv:181` — `_cpuReset = minResetPassed && !egret_reset_680x0`.
- `rtl/dataController_top.sv:166` / `:194` — `resetDelay`/`egretReset` (reset on `_systemReset`).
- `rtl/addrController_top.v:322` — overlay re-arm `if (!_cpuReset) rom_overlay<=1`.
- `rtl/pseudovia.sv:103-111` — reset clears `ram_configured`, `video_config<=8'h03`.
- `rtl/pseudovia.sv:258` — monitor sense readback = `{1'b0, monitor_id, 3'b000}`.
- `rtl/sdram.v:82-94, 126-137` — controller reset/init sequence (precharge + mode).
- `verilator/patch_skip_ramtest.py` — the `'WLSC'` warm-start check (ROM $46558).
- `verilator/sim_main.cpp` — `--reset-at-frame` flag.

---

## 7. Relevant commits (branch `new-video-technique-part-2`)

- `da748b4` video(ariel): CLUT color fix — **video work done, HW-validated.**
- `13f0428` build: pin Quartus project files to LF (.gitattributes).
- `e7a1cb1` sim: add `--reset-at-frame N` (warm-reset diagnostic).
- `d88c098` sdram: re-init on `~n_reset` — **REGRESSED cold boot (black screen).**
- `50d0c32` sdram: fix that regression — gate re-init on `status[0]`. **← test this.**

---

## 8. Reset chain reference (FPGA)

```
R0 (OSD "Reset & Apply")  → status[0]=1 → n_reset=0 (_systemReset)
                            → resetDelay=FFFFF, egretBootCounter=0, minResetPassed=0
                            → _cpuReset=0 (68k held), egretReset=1 (Egret held)
status[0] clears → n_reset holds for rst_cnt, then n_reset=1
                 → resetDelay counts down (~1M) → minResetPassed=1
                 → Egret re-boots, releases → _cpuReset=1 (68k runs)

OS Restart (Special→Restart) → Egret asserts egret_reset_680x0 → _cpuReset=0
   (n_reset does NOT assert; minResetPassed stays 1; no resetDelay hold)
   → Egret releases → _cpuReset=1 immediately
```

The asymmetry (n_reset asserts on R0 but not on OS-restart) is why the `status[0]`
fix covers R0 only and the OS-restart case needs the separate hold (§5 follow-up).
