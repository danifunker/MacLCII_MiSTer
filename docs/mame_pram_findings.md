# MAME PRAM persistence findings (Mac LC, ground truth) — 2026-06-06

Investigated on the MacBook with MAME `maclc` as ground truth, per
`docs/mame_pram_passoff.md`. This answers the open question from
`docs/findings_pram_load_broken_2026-06-06.md`: **does PRAM persistence even work,
and if so, what exactly makes the 68k ROM accept persisted PRAM (skip `InitUtil`)?**

**Headline:** MAME persists PRAM perfectly. The extended-XPRAM reinit is gated by a
**single condition — the `'NuMc'` signature at XPRAM `0x0C-0x0F`.** With it present,
`InitUtil` is skipped and *every* reserved byte survives a reboot. There is **no
checksum** and **no clock/Egret-status gate** on the extended reinit. So our FPGA
core's loaded PRAM (which carries valid `NuMc`) must be getting **clobbered before
the 68k reads it** — almost certainly the HC05 firmware's own startup PRAM-clear
overwriting our boot-copy (MAME explicitly works around exactly this; see §10).

---

## How MAME does it (from `~/repos/mame/src/mame/apple/egret.cpp`)

The Egret is `device_nvram_interface`. PRAM lives in the HC05's internal RAM at
`0x70..0x16F` (256 bytes = the OS-visible XPRAM, 1:1). Three pieces:

- `nvram_default()` (L321): `memset(m_disk_pram,0,0x100)`, `m_pram_loaded=false`.
- `nvram_read()` (L329): reads 256 bytes from the nvram file into `m_disk_pram`,
  sets `m_pram_loaded=false` (so the boot-copy will fire after the load).
- `nvram_write()` (L341): on exit, `m_disk_pram[byte]=read_internal_ram(0x70+byte)`
  for 256 bytes, then writes the file.
- **The boot-copy** is in `pc_w()` (L237-272), keyed on the **68k-reset line edge
  the HC05 firmware drives** (Port C bit 3). On that edge, if `!m_pram_loaded`, it
  copies `m_disk_pram[]` → `write_internal_ram(0x70+byte)` and **also reseeds the
  RTC seconds** (internal RAM `0xAB-0xAE`) from the host clock. The author's comment
  (L318-320) is the smoking gun for our bug:

  > "the 6805 program clears PRAM on startup (on h/w it's always running once a
  >  battery is inserted) **we deal with that by loading pram from disk to a
  >  secondary buffer and then slapping it into 'live' once the Egret reboots the
  >  68k**"

  i.e. MAME deliberately injects PRAM **after** the firmware's self-clear, at the
  reset edge, so the loaded image is the last thing written before the 68k runs.

The RTC epoch is **1904** (`macseconds.cpp`: Unix `mktime + 2082844800`), reseeded
every boot, **not** persisted in nvram.

---

## Experiments run (controlled, decisive)

All diskless, 8 s each (`run_mame.sh -seconds_to_run 8`); the ROM's PRAM-validity /
`InitUtil` path runs in the first second of 68k boot, so no boot disk is needed.
nvram file = `nvram/maclc/egret` (256 bytes). Artifacts in `scratch/pram_mame/`.

| Test | Setup (injected into nvram) | Result after reboot |
|------|------------------------------|---------------------|
| **A. Valid round-trip** | `0xAA` @ reserved `0x20/24/28/2C/40`, `0xEE` @ preserved `0x18-0x1A`, NuMc+SPValid intact | **`0xAA` & `0xEE` SURVIVED.** Byte `0x60` got a targeted OS write `AA→00` (proves the 68k ran and *chose not* to clear) |
| **B. Corrupt NuMc** (negative control) | zero `0x0C-0x0F`, keep `0xAA` | **`InitUtil` RAN:** NuMc rewritten to `4e754d63`, all `0xAA` in `0x20-0xFF` CLEARED to `00`. `0xEE` @ `0x18-0x1A` still survived (0x08-0x1F preserved) |
| **C. Corrupt SPValid only** | `0x10`→`00`, NuMc valid, keep `0xAA` | SPValid **repaired in place** to `0xA8`; `0xAA` reserved bytes **SURVIVED** → SPValid is *not* the extended-reinit gate |
| **D. From empty** (delete nvram, boot ×2) | — | Run 1 creates valid PRAM (NuMc, SPValid=`A8`, depth=`80`); run 2 identical except volatile `0xF0/F1/F3/F9/FB` → **persists** |

