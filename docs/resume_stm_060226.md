# RESUME PROMPT — Mac LC core boots into STM diagnostic instead of desktop (2026-06-02)

You are continuing a deep debugging investigation on the **MacLC_MiSTer** core (MiSTer FPGA
Macintosh LC: TG68K 68020 + V8 ASIC + Egret HC05). **Goal: fix this TODAY.** All work happens in
`verilator/` (fast sim). Read `CLAUDE.md` first for build rules. **Do NOT push.** Branch is
`new-video-on-fix-egret` (local, ahead of `master`).

## TL;DR of the bug (root cause is NARROWED, not yet fixed)
The core no longer hangs in the RAM march (that was fixed — see "Already fixed" below). It now
boots through the entire boot state machine, then **FAILS a power-on self-test (POST)** and jumps
to the ROM's **fatal-error handler**, which runs **STM (the Serial Test Monitor)** to report the
failure over the SCC serial port (`*APPLE*...`). The screen is orange (intermediate VRAM/palette,
not meaningful). **STM / SCC / VIA-Port-A / D7-bit26 are all RED HERRINGS** — STM is just the error
*reporter*. The real bug is **a self-test our hardware fails that MAME passes.**

**Your job:** find which specific self-test/read diverges from MAME, fix the RTL, verify the boot
reaches the healthy "?"-disk desktop instead of STM.

## Repo / branch / commits this session
- Repo: `/Users/dani/repos/MacLC_MiSTer`, branch `new-video-on-fix-egret`.
- `72c5f99` — **THE committed real fix**: phantom-$0-bank RAM-march hang. `ram_configured` latch in
  `rtl/pseudovia.sv` gates `in_motherboard_low` in `rtl/addrDecoder.v` (threaded via
  `addrController_top.v` + `MacLC.sv`). $0 stays unmapped during RAM enumeration (like MAME) so the
  ROM doesn't enumerate a phantom 2MB bank at $0. **Don't break this.**
- `d14e96c`, `c5df35d`, `f9f59df` — sim instrumentation + findings (no RTL).
- Working tree: `rtl/dataController_top.sv` has a doc-only comment change (via_pa_i still `$55`).

## Already FIXED (verified) — don't redo
- Phantom-bank march hang. Descriptor table is now single-entry `[$800000,$200000,$FFFFFFFF]`
  @ `$9FFFEC` (matches MAME), SP=`$807FFC`, march `$800000→$9FFFEC`, `[MARCH] *** DONE` x2.
  Oracles: `[TBLMEM]`, `[RAMCFG]`, `[RAMCFGD]`.

## RULED OUT (do NOT re-investigate)
- **SCC** — STM is only the reporter. `$A499xx` polls SCC ($F04000) just to print `*APPLE*`.
- **VIA1 Port A** — with `via_pa_i=$D4` our VIA6522 returns EXACTLY MAME's `via_in_a()`=$D4
  (reg1/15 read returns `ira`=latched pins, `via6522.sv:437/485`), yet STILL enters STM.
  Reverted to `$55`. `$D4` is the *correct* value (LC has no FPU; MAME `via_in_a()=0xd4|(config&1)`,
  config bit0=FPU=0) — apply `$D4` as part of the eventual fix, but it's insufficient alone.
- **D7 bit26** — clear in both cores (`[TSTB26]` showed D7=$85–$88).
- **68k LC HMMU** — `M68K_HMMU_ENABLE_LC` only masks A31; not the $0 mirror.
- **$FFFF-vs-$0 unmapped reads** — only at F45 bank probe (correct/intended).

## THE EXACT DIVERGENCE (resume here)
Our core runs **all 11 of MAME's boot state-machine handlers identically** (walker `jmp` at
`$A46600` dispatches them): `A46F5A, A4703E, A46EC8, A4713E, A4730C, A473F4, A477D2, A47942,
A47C30, A483FC, A48468` (last = `$A48468` @ F313). Then VRAM march passes (DONE F360), then
post-march code at `$A469xx → $A15432` (peripheral handshake) → at **F414 a POST self-test FAILS**:

```
test-result dispatcher $A46200 (negxl d4; blss <error_entry>)  -- d4 = test-result bitmask
   -> error entry $A46280 (oriw #$0A00,d7)        -- error code ~$0A
   -> bras $A462C0 -> braw $A4638C (bset #24,d7; movel sp,d6; moveaw #$2600,sp)
   -> jmp $A48CDA  -- FATAL handler: $A48CD0 loads magic $87654321; $A48CDA resets SP=$2600,
                       lea $A48CE8,fp; jmp $A467A6 -> $A48CE8 btst #26,d7 (clear) -> falls to
                       $A498A0 = STM monitor -> prints "*APPLE*..." over SCC forever.
```

