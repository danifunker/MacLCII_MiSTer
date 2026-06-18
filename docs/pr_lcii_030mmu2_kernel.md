# Upstream PR — TG68K 030_mmu2 LC II kernel fixes (bsr.w PMMU-stall + prefetch grace)

**Single combined PR** carrying both MacLC→upstream kernel contributions. Supersedes the idea of a separate
grace PR — grace was folded into the existing bsr.w PR branch so there is **one** PR.

## Where it is
- **Repo:** `/Users/dani/repos/Minimig-AGA_MiSTer-danifunker` · **Branch:** `030_mmu2_fixes` (the PR #3 branch)
- **Commits ahead of `apolkosnik/030_mmu2`:**
  - `d21cd6c` tg68k: bsr.w/bsr.l PMMU-stall push fix (already in PR #3)
  - `c863dd6` TG68K 68030: instruction-prefetch grace across MMU enable (newly folded in)
- Net kernel diff vs upstream: 93 ins / 6 del, kernel-only, `ghdl --synth` clean.
- Combined patch saved at `docs/pr_lcii_030mmu2_kernel.patch`.

## To push & open (or update the existing PR #3)
```bash
cd /Users/dani/repos/Minimig-AGA_MiSTer-danifunker
git push origin 030_mmu2_fixes          # updates PR apolkosnik#3 to include both commits
# then retitle PR #3, e.g.:
gh pr edit <#3> --repo apolkosnik/Minimig-AGA_MiSTer \
  --title "TG68K 030_mmu2: LC II MMU boot fixes — bsr.w PMMU-stall push + instruction-prefetch grace"
```
(If you'd rather keep PR #3 bsr.w-only, instead branch grace off it separately — but the request was one PR,
so folding into #3 is the path taken.)

## What the two fixes are
1. **bsr.w/bsr.l PMMU-stall push** (`d21cd6c`): the return-PC push (`set(presub)`) must fire atomically with
   the `setstate="11"` push write; a PMMU-translation stall otherwise let the push land on the branch target
   and left the stack slot `$0`.
2. **Instruction-prefetch grace across MMU enable** (`c863dd6`): when `pmove TC` enables the MMU, already-
   prefetched instruction words must execute without re-translation (real 68030 prefetch/I-cache behaviour).
   TG68K is uncached and refetches the next opcode after the pmove, so it re-translates the still-physical PC
   and bus-errors when the post-enable region is intentionally unmapped. A small grace state machine bypasses
   translation (identity) while fetches stay in the page the CPU was executing when the MMU came on, and
   re-arms on the first fetch that leaves it (the jmp target). Generic 68030 behaviour; found+validated on the
   Mac LC II boot (MacLC_MiSTer), which derails without it (Phase E proof in
   `docs/findings_kernel_merge_030mmu2_2026-06-18.md`).

## Byte-identity follow-up (the proper downstream direction)
Once this lands in `apolkosnik/030_mmu2`, **re-sync MacLC + MacIIvi kernels FROM the landed upstream** to reach
literal byte-identity. The combined PR uses upstream-appropriate (generic) grace comments and upstream's
whitespace-clean bsr.w, which differ cosmetically from MacLC's current text (comment wording + 3 trailing-tab
lines, ~96 cosmetic lines, **zero functional difference**). Syncing downstream-from-upstream after the PR
merges picks those up and makes all three cores byte-identical — the canonical-upstream collaboration flow.