Test A vs B is the clean isolation: **valid NuMc ⇒ no reinit (everything persists);
corrupt NuMc ⇒ reinit (reserved zeroed, NuMc rewritten).** Test A also rules out any
checksum gate — arbitrary `0xAA` in reserved bytes did not trigger a reinit.

---

## Deliverable summary

```
MAME PRAM PERSISTENCE FINDINGS
1. MAME version + maclc ROM set:
   MAME 0.287. ROM 350eacf0.rom (== our boot0.rom). Egret BIOS = 341s0851 (default),
   md5 b955ecbdf6d2f979f3683dd1d6884643 — BYTE-IDENTICAL to our rtl/egret/341s0851.bin
   (our egret_rom.hex is built from it). So HC05 firmware matches exactly; ruled out.

2. PRAM persists across MAME restarts? YES.
   Path: <cwd>/nvram/maclc/egret. Size: 256 bytes (raw XPRAM 0x00-0xFF, 1:1, no
   header). Format: HC05 internal RAM 0x70..0x16F dumped on clean exit. RTC seconds
   are NOT in this file (kept at internal RAM 0x1b-0x1e, reseeded each boot, 1904 epoch).

3. Setting round-trip: injected 0xAA into reserved XPRAM bytes + 0xEE into preserved
   0x08-0x1F. After reboot they PERSIST byte-for-byte (Test A). A real OS setting
   write was also observed (byte 0x60 AA→00). Persistence confirmed.

4. Does InitUtil/PRAM-reinit run EVERY boot? NO — only when invalid.
   Evidence: with valid NuMc, 0xAA at 0x20/24/28/2C/40 all read back 0xAA after reboot
   (NOT cleared) → InitUtil's "clear 0x20-0xFF" did NOT run. Corrupting NuMc made the
   SAME bytes read back 0x00 AND rewrote NuMc=4e754d63 → InitUtil DID run. Clean toggle.

5. EXACT validity gate(s):
   - Extended XPRAM reinit (clear 0x20-0xFF & 0x00-0x07, write PRAMInitTbl to 0x76-0x89):
     gated SOLELY by 'NuMc' == 0x4E754D63 at XPRAM 0x0C-0x0F. Present ⇒ skip; absent ⇒ run.
   - Traditional/clock-chip PRAM: gated by SPValid == 0xA8 at XPRAM 0x10. If wrong, the
     ROM REPAIRS it in place (rewrote 0xA8) and resets the traditional area, but does
     NOT touch the extended region — confirmed independent of (and weaker than) the NuMc gate.
   - NO checksum gate (arbitrary 0xAA in reserved bytes did not trigger reinit).
   - NO clock/Egret-status gate on the extended reinit (clock is always freshly valid in
     MAME and never persisted, yet persistence works; corrupting NuMc alone flips behavior).
   - Cross-checked against docs/MacLC_ROM_Boot_Sequence_Analysis.md §"Extended PRAM
     Validity" / §"PRAM Validity Summary" — matches exactly.
   (Note: the 68k reads PRAM over the Egret SERIAL channel into low memory, not via a
   tappable memory address, so the gate was established by controlled behavioral test +
   MAME source + the ROM analysis doc rather than a single CMP instruction address.)

6. Known-good 256-byte XPRAM from MAME (rows of 16, offset: bytes):
   00: 00 00 4f 48 00 00 00 00 13 88 00 4c 4e 75 4d 63
   10: a8 00 00 00 cc 0a cc 0a 00 00 00 00 00 02 63 00
   20: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   30: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   40: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   50: 00 00 00 00 00 00 00 29 80 a6 06 00 00 00 00 00
   60: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   70: 00 00 00 00 00 00 00 01 ff ff ff df 00 00 00 00
   80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   90: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   a0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
   b0: 00 00 00 00 00 00 00 00 55 90 00 00 00 00 00 00
   c0..e0: all 00
   f0: 02 ee 00 ec 00 00 00 00 00 01 00 8c 00 00 00 00
   (0C-0F='NuMc', 10=SPValid 0xA8, 58=depth 0x80=2bpp, 77-7B=01 ff ff ff df.)

7. Diff vs our nvr0 (only these differ; all validity-critical bytes MATCH):
   - 0x01: MAME=00, nvr0=80  (traditional clock-chip area; our stray 0x80 — harmless
     but non-canonical; MAME keeps 00).
   - 0xB8=55 0xB9=90: present in MAME, 00 in nvr0 (extended XPRAM, OS/firmware-written).
   - 0xF0=02 0xF1=ee 0xF3=ec 0xF9=01 0xFB=8c: VOLATILE high bytes — they change every
     boot in MAME too (Test D), so they are NOT persistence-critical and not worth matching.
   NuMc, SPValid, the whole 0x08-0x1F traditional area, and all settings bytes are identical.

8. Egret RTC: 1904 epoch (Unix mktime + 2082844800, macseconds.cpp). Reseeded from the
   HOST clock at every boot-copy; NOT stored in nvram. A bad clock does NOT trigger the
   extended reinit (it isn't part of the NuMc gate). Our core already reseeds RTC at the
   boot-copy from `timestamp` (egret_wrapper.sv:741-744) — verify it's a 1904-epoch value,
   but it is not the persistence blocker.

9. Egret status/power: the ROM does NOT need any "didn't lose power / clock valid" status
   byte to trust PRAM. pa_r/pb_r/pc_r return fixed soft-power/handshake bits; none gate the
   extended reinit. The only thing the ROM trusts is the NuMc signature it reads back.

10. BOTTOM LINE — the single thing our FPGA core must do:
    Guarantee the loaded PRAM (with valid NuMc) is the LAST thing written to the HC05
    internal RAM 0x70..0x16F BEFORE the 68k starts — i.e. the boot-copy must land AFTER
    the HC05 firmware's own startup PRAM-clear, exactly like MAME injects on the reset
    edge "once the Egret reboots the 68k." Our findings_pram_load_broken result ("valid
    egret.pram default, InitUtil STILL runs") is fully explained by the firmware zeroing
    intram[0x70..] AFTER our boot-copy — so a valid default can't help. FIX: fire the
    boot-copy on the firmware's reset-RELEASE edge (MAME: PC bit3 1->0 = write_reset
    CLEAR), not on an earlier assert/hold edge, and confirm no firmware write to
    0x70..0x16F follows it. (Validity is JUST NuMc; nothing else to add.)
```