**Registers at failure (F414), captured by the `[ERR]` probe:**
`D0=$773F  D1=$1A6  D2=$DC000D1F (checksum-like)  D3=$00800000  D4=$FFFFFFFF (test-result mask)
 D6=$8FFFF4  D7=$000D0A02 (→$010D0A02 after bset#24)  A0=$00A03AE4  A1=$00A03BA4`

`A0=$A03AE4` / `A1=$A03BA4` point to a **ROM config/descriptor struct**. `$A03AE4` is the SAME
`D7=3` descriptor entry seen at the very start of boot (`[TBL] #1: A0(start)=$00A03AE4, len $773F`).
So the failing test validates this `$A03AE4`-based structure. `D2=$DC000D1F` is the prime suspect
(a computed checksum that should match a stored value and doesn't → our core read different input
data than MAME).

## NEXT EXPERIMENTS (in order) — to pin the failing test
1. **Trace where `D4` (test-result mask) is built.** `$A46200` dispatcher does `negxl d4; blss`
   per bit. `D4=$FFFFFFFF` at the error — figure out if that's "all tests" or a sentinel, and which
   bit maps to error `$0A` (entry `$A46280`). Look at `$A461xx` (the sub-tests above `$A46200`).
2. **Find what jumps to `$A46280`** (error `$0A`) and the test that produces it.
3. **Trace where `D2=$DC000D1F` is computed** (likely a checksum/CRC loop over the `A0=$A03AE4`
   region or a peripheral). Compare our `D2` vs MAME's `D2` at the same PC.
4. **Get MAME's value at that test** via a lua tap reading the memory the test reads, or a debugger
   breakpoint (target maincpu — see gotchas). If MAME computes a different (passing) value, the
   INPUT data differs → find the divergent read (a peripheral register or a memory location our
   core gets wrong). That divergent read is the bug.
5. **Fix the RTL**, `make clean && make`, verify (below). Likely also apply `via_pa_i=$D4`.

## VERIFICATION CHECKLIST (the fix is done when)
- `cd verilator && make clean && make`
- `./obj_dir/Vemu --no-cpu-trace --screenshot 750 --stop-at-frame 800 2>run.err 1>/dev/null`
- **NO `[ERR]` and NO `[STM_ENTRY]` in run.err.**
- Boot reaches the healthy `$A148xx`/`$A149xx` wait loop (no-disk "?" floppy).
- `screenshot_frame_0750.png` shows grey desktop + blinking "?" floppy (not orange, not black).
- Phantom-bank fix still intact: `[TBLMEM]` single-entry `$800000/$200000`@`$9FFFEC`, SP `$807FFC`.

