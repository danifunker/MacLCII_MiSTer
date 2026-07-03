# Findings: the TG68 PMMU walk of the 32-bit alias is CORRECT — Sad Mac root cause is UPSTREAM (2026-06-23)

**This DISPROVES the root cause asserted in `docs/resume_pmmu_32bit_alias_2026-06-23.md`,
`docs/findings_berr_hw_pctrace_2026-06-22.md` (UPDATE 4), and the memory note
`maclcii-sadmac-0f-is-pmmu-mistranslation`.** Those say the boot `0000000F/00007FFF` Sad Mac is a
TG68 PMMU *mistranslation* of the 32-bit ROM alias (`$40A0010E`) — a bug in the DT=01 early-term /
IS handling of the page-table walk in `rtl/tg68k/TG68K_PMMU_030.vhd`. **Direct simulation shows the
walk is correct for the oracle inputs.** The bug is therefore elsewhere (upstream).

## What was tested (two independent harnesses, both LOCAL in WSL)

### 1. Standalone PMMU bench — `verilator/pmmu_bench/`
GHDL-synth `TG68K_PMMU_030` alone (`synth_pmmu.sh`, LLVM shim) → Verilator + a C++ driver
(`pmmu_bench.cpp`) that writes TC/CRP via the real `reg_we` PMOVE interface, models the descriptor
memory, issues a translation `req`, and reads `addr_phys` + the `debug_*` walk trace. Inputs are the
**exact MAME oracle** (confirmed by `verilator/pt10_4m.txt` / `verilator/mame/pt10_out.txt`):
```
TC = $80F84500  (E=1, PS=$F=32K, IS=8, TIA=4, TIB=5, TIC=TID=0)
CRP_H=$7FFF0003 (limit $7FFF, DT=11 long table), CRP_L=root table base
root[10] @ base+$50 = 7FFFFC19 (HIGH, DT=01 early-term) / 00A00000 (LOW, page base)
```
Results (all PASS):
| scenario | input | got | expected |
|---|---|---|---|
| S1 fresh clean walk | `$40A0010E` | `$00A0010E` | `$00A0010E` ✓ |
| S2 24-bit form       | `$00A41B8E` | `$00A41B8E` | `$00A41B8E` ✓ |
| S3 boot order (TC written LAST, immediate xlate) | `$40A0010E` | `$00A0010E` | ✓ |
| S4 prime ATC → reconfig TC (flush) → xlate alias  | `$40A0010E` | `$00A0010E` | ✓ |

The walk reads root[10] HIGH `$..E870`→`7FFFFC19`, LOW `$..E874`→`00A00000`, recognizes DT=01
early-term, folds the low 20 bits, and yields `$00A0010E`. Exactly the oracle.

### 2. Kernel-level mode-switch micro-repro — `verilator/ksw_bench/`
Drives the **full** `TG68KdotC_Kernel` (CPU="10", 68030+PMMU) through the exact derail sequence:
enable MMU (early-term identity table) → execute → `pmove (A3),tc` RECONFIG (E=1→E=1, which
glitches `tc_en` 1→0→1 and re-arms `mmu_fetch_grace`) → `jmp (A5)` with A5=`$40A0010E`. The harness
services the CPU 16-bit bus AND the 32-bit walker bus from one RAM, and gates `clkena` on
`pmmu_busy` exactly like `tg68k.v` (suppress while the walker borrows the bus).

Result: **PASS.** The jmp-target fetch translates `log=$40A0010E → phys=$00A0010E → addr_out=$00A0010E`
(`tc_en=1 grace=0`), and the target instruction at `$00A0010E` executes (a `bra.s .` self-loop
keeps fetching `$40A0010E` correctly). The `tc_en` glitch + grace re-arm at the reconfig do **not**
corrupt the alias translation.

