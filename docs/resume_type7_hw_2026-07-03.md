# RESUME — 7.1 "type 7 / bad F-Line" Finder-launch bomb: FIXED IN SIM (v9), NEXT = HW VALIDATION (2026-07-03 evening)

Read cold to continue. The multi-day type-7 chase is DONE in simulation: root
cause captured cycle-exact, one-condition fix applied, full 7.1 sim boot runs
clean past Finder launch to F2500. Committed on branch `video-performance`.
**The ONLY remaining step is hardware validation on the MiSTer — and the user
explicitly gated it: DO NOT deploy until they say go.** (2026-07-03 ~08:00:
"hold off on deploying to mister for now, let me know when you are ready" —
they were told "ready" at ~16:30 and answered with "commit + resume prompt",
which is still NOT a deploy go.)

## THE BUG (one paragraph, for context)
When an instruction FETCH into an ATC-cold page starts a PMMU table walk, the
kernel's address-datapath registers (use_base / memaddr_delta_rega/b) kept
recomputing on clkena_in edges mid-walk (the June hold covered only DATA
walks, state(1)='1'). Observed in the PCRING capture: addr collapses to
0-4 = $FFFFFFFC two ticks into the walk of the $378000 prefetch (first word
of a cold 32K page at Finder launch, ATC freshly flushed by the MMU-mode-swap
storm). The walker translates the CORRECT original address, but the post-walk
REPLAYED fetch issues at the corrupted one → open-bus garbage enters the
decode stream as "the fetched word" → $FFFF-class garbage = F-line bomb (sim)
/ other garbage = privileged op = "error type 7" (HW). Same root, two surface
vectors. TG68_PC stayed correct the whole time (v7 gates fine). Full story +
the two disproven theories (v8 "torn return", "fall-through") and the trace
GHOST misreads that caused them: `docs/findings_type7_sim_2026-07-03.md`.

## THE FIX (v9, committed)
`rtl/tg68k/TG68KdotC_Kernel.vhd` ~:3131 — widen the June PMMU-stall address
hold from `pmmu_busy='1' AND state(1)='1'` to
`pmmu_busy='1' AND (state="00" OR state(1)='1')` (mirrors the memmask hold at
~:3455 which was already widened to "any access" in June). The v8
`pmmu_busy='0'` gates on exec(directPC)/exec(ea_to_pc) (~:3480) are inert for
this bug but kept as hardening. `.v` regenerated via the conv_lf.sh flow.

## VALIDATION STATE
- ✅ berr_bench / ksw_bench / pmmu_bench: PASS on v9 (note: these benches
  CANNOT repro this bug class — their stall model freezes clkena_in for the
  whole walk; the full Vemu boot is the only arbiter for walk-interleave).
- ✅ Full 7.1 sim boot (verilator/sim_v9.log): F2500, ZERO [EXC], ZERO
  [PCRING] dumps, Finder desktop at F1800/2000/2400.
  PASS shot: `scratch/desktop_f1800_v9_2026-07-03.png`;
  FAIL ref (pre-fix bomb): `scratch/bomb_f1800_excrun_2026-07-03.png`.
- ✅ v9 RBF: `output_files/MacLCii.rbf` (2026-07-03 16:01). STA: core domains
  clean (emu|pll +0.477/+2.030); pll_hdmi −0.355 = framework-domain fit noise,
  same class as every recent build (running v7 had −0.523).
- ⬜ **HW validation — WAITING ON USER GO.**

## HW VALIDATION STEPS (when the user says go)
1. **Power-cycle the MiSTer first** (192.168.99.143, scripts/local.env). It
   sits WEDGED at the v7 type-7 bomb; JTAG is dead in that state.
2. Deploy: `launch_unstable_core.py --push ./output_files/MacLCii.rbf
   --core MacLCii.rbf --delay 0.12`; confirm coreRunning='MacLCii' + md5.
3. Hygiene: `refresh_disks.sh`; restore PRAM `cp MacLCii.nvr.bak MacLCii.nvr`
   (see [[maclcii-mister-hardware-access]] + [[maclcii-disk-corruption-from-hard-restarts]]).
