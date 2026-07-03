# Findings: HW continue-past Sad Mac is a FC7 moves.w derail, not the OS probe (2026-06-22)

Supersedes the diagnosis in `docs/resume_berr_hw_continue_past_2026-06-21.md` and
`docs/results_berrframe_sim_2026-06-20.md` on the KEY question of *what faults*. The
fix direction there (stack `exe_pc+len` for the OS `(An)`/`(d16,An)` handle-validation
probe) is **not** what breaks the HW boot. Established by JTAG PC-trace on real hardware.

## What the hardware actually shows (System 6.0.8 + POP HD, boot0-nomemcheck.rom)

1. **Every `make_berr` is the FC7 `moves.w $22000.l,d1` probe at `$A03A8A`** (opcode
   `$0E79`). A JTAG recorder that froze on the first fault with `exe_pc[15:0] != $3A8A`
   (i.e. any non-RAM-probe fault) found **NONE** across all ~14 faults. The OS
   handle-validation `move.l $38(a6),d0` / `movea.l (a1),a0` probe (`$A0DBxx`/`$A0DCxx`)
   **never faults** on this boot — the prior session's whole premise was unconfirmed.
   `$22000` is *hardcoded*, so 14 faults = the same probe re-running, then Sad Mac.

2. **PEXC `faulting IF=$A0DBFC vec-2` is a FALSE POSITIVE.** `$A0DBF8: movea.l $8.w,a2`
   is the ROM *reading* the bus-error vector to save it before installing a temp
   handler. That supervisor read of address `$8` trips PEXC's `vec_fetch` detector
   (`cpuFC[2] && addr in [$08..$24]`). It is NOT a bus error at `$A0DBFC`. The
   "derail at `$A0DBFC` → `$A09B8A`" narrative in the resume doc is built on this artifact.

3. **PC TRACE: the PC derails into HIGH RAM.** A 4-deep ring of fetch PCs, armed after
   the first fault, frozen on entry to the Sad Mac handler page (`$A49xxx`), captured:
   ```
   pc3=$9FE870  pc2=$9FE872  pc1=$9FE874  pc0=$9FE876  -> $A49xxx (Sad Mac)
   ```
   Four SEQUENTIAL fetches at `$9FE87x` = **high RAM (~10 MB), not ROM**. So after ~13
   `moves.w` recoveries, control ends up executing garbage in high RAM, then reaches the
   Sad Mac handler. (v2 of the trace re-targets the freeze to the first high-RAM fetch
   to capture the ROM jump/vector site that derails — pending.)

## Confounders RULED OUT (do not re-chase)

- **Environmental HPS exhaustion** (advisory_shared_mister_hps): that is *random* per-boot
  crash variety with sluggish boot / dead sshd. This is **deterministic** (same ~14
  faults, same `0000000F/00007FFF` every boot). HPS was healthy (12-min uptime, live sshd).
- **Phantom PDS card** (findings_pds_phantom_card): the `slot_space`→`$FFFF`-ack fix IS
  present (`MacLC.sv:554/742`); slots don't BERR, and 6.0.8 doesn't exercise the Slot
  Manager anyway. Not this.
- **My continue-past fix** (uncommitted, `TG68KdotC_Kernel.vhd` `berr_setup_*`): a NO-OP
  for this bug — the `moves.w` is EA mode 111 (absolute), so it takes the fallback branch
  (`berr_frame_pc <= instr_boundary_pc`), unchanged. Built clean, deployed, Sad Mac identical.

## Why the sim never caught it

`verilator/sim.v` wedges at the Egret/ADB idle loop (`$A06F0E`) BEFORE the full probe
sequence. Its one-shot frame-9 `moves.w` recovery (jmp A6) was real but is not the failing
path — the 14-fault sequence + derail only happens in the full HW boot.

## Current hypothesis (to confirm with PC-trace v2)

TG68's bus-error handling for the FC7 `moves.w` probe **corrupts the recovery target** so
that after some iterations control jumps into high-RAM garbage (`$9FE87x`):
- the probe's handler recovers via `jmp (a6)` (a6 pre-armed) — a corrupted `a6` would land
  there; OR