## Why the original hypothesis was wrong
The HW capture proved `exe_pc`=ROM (`$00A416B6`) while a program fetch landed on physical `$9FExxx`.
That was read as "the PMMU mistranslated the (assumed `$40A0010E`) jmp target." But the **logical**
fetch address at the derail was never cleanly captured (the tap read `$00000000`, "transient/
unreliable"). Since the walk is provably correct for `$40A0010E`+oracle table, one of these must hold
instead:
- **A5 (jmp target) is wrong** before the `jmp` — an upstream divergence corrupted it, so the CPU
  jumps to a wrong *logical* address that maps to `$9FExxx`. (Most likely: the derail target wobbles
  `$9FE876`/`$9FEE40`, inconsistent with a deterministic walk of a fixed logical address.)
- **TG68's runtime TC/CRP/table differ from the oracle** at the instant of this walk (e.g. CRP mid-
  reconfiguration, or the table in RAM not what `pt10` captured), so the walk faithfully translates
  using bad inputs.

Either way the fault is **upstream of the PMMU walk math** — the walk itself is sound.

## Recommended next step — find the FIRST divergence vs MAME
Stop trying to "fix the walk." Instead get TG68's actual runtime state and find where it first
diverges from MAME `maclc2`:
1. Capture TG68's A5 + TC + CRP + the LOGICAL jmp-target at `$A416B6` (boot sim with a focused tap,
   or a refined registered HW JTAG capture — the prior logical-addr tap was combinational/unreliable).
2. PC-stream divergence diff vs MAME (`docs/mame_compare.md`): the first instruction where TG68's PC
   stream departs from MAME's is the real bug, and it is *before* `$A416B2`.
3. If A5 is correct but CRP/table is wrong → the divergence corrupted the MMU setup; if A5 is wrong →
   trace back what computed A5.

## HW CONFIRMATION (2026-06-23) — A5 is correct; the MMU INPUTS are wrong
Built a probe latching the kernel's `pmmu_addr_log` (= the derailing fetch's LOGICAL address
= A5/jmp target) at the proven `hiram_pf` derail trigger (PFR2), deployed, read via JTAG. Result
on real hardware (Sad Mac `0000000F/00007FFF` confirmed by screenshot):
```
exe_pc        LOGICAL (instr) = 00A416B6   (the jmp (A5) instruction)
tx0 last txn  = A416B8 FC=sPRG rd
pmmu_addr_log LOGICAL (A5/tgt)= 40A0010E   <-- the CORRECT jmp target (A5 is NOT corrupted)
derail fetch  PHYSICAL (bus)  = 9FEE40     (WRONG; should be 00A0010E)
```
So A5 = `$40A0010E` exactly matches the oracle. The logical fetch is correct; only the PHYSICAL is
wrong. Combined with the sim proof (walk correct for the oracle inputs), this pins the fault to
**TG68's runtime MMU inputs** — TC, CRP, or the page table in RAM — differing from the oracle at the
instant of this walk. NOT A5, NOT control-flow, NOT the walk math. Next: a follow-up probe build
latching `debug_pmmu_tc` / `debug_pmmu_crp_lo` / `debug_pmmu_walk_desc_addr` / `debug_pmmu_walk_desc_data`
at the derail to see WHICH input is wrong (is TC=$80F84500? CRP→$9FE820? does the walk read root[10]
@ $9FE870 = 7FFFFC19/00A00000, or a wrong descriptor?).

## HW CONFIRMATION #2 (2026-06-23) — TG68's TC *and* CRP are WRONG (the walk is innocent)
Follow-up probe build latched the PMMU registers + the descriptor the walk read, at the derail:
```
TC            = 80F05750   (oracle 80F84500)  WRONG: IS=0,TIA=5,TIB=7,TIC=5 vs oracle IS=8,TIA=4,TIB=5,TIC=0 (PS=15 same)
CRP_lo (base) = 009FEE00   (oracle 9FE820)    WRONG root-table base
walk desc ADDR= 009FEE40   = CRP_base + 8*8   (with wrong TC: IS=0 so no top-byte strip; TIA=5, shift=27 -> root index 8)
walk desc DATA= 00000000   INVALID (DT=00) — zeros past the real 16-entry table
walk state    = ROOT       fault_status=0000
```
The values are SELF-CONSISTENT: TG68's wrong TC geometry makes `$40A0010E` index root[8]; the wrong
CRP base puts root[8] at `$9FEE40`; that reads zero; the derail physical IS `$9FEE40`. So the PMMU
table-walk is faithful to its inputs — **the inputs (TC, CRP) are corrupted before/at the `pmove`.**

