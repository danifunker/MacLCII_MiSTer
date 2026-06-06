# Findings: Mac LC PRAM persistence is NOT working (load is clobbered) — 2026-06-06

Branch `video-fixes`. Follow-up to `handoff_pram_persistence_2026-06-06.md`. This
**overturns** that handoff's "SAVE works / Load-race FIXED / persistence HW-confirmed"
status. Tested fully autonomously on HW (no Verilator on this box) via the
deploy/screenshot/PRAM-roundtrip tooling.

## TL;DR
A saved `.nvr` does **not** restore on the next boot. The 68k ROM's `InitUtil`
reinitializes PRAM to defaults **on every boot**, discarding whatever was loaded.
The prior "load confirmed" result was a **false positive / tautology** (it only ever
loaded a 2bpp image and read 2bpp back; it never loaded a *different* image to prove
the output tracks the input).

## The experiment (4 distinct images, all → identical output)
Inject a known 512-byte image into `games/MACLC/MacLC.nvr`, relaunch the core
(reboot re-mounts slot 2 → triggers load), let the Mac boot ~140 s, open the OSD
over the websocket to trigger the autosave flush, then read `.nvr` back.

| # | Loaded image (differs from nvr0 in…) | Flushed output |
|---|---|---|
| 1 | `nvr0` (2bpp baseline) | == `nvr0` |
| 2 | `nvr0` + `0xAA` at 4 reserved bytes (48,108,200,240) | == `nvr0` (sentinels zeroed) |
| 3 | `nvr0` + `0xAA` at 21 reserved bytes (spread `0x24-0xF8`) | == `nvr0` (all 21 zeroed) |
| 4 | `bak.1bpp` (valid prior save: bytes 10,88,129,187 differ) | == `nvr0` (reverted) |
| 5 | `nvr0` + `0x5A` at 11 **used** setting bytes (sig kept valid) | == `nvr0` (0/11 survived) |

**The flushed PRAM is always byte-identical to `nvr0`, independent of the loaded
image.** The output does not track the input → persistence is non-functional.

Note the flush *firing* proves the load path executed: it only fires on
`OSD_STATUS & pram_dirty & pram_ena`. `pram_ena` ⇒ the mount fired; `pram_dirty` ⇒
the 68k wrote PRAM during boot; and it changed the file from my upload to `nvr0`.
So mount + load FSM + boot-copy all run — and then the 68k overwrites everything.

## Why it converges to `nvr0`: `InitUtil` runs every boot
Per `docs/MacLC_ROM_Boot_Sequence_Analysis.md` §"Extended PRAM Validity": if the
`'NuMc'` signature (XPRAM `0x0C-0x0F`) is absent at boot, `InitUtil`:
1. writes a fresh `'NuMc'`,
2. **clears XPRAM `0x20-0xFF` (and `0x00-0x07`)**,
3. writes `PRAMInitTbl` defaults to XPRAM `0x76-0x89`,
4. preserves `0x08-0x1F`.

My results map onto this exactly: every byte I set in `0x20-0xFF` came back `0x00`
(step 2); the `0x77-0x7B` bytes came back as defaults (step 3). So **`InitUtil` is
firing every boot** — the 68k sees PRAM as *invalid* even though every loaded image
carried a valid `NuMc` (byte 12) and `SPValid=0xA8` (byte 16).

## Root cause (leading hypothesis): the `pram_ready` timeout wins the boot-copy race
- `MacLC.sv` ~L243-245: `pram_ready` is released by a **blind ~3 s timeout** that
  counts from core reset and does **not** check whether a mount/load is pending.
