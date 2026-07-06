# RESUME — CPU (TG68K/68030) open issues, post-pseudo-VIA fix (2026-07-06 ~06:30)

Read cold to continue CPU-side work. Context: the 7.5.5 menu-bar wedge turned
out to be a PERIPHERAL bug (pseudo-VIA slot-interrupt starvation — fixed in
`ddad62a`, full story in `docs/findings_755_slot_dispatch_2026-07-06.md`),
NOT a CPU bug. This doc collects every OPEN CPU-related thread so a session
can pick them up without re-deriving. The CPU kernel is
`rtl/tg68k/TG68KdotC_Kernel.vhd` (SOURCE OF TRUTH — Quartus compiles it);
`TG68KdotC_Kernel.v` is GHDL-generated for Verilator only.

## STATE (what is DONE and validated in sim)
- **v9 walk-hold fix** (commit `c2f3505`): instruction-fetch PMMU-walk
  address-datapath hold. 7.1 boots to a stable Finder desktop in sim —
  re-validated on the macOS toolchain 2026-07-06 (F1800/F2400 desktop, zero
  [EXC], both pre- and post-pseudo-VIA rewrite).
- **Walk-exposure audit of all 11 `clkena_in='1'` kernel blocks** done:
  `docs/audit_clkena_walk_2026-07-05.md`. No proven un-gated register left.
- Benches (berr/ksw/pmmu) all PASS on macOS, on BOTH the committed kernel
  .v and a GHDL 6.0.0 regen (`scratch/*.ghdl6`, NOT committed).

## OPEN CPU THREADS (priority order)

### 1. v9 fix HW validation — BLOCKED on the MiSTer being down
The only remaining step for the 7.1 type-7/F-line saga. When the user
revives the box: power-cycle first (it sits wedged at the old v7 bomb),
deploy per `docs/resume_type7_hw_2026-07-03.md` steps, cold-boot 7.1,
expect Finder desktop with no "type 7". **Explicit user gate on deploys
still stands.** NOTE: `output_files/` is NOT in this Mac checkout — the v9
RBF lives on the old Windows box, or needs a fresh Quartus build there
(Quartus cannot run on this Mac). The NEW pseudo-VIA rewrite also needs an
FPGA build + Quartus-clean check (single always-block per reg — the rewrite
follows that rule; watch Error 10028 anyway) before any combined deploy.

### 2. Audit residual candidate #1: `last_data_read`/`last_data_in`
mid-fetch-walk pollution (Kernel.vhd ~:1738). Both latch on every
`clkena_in` edge during an instruction-FETCH walk (`state="00"` is true),
shifting table-walk DESCRIPTOR data through them mid-walk. Consumers are
lw-gated or walk-exit-aligned, and 7.1/7.5.5 boot clean — so NO evidence of
harm — but the walk-exit edge alignment is unproven for the data path
(the v9 capture proved only the ADDRESS path). **Symptom signature if this
ever bites: a wrong LOADED VALUE (not a wrong address/PC)** — e.g. a
branch-displacement or operand that is table-descriptor-shaped. Candidate
fix shape: qualify both latches with `pmmu_busy='0'` (mirror the June
holds); MUST re-run berr/ksw/pmmu benches + BOTH OS boots after (this
touches every memory read).

### 3. Audit residual candidate #2: `rte_format_word` (~:1767)
Latches `data_in` on clkena_in edges while `micro_state=rte3→rte4`; if the
format-word stack read itself walks, mid-walk edges latch descriptor bytes
and only the final walk-exit latch makes it sane. Symptom signature:
spurious Format Errors / wrong RTE unwind (a bomb, not a wedge). No
evidence it misbehaves; heavy RTE traffic in both boots is clean.

### 4. Dead code cleanup at next kernel edit
The inert v7 "fix #2" (`data_write_tmp` hold inside a `clkena_lw`-gated
block at ~:2557 where `pmmu_busy≡0`) — remove when the kernel is next
edited for real work; do NOT do a churn-only edit (every .vhd edit forces
the GHDL regen + full revalidation cycle).

### 5. GHDL regen path — validated bench-clean, NOT boot-validated
`rtl/tg68k/conv_lf.sh` works on this Mac (GHDL 6.0.0, ~2 min) and its
output passes all three benches, BUT it generates a structurally different
.v (116,544 lines vs the committed WSL-era 131,589) — textual diff is
total. Before the FIRST kernel .vhd edit on this machine, do a one-time
A/B: build the sim with the UNMODIFIED-source GHDL-6 regen
(`scratch/TG68KdotC_Kernel.v.ghdl6` + `TG68K_Cache_030.v.ghdl6`) and
heartbeat-diff a boot (F0-F400 suffices; expect identical [HB] PCs) against
the committed kernel. If identical, the regen flow is fully trusted and
future .vhd edits are cheap. Keep the committed .v in tree until then.