### Conclusion / fix locus
The boot Sad Mac is a **corrupted MMU configuration**: the `pmove`-loaded TC and CRP at (or before)
`$A416B2` hold wrong values. NOT the walk, NOT A5, NOT the early-term/IS math. Candidates for WHERE
the corruption enters (next investigation):
1. The `pmove (A3),tc` / `pmove (Ax),crp` **data reads are themselves mistranslated** by the MMU's
   PRIOR (already-wrong) config — a cascading corruption that started at an earlier `pmove`.
   (TC was read as $80F05750 ≠ a maskable variant of $80F84500 — bit 12 goes 0→1, so the *read data*
   was wrong, not the register-write masking; the pmove fetched garbage, plausibly from a
   mistranslated source address.)
2. The TC/CRP **images in RAM were written wrong** earlier (a mistranslated store).
3. A3 / the CRP pointer register is wrong.
Next: find the FIRST `pmove` whose loaded TC/CRP diverges from MAME `maclc2` — either via the boot
sim's PMMU_TRACE (`$display ... crp=%h tc=%h` per walk) compared to MAME, or an HW ring of the last
N TC/CRP writes + their `pmove` source addresses. The earlier MMU enables ($A0006E, $A03EB2) are the
place to check first.

## ROOT CAUSE (2026-06-24) — TG68 builds the 32-bit page table INCOMPLETELY (table contents, in RAM)
MAME `maclc2` (10M, WSL) logs the boot toggling between TWO valid MMU configs (`log_mmu_writes.lua`):
```
Config A: TC=80F05750 (IS=0, full 32-bit)  CRP_APTR=9FEE00  (CRP_LIMIT=7FFF0003, DT=3 long)
Config B: TC=80F84500 (IS=8, 24-bit alias) CRP_APTR=9FE820
```
TG68's derail values (TC=80F05750, CRP=9FEE00) are **exactly MAME's Config A** — a VALID config, NOT
corruption. So TC/CRP are correct. The difference is the TABLE CONTENTS (`dump_tables.lua`, MAME):
```
MAME Config A @ 9FEE00:  root[8] @9FEE40 = 000BFC0A 009FEDA0  DT=2 (valid, multi-level -> sub-table @9FEDA0)
TG68 (HW walk_desc_data): root[8] @9FEE40 = 00000000            DT=0 (INVALID — not built)
```
(MAME Config A also has root[0]=DT2@9FEDD0, root[10]=DT2@9FEBA0, root[11..15]=DT1 early-term; root[1..7,9]=DT0.)

**So: TG68 is in the correct config, the walk faithfully indexes root[8] @ $9FEE40, but RAM there is
0 — TG68 failed to build the Config A (32-bit) page table.** The boot constructs this table via CPU
stores; in TG68 root[8]'s entry (and likely its sub-tables) never lands at $9FEE40. Most likely a
**mistranslated store** during table construction (the build writes go through the MMU; an earlier
wrong config misdirects them) or a control-flow divergence in the build loop.

### Next investigation (the table-build divergence)
Find why TG68's store(s) building `$9FEE00`'s root[8] (and sub-tables `$9FEDA0`/`$9FEDD0`/`$9FEBA0`)
don't land. Options: (a) HW-capture stores to the `$9FExxx` region during boot (value + logical→phys);
(b) confirm RAM[`$9FEE40`] via a CPU read probe (rule out a walker-read bug vs a genuine un-built
table); (c) MAME-vs-TG68 divergence diff over the table-build code. NOTE: build #3's TC/CRP write-ring
(in flight) confirms TG68's config *sequence* matches MAME's A<->B toggling (registers fine).