- the ROM's save/restore of the `$8.w` BERR vector (`movea.l $8.w,a2` … `move.l a2,$8.w`)
  is corrupted, so a later vec-2 dispatch reads a garbage handler address.
PC-trace v2 (`pc0` = last ROM PC before the high-RAM fetch) should name the exact site.

## Diagnostic tooling state (rtl/dbg_probes.sv, PFR0-3 repurposed)

- PFR0-3 = a 4-deep fetch-PC ring (`pc0`=newest). Armed after first `make_berr`. v1 froze
  on `$A49xxx`; v2 freezes on first fetch in `$40_0000..$9F_FFFF` (high RAM = derail).
- PFR3 = `{trigs[5:0], armed, frozen, pc3[23:0]}`. Decode in `scripts/cpu_state.tcl`.
- Disasm any ROM PC with `python scratch/disasm_at.py 0x<pc>` (ROM = `boot0-nomemcheck.rom`,
  offset = pc & 0x7FFFF). High-RAM PCs ($9FE87x) are NOT in ROM — cannot static-disasm.

## UPDATE — the derail is in MMU/cache setup, NOT a continue-past probe

PC-trace v2 (freeze on first high-RAM fetch) captured the ROM→RAM transition:
```
pc3=$A416B2  pc2=$A416B4  pc1=$A416B6  pc0=$A416B8  -> $9FE87x (high RAM)
```
Authoritative disasm (`docs/MacLC_ROM_disasm.txt`, addr = $40800000 + (runtime&0x7FFFF);
my capstone linear disasm was MISALIGNED — ignore the earlier "movec d5,vbr / jmp (a2)"):
```
$A416AE: movea.l a1,a4
$A416B0: movea.l a0,a2
$A416B2: bsr.w   $A41A5C
$A416B6: movea.l a2,a0
$A416B8: bsr.w   $A41B8E      <- last ROM fetch; next fetch is physical $9FE87x
```
The enclosing routine (`$A4168E` link a5,#-124; bsr $A41726; bsr $A418E4; …) is **low-level
MMU/cache/VBR setup**: `$A416E0 pflusha`, `$A416E4 movec …,cacr`, `$A4170E movec d5,vbr`,
plus a structured descriptor table at `$A41602-$A4167E`. So the failure is in the
**Memory-Manager / PMMU bring-up**, NOT the continue-past RTE the resume doc chased.

Key constraints on the mechanism:
- **No make_berr** at `$A416xx` (the recorder saw faults ONLY at the FC7 `moves.w` $3A8A).
- **No illegal** (PEX3 none). So it is NOT a bus error or illegal-instruction exception.
- The CPU prefetches `$A416B2-B8` and the NEXT fetch is **physical `$9FE87x`** (~10 MB,
  top of RAM). The bsr targets are fixed ROM ($A41A5C/$A41B8E) — not corrupt.
- Leading theory: a **TG68 PMMU translation error** — once the MMU is (being) enabled in
  this routine, a fetch's logical→physical translation is wrong, so the CPU fetches the
  right logical PC but the wrong physical page (high-RAM garbage). The kernel's PMMU is
  heavily patched (pmmu_fault/ATC/pmmu_busy); a bring-up-phase translation bug fits.
  (Alternative: an exception that is neither vec-2 nor vec-4 vectoring through a not-yet-
  valid VBR table — but VBR is set at $A4170E, AFTER the derail.)

The FC7 `moves.w` $22000 faults are a **red herring**: they are the FPU/coprocessor
presence probe (SFC=7 = CPU space), they recover fine, and the boot proceeds PAST them
into this MMU setup where it actually dies.

## UPDATE 2 — not an exception; PMMU mistranslation suspected

Bus-txn trace (last txns before the high-RAM program fetch), frozen on the derail:
```
tx2 = $9FFFAC  FC=sDAT rd   (supervisor DATA read, top-of-RAM — table-walk descriptor? stack?)
tx1 = $A416B6  FC=sPRG rd   (fetch: movea.l a2,a0)
tx0 = $A416B8  FC=sPRG rd   (fetch: bsr.w $A41B8E)
derail -> $9FEE40  FC=sPRG  (program fetch, high RAM)
```
**No vector read at vecnum*4, no exception-frame writes** => NOT a vectored exception. The CPU
fetches `$A416B8` (`bsr.w $A41B8E`) and the next program fetch is physical `$9FEE40` instead of
the bsr target `$A41B8E` (the displacement word `$A416BA` is never even fetched). The enclosing
routine is the PMMU enable (`$A4171E pmove (a3),tc`). Derail target varies slightly per boot
($9FE876, $9FEE40 — both `$9FExxx`). Leading theory: **TG68 PMMU mistranslates the bsr's logical
target `$A41B8E` to physical `$9FEE40`** (a ROM-logical → high-RAM-physical mapping, plausibly a
botched ROM-to-RAM shadow or a bad table walk / ATC entry). The `$9FFFAC` sDAT read may be the
table-walk descriptor fetch.

Decisive test in flight: latch the kernel's LOGICAL `exe_pc` at the derail (already routed as
`cpu_exe_pc`). exe_pc in ROM (`$A4xxxx`) + physical `$9FEE40` ⇒ mistranslation confirmed;
exe_pc `$9FExxx` ⇒ the logical PC genuinely derailed (different bug).

