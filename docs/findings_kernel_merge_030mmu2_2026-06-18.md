# Findings — TG68K core convergence MacLC ⇄ upstream Minimig `030_mmu2`

**Date:** 2026-06-18 · **Branch:** `kernel-sync-030mmu2` (off `030_LCii_rebased` @ `3194397`)
**Companion plan:** `docs/plan_061826.md`. This doc records the classified comparison + execution results.

## TL;DR
The two TG68K cores **share a common ancestor** (`ede91c3` = MacLC's original 030_mmu import) and are far
more converged than the prior handoff implied. Convergence was executed as **incremental, boot-tested steps**
(never a wholesale swap — that regressed before). After Phases C+D, **4 of the 5 shared core files are
converged**:

| Core file | State after Phase C/D |
|---|---|
| `TG68K_PMMU_030.vhd` | ✅ byte-identical (was already) |
| `TG68K_Pack.vhd` | ✅ byte-identical to upstream |
| `TG68K_ALU.vhd` | ✅ byte-identical to upstream |
| `TG68KdotC_Kernel.vhd` | ✅ upstream + **127-line delta** = MacLC's `mmu_fetch_grace` + bsr.w fix (both heading upstream) |
| `TG68K_Cache_030.vhd` | ⏳ Phase F — deferred (FPGA-only; sim runs uncached, cannot validate) |

The LC II boot stays green (desktop checkerboard at F399) at every step.

## Why the prior wholesale swap regressed (root cause)
The earlier "adopt their kernel + ALU + Cache + Pack" swap hung in **pre-MMU POST (`$A45Exx`)**. Decisive:
the Verilator sim runs the kernel **uncached** (cache not instantiated in `tg68k.v`), and `mmu_fetch_grace`
only acts at/after MMU-enable — so neither the cache nor missing grace can explain a *pre-MMU* hang. The real
cause: a wholesale swap **drops MacLC's own kernel edits** (the 128-line delta vs the import point), and at
least one of those is load-bearing in a pre-MMU path. The 3-way merge fixes this by *preserving* MacLC's edits.

## Method: 3-way merge on the common ancestor
- base = `git show ede91c3:rtl/tg68k/TG68KdotC_Kernel.vhd` (MacLC's import point, 8821 lines)
- ours = MacLC HEAD kernel · theirs = `apolkosnik/030_mmu2` pristine
- Deltas: **base→ours = 128 changed lines** (MacLC barely diverged), **base→theirs = 1194** (upstream added
  the whole advanced fault-recovery family).
- `git merge-file -p ours base theirs` → **only 2 conflicts**, both resolved by judgment:
  1. **debug-port tail** (cosmetic): took upstream's set (`USP/MSP/ISP`, `rte_mmu_fix_*`, `pmmu_fault_*`,
     `pmmu_pending_flags`), dropped MacLC's `OP1out/OP2out` (unused by `tg68k.v`; removed ports + body assigns).
  2. **`pmmu_req`** (semantic, both edited the same line): **ANDed** MacLC's `mmu_grace_suppress` term with
     upstream's `$00DD4000` MiSTer-FS trapdoor exclusion. The trapdoor is **Amiga-only** board I/O and a
     **harmless no-op on the Mac** (which never accesses that range); kept for byte-parity with upstream.

## Per-file classification (G generic / M Mac-specific / S sim-debug / A Amiga-specific)

### `TG68K_Pack.vhd` — (G) — DONE
+1 enum value `rte_mmu_replay` (used by upstream's RTE-replay). Adopted upstream verbatim → byte-identical.

### `TG68K_ALU.vhd` — (G) — DONE
Same DIVS.W overflow **N-flag** fix on both sides, two impls. MacLC recomputed `dividend_abs/divisor_abs`
inside `divs_overflow_flags_68020`; upstream passes `quotient_abs_low8 = div_reg(7:0)`. **Functionally
equivalent** — verified: `div_reg` is loaded with the *absolute* dividend (`0-dividend` when negative),
accumulates the quotient via non-restoring iteration, and the sign-adjust (`div_neg`) is applied downstream to
`result_div`, **not** written back to `div_reg`; so `div_reg(7:0)` at the overflow-check state *is* the
absolute trial quotient's low byte. Upstream's form is also strictly better for FPGA (reuses the datapath
divider instead of synthesizing a second 32/16 divide). Adopted upstream → byte-identical. Boot unregressed.

### `TG68KdotC_Kernel.vhd` — the substance — DONE (functional convergence)
- **Pulled in from upstream** (the advance): `rte_fmt_a_replay_*` (replay a faulted data write on RTE,
  format $A), `rte_format_b` (long MMU bus-fault frame fixup), the `rte_mmu_replay` micro-state, extended
  `berr_exception_active` / `rte_mmu_fix` / `pmmu_fault_dispatched`/`_was_cleared` (double-bus-fault detect),
  and the `pmmu_pending_flags` debug passthrough. All (G).
- **Preserved (MacLC, the 127-line retained delta)**: `mmu_fetch_grace` (LC II boot bug #3 — instruction-
  prefetch grace across MMU-enable; the very-cycle term + the page grace window; `addr_out` identity-fallback)
  and the bsr.w/`pmmu_busy` stall fix (`c8895d8`). The grace is (M) today but is really a generic 68030
  prefetch-vs-MMU-enable hazard → **(G) candidate to upstream**. bsr.w is (G), already in flight as PR
  apolkosnik#3.
- **Amiga content auto-pulled** is harmless: comments mentioning AmigaOS / test programs (`WhichAmiga`,
  `ptestw`), and the `$00DD4000` trapdoor no-op. No Amiga-gated *logic* that affects the Mac.
- **Debug ports** (S): adopted upstream's set; `tg68k.v` binds a subset by name and leaves the rest open.

### `TG68K_Cache_030.vhd` — (G, FPGA-only) — DEFERRED to Phase F
Upstream switched the 68030 caches **physical→logical** indexing/tagging with **FC-qualified tags**
(`i_fc`/`d_fc` ports), removed write-allocate, relaxed cache-inhibit (CI blocks allocation, not hits), made
CACR line-invalidate unconditional. MacLC keeps physical tags + write-allocate. **No Mac- or Amiga-gated
logic** — same generic cache, opposite trade-offs. Physical tagging sidesteps PMMU logical-address aliasing
(the area just stabilized for the LC II). **The sim cannot validate this** (runs uncached) → requires real
FPGA boot + MAME oracle. Treat as a separate, HW-gated, revertible step.

### `TG68K.vhd` — (S, inert) — Phase G
Reference-only in MacLC (`TG68K.qip:5-9`: compiled by neither sim nor FPGA). Diffs are debug surface +
`i_fc`/`d_fc` plumbing. Zero behavioral effect; sync last for cleanliness.

### Excluded (not core): `TG68K_CacheCtrl_030.vhd` + `cpu_wrapper.v`
Upstream's Amiga integration layer (Zorro/Fast-RAM, Amiga walker handshake), instantiated only by
`cpu_wrapper.v`. MacLC uses `tg68k.v`. Not part of the shared core — do not import.

## Execution results (per phase)
| Phase | Change | ghdl `--synth` | LC II boot F399 |
|---|---|---|---|
| A | baseline reconfirm | — | ✅ checkerboard (reference) |
| C | Pack + ALU → upstream (byte-identical) | clean | ✅ checkerboard (`8ef29c7`) |
| D | 3-way merge kernel (RTE/fault family) | clean | ✅ checkerboard (`75f016b`) |
| E | grace EFFECT disabled — is `mmu_fetch_grace` still needed? | clean | ❌ regresses — **grace is required, kept** |

**Phase E verdict:** forcing `mmu_grace_suppress <= '0'` regresses the boot. The CPU passes early POST and
enables the MMU (`a2=40A48D04` shows the `$40`/A30 alias appear), then derails back into a `$A45Exx` loop
through F400 — never reaching the desktop (`A06F0E` count 0). So `mmu_fetch_grace` and the PMMU early-term fix
(`f605e44`) address **independent** bugs; the prefetch-vs-MMU-enable hazard is real and grace is load-bearing.
**Decision: keep grace** → it becomes an upstream-PR candidate (Phase I), framed as a generic 68030 hazard fix.
Kernel delta stays 127 lines (grace + bsr.w).

## Retained delta & upstream path (toward true byte-identity)
Kernel delta vs `apolkosnik/030_mmu2` = 127 lines = `mmu_fetch_grace` + bsr.w fix.
- **bsr.w**: already PR apolkosnik#3 (open). When merged upstream, that part of the delta disappears.
- **`mmu_fetch_grace`**: Phase E proved it is **still required** (disabling it regresses the boot). Keep it
  and **upstream it** as a generic 68030 prefetch-vs-MMU-enable hazard fix; once merged upstream, the kernel
  becomes byte-identical. This is a second PR alongside the bsr.w one.

## Recommendation
The "keep MacLC's working kernel and converge via 3-way merge" path is the correct one: it gained the full
upstream advance in a single boot-validated step while preserving every MacLC fix, and reduced the kernel to
a 127-line, fully-documented, upstream-bound delta. Next: settle Phase E (final delta size), then Phase F
(cache, on hardware), then upstream PRs (Phase I) and propagate to MacIIvi (Phase J).