## STRONG LEAD (2026-06-24) — the 10MB RAM map (where the page table lives) is UNVERIFIED
The Config A page table is at CPU/physical `$9FEE00` — the **10MB** region. The core's 10MB memory
config is flagged **"not yet verified against MAME"** (`MacLC.sv:408`; menu `O23,Memory,4MB,2MB,10MB`).
In `rtl/addrController_top.v` the RAM→SDRAM map (lines 167-190):
```
motherboard_high = cpuAddr[23:21]==3'b100   ($800000-$9FFFFF, the 2MB board, -> SDRAM $000000+)
in_simm          = cpuAddr[22:0] < simm_byte_size   ($800000=8MB for 10MB)
ram_sdram_word = motherboard_high ? {3'b000,cpuAddr[20:1]}      // $9FEE40 -> SDRAM byte $1FEE40
               : in_simm          ? (23'h100000 + cpu_word) ...
```
`$9FEE40` is BOTH motherboard_high AND in_simm (low 23 bits < 8MB); motherboard_high wins, so the
table at `$9FEExx` maps to the 2MB board bank (SDRAM `$1FEExx`). This is consistent for reads and
writes that both present physical `$9FEExx` — BUT the bug is whether the table-build STORE actually
reaches physical `$9FEE00`. If the build store's MMU translation (or addressing) puts it at a
different physical (e.g. `$1FEExx`, which maps to a DIFFERENT SDRAM, the SIMM `$3FEExx`), the walker's
read of `$9FEE40` (-> SDRAM `$1FEE40`) sees 0. Build #4's store capture (intended-logical vs
landed-physical of the root[8] write) pins this: mistranslated store vs never-stored vs
walker-read/RAM-persistence. The unverified 10MB map is the prime suspect for a write/read SDRAM
mismatch around `$9FExxx`.

## CONFIRMED (2026-06-24) — the 10MB derail is the 10MB RAM map; 4MB exposes a DIFFERENT bug
HW config `MacLCii.CFG` = `08` => status[3:2]=2 = the **10MB** Memory option (the unverified path).
Set it to `00` (4MB, the verified default), rebooted, re-read probes:
- **PMMU derail GONE**: `PFR frozen=0` (no high-RAM `$9FExxx` fetch). The boot gets PAST the `$A416B2`
  mode switch that derails under 10MB. => the `$9FEE40`/root[8] PMMU derail is **10MB-RAM-map-specific**.
- **Still a Sad Mac, but a DIFFERENT failure**: CPU alive (PACT advancing), fetching in the Sad Mac
  handler `$A49xxx`, `PRC0 boot_inits=2` + `scsi_bus_resets=1` — i.e. the separate **"#3 cold-boot
  reboot loop"** (what dbg_probes/PRC0 were originally built for), NOT the PMMU derail.

So the core has (at least) TWO boot blockers, config-dependent:
- **10MB**: the PMMU derail = THIS session's root cause = the unverified 10MB RAM map (page table at
  `$9FEE00` / SDRAM `$1FEExx` not correctly built/backed -> walker reads 0 at root[8]).
- **4MB**: the #3 reboot loop (pre-existing, separate).
The user's saved config was 10MB, so they were hitting the PMMU derail. Config restored to 10MB.
Build #4 (table-build store capture, 10MB) will pin the exact 10MB-map store mechanism for the fix.

## BUILD #4 — table-build store LANDS, walker reads 0 => 10MB SDRAM clobber/mirror (the fix locus)
HW table-build store capture (10MB, frozen at derail):
```
stores INTENDING $9FEExx (logical) = 128 ; LANDING $9FEExx (physical) = 128  (whole table page written)
intended root8 store: logical=009FEE40 -> physical=9FEE40  data=000B  TC=000046FC (MMU OFF) -> LANDED at root8
store LANDED at phys root8 $9FEE4x: from logical=9FEE40  data=000B   (= high half of 000BFC0A)
```
So the CPU DOES write root[8] (`000B...`) to physical `$9FEE40` (MMU off). But build #2 showed the
WALKER (MMU on) reads `$9FEE40 = 0`. The SDRAM word is identical for both paths (`memoryAddr` from
addrController; `$9FEE40` -> motherboard_high -> SDRAM word `$0FF720`), and `selectRAM=1` for `$9FExxx`
(addrDecoder `in_motherboard_range`). So the write and read target the SAME SDRAM, yet the data is
gone => the page table at `$9FExxx` is **clobbered / not persisted** in the 10MB map.