## UPDATE 4 (2026-06-23) — ROOT CAUSE via MAME(WSL): 32-bit ROM-alias PMMU mistranslation

Ran MAME `maclc2` LOCALLY in **WSL** (no MacBook needed): `/usr/games/mame` 0.264 HAS the `maclc2`
driver. Built CRC-valid ROMs by splitting `boot0.rom` into the 4 LC II byte-lanes (verified) + the
Egret ROMs (`rtl/egret/`); for an exact HW match, force-loaded the `boot0-nomemcheck.rom` lanes
(BAD-CRC warning, runs anyway). Setup lives in `verilator/mame/roms{,_nomemcheck}/maclc2/`.

**The derail is the 24→32-bit addressing-mode switch.** At ROM `$A416B2` the boot runs
`pmove (A3),tc` (MMU enable/reconfig — capstone mis-decodes cpid-0 PMMU ops as `fmove`; MAME and
`m68k-elf-objdump` are authoritative; the `docs/MacLC_ROM_disasm.txt` `bsr.w` reading was misaligned).
The very next instruction `jmp (A5)` (A5=`$40A0010E`, a 32-bit ROM alias) is where it diverges:
- **MAME:** `jmp` → `$40A0010E` → boots ON into 32-bit mode (`$40A09Bxx`…).
- **TG68 (HW):** `jmp` target translates to physical **`$9FEE40`** (high-RAM garbage) → derail → Sad Mac.

**This bug is ALREADY DEEPLY INVESTIGATED (June 15–18) — the resume-doc continue-past thread was a
wrong detour.** See `docs/handoff_lcii_postpmmu_2026-06-18.md`, `findings_1ff35a_mmuswitch`,
`findings_postpmmu_*`, `pr_lcii_030mmu2_kernel.{md,patch}`. TWO fixes from that work are **already in
my kernel**: the `bsr.w` PMMU-stall push (`c8895d8`, in HEAD) and the **instruction-prefetch grace
across MMU enable** (`mmu_fetch_grace`/`mmu_grace_suppress`, `TG68KdotC_Kernel.vhd:748+/1147+`). The
grace fix correctly lets the prefetched `jmp` execute — so the REMAINING bug is the **jmp-target
translation** of the `$40A` alias, a layer the June work hadn't reached (it wedged earlier at the
first `pmove TC` `$A03F12`; the grace fix advanced the boot to this NEXT `pmove TC` `$A416B2`).

**MAME oracle — the CORRECT translation** (`pt_root10.lua`, nomemcheck, 10M):
```
CRP root @ $9FE820 ; TC=$80F84500 (E=1, IS=8, PS=32K, TIA=4) ; TT0=TT1=0
root[10] @ $9FE870 = 7FFFFC19 / 00A00000  DT=01 early-term page descriptor -> ROM base $00A00000
=> $40A0010E  --(IS=8 strip $40)-->  $A0010E  --TIA=$A=root[10] early-term-->  physical $00A0010E (ROM)
```
TG68 gives `$9FEE40`. **Smoking gun:** the root table is at `$9FE820` and TG68's derail target
`$9FEE40` / earlier `$9FE876` sit INSIDE/just-past the root-table region (`$9FE876` is within root[10]'s
8 bytes). So TG68 mis-extracts the early-term descriptor for the 32-bit alias — outputting near the
descriptor's address region instead of its base field `$00A00000`. The fix locus is TG68's PMMU walk
(`rtl/tg68k/TG68K_PMMU_030.vhd`, the DT=01 early-term page-base extraction / IS=8 handling for the
`$40A` alias), validated against the MacIIvi PMMU corpus (40 tests, on the MacBook).

