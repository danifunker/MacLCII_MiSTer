# Draft upstream PR — TG68K instruction-prefetch grace across MMU enable

**Status:** prepared, **not pushed/opened** (yours to push). Companion to the open bsr.w PR (apolkosnik#3).
Together these are the two MacLC kernel deltas vs `apolkosnik/030_mmu2`; landing both makes the shared
`TG68KdotC_Kernel.vhd` byte-identical between MacLC, MacIIvi and upstream Minimig.

## Where it is
- **Repo:** `/Users/dani/repos/Minimig-AGA_MiSTer-danifunker`
- **Branch:** `mmu-fetch-grace` (off `apolkosnik/030_mmu2`), commit `b192f85`
- **Diff:** grace-only — 62 added / 4 removed lines, no bsr.w/RTE changes leaked in. `ghdl --synth` clean on the
  Minimig base. (Minimig tracks no generated `.v`, so the `.vhd` change is the whole PR.)
- A copy of the diff is saved at `docs/pr_mmu_fetch_grace.patch`.

## To push & open
```bash
cd /Users/dani/repos/Minimig-AGA_MiSTer-danifunker
git push -u origin mmu-fetch-grace
gh pr create --repo apolkosnik/Minimig-AGA_MiSTer \
  --base 030_mmu2 --head danifunker:mmu-fetch-grace \
  --title "TG68K 68030: instruction-prefetch grace across MMU enable" \
  --body-file -   # paste the commit body, or point at this file's "PR body" section
```

## PR body (ready to paste)
> When `pmove TC` enables the MMU, instruction words already prefetched while the MMU was off must execute
> **without** being re-translated (real 68030 prefetch-queue / logical I-cache behaviour). The canonical
> `pmove TC; jmp <alias>` relies on this: the jmp is prefetched and executes, only its target is translated.
> TG68K is uncached and refetches the next opcode after the pmove, so it re-translates the still-physical PC
> and bus-errors when the execution region is intentionally unmapped after enable.
>
> **Fix:** a small grace state machine. Arm on the rising edge of `pmmu_tc_en`, capturing the executing page
> (`TG68_PC[31:20]`); while instruction fetches (`state="00"`) stay in that page, bypass translation
> (`addr_out` identity); disarm on the first fetch that leaves the page (the jmp target), which translates
> normally. Data accesses are never graced. Two suppression terms cover the enable cycle (`pmmu_tc_en_d`
> edge) and the persistent page window.
>
> Found and validated on the **Mac LC II boot** (MacLC_MiSTer), whose ROM runs the post-`pmove` code from a
> now-unmapped alias; without this it bus-errors right after MMU enable and never reaches the OS. Generic
> 68030 behaviour — applies to any TG68K `030_mmu2` user. `ghdl --synth` clean; no functional change when the
> MMU is off or once the CPU has branched out of the enable page.

## Evidence it's load-bearing (MacLC Phase E)
Disabling the grace effect (`mmu_grace_suppress <= '0'`) on the otherwise-converged MacLC kernel regresses the
LC II boot: the CPU passes POST and enables the MMU (`a2` shows the `$40`/A30 alias appear), then derails into
an `$A45Exx` loop and never reaches the desktop. With grace present it boots to the desktop checkerboard.
This is independent of the PMMU long-format early-termination fix (`f605e44`).