- `egret_wrapper.sv` ~L729-746: the boot-copy (`pram[]` → `intram[0x70..0x16F]`,
  i.e. the 68k's PRAM) fires once, when `pram_copy_pending & pram_ready`, using
  whatever `pram[]` holds **at that instant**, then latches `pram_loaded` (cannot
  re-fire).
- MiSTer's auto-mount of slot 2 (from `config/MacLC.s2`) + the SD sector read take
  **> 3 s**, so the timeout releases `pram_ready` while `pram[]` still holds the
  all-zero `egret.pram` default (which has **no** `NuMc`/`SPValid`). The boot-copy
  seeds the 68k with **invalid** PRAM → `InitUtil` reinitializes → loaded settings
  lost. The real load (`pram[]` ← image) lands *after* the boot-copy, too late, and
  is then overwritten by the 68k's `InitUtil` writes (mirrored back into `pram[]`).

Why it escaped earlier testing: `verilator/sim.v` hardwires `pram_ready(1'b1)` and
ties off the load ports (L692-698), so sim never exercises this path — it's FPGA-only.

## Proposed fix (to implement + rebuild + retest)
Make the 68k wait for the **actual** load when an image is present, instead of the
blind 3 s timeout:
1. Track "a slot-2 mount event has been seen." Suppress the short timeout until then
   (MiSTer always sends an `img_mounted` for a configured slot at startup).
2. On that event: if `img_size != 0` → drive `pram_ready` **only** from `P_LD_CPY`
   completion (load done); if `img_size == 0` → release `pram_ready` immediately.
3. Keep a *generous* fallback timeout (~10-15 s) only for the "no mount event ever"
   case so boot still can't hang.
4. Belt-and-suspenders: seed `rtl/egret/egret.pram` with a **valid** default image
   (`NuMc` + `SPValid=0xA8` + sane `PRAMInitTbl` values) so even a slow/failed load
   never hands the 68k an invalid default (avoids `InitUtil` clobbering).

Confirmation criterion (the test that was missing): load `bak.1bpp`, boot, flush —
the output must come back with the 1bpp bytes (10/88/129/187), i.e. **track the
input**. Repeat with a perturbed *used* byte and confirm it survives.

## Fix attempt #1 (built + HW-tested) — race fixed, but persistence STILL broken
Implemented the load-gate fix in `MacLC.sv` (wait for the actual slot-2 mount/load
instead of a blind timeout; clk_sys is ~65MHz so the old "3s" gate was really ~1.5s)
and seeded a valid `egret.pram` default (= nvr0, with `NuMc`+`SPValid=0xA8`). Two
builds (the 2nd removed the short timeout entirely: release `pram_ready` only via the
load FSM `P_LD_CPY`, an immediate release on a size==0 mount, or a ~60s backstop).

Result (HW): **boots clean** (no stall from the longer reset-hold), but persistence
**still fails** — a diagnostic image (0xAA in 21 reserved `0x20-0xFF` bytes + 0xEE in
preserved `0x18-0x1A`) flushed back **byte-identical to nvr0 again**: 0/21 reserved
and 0/3 preserved survived. So `InitUtil` still clears `0x20-0xFF` every boot.

Key deduction: with `egret.pram` now carrying a **valid** `NuMc`, the 68k boots on
valid-signature PRAM **whether or not** the load was delivered — yet `InitUtil` still
runs. So the root cause is **NOT** the load race (that was a real bug, now fixed and
worth keeping): **the 68k ROM reinitializes PRAM every boot even though `NuMc` +
`SPValid` are present in the delivered PRAM.**

Why HW-flush testing can't go further: the OS overwrites **every** PRAM byte when
InitUtil runs (clears `0x00-0x07`+`0x20-0xFF`, writes defaults to `0x76-0x89`, and
the OS rewrites the traditional area `0x08-0x1F`), so no injected byte can survive to
prove what the 68k actually read. Resolving "why does InitUtil run on valid PRAM"
needs a path that can SEE the 68k's PRAM reads:
- **Verilator** (not on this Windows box) to trace the 68k validity check + the
  Egret PRAM read path (note sim hardwires `pram_ready=1`, so wire up the load first).
- **MAME `maclc`** with a saved PRAM image: does it persist? (isolates ROM/OS vs core).
- **HC05 firmware**: does egret.rom re-init its PRAM region (intram `0x70..0x16F`)
  AFTER our boot-copy, or read the validity bytes from a different place?
- A **combined check** (clock/time validity): the boot-copy re-seeds RTC seconds from
  the HPS `TIMESTAMP` (Unix epoch) every boot; verify the Mac sees a valid 1904-epoch
  clock, since a power-fail/invalid-clock status can make the OS zap PRAM.

Net: the race fix (`MacLC.sv`) + valid `egret.pram` default are correct improvements
and boot clean, but they are **not sufficient**; the persistence blocker is upstream
in the ROM/Egret PRAM-validity path.

## RESOLVED — fix #2: boot-copy on the post-clear reset-RELEASE (CONFIRMED on HW)
MAME ground truth (`docs/mame_pram_findings.md`) cracked it: validity is gated by the
`'NuMc'` signature **only** (no checksum/clock/status), and MAME injects the saved PRAM
at the **post-clear reset-release** edge. Our bug: the HC05 firmware zeroes its PRAM
region (`intram[0x70..0x16F]`) during startup; our boot-copy was gated on the reset
**assert** edge (pre-clear, our `pc_out[3]=1`=RELEASE polarity is inverted vs MAME), so
on a **fast** SD load the copy landed before/during the firmware clear and got wiped →
68k reads zeroed PRAM (no `NuMc`) → `InitUtil` reinitializes every boot.

**Fix** (`rtl/egret/egret_wrapper.sv`): gate the boot-copy on the firmware having
RELEASED the 68k (`reset_680x0_latched==0`, which is post-clear) **and** `pram_ready`,
so the copy is the LAST write to `intram[0x70..0x16F]` before the 68k runs (the 68k is
already held until `pram_loaded`). Dropped the `pc_bit3_prev`/`pram_copy_pending` edge
latch. Validity needs only `NuMc`; nothing else added.

**HW result (CONFIRMED):** loaded `nvr3` (valid `NuMc` + `0xAA` in 21 reserved bytes)
→ after reboot+flush, **16/21 reserved `0xAA` survived**; output ≠ `nvr0` (default) and
≠ pure InitUtil result. The 5 that cleared (`0x48/0x50/0x60/0x68/0x70`) plus the
volatile high bytes (`0xF0/F1/F3/F9/FB`) are **normal OS field writes** — MAME's Test A
flagged byte `0x60 AA→00` and those exact high bytes as ground-truth OS behavior. Boots
clean. So PRAM now persists, matching MAME. (Final user-facing confirmation would be a
real OS setting round-trip, but the mechanism is proven.) Artifacts: `fix3_test.bin`,
`fix3_boot.png`.

## Test artifacts
`scratch/pram_test/`: `nvr0.bin` (2bpp baseline), `bak1bpp.bin`, `nvr1/3/6.bin`
(injected), `nvr2/4/5/6_out.bin` (flushed results), `after_boot.png` (clean 1bpp
desktop). Device: `.nvr` restored to `nvr0`; backups `.bak.1bpp`, `.bak.presentinel`.

## Side fix landed this session
`tools/misterdeploy/launch_unstable_core.py` `reboot_and_wait` now confirms the web
service goes DOWN then back UP (was a blind `sleep(12)` + poll-up) — handoff open
item #4. Note: a GenMidi mis-launch still recurred once *with* correct reboot timing,
so the OSD-nav itself has a second, independent flakiness (the verify+retry covers it).