## UPDATE 3 — CONFIRMED: PMMU mistranslation during MMU bring-up

Logical-vs-physical capture at the derail (PFR taps):
```
derail fetch PHYSICAL (bus)   = $9FEE40   (high-RAM garbage page)
exe_pc        LOGICAL (instr) = $00A416B6 (CPU is executing in ROM)
TG68_PC       LOGICAL (fetch) = $00000000 (transient — combinational tap caught it mid-update; unreliable)
```
exe_pc proves the CPU is **logically in ROM** while a program fetch lands on **physical high-RAM**.
The MMU is **ON** at the derail: `pmove ...,tc` runs early ($A0006E, $A03EB2, …) long before the
derail; this routine's own `pmove crp`($A41716)/`pmove tc`($A4171E) are a *reconfiguration* that
comes AFTER the derail ($A416B8). So at the derail the MMU uses the PRIOR CRP/TC and **mistranslates
the `bsr.w $A41B8E` target (ROM) to physical `$9FEE40`** (and the `$A416` page still maps 1:1 — a
per-page error). Derail target wobbles ($9FE876/$9FEE40) ⇒ the bad mapping/descriptor is not stable.

So the bug is **TG68's PMMU translation** (bad ATC entry, bad table walk, or a garbage CRP), NOT the
Format-$B continue-past path the resume doc/MacBook chased, and NOT the FC7 `moves.w` (which recovers
fine and is a red herring).

### Why HW JTAG is now the wrong tool
- The PMMU debug ports (`debug_pmmu_tc/crp_lo/saved_addr/fault`) are behind `` `ifdef PMMU_TRACE ``
  (sim-only) — exposing them needs per-signal kernel reconnection + 3-file routing per build.
- The ROOT of a mistranslation is the **MMU table descriptors in RAM**, which JTAG cannot read
  (no RAM-read probe; only the bus shows what the CPU fetches). If it's an **ATC hit** (cached
  wrong entry) there are no descriptor bus-reads to capture at all.
- **MAME `maclc`** emulates the 68030 MMU correctly: it can dump the MMU table, show the CORRECT
  physical for logical `$A41B8E`, and trace the PC stream — the exact oracle for this divergence.

### Recommendation
Pivot to a MAME comparison (on the MacBook) to get the correct translation/table for `$A41B8E`, then
fix TG68's PMMU table-walk/ATC to match. Continuing pure-HW means heavy sim-only-port instrumentation
that still can't see the RAM table. See `docs/mame_compare.md`.

## Next steps (revised)
1. (in flight) confirm logical-vs-physical. If MISTRANSLATION: capture the PMMU state — TC
   (`dbg_pmmu_tc`), CRP/SRP root (`dbg_pmmu_crplo`/`saddr`), `pmmu_fault`, ATC — at the derail,
   then read the in-RAM translation descriptors (PIFD/JTAG) and hand-walk `$A41B8E` to find where
   TG68's walk diverges from the descriptor. The kernel PMMU (table walk / ATC / page size) is the
   fix locus, NOT the Format-$B continue-past path.
2. The FC7 `moves.w` continue-past fix (`berr_setup_*`) is unrelated to this Sad Mac — keep or drop
   per a later sim regression check, but it is not load-bearing here.

## (original next steps below)

1. Read PC-trace v2 `pc0` = the ROM derail site. Disasm it: is it `jmp (a6)` (corrupt a6)
   or a vec-2 landing (corrupt `$8.w`)?
2. From that, capture the corrupted value (a6 or the `$8.w` handler word) at the fault to
   prove the corruption, then fix TG68's `moves.w`/FC7 berr handling so the register/vector
   survives the bus-error exception.
3. MAME `maclc` cross-check (docs/mame_compare.md, on the MacBook) would give the exact
   register/frame a real 68030 leaves after this probe — the ground-truth oracle.
