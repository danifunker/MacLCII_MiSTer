# Handoff — 10 MB RAM config: "zero K available" despite ~7 MB free

*2026-06-13. Found while HW-testing the 1.44 MB floppy build (`MacLC.rbf` md5
`49e69e55`) on the **10 MB** OSD memory setting. Separate from the floppy work —
parked here so it isn't lost.*

## Symptom (HW, System 7.1, 10 MB setting)

"About This Macintosh" (`scratch/mem_shot2.png`) reports:

| field | value |
|---|---|
| Total Memory | **10,240K** (correct — OS sees the full 10 MB) |
| System Software | 3,184K |
| **Largest Unused Block** | **7,021K** |

Yet launching a 512K app (TattleTech 2.17) fails: *"not enough memory … 512K
needed, **zero K available**."* So ~7 MB shows free **and contiguous** (largest
block 7 MB ≫ 512K), but allocations into it fail. This is NOT a size or
fragmentation problem — it's a "memory present in the map but not actually
usable" problem.

## What it means

The RAM is **sized correctly** (10,240K total reported) but the upper bank — the
8 MB SIMM region — appears free to the Memory Manager yet isn't usable when the
Process Manager actually allocates a partition there. Classic **phantom / bad
upper bank**: the boot ROM's RAM probe "found" the SIMM (→ 10 MB total, 7 MB
free), but real allocation/use of it fails.

JTAG probes during the failure (`bash scripts/read_probes.sh`) show the core
**healthy** — CPU running (`PACT` advancing, fetching RAM), video live
(`vbl_cnt` advancing), no hang. So it's a Mac-OS-level allocation failure, not a
core crash.

## Why it's pre-existing (not the floppy build)

- The floppy build didn't touch the RAM map (`addrController` `ram_sdram_word` /
  `ram_config_phys`, `addrDecoder`).
- **10 MB has been UNVERIFIED all along.** Prior notes: *"for 10 MB ($E4)
  validate against `mame -ramsize 10M` + `v8.cpp ram_size()` before trusting
  `ram_config_phys`."* The phantom-bank fixes only fully validated **2 MB**.
- The **2 MB** setting does NOT show this (no SIMM region).
- CAVEAT to rule out: the cold-load fix this session changed the SDRAM init
  ladder (`rtl/sdram.v`). Low odds it's region-specific (the mode register is
  chip-wide and low RAM works), but compare against a build with the old init.

## The 10 MB memory map (current core)

`configRAMSize = status[4] ? 8'hE4 (10 MB) : 8'h24 (2 MB)` — `MacLC.sv`.
`$E4` bits[7:6]=`11` → **8 MB SIMM** (`addrController` `simm_byte_size`).

| region | CPU address | SDRAM word address |
|---|---|---|
| SIMM (8 MB) | `$000000–$7FFFFF` | `$100000–$4FFFFF` |
| Motherboard (2 MB) | `$800000–$9FFFFF` | `$000000–$0FFFFF` |

CPU `$000000–$9FFFFF` = 10 MB contiguous; SDRAM backing is split but distinct
(no *obvious* aliasing). The System boots into low RAM (SIMM region) and runs —
so the SIMM **low** region works. The failure is in the mid/upper region, or
across the `$800000` SIMM→motherboard boundary, or in the bank descriptor.

## Investigation steps

1. **Diff against MAME `maclc -ramsize 10M`** — how does MAME place the 8 MB
   SIMM + 2 MB motherboard, and what RAM-bank descriptor does the ROM write
   (~`$9FFFEC`)? Compare to ours. (`v8.cpp` `ram_size()`, `m_baseIs4M`,
   `simm_sizes`.) Can run from WSL — see the floppy MAME handoff for setup.
2. **Review `addrController` SIMM mapping** (8 MB case) + `addrDecoder` RAM
   sizing + `pseudovia` `ram_configured` latch. Look for an off-by-one /
   boundary issue at `$800000`, or a region mapping to the wrong SDRAM.
3. **RAM-stress on HW** — write a known address-in-address pattern across all
   10 MB and read back (a small 68k tester, or a Mac RAM-test app). Find exactly
   where the upper region stops holding data:
   - **fails** → the SIMM SDRAM region is flaky/mismapped (HW/addressing bug).
   - **holds** → the ROM bank descriptor / reported RAM sizing is wrong (the OS
     free list points at memory it can't actually allocate).

## Files

- `rtl/addrController_top.v` — `ram_sdram_word`, `simm_byte_size`, `in_simm`,
  `motherboard_high`, `mb_mirror_offset`
- `rtl/addrDecoder.v` — RAM region decode / sizing
- `rtl/pseudovia.sv` — `ram_configured` latch (gates the `$0` mirror)
- `MacLC.sv` — `configRAMSize` (`status[4]`)
- `rtl/sdram.v` — SDRAM controller (init ladder changed this session; rule out)
- Memory: phantom-bank / `ram-config-2mb-vs-10mb` notes.

## Workaround

Run on the **2 MB** OSD Memory setting — no SIMM region, no phantom bank, no OOM
(but tight for System 7.1).

## Artifacts

- `scratch/mem_shot2.png` — About This Macintosh (10,240K / 3,184K / 7,021K)
- `scratch/oom_shot.png` — the "512K needed, zero K available" dialog