`rtl/addrDecoder.v:108-113` documents EXACTLY this hazard: the motherboard low/high **`$0<->$800000`
SDRAM mirror**, whose RAM march/writes "clobber the ... descriptor table" — gated by `ram_configured`
for the probe, but evidently still clobbering the Config A table at `$9FExxx` in the 10MB path. So
some later CPU write (a low address that aliases the motherboard 2MB bank, SDRAM `$0FF7xx`) overwrites
root[8] after the table-build, before the walker reads it.

### FIX LOCUS (10MB RAM map)
`rtl/addrController_top.v` (RAM->SDRAM map, lines 167-190) + `rtl/addrDecoder.v` (selectRAM ranges,
107-118): the 10MB motherboard 2MB bank (`$800000-$9FFFFF` -> SDRAM `$000000-$1FFFFF`) aliases a low
CPU range, so the page table at `$9FExxx` gets clobbered. Next: a targeted HW capture of WHICH CPU
address writes SDRAM word `~$0FF720` after the table-build (the clobber source), then de-alias the
10MB map. Confirmed 10MB-specific (4MB has no derail). NOTE: 4MB then hits the separate #3 reboot loop.

## BUILD #6 — the page table is CLOBBERED BY CODE (10MB map collision), confirmed
Write-vs-read SDRAM capture for root[8] (CPU `$9FEE40`):
```
table-build WRITE: cpuAddr=9FEE42 -> SDRAMword=0FF721  data=FC0A   (low half of root[8] 000BFC0A — correct)
walker/fetch READ: cpuAddr=9FEE40 -> SDRAMword=0FF720  data=4ED2   (= 68k 'jmp (A2)' OPCODE, not 000B)
```
root[8]'s hi-word at SDRAM `$0FF720` was written `$000B` (build #4) but reads back `$4ED2` — a code
opcode. So the page table is **overwritten by a code write** between build and use. (Capture caveat:
`w8` latched the LAST root[8] write `$9FEE42`->`$0FF721`, so the auto "write!=read" verdict compared
different addresses; the real, unambiguous signal is root[8] holding CODE `$4ED2` instead of `$000B`.)
In the 10MB map only CPU `$9FEE40` (motherboard_high) maps to SDRAM `$0FF720`, so either the boot's
32-bit-mode code copy/relocation writes physical `$9FEE40`, or the MMU's Config A maps a code region's
logical to physical `$9FEE40` (= the table). MAME (linear 10MB) doesn't clobber its `$9FEE00` table,
so the MacLCii 10MB map collides where a linear map wouldn't. FIX = the 10MB RAM map. NEXT (one clean
build): a clobber capture latched on SDRAM word `$0FF720` exactly (any cpuAddr), to name the clobber
source, then de-alias.

## BUILD #7 — DEFINITIVE: the 10MB motherboard bank does NOT persist the page table (not a clobber)
Corrected capture, watching SDRAM word `$0FF720` (= where CPU `$9FEE40` maps via motherboard_high)
exactly, frozen at the derail:
```
writes to $0FF720 = 1 ;  CPU $9FEE40 reads back = 0000 (from cpuAddr 9FEE40)
newest write: cpuAddr=9FEE40  data=000B  LOGICAL=009FEE40   (the CORRECT root[8] hi-word, MMU off)
```
ONE write (the table-build, correct `$000B`), NO clobber — yet a later read returns `$0000`. So the
write to the motherboard bank simply **doesn't persist**. `selectRAM` (addrDecoder `in_motherboard_range`,
`$800000-$9FFFFF`) and `_ramWE` are NOT range-gated, so the decode is fine; the SDRAM BACKING of the
motherboard 2MB bank (CPU `$800000-$9FFFFF` -> SDRAM words `$000000-$0FFFFF`, `addrController_top.v:188`)
is what fails in the 10MB config — the page table at `$9FExxx` cannot survive there.

