# RESUME — 7.1 bomb is a WILD JUMP to $24, NOT the continue-past bug (2026-07-02)

Read cold to continue. This CORRECTS the prior session's diagnosis mid-flight.

## ★ ONE-LINE
System 7.1 bombs with **"bad F-Line instruction"** because the CPU **jumps to a
garbage low address ($24) and runs the exception vector table as code up to $100**
where the bytes are `$FFFF` (F-line) → the OS F-line handler catches it and draws
the bomb. The prior session's "Format-$B continue-past" fix (v3/v4) is a REAL and
validated correctness fix but **does NOT unblock 7.1** — HW proved the fatal event
is the wild jump, which is still undiagnosed. Re-aim here.

## ★★ THE REFRAME (what HW just proved — trust this over the older docs)
Deployed **v4** (`releases/MacLCii_flineFix_v4_20260702.rbf`, md5 `5953ba4d`) and
cold-booted 7.1. Result = **IDENTICAL bomb signature to the pre-fix build**:
- `PFLx F-line trap: count=1  pc=00000100 op=FFFF ctx=0`
- `PFJM fetch-hist frozen=1` → **fetch history (oldest→newest): F2 F4 F6 F8 FA FC FE 100**, and **last jump: src=0040C2 → tgt=000024**.
- `PEXC last fatal: IF=A0DBFC vec=2 (BUSERR) fires(wrap16)=5`, **PACT ADVANCING**.

Two deductions:
1. **`fires=5` + PACT advancing = only 5 bus errors, NOT a storm.** The validator
   BERRs at `$A0DBFC` are being HANDLED and the CPU moves on. So the continue-past
   path is (at least mostly) WORKING on hardware — the earlier "1009-fault storm"
   was an artifact of berr_bench's synthetic back-to-back probe loop, not the real
   ROM's spacing. **Continue-past was a real bug but is NOT the fatal one here.**
