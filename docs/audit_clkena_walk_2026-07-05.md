# AUDIT — clkena_in-domain kernel registers vs PMMU-walk exposure (2026-07-05)

Executes follow-up #1 from `resume_type7_hw_2026-07-03.md`: after three
confirmed members of the walk-tear family (data-addr hold June, memmask hold +
v9 fetch widening, TG68_PC brw v7 / directPC+ea_to_pc v8), audit every
`IF clkena_in='1'` registered assignment in `TG68KdotC_Kernel.vhd` for
"held or walk-safe". Context: clkena_in keeps firing during PMMU walks;
clkena_lw freezes (`clkena_lw = clkena_in AND memmaskmux(3) AND NOT
pmmu_busy`, :1575). Any clkena_in-domain register that samples decode- or
bus-derived values can tear at walk boundaries.

There are 11 `clkena_in='1'` sites. Verdict per block:

| line | registers | verdict |
|---|---|---|
| :1584 | syncReset/Reset | SAFE — reset synchronizer, no decode/bus inputs |
| :1738 | `last_data_read`, `last_data_in` | ⚠ **CANDIDATE #1** (see below) |
| :1767 | `rte_format_word` | ⚠ CANDIDATE #2 (see below) |
| :2733 | `trap_vector`, `trap_vector_latched` | SAFE-ish — all trap_* inputs are lw-domain registers, stable mid-walk; deliberate clkena_in per BUG comment (format-error fix) |
| :2847 | `use_base`, `memaddr_delta_rega/b`, `tmp_TG68_PC`, `memaddr` | HELD — v9 hold at :3131 terminates the chain (last-assignment-wins) for state="00" OR state(1)='1'; `memaddr <= addr` after it re-latches a frozen value (addr inputs all held; reg_QA stable because regfile is lw-gated) |
| :3424 | `TG68_PC` block | GATED — v7 brw arm, v8 directPC/ea_to_pc arms, v9-era `NOT ((state="00" OR state(1)='1') AND pmmu_busy='1')` wrap at :3453, seq-fetch arm gated :3496; `PC_datab` increment arm gated :3205 |
| :9116 | PMOVE plumbing (`pmove_ea_latched`, `pmmu_reg_*_d`) | SAFE — hot spots already lw-guarded (BUG #389 V2); PMOVE-only path, exercised heavily by the working mode-swap routine |
| (9178/9275 are comments; 1575 is the clkena_lw definition) | | |

## CANDIDATE #1 — `last_data_read` / `last_data_in` mid-walk pollution (:1738)

```vhdl
ELSIF clkena_in='1' THEN
    IF state="00" OR exec(update_ld)='1' THEN
        last_data_read <= data_read;          -- fires EVERY edge of a FETCH walk
        ...
    END IF;
    last_data_in <= last_data_in(15 downto 0)&data_in(15 downto 0);  -- unconditional
```

During an instruction-FETCH walk (state="00", pmmu_busy=1) both latches keep
firing while the bus carries walk DESCRIPTORS, so mid-walk their contents are
table-walk garbage. Whether that garbage is ever *consumed*:

- Consumers that commit on lw-domain (ea_data, operands, regfile) are frozen
  through the walk and re-sample after the replayed fetch delivers real data —
  safe IF the walk-exit replay re-latches before the first lw edge (the same
  edge-alignment question the v9 capture answered for the address path — NOT
  yet proven for the data path).
- `TG68_PC_brw` arm consumes `last_data_read` via `PC_datab` (:3210) at its
  pmmu_busy='0' commit edge. A bsr.w whose *displacement/target fetch* walks
  commits the redirect at walk exit using whatever last_data_read holds on
  that edge. 7.1 boots clean to F2500 post-v9, so the common alignment is
  fine; a rarer alignment may not be.
- For DATA reads (state="10"/"11") the `state="00"` arm is false and
  `exec(update_ld)` is decode-driven (lw-frozen), so heap-walk style
  `add.l (a1),d0` loops do NOT pollute last_data_read mid-walk. (Their
  operand path is lw-gated anyway.)

**If a new walk-family bug shows up whose symptom is a WRONG LOADED VALUE
(rather than a wrong address/PC), instrument these two registers first.**
Candidate fix shape (NOT applied — no evidence yet): qualify both latches
with `pmmu_busy='0'`, mirroring the June/memmask holds, and let the walk-exit
replay do the (re-)latch.

## CANDIDATE #2 — `rte_format_word` (:1767)

Latches `data_in` on every clkena_in edge while `micro_state=rte3 AND
next_micro_state=rte4` (micro_state frozen mid-walk). If the format-word
stack read itself walks, mid-walk edges latch descriptor bytes; the value is
only sane if the final latch coincides with the replayed read's true data.
Same alignment question as #1. Consumed at rte4 (lw-domain), so the *final*
value is what matters. A tear here would surface as spurious Format Errors /
wrong RTE unwind — a bomb, not a silent wedge. No evidence yet; leave as
documented residual risk.

## Explicitly re-verified SAFE (matches 2026-07-03 findings)
FlagsSR / SVmode / preSVmode / trap_SR / regfile / data_write_tmp are all in
`clkena_lw`-gated processes — frozen through walks. The walker's own
descriptor datapath (TG68K_PMMU_030) was validated by the June
`findings_pmmu_walk_correct` work and is out of scope here.

## Bottom line
No un-gated register with *proven* walk exposure remains. The two candidates
above are alignment-dependent residual risks with a defined observable
(wrong VALUE vs wrong ADDRESS) — use them as the first suspects if 7.5.5 (or
anything else) presents a data-corruption-shaped walk bug.