### ROOT CAUSE (final) + FIX
The 10MB RAM->SDRAM map is broken: the motherboard 2MB bank doesn't retain writes (the page table at
`$9FExxx` reads back 0). The PMMU then walks a zeroed root[8] -> derail -> Sad Mac. The walk, A5, and
TC/CRP are all correct; only this RAM map is wrong (4MB avoids it). FIX locus: `rtl/addrController_top.v`
`ram_sdram_word` (lines 167-190) — the motherboard_high mapping `{3'b000, cpuAddr[20:1]}` -> SDRAM
`$000000+`. Likely the motherboard bank's SDRAM region collides with another user (SIMM/ROM/disk-image/
download) or isn't backed; the robust fix is to make the 10MB CPU->SDRAM map linear (`$000000-$9FFFFF`
1:1) and relocate ROM/VRAM/disk above `$A00000` (coordinated with the download map in MacLC.sv + sim.v).
Open sub-question for the fix: which other SDRAM user (if any) overlaps motherboard words `$000000-$0FFFFF`
— a 1-build capture of whether `_ramWE`/`sdram_we` actually assert for the `$9FEE40` write would confirm
write-drop vs overwrite. SEPARATE bug: 4MB hits the #3 reboot loop. (MiSTer Remote web service died from
repeated reboots this session — restart with `/media/fat/Scripts/remote.sh -service restart`.)

## Reusable assets created this session
- `verilator/pmmu_bench/` — standalone PMMU translation bench (synth + Verilator + C++). Fast
  iteration; also the regression validator for any real PMMU fix. `synth_pmmu.sh` regenerates the
  standalone `.v` (GHDL LLVM shim).
- `verilator/ksw_bench/` — kernel-level mode-switch micro-repro (full kernel, two-bus harness,
  clkena gated on `pmmu_busy`). The faithful, fast (~seconds) reproduction of the boot mode switch;
  reuse it to test any kernel-level fix without a 24-min FPGA build.
- The committed `rtl/tg68k/TG68KdotC_Kernel.v` already contains the PMMU as submodule
  `tg68k_pmmu_030_Brtl`; `TG68K_PMMU_030.vhd` is unmodified, so the standalone synth matches it.

## BUILD #8 (in progress) — PIN: does the SDRAM write STROBE fire for the $9FEE40 write?
This session's analytical rulings narrowed build #7's "doesn't persist" to one remaining unknown:

- **Download is NOT the overwriter.** The dio download map (`MacLC.sv:1400-1402`) writes SDRAM word
  `$500000` (ROM), `$600000` (Floppy1), `$700000` (Floppy2) — NONE in the motherboard region
  (`$000000-$0FFFFF`). And SDRAM writes come ONLY from `download_cycle?dio:CPU` (`sdram_we` mux); there
  is no third writer. So nothing overwrites SDRAM `$0FF720`.
- **No SDRAM aliasing.** `sdram.v` decodes bank=`addr[21:20]`, row=`addr[19:8]`, col=`{addr[22],addr[7:0]}`
  — every `addr[22:0]` is unique. `$0FF720` → bank0/row$FF7/col$020 (distinct from the SIMM bank-1 region).
- **`_ramWE`/`_ramOE` are NOT range-gated** (`addrController_top.v:126-129`): they assert for ANY
  `selectRAM` access given `cpuBusControl`. So the decode permits the write.

REMAINING unknown → build #8 pins it: does the SDRAM write strobe (`_ramWE` => `sdram_we`) ACTUALLY
assert for the `$9FEE40` table-build write? Capture (existing routing): `we_fired` = `_ramWE` asserted
(`cpu_ramwe_n` low) while `memoryAddr==$0FF720`; `we_cnt`/`we_data`; plus `rd_memaddr` = the SDRAM word
the `$9FEE40` READ targets. Probes repurposed: `PSWL={we_data,we_cnt}`, `PSNC={we_fired,rd_memaddr}`.