2. **The fatal event is the jump `$40C2 → $24`.** `$24`–`$100` is the 68k exception
   VECTOR TABLE (vectors 9–64). tgt=$24 is a *code* fetch (my ring only records
   FC=2'b10 IFs), so the CPU is genuinely EXECUTING at $24 — it jumped to a garbage
   low address and ran the vector table as instructions until `$FFFF` at $100.

⇒ **Something computed/dispatched to the bad target $24.** Find THAT.

## ★★ WHAT v4 IS (keep it — validated — but it is not the fix)
Root (real, but non-fatal here): 68030 Format-$B continue-past resume PC was wrong
for two-word opcodes. v2/v3 reconstructed length from EA mode; `btst #$6,(A0)` =
`$0810 $0006` (4 bytes, EA mode 010) → v3 stacked +2 → resumed on the immediate
word. **v4** (`rtl/tg68k/TG68KdotC_Kernel.vhd`): capture prefetch pointer `TG68_PC`
at external-BERR first-fire (`berr_capture_nextpc`), resume = `berr_capture_nextpc
- 2` (measured = next-instr+2 for all validator read forms). Proven in
`verilator/berr_bench/` (5/5 forms) + ksw_bench + pmmu_bench all PASS. **Leave v4
in** (it's correct and may matter downstream); just don't expect it to fix 7.1.

## ★★★ NEXT STEP — MAME diff on $40C2, then an improved fetch ring
MAME `maclc2` boots 7.1 to the desktop, so it is the oracle for the healthy path.

**A. Mine the MAME trace (FAST, do this first — no build):**
The full-boot maincpu trace is at `scratch/m71_trace.tr.gz` (38 MB gz, 8-digit PCs,
format `PC: disasm`). Already found: **`40C2:` appears 659× as a PC** (so `$xx40C2`
is executed in the HEALTHY boot too — the low 24 bits match our HW `src=$0040C2`;
get the full 8-digit PC to learn if it's RAM or a ROM alias). Do:
```bash
wsl bash -lc "zcat scratch/m71_trace.tr.gz | grep -nE '40C2:' | head -20"     # full PCs + disasm at $40C2
wsl bash -lc "zcat scratch/m71_trace.tr.gz | grep -A6 '40C2:' | head -60"      # where MAME goes AFTER $40C2 (NOT $24 if healthy)
wsl bash -lc "zcat scratch/m71_trace.tr.gz | grep -cE '^........24: '"          # does MAME EVER execute at $..0024? (expect ~0)
```
The instruction at `$40C2` and MAME's *next* PC after it is the ground truth. Our
core jumps to `$24`; MAME goes somewhere real. The divergence names the bug: a
wrong branch/jmp target, a bad handle from a mis-verdicted validator, or a bad
dispatch. (NOTE: `$40C2` is almost certainly a ROM address — either overlay-on
`$0040C2` or ROM-alias `$40A040C2`/`$00A040C2` truncated to 24b — so it IS
statically disassemblable, unlike RAM. Confirm via MAME's full PC.)

**B. Improve the fetch ring (one FPGA build) to catch the JUMP, not the aftermath:**
Current ring (`MacLC.sv` PFH0-7/PFJ) freezes on the F-line at $100, so its 8 slots
already got overwritten by the $24→$100 vector-table run — it can't show what led
to `$40C2` or the faulting instruction. Change it to:
  - freeze on the **first jump into the vector table** (`tgt < $400` while
    `cpuFC==2'b10`), NOT on the F-line;
  - capture **full address incl. `cpuAddrFullHi`** (not just cpuAddr[23:0]) so
    ROM-alias vs RAM vs overlay is unambiguous;
  - capture the **IF opcode word** alongside each address (reuse the PIFD pair
    tap) so the jumper at `$40C2` is directly visible without disasm guessing;
  - keep it 8-16 deep. Then `read_probes.sh` shows the exact instruction that
    jumped to $24 and the ~8 instructions before it.

**C. Discriminate the two hypotheses with A+B:**
- **H1 (prime suspect): a validator returns a WRONG verdict → a handle/pointer
  gets a garbage value (~$24) → a later `jmp (An)`/`rts` wild-jumps.** This is
  DOWNSTREAM of continue-past: the `$A0DB6A` validator family does
  `tst.b (A0); beq` and `btst #$6,(A0); beq`. v4 fixes their RESUME PC but the
  `rte_mmu_fix` writeback still does NOT set **CCR from the DIB** for TST/BTST
  (only MOVE/MOVEA→Dn/An get a writeback). So after a continued-past `tst.b`/`btst`
  the Z/N flags are STALE → the `beq` branches wrong → wrong verdict → bad handle →
  wild jump. **If MAME's $40C2 path shows a validator verdict our core gets wrong,
  extend `rte_mmu_fix` to set CCR-from-DIB for TST/BTST — that is the likely fix.**
  (berr_bench currently checks only resume-PC via markers; ADD a CCR/Z-flag check
  to a tst.b probe to reproduce H1 in sim before building.)
- **H2: unrelated** — bad jump table / PMMU mistranslation of a jump target /
  corrupted dispatch. Less likely (6.0.8 works, high RAM proven sound) but keep
  open until the $40C2 instruction is known.

## STATE OF HW / TREE / TOOLING
- **MiSTer:** freshly POWER-CYCLED by the user (the prior box had wedged — pings,
  SSH/HTTP dead). Now up (uptime was ~1 min at 06:56), running v4 (`5953ba4d`) from
  `/media/fat/_Unstable/MacLCii.rbf`, 10 MB (`CFG` byte0=`08`), 7.1 mounted
  (`.s0` = `games/MacLCii/MacLC_7-1.hda`), currently displaying the F-line bomb.
  HTTP API port 8182 + SSH back. Reboot freely; the tripwire is RAPID JTAG, not
  reboot count. Re-run hygiene (`refresh_disks.sh` + `cp MacLCii.nvr.bak
  MacLCii.nvr`) before every cold boot.
- **Working tree (branch `video-performance`, HEAD `0d2723f`), UNCOMMITTED:**
  - `rtl/tg68k/TG68KdotC_Kernel.vhd` (+ regenerated `.v` and `TG68K_Cache_030.v`) —
    the v4 continue-past fix + the F-line debug output ports.
  - `MacLC.sv` + `rtl/tg68k/tg68k.v` — F-line capture (PFLA-E) + fetch-ring
    (PFH0-7/PFJS/PFJT/PFJM) probes; the tg68k F-line trap latch.
  - `scripts/cpu_state.tcl` — PFLx + PFHx/PFJx decode.
  - `verilator/berr_bench/` (NEW) — the continue-past regression harness (5 probe
    forms; v4 PASS, v3 FAILs btst). Keep.
  - Commit v4 only AFTER it earns its keep OR as a labeled "correctness, not the
    7.1 fix" commit; the user builds/commits per their workflow.
- **Builds:** `releases/MacLCii_flineFix_v4_20260702.rbf` = `5953ba4d` (deployed,
  STA all-positive incl HDMI +0.025). `output_files/MacLCii.rbf` = same.
- **berr_bench:** `cd verilator/berr_bench && make && ./obj_dir/Vberr_top` (`-v`
  for frame dump). Byte-exact ROM handlers $A0DB50 (DIB=0) / $A0DB5C (DIB=-1).

## TOOLING GOTCHAS (verified this session)
- **MAME oracle (WSL):** `verilator/mame/mame_headless.sh <disk.hd> 10M <snap> <out>`
  for screenshots; for a maincpu trace use `-debug -debugscript
  verilator/mame/fline_trace.dbg` (a `dasm <file>,<addr>,<len>` command works
  headless for static ROM disasm). ALWAYS the headless flags (`-skip_gameinfo
  -video none -sound none`); a `quit` at script end can segfault — end with `go` +
  `-seconds_to_run`. MAME m68k disasm names PMOVE group-000 regs by 68851
  convention and renders PFLUSHA as "pflushr" — check raw ext words.
- **WSL2 idle-kills** nohup jobs + wipes /tmp ~60s after the last wsl.exe client
  exits — run long WSL jobs as TRACKED background Bash calls; persist to /mnt/c.
  The 38MB `scratch/m71_trace.tr.gz` survives; re-gen with `fline_trace.dbg` (~7min)
  if gone.
- **PFLx clears on CPU reset** → a bomb-then-reset boot reads PFLx=0; corroborate
  with the PFJ fetch-ring (freezes on F-line) + PEXC + a fresh screenshot.
- **Probe read:** `bash scripts/read_probes.sh` (single, spaced — NO rapid loops).
- **Deploy:** `source scripts/local.env && python tools/misterdeploy/
  launch_unstable_core.py --push <rbf> --core MacLCii.rbf --delay 0.12`; confirm
  `coreRunning='MacLCii'` + `md5sum /media/fat/_Unstable/MacLCii.rbf`. The launcher
  can MISS the OSD selection (retry once).
- **FPGA build:** `rm -rf db incremental_db && bash scripts/build.sh` (~29 min,
  tracked background). After a `.vhd` edit, regen the `.v`: `cd rtl/tg68k && sed
  's/\r$//' convert_to_verilog.sh > conv_lf.sh && LD_LIBRARY_PATH=$HOME/ghdllib
  bash conv_lf.sh` (needs the libLLVM shim: `ln -sf
  /lib/x86_64-linux-gnu/libLLVM.so.18.1 ~/ghdllib/libLLVM-18.so.18.1`). Quartus
  compiles the `.vhd`; Verilator the `.v` — regen keeps them in sync. GHDL prunes
  write-only signals, so a bench tap on an unread signal fails to elaborate.

## DO-NOT-RE-CHASE
- **"continue-past storm on HW"** — DISPROVEN: `fires=5` + PACT advancing = handled,
  not storming. berr_bench's 1009-fault storm was synthetic.
- **F-line DECODE / FPU-trap / PMMU-decode strictness** — the bomb is a caught
  wild-jump into $FFFF, not a mis-decoded real F-line op. cp-id/vector-11 dispatch
  is fine.
- **SDRAM high-RAM / mb_hi** — 6.0.8 desktops at 10 MB; high RAM is sound.
- **SCSI / video** — fixed + committed; the wedge is pure CPU control-flow.

## RELEVANT MEMORY
[[maclcii-fline-continue-past-root]] (v4 fix — UPDATE it: continue-past is correct
but NOT the 7.1 bomb; fatal = wild jump to $24) · [[maclcii-mister-hardware-access]]
· [[maclcii-pmmu-sim-harnesses]] · [[timing-bugs-use-hw-not-ideal-sim]] ·
[[prefers-autonomous-driving]].