## Pointers for the FPGA session

- Compare our boot-copy edge to MAME's. MAME `pc_w`: copy on **PC bit3 falling edge,
  which is `write_reset(CLEAR_LINE)` = RELEASE** (firmware has already finished init +
  PRAM-clear). Our `rtl/egret/egret_wrapper.sv:729` fires on `pc_bit3_prev && !pc_out[3]`
  (PC3 1→0) — but note our polarity comment (L541-542: `pc_out[3]=1`=RELEASE) is the
  **opposite** of MAME's (PC3=1 = ASSERT/hold). So our copy likely fires on the
  firmware's *assert/hold* edge — **before** its PRAM-clear — which then wipes the load.
  This is the prime suspect; align the copy to the post-clear release edge.
- Sanity check on FPGA: confirm the HC05 firmware (341s0851) writes zeros to CPU
  0x100..0x1FF during its startup, and that our boot-copy at egret_wrapper.sv:737-739
  executes *after* those writes (add a one-shot debug counter of firmware writes to
  intram[0x70..0x16F] occurring after `pram_loaded`).
- Validity needs ONLY NuMc; do not add checksum/clock/status logic. Our `egret.pram`
  default already carries valid NuMc+SPValid, which is correct — keep it.

## Reproduce
```bash
# install/dump nvram, then:
verilator/mame/run_mame.sh -seconds_to_run 8     # boots maclc headless, saves nvram/maclc/egret
od -Ax -tx1 nvram/maclc/egret                    # 256-byte XPRAM, offset = XPRAM byte
# Sentinel test: inject 0xAA into reserved bytes of nvram/maclc/egret, rerun, re-dump.
# Negative control: zero 0x0C-0x0F (NuMc), rerun -> sentinels clear + NuMc rewritten.
```
