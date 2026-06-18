# HANDOFF — Prove it in ModelSim: A/B the tg68k_030 suite (base vs bsr.w PR)

**For:** a Claude session (or human) on the **Windows machine that has ModelSim** (Intel FPGA
Lite / ModelSim-Intel Starter, `vsim`/`vcom`/`vlib`). **Repo:** the Minimig fork
`Minimig-AGA_MiSTer-danifunker` (the one with the `tg68k_030` tests + the PR branch).

## Mission (one sentence)
Determine, **in ModelSim**, whether the bsr.w PR commit **`d21cd6c`** causes **any** test
verdict to change versus the upstream base **`1196403`** (= `apolkosnik/030_mmu2` HEAD, which is
the PR's merge-base). If a single test goes **pass→fail** from base→PR, the PR has a real
regression. If the verdicts are identical, the PR is clean and the failing tests are pre-existing.

> This was already run on a Mac with **ghdl** and came back "identical / pre-existing." The
> maintainer disputes it because they run **ModelSim**. So this handoff re-runs the *exact same
> A/B* in ModelSim to confirm or refute the ghdl result. The deliverable is the **base-vs-PR
> diff**, not absolute pass counts — ghdl and ModelSim may differ in absolute numbers, but the
> *delta* between base and PR is the falsifiable claim.

## Ground facts (already verified with git — re-verify if you like)
- `git diff 1196403 d21cd6c --stat` → **one file**, `rtl/tg68k/TG68KdotC_Kernel.vhd`, +32/-3.
- `git diff 1196403 d21cd6c -- rtl/tg68k/TG68KdotC_Kernel.vhd | grep -E '^[+-].*(entity|port\(|: *(in|out|buffer) )'`
  → **empty**: the PR adds/removes **no ports**. It is pure microcode (bsr.w/bsr.l PMMU-stall fix:
  three changes — `set(presub)` relocation, and two holds gated on `pmmu_busy='1' AND state(1)='1'`).
- `merge-base(d21cd6c, apolkosnik/030_mmu2)` = `1196403`. Our branch = base + only `d21cd6c`.

## ghdl reference results (cross-check ModelSim against these)
| testbench | ghdl result (base AND PR — identical) |
|---|---|
| `tb_mmu_translation` | **22 tests, 21 passed, 1 failed** — TEST 6 "PTEST W valid page: MMUSR has no fault bits" FAILS (MMUSR read back `0x02034E71`, note `$4E71`=NOP). Same on base & PR. |
| `tb_branch_odd_addr` | 14/14 PASS incl "A4: BSR.W to odd address" |
| 16 PMMU/MMU testbenches | raw output **byte-identical** base vs PR |
| `tb_div_rtr_frame_probe` | 4 FAIL (pre-existing, base & PR) |
| `tb_addr_error_pmmu_data` | 1 FAIL (pre-existing, base & PR) |
| `tb_bug95_pmove_dn`, `tb_bug95_pmove_ea_pc`, `tb_bug97_d0_corruption` | **COMPILE ERROR** — reference ports `cache_cinv_req`/`cache_cpush_req` the kernel does not declare (it has `cache_inv_req`, no cpush). Pre-existing since test-import commit `49eebc7`. ModelSim will also fail to compile a missing port. |

**Headline expectation to confirm in ModelSim:** `tb_mmu_translation` fails **TEST 6 on BOTH**
`1196403` and `d21cd6c`. That is "the mmu translations" the maintainer flagged.

---

## Step 1 — Locate ModelSim (Windows)
ModelSim-Intel Starter usually lives at `C:\intelFPGA_lite\<ver>\modelsim_ase\win32aloem\`
(binaries `vlib.exe vmap.exe vcom.exe vsim.exe`). Confirm:
```
where vsim
# or
dir "C:\intelFPGA_lite\*\modelsim_ase\win32aloem\vsim.exe"
```
Add that `win32aloem` dir to PATH for the session, or call binaries by full path. Use a shell you
like (cmd, PowerShell, or Git Bash). `cd` into `tests/tg68k_030` inside the Minimig repo.

## Step 2 — The decisive single test (do this first)
Create `ab_one.do` in `tests/tg68k_030/` (compiles RTL + one tb, runs it, bounded):
```tcl
# ab_one.do — compile RTL + tb_mmu_translation, run, print summary
vlib work
vmap work work
vcom -93 -quiet ../../rtl/tg68k/TG68K_Pack.vhd
vcom -93 -quiet ../../rtl/tg68k/TG68K_ALU.vhd
vcom -93 -quiet ../../rtl/tg68k/TG68K_PMMU_030.vhd
vcom -93 -quiet ../../rtl/tg68k/TG68K_Cache_030.vhd
vcom -93 -quiet ../../rtl/tg68k/TG68KdotC_Kernel.vhd
vcom -93 -quiet tb_mmu_translation.vhd
vsim -c work.tb_mmu_translation
run 30 ms
quit -f
```
Run it at **base** and at **PR**, capturing each transcript:
```
git checkout 1196403
rm -rf work
vsim -c -do ab_one.do > /tmp/mt_base.txt 2>&1        # (use a real path on Windows, e.g. %TEMP%\mt_base.txt)

git checkout d21cd6c
rm -rf work
vsim -c -do ab_one.do > /tmp/mt_pr.txt 2>&1

git checkout -    # back to the PR branch
```
Compare the verdict lines:
```
grep -E "TOTAL:|TEST 6:|MMU TESTS FAILED" /tmp/mt_base.txt
grep -E "TOTAL:|TEST 6:|MMU TESTS FAILED" /tmp/mt_pr.txt
```
**Decision:**
- If both show `TOTAL: 22 tests, 21 passed, 1 failed` and TEST 6 FAILED → **PR is clean; TEST 6 is
  pre-existing.** (Matches ghdl. Case closed for MMU translation.)
- If base shows TEST 6 **passed** and PR shows it **failed** → **real regression**; capture both
  full transcripts and report — the bsr.w change must be revised.

## Step 3 — The full comprehensive A/B (what `make` runs)
Reproduce the maintainer's actual command at both commits and diff. The Makefile assumes Linux
paths (`$(MODELSIM_PATH)/linuxaloem/...`); on Windows override the tool vars:
```
MS=C:/intelFPGA_lite/17.0/modelsim_ase     # adjust version/path
git checkout 1196403 && make -C tests/tg68k_030 \
    MODELSIM_PATH=$MS VSIM=$MS/win32aloem/vsim VCOM=$MS/win32aloem/vcom VLIB=$MS/win32aloem/vlib \
    2>&1 | tee /tmp/suite_base.txt
git checkout d21cd6c  && make -C tests/tg68k_030 \
    MODELSIM_PATH=$MS VSIM=$MS/win32aloem/vsim VCOM=$MS/win32aloem/vcom VLIB=$MS/win32aloem/vlib \
    2>&1 | tee /tmp/suite_pr.txt
git checkout -
# Diff the verdicts (ignore timestamps/paths):
diff <(grep -iE 'PASS|FAIL|TOTAL|tests,' /tmp/suite_base.txt) \
     <(grep -iE 'PASS|FAIL|TOTAL|tests,' /tmp/suite_pr.txt)
```
(If `make` won't cooperate on Windows, fall back to a per-test `.do` like Step 2, looping the
testbench list. The point is identical: **same tests, two commits, diff the verdicts.**)

## Step 4 — Report back
Produce a short table: `testbench | base verdict | PR verdict | same?`. Then state plainly:
1. **Did ANY test flip pass→fail base→PR?** (yes = regression, list it; no = PR clean)
2. Confirm whether `tb_mmu_translation` TEST 6 fails on **base** (expected: yes).
3. Confirm the 3 `cache_cinv_req` testbenches fail to **compile** on base too (expected: yes).
4. Note any place ModelSim disagrees with the ghdl reference table above (interesting either way).

## Gotchas
- **`vcom -93`** is what `run_tests.do` uses and is correct for ModelSim (it's more lenient than
  ghdl's `--std=93`; no need for `--mb-comments`/`--std=08` tricks here — those were ghdl-only).
- Some testbenches don't self-terminate; use a **bounded** `run 30 ms` (not `run -all`) to avoid
  hangs, exactly as the Makefile's `run_test` proc does.
- `rm -rf work` (delete the ModelSim `work` lib) between the base and PR compiles so stale
  compiled units don't leak across the A/B.
- `git checkout 1196403` detaches HEAD — that's fine; `git checkout -` returns to the PR branch.
  `git stash` first if the tree is dirty.

## TL;DR of the claim being tested
> The bsr.w PR (`d21cd6c`) is a microcode-only kernel change (no ports). Run `tb_mmu_translation`
> (and the whole suite) at `1196403` and at `d21cd6c`: the pass/fail set is **identical**. The MMU
> translation failure (TEST 6, PTEST→MMUSR `0x..4E71`) and the `cache_cinv_req` compile errors are
> **pre-existing on the base**. If ModelSim shows otherwise, capture it and we fix it.