### Fix branches by result (note: `ram_sdram_word` sets the SDRAM DESTINATION, not whether `_ramWE` fires)
- **`we_fired=0` (write DROPPED):** `selectRAM=1` (build #7) but the strobe never asserted ⇒
  `cpuBusControl` was low at that write (bus not granted) — a bus-arbitration/decode issue. Fix locus is
  `addrDecoder.v` / the `cpuBusControl` path for the `$800000-$9FFFFF` range, NOT `ram_sdram_word`. The
  linear-map change would NOT help here.
- **`we_fired=1` + `rd_memaddr==$0FF720` (committed but SDRAM loses it):** the write reached SDRAM
  `$0FF720` yet the read returns 0 ⇒ the SDRAM backing of that region is the problem. Fix by relocating
  the motherboard bank to a known-good SDRAM region (change `ram_sdram_word`) and/or `sdram.v`. A linear
  1:1 map (`ram_sdram_word = cpuAddr[23:1]`) is viable ONLY if SDRAM `$000000-$0FFFFF` is actually good
  (it would then host low RAM); if that region is the bad one, linearizing is catastrophic — shift the
  whole RAM map UP off `$000000-$0FFFFF` instead.
- **`we_fired=1` + `rd_memaddr!=$0FF720` (read-mismatch):** the MMU-on read maps `$9FEE40` to a different
  SDRAM word than the MMU-off write did. Fix locus is the addrController READ path / address presentation.

---

## BUILD #8 — DEFINITIVE: committed write is LOST by the low SDRAM region (2026-06-24)
JTAG capture frozen at the derail (10MB config, RBF md5 9cfd7306…):
```
BUILD#8 write-STROBE commit of root#8 @ SDRAM word $0FF720:
  WRITE cycles to $0FF720 = 1 ;  newest {a16:data}=EE40000B (cpuAddr=9FEE40)
  _ramWE STROBE fired = 1  (count=5 data=000B)   <== COMMITTED to SDRAM
  CPU $9FEE40 reads back = 0000 (seen=1) ; READ SDRAM word=0FF720 (=expected)
```
Interpretation: the `_ramWE`/`sdram_we` strobe **fires** (data `$000B`, word `$0FF720`), the read
**targets the same word** `$0FF720`, yet it reads `$0000`. So the write COMMITS to the controller but
the **low SDRAM region the motherboard bank maps to loses it**. Not a decode-drop, not a read-mismatch,
not an overwrite (cw_cnt=1), not a download/DMA collision. The PMMU walker reads *other* descriptors
fine (boot reaches `$A416B2` with MMU on), so the read path works — it is specific to the motherboard
bank's SDRAM region (`$000000-$0FFFFF`).

### sdram.v analysis → the real mechanism + the fix
`rtl/sdram.v` is a correct standard MT48LC16M16 controller (per-access ACTIVE→R/W with auto-precharge;
AUTO_REFRESH every idle chipset cycle = massively over-refreshed). **MT48LC16M16 = 32MB (16M words),
but the controller ties row bit A12 to 0** (line 164 `sd_addr <= {1'b0, addr[19:8]}`) → only the LOWER
16MB (`addr[22:0]`) is addressable; the motherboard bank lives in it; the **upper 16MB is unused**.

**FIX (2026-06-24): relocate the motherboard bank to the unused upper 16MB.**
- `rtl/sdram.v`: `sd_addr <= {addr[23], addr[19:8]}` — drive A12 from addr[23].
- `rtl/addrController_top.v`: add `output mb_hi = !dskReadAckInt && !dskReadAckExt && selectRAM &&
  motherboard_high;` (memoryAddr stays 23-bit/unchanged).
- `MacLC.sv`: `sdram_addr = download ? {..dio} : {1'b0, mb_hi, memoryAddr[22:0]}` (bit23 = mb_hi).
- `verilator/sim.v`: mirror for parity.
Result: motherboard CPU `$800000-$9FFFFF` → SDRAM `$800000-$8FFFFF` (upper half, A12=1); page table CPU
`$9FEE40` → SDRAM `$8FF720`. SIMM/ROM/VRAM/floppy keep bit23=0 → **byte-identical, no regression**;
worst case on a <32MB module is A12=1 wraps to the current region (no worse than today). `memoryAddr`
for `$9FEE40` stays `$0FF720`, so the build #8 probe now VERIFIES the fix (reads-back should be `$000B`).
Assumption to revisit first if it doesn't boot: the physical module is ≥32MB (comment + MiSTer standard).