### 6. HW-side 7.5.5 wedge ($A0DE04 MemMgr free-walk) — REFRAMED, retest first
The 2026-07-01 HW capture (CPU spinning in the ROM free-block-coalesce loop
on a zero block header, high RAM) was previously theorized as a
32-bit/PMMU CPU bug (`docs/resume_755_desktop_32bit_pmmu_2026-07-01.md`).
The sim investigation now points the other way: the pseudo-VIA slot-dispatch
starvation existed on HW builds too (same RTL), and a starved/storming
interrupt path at Finder launch plausibly corrupts launch-time heap writes
→ the free-walk wedge is DOWNSTREAM damage, not a CPU bug. **Do not chase
the CPU angle until 7.5.5 has been retested ON HW with the pseudo-VIA
rewrite in the build.** If HW still wedges at $A0DE04 with the new
pseudo-VIA while sim boots clean, THEN the CPU/PMMU/SDRAM angle reopens —
discriminator: sim vs HW divergence with identical RTL = timing/analog
(SDRAM walk-read class, see `docs/resume_walk_sdram_timing_2026-06-25.md`),
not logic.

## IN FLIGHT AT WRITING (sim, this Mac)
- 7.5.5 cure test on the pseudo-VIA rewrite: `sim755fix/sim755_pfix.log`,
  ~F1900 of 3500; menu-bar verdict window ~F2600; screenshots
  2000/2600/3000/3400. PASS = Finder desktop (goal-state reference:
  `scratch/mamesnap755_4m/maclc2/f0000.png`). On PASS: append to findings
  doc + update [[task list]] + commit; consider this campaign's sim side
  COMPLETE. On FAIL: the fix is necessary-but-insufficient — next lead is
  the forensic trace `sim755run2/cpu_trace.log` (203 MB, F2500-2820,
  wedge formation captured; grep the $A06EAA/$A06ECA/$A06EEC loop and the
  slot-queue element addresses it walks).
- 7.1 regression on the rewrite: PASSED (desktop F1800, zero [EXC]) — done.

## TOOLING NOTES FOR CPU WORK ON THIS MACHINE
- Benches: `cd verilator/<berr|ksw|pmmu>_bench && make -j4 && ./obj_dir/V*`.
  Remember they CANNOT repro walk-interleave bugs (frozen-clkena model) —
  full Vemu boots are the arbiter for that class.
- Sim rebuild after kernel .v change: `cd verilator && make -j8` (~3 min).
  Any NEW rootp-> signal tap needs a `public_flat_rd` line in
  `verilator/tg68k_debug.vlt` FIRST (no-trace build, see CLAUDE.md).
- Bounded forensics: `--trace-frames A,B` + `--screenshot` at suspect
  frames; ~0.7 MB/frame of cpu_trace. [EXC]/PCRING instrumentation is
  compiled in and frame-gated (arms F>=1600).
- MAME oracle (maclc2, 4M or 10M) is set up and fast — romset at
  `verilator/mame/roms/`, wrapper `verilator/mame/mame_headless.sh`,
  register watch `verilator/mame/pvia_watch.lua`. Gotchas (headless
  debugger printf discarded; Lua taps blind to FETCHES — tap data reads
  instead) are in the findings doc + memory.
- cpu_trace `@xxxx` column lags one line; prefetch ghosts still apply
  (see `docs/resume_type7_hw_2026-07-03.md` gotchas — do not conclude
  execution from a lone trace line).

## RELEVANT MEMORY / DOCS
`docs/findings_755_slot_dispatch_2026-07-06.md` (the peripheral fix) ·
`docs/audit_clkena_walk_2026-07-05.md` (candidates #2/#3 detail) ·
`docs/resume_type7_hw_2026-07-03.md` (v9 saga + HW steps) ·
`docs/resume_755_sim_campaign_2026-07-05.md` (campaign context) ·
memory: [[maclcii-macos-sim-environment]], [[maclcii-sim-build-no-trace-rule]],
[[maclcii-mame-oracle-macos]], [[mister-hardware-down-2026-07]],
[[prefers-autonomous-driving]].