4. Cold-boot 7.1 (boot disk at SCSI ID 0). PASS = Finder desktop on the HDMI
   screenshot, no "type 7". (Boot is slow — gray phases = loading, not stalls.)
5. If HW PASSES: update memory ([[maclcii-fline-continue-past-root]] → mark
   HW-CONFIRMED), copy the RBF to releases/ if that's the flow, and consider
   the follow-ups below.
6. If HW FAILS with a NEW signature: the sim fix is still right (deterministic
   sim proof); suspect timing/fit — check STA, rebuild (fit lottery), and
   compare the failure vector against the old type-7 (a DIFFERENT crash =
   progress, likely the next family member — see follow-up #1).

## COMMITTED (2026-07-03, branch video-performance)
- `c2f3505` fpga: the .vhd fix (v9 + v8 gates) + regenerated Kernel.v.
- the dbg+docs commit right after it (this file's own commit — hash not
  self-referenced): [EXC]/PCRING instrumentation (sim_main.cpp,
  tg68k_debug.vlt), CLAUDE.md sim-flags/CWD section, findings + resume docs,
  rtl/tg68k/conv_lf.sh (canonical regen), .gitignore (GHDL artifacts).
- NOT committed (deliberate): verilator/mame/roms* (ROM images), sim755run/
  (run junk), cr_ie_info.json (unknown tool artifact), scratch/ (ignored).

## FOLLOW-UPS (post-HW, in value order)
1. **Audit ALL clkena_in-domain registered assignments in the kernel for walk
   exposure.** Three confirmed members of this family so far (data-addr hold
   June, memmask hold June-pt2 + this fetch widening, TG68_PC brw gate v7).
   The pattern is systemic: clkena_in fires during walks, clkena_lw doesn't,
   and any clkena_in-domain register that samples decode-derived values can
   tear at walk boundaries. grep the `IF clkena_in='1'` blocks and check each
   register against "held or walk-safe".
2. Remove the INERT v7 "fix #2" dead code (data_write_tmp hold inside the
   clkena_lw block at ~:2557 — pmmu_busy≡0 there) at the next kernel edit.
3. 7.5.5: separate pre-existing hang at menu-bar draw (~F2500 in the control
   run, sim_run755_postfix.log) — parked, do not conflate with type-7.
4. PCRING/[EXC] instrumentation: leave compiled in (frame/site-gated, zero
   cost when healthy) — it is the proven tool for this bug class.

## GOTCHAS (all bit this investigation — do not relearn)
- **cpu_trace.log logs PREFETCH GHOSTS** (post-redirect PC+2 lines that never
  executed). It caused BOTH wrong theories (run#3 "returned correctly" and
  the $E3FFFC dismissal). Never conclude execution from a trace line without
  checking the next real line; PCRING/waveform-level taps are the truth.
- Benches freeze clkena_in during walks → walk-interleave bugs NEVER repro
  there; benches are regression-only for this class.
- opcode_pc in a trap frame can be MIS-BOOKED (+4 here) when the fault window
  itself slipped the PC accounting — the handler's "faulting opcode" readback
  can point at an innocent word ($FD48 was the jsr displacement, red herring).
- wsl.exe mangles inline `$()`/quotes — ALWAYS `tr -d '\r' < scratch/X.sh >
  ~/X.sh && bash ~/X.sh`. nohup dies with wsl.exe — tracked background Bash
  calls only. Long sims: fresh disk COPY per run, CWD with `../rtl/egret/`.
- Quartus compiles the .vhd directly; the .v is Verilator-only. After ANY
  .vhd edit: regen (conv_lf.sh flow — NOT scripts/regen_tg68k.sh, it predates
  the PMMU retrofit) + `make` in verilator/ (re-verilate, ~15 min).

## RELEVANT MEMORY
[[maclcii-fline-continue-past-root]] (the whole saga; update on HW verdict) ·
[[maclcii-mister-hardware-access]] (deploy/screenshot loops) ·
[[maclcii-pmmu-sim-harnesses]] · [[prefers-autonomous-driving]] ·
[[timing-bugs-use-hw-not-ideal-sim]] (note: this bug INVERTED the rule — a
zero-latency-sim-reproducible LOGIC bug that looked timing-flaky on HW).