## TOOLING / WORKFLOW
- **Build:** RTL change ⇒ `cd verilator && make clean && make` (incremental gives FALSE POSITIVES).
  C++-only (`sim_main.cpp`) ⇒ plain `make` OK. Run ONCE, analyze logs (don't re-run repeatedly).
- **Run:** `./obj_dir/Vemu --no-cpu-trace --screenshot 750 --stop-at-frame 800 2>run.err 1>/dev/null`
- **Sim probes already in `sim_main.cpp`** (in the `if (debug_fetch_valid && !ioctl_download)` block,
  `mpc` dispatch ~lines 260–340): `[STATE]` (handler entries via `$A46600`), `[STM_ENTRY]`
  ($A49800-$A499FF), `[ERR]` (fatal handler $A48CD0/$A48CDA/$A4638C/$A46200 with regs). Plus
  pre-existing `[MARCH] [PROBE] [TBL] [TBLMEM] [RAMCFG] [RAMCFGD] [OVERLAY] [FC]`.
- **regfile:** `VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile` — D0-D7 = idx 0–7,
  A0-A7 = idx 8–15.
- **SDRAM:** `VERTOPINTERN->emu__DOT__ram__DOT__mem` (16-bit words, addr[22:0]); CPU `$9FFFEC` →
  word `$0FFFF6`; 68k longwords are big-endian word pairs `(M[w]<<16)|M[w+1]`.
- **Exposed sigs:** `top->debug_pc`, `top->debug_cpuAddr`, `emu__DOT__selectUnmapped`,
  `emu__DOT__pvia__DOT__ram_cfg`/`__ram_configured`, `emu__DOT__ac0__DOT__rom_overlay`.
  (`emu__DOT__cpuBusControl`/`cpuAddr` are NOT root members — use `selectUnmapped`/`debug_cpuAddr`.)
- **Edit tool mis-handles tabs in `sim_main.cpp`** — insert probes via a `python3` heredoc using a
  literal-tab anchor (the dispatch uses 5–6 tabs). Pattern that works:
  `anchor='\t\t\t\t\tmarch_last_pc = mpc;\n'; s=s.replace(anchor, anchor+BLOCK, 1)`.
- **Disasm:** `docs/MacLC_ROM_disasm.txt`, VMA `0x40800000`. Runtime `$A4xxxx`/`$A0xxxx` ↔ disasm
  `$4084xxxx`/`$4080xxxx` (low 20 bits match). grep e.g. `^40846280:` for runtime `$A46280`.
- **ROM strings:** `strings -t x releases/boot0.rom`. STM banner at $49F2C `*APPLE*`, $49F24
  `*ERROR*`, $49F4A `STM Version 2.0, Scott Smyers`.

## MAME GROUND TRUTH (this machine)
- **Binary:** `/opt/homebrew/bin/mame` (v0.287). The local `~/repos/mame/mame` and `maclc`
  subtarget do NOT include maclc — use the homebrew one.
- **Run:** `cd /Users/dani/repos/mame && /opt/homebrew/bin/mame maclc -rompath /private/tmp/goodroms
  -ramsize 2M -autoboot_script /tmp/X.lua -seconds_to_run N -nothrottle -video none -sound none 2>/dev/null`
  (`timeout` not on macOS; lua self-exits via `emu.register_frame_done` + `manager.machine:exit()`).
- **Full instruction trace already at `/tmp/mame_maincpu.tr`** (5.4M lines, format `<PC>: <disasm>`,
  PC=8 hex e.g. `00A46280:`). Regenerate: debugscript `trace /tmp/mame_maincpu.tr,maincpu` + `go`
  with `-debug -debugscript -seconds_to_run 12`.
- **MAME distinct-PC set at `/tmp/mamepcs.txt`** (14726). Regenerate:
  `grep -oE '^00[0-9A-F]{6}:' /tmp/mame_maincpu.tr | sed 's/^00//; s/:$//' | sort -u`.
- **Check if MAME runs a PC:** `grep -c '^00A46280:' /tmp/mame_maincpu.tr`. MAME executes NONE of
  the error path ($A462xx, $A4638C, $A48Cxx, $A498xx) — confirms it passes the test.
- **Gotchas:** debugger `bpset`/`trace` default to the **Egret HC05** — use `trace file,maincpu`;
  `focus maincpu` + late `bpset` was flaky (seconds_to_run may exit first). `install_read_tap` does
  NOT fire on instruction fetches (data reads only) — use the full trace or frame-sampled
  `cpu.state["PC"].value`. Read memory in lua: `pgm:read_u32(addr)`. Example lua taps in `/tmp`:
  `taptable.lua`, `tapwhen.lua`, `tapnarrow.lua`, `tappath.lua`.
- MAME healthy at F240 = PC `$A14900` (`$A148/$A149xx` loop, 617 distinct PCs = real work).

## ROM ERROR-PATH MAP (reference)
- `$A46200-$A4623E`: dispatcher `negxl d4; blss/bhis <entry>` (d4 = test-result mask).
- `$A46240`: `btst #27,d7; beq $A4624A` (continue) else `oriw #$0100` (error). d7 bit27 = pass flag.
- `$A46280..$A462BC`: error entries `oriw #$0A00..$1400,d7` → `bras $A462C0 → braw $A4638C`.
- `$A4632x..$A46388`: error entries `$1500..$2000`.
- `$A4638C`: `bset #24,d7; movel sp,d6; moveaw #$2600,sp; jmp $A48CDA` (fatal bail).
- Other `→$A48CDA` branches: `$A46396` (jmp), `$A4640C, $A464EC, $A46546, $A465A8, $A465C2,
  $A46614`(bit15)`, $A46628/$A46634`(bit26)`, $A49134`.
- `$A48CD0`: `tstw d7; bne $A48CDA; movel #$87654321,d6`. `$A48CDA`: `moveaw #$2600,sp; jmp $A467A6`
  → `$A48CE8 btst #26,d7` (clear → `$A498A0` = STM monitor).
- `$A48468` handler does bit-banged serial I/O (`moveb a0@,d0; rorl #1,d0; dbf` 16×) over `[a0]`.

## Save findings to memory after progress
Project memory dir: `/Users/dani/.claude/projects/-Users-dani-repos-MacLC-MiSTer/memory/`.
Existing relevant notes: `candidate_b_phantom_bank_fix.md` (the committed fix),
`mame_ground_truth_maclc.md`. Update `MEMORY.md` index after writing.
