# LC II boot — RTL fix log (branch `030_LCii`)

Running log of the chipset/RTL changes needed to get the Macintosh LC II to boot
on this core, with the evidence for each. Newest entries at the bottom.

## Context / where the boot actually stands (2026-06-16)

Established this session (see memory `lcii-boot-blocker-ramtable`):

- **The "null RAM descriptor table" blocker was a measurement artifact**, not a
  real bug — the `[TBL]`/`[MARCH]` Verilator detectors indexed the TG68K regfile
  with the wrong mapping. Correct mapping (from the kernel's `debug_regfile_*`
  taps): `Dn = rf[15-n]`, `An = rf[7-n]`. Fixed in `verilator/sim_main.cpp`
  (commit `00e3186`). No RTL change.
- With correct measurement the boot is healthy through: ROM checksum POST (pass),
  startup chime, RAM enumeration (**valid 4 MB descriptor** `{start=0,
  len=$400000}`), and the **entire 11-handler boot state machine** (Verilator
  frames F94→F150).

### The real blocker: Egret ↔ VIA1 shift-register handshake never completes

After the state machine, the boot runs an Egret/ADB init routine (`$A4A290`,
driving VIA1 at CPU `$F00000`) with a shift-register handshake loop at
**`$A4A18C`–`$A4A24C`**:

```
$A4A18C: btst #3,(A2)         ; VIA PB3 = Egret/Cuda TREQ (transfer request)
$A4A1F4: btst #2,($1A00,A2)   ; VIA IFR bit2 = shift-register interrupt
$A4A1FA: beq  $a4a1f4         ; wait for an SR byte
$A4A1FC: btst #3,(A2)         ; re-check TREQ
$A4A200: bne  $a4a1f4         ; loop until the Egret finishes the packet
```

**Oracle (MAME fed our exact patched ROM — see method below):** MAME runs this
loop **14 iterations and exits**; our core **spins it indefinitely** (F117→F150),
the VIA SR poll *succeeds* every time (never a timeout), then the boot derails to
`$FFFFFFAA` → wedges at `$00007FF8`. So the transaction (VIA shift register +
Egret TREQ/byteack) never terminates in our core.

Model is present: `rtl/egret/` (HC05 + ROM), `rtl/cuda_adb.sv` (TREQ/SR
handshake), `rtl/via6522.sv` (the VIA + SR FSM).

### MAME-on-our-ROM oracle (key tool)

MAME validates the romset hash but still RUNS a mismatched ROM (warns
"WRONG CHECKSUMS … might not run correctly"; only `-skip_gameinfo` needed). The
maclc2 ROM is 4-way byte-interleaved (`ROM_LOAD32_BYTE`: hh=341-0476→merged off0,
mh=0475→off1, ml=0474→off2, ll=0473→off3). Split `releases/boot0-fastmem.rom`
into the 4 chips (`chip[k] = merged[k::4]`) into `/tmp/patchroms/maclc2/`, then:

```
mame maclc2 -rompath '/tmp/patchroms;/private/tmp/goodroms' -ramsize 4M \
  -skip_gameinfo -debug -debugscript trace.dbg -seconds_to_run 4
```

With the fast-mem clamp, MAME reaches the `$A4A4xx` Egret window in ~4 s and boots
cleanly (no `$FFFFFFxx`, no `$7FF8`) — proving the fast-mem ROM is sound and the
bug is in our core's chipset.

---

## Investigation notes (pre-fix)

Active chipset config (`rtl/dataController_top.sv`): `via6522 via` (583) +
`egret_wrapper egret_inst` (real 68HC05 + Egret ROM, used for BOTH Verilator and
FPGA per the comment at ~690) + `cuda_maclc cuda` (792). VIA↔Egret handshake pins:
- PB3 = TREQ (Egret→VIA, active low): `egret.sv:179 cuda_treq = ~pb_out[1]`
- PB4 = BYTEACK (VIA→Egret), PB5 = TIP (VIA→Egret, `via_tip_latched`)
- CB1 = SR shift clock (Egret drives in external-clock mode)
- CB2 = SR data

**Prime suspect (already flagged in-tree):** `dataController_top.sv:692` —
*"the Egret CB1/overlay-escape bug (it drives CB1 slowly, so the VIA SR never
drops edges)."* The `via6522.sv` SR FSM (lines ~700-944) is external-clock mode
(`shift_mode_control` 011/111), shifting on per-`clk` CB1 edge pulses
(`shift_tick_r`/`shift_tick_f`). If CB1 edges from the HC05 are missed/coalesced
or the 8-bit `bit_cnt` completion (`serial_event → IFR[2]`) mis-fires, the
`$A4A18C` packet loop never sees TREQ deassert and spins. This file already
carries several prior SR fixes ("byte-4 turnaround", "Egret SR hang").

Note: this RTL has heavy AI-generated comment cruft ("directly directly
directly…"); treat surrounding logic with suspicion.

## Byte-level diagnosis (2026-06-16) — it is NOT the VIA shift mechanism

Instrumented the VIA SR + Egret handshake (`sim_main.cpp` [SR]/[SRBYTE], using
`--trace`-preserved signals `emu__DOT__dc0__DOT__via__DOT__{shift_reg,bit_cnt,
shift_active,irq_flags,acr}`, `emu__DOT__dc0__DOT__via_pb_i`,
`emu__DOT__dc0__DOT__egret_dbg_treq`, `emu__DOT__dc0__DOT__egret_inst__DOT__pb_out`
— no re-verilate needed). Captured the CPU↔Egret byte stream and diffed vs a MAME
lua tap on the VIA SR reg `$F01400` (our patched ROM).

Findings (rules OUT the VIA6522):
- VIA SR works: `bit_cnt` 7→0, `shift_reg` shifts, IFR[2] (SR-int) fires, ACR
  toggles `$1C`(shift-out, mode7) / `$0C`(shift-in, mode3). Bytes transfer.
- Egret HC05 runs (firmware executes; session handler; `pb_out` advances).
- Handshake toggles: TREQ=1 (idle) during OUT, TREQ=0 (asserted) during the
  Egret's response (IN). Same as MAME.

**The actual divergence — the Egret's response packet bytes:**
```
            command (CPU->Egret)   Egret response (Egret->CPU)
  MAME:     01 07 00 F9            00 01 00 07 01
  Ours:     01 07 00 F9   (match)  FF 01 00 07 00
```
Command matches; response middle `01 00 07` matches; but **our first response
byte is `FF` (MAME `00`)** and the last is `00` (MAME `01`). `FF` = the SR idle
value; at that first IN read `via_pb_i`=`$40` (TIP=0, TREQ asserted) — the byte is
**mis-framed at the shift-out→shift-in turnaround**: the VIA captures 8 idle-`1`s
before the Egret's CB2 response data is valid (or the Egret drives CB2 one
bit-cell late). A non-`00` first byte is an invalid packet type, so the ROM
rejects the response and retries → the `$A4A18C` loop never terminates.

=> Root cause is a **VIA-shift-in / Egret-CB2 turnaround timing mismatch**, NOT a
VIA byte-shift bug and NOT the RAM/CPU. Candidate fix locations:
1. VIA `via6522.sv` shift-in start timing (don't begin capturing until the Egret's
   first CB2 data bit is valid after TREQ assert / the mode switch), and/or
2. Egret CB2 data drive timing relative to CB1 on the first response byte.

NEXT: capture CB2 (and CB1) bit-level timing across the turnaround in both cores
to decide which side leads/lags, then a targeted one-line timing fix.

## MAME reference (the turnaround oracle) — `6522via.cpp`

- `write_cb1(state)` is called on EVERY CB1 edge (Egret drives CB1 in ext mode).
  In SO_EXT (mode7) it calls `shift_out()`, in SI_EXT/SR_DISABLED it calls
  `shift_in()`.
- A single `m_shift_counter` counts ALL 16 edges (0x0f→0). `shift_out` acts on
  ODD counts (CB2 driven on falling), `shift_in` samples `m_in_cb2` on EVEN
  counts (rising): `m_sr = (m_sr<<1) | m_in_cb2`.
- **Key turnaround detail:** when the CPU reads/writes the SR, the counter is
  re-initialised FROM THE CB1 LEVEL: `m_shift_counter = m_in_cb1 ? 0x0f : 0x10`
  (6522via.cpp:772/968). Starting at 0x0f (CB1 high) means the very first edge is
  ODD → NOT a shift-in, so the first DATA bit is sampled only on the next
  (aligned) edge. This is what phase-aligns the first response byte to the
  Egret's CB2 data.
- `m_in_cb2` is the LATCHED CB2 value (`write_cb2` latches it); `shift_in` uses
  the latched value, not a live sample.

Our `via6522.sv` differs: it arms `bit_cnt<=7` on SR trigger regardless of CB1
level, counts only 8 (relevant) edges, and shifts-in on every CB1 RISING edge
sampling `cb2_i` LIVE. At the out→in turnaround the first rising edge can fall
while CB2 is still idle (1) → first byte = FF (the observed bug). Subsequent
bytes re-sync, so only the first (and the framing-dependent last) byte are wrong.

### Fix plan (targeted, low regression risk — VIA-SR is only used from $A4A290+)
Align our shift-in start to the CB1 level at SR-trigger time, matching MAME:
when arming a shift-IN in ext-clock mode, if CB1 (`shift_clock`) is HIGH at the
trigger, skip the first rising edge (don't sample the turnaround bit). Equivalent
to MAME's `0x0f` (CB1 high) vs `0x10` (CB1 low) counter init. Also consider
latching cb2_i (sample the value present before the edge) to match `m_in_cb2`.

## Bit-level turnaround capture ([SRBIT], F117) — refines the culprit to the EGRET

Captured CB1/CB2/bit_cnt/shift_reg per edge across the first shift-in
(`sim_main.cpp` [SRBIT]). Decisive:
```
1st IN byte (pc A4A36x): CB1 clocks 8 edges, CB2=1 the WHOLE time -> SReg=FF (idle)
2nd IN byte (pc A4A42x): CB2 toggles 0/1 (real data)            -> SReg=FE.. valid
```
So the VIA shifts correctly; the **Egret drives its CB2 response data one byte
LATE** — it clocks a leading idle (CB2=1) byte, which the VIA captures as FF. The
ROM reads FF (invalid packet type), branches to a different path (pc diverges:
ours A4A36C vs MAME A4A374) and the `$A4A18C` loop never terminates.

Our Egret runs the SAME HC05 ROM (341S0850) as MAME, so the bug is in the
**cycle timing of `egret_wrapper`/the HC05 model** — when its CB2 port write
takes effect relative to CB1/BYTEACK — NOT the VIA6522 (which shifts faithfully)
and NOT the RAM/CPU. This matches the in-tree note at dataController_top.sv:692
about an Egret CB1/handshake bug.

### Status / recommended next step
- The VIA6522 is exonerated (shift mechanism + byte transfer verified correct).
- Fix target: `rtl/egret/egret_wrapper.sv` + the HC05 port/handshake timing (and
  the TIP/BYTEACK sync in dataController_top.sv) so the Egret's first response
  CB2 bit is valid on the first CB1 edge (no leading idle byte), matching MAME.
- To pin the exact one-cell offset, get MAME's CB1/CB2/BYTEACK bit timing in this
  window (needs MAME egret.cpp instrumentation or HC05 trace — lua taps can't see
  the CB lines), then a targeted timing fix + re-verilate.

## MAME ground truth (2026-06-16) — source-verified, no rebuild needed

Verified against `/Users/dani/repos/mame` source + the v0.288 binary (`-listdevices
maclc2`). Topology: Egret HC05 `pb_w` → `write_via_clock`(PB4)→`v8::cb1_w`→`via1.write_cb1`,
`write_via_data`(PB5)→`v8::cb2_w`→`via1.write_cb2`. Host reads SR at `$F01400` → `via1 SR`.
The VIA inside V8 is `:v8:via1` (R65NC22); the Egret HC05 is `:egret:egret` (M68HC05E1).

1. **VIA shift-in turnaround alignment.** `SI_EXT_CONTROL` ((ACR&$1c)==$0c). `write_cb1`
   calls `shift_in()` on EVERY CB1 edge; ONE `m_shift_counter` counts all 16 edges/byte.
   `shift_in` (6522via.cpp:468) samples `m_in_cb2` into the SR **only on EVEN counter
   values** (every other edge), arming the SR IRQ when it shifts at counter==0.
   `m_in_cb2` is the **latched** CB2 (set by `write_cb2`), not a live sample.
   **Key line:** on SR read AND write, `m_shift_counter = m_in_cb1 ? 0x0f : 0x10`
   (6522via.cpp:775 / :971). CB1 HIGH at SR-read → counter=$0f (odd): the first
   (falling) edge is counted-but-skipped, the first DATA bit lands on the next RISING
   edge; CB1 LOW → $10: the first RISING edge shifts immediately. Either way the 8 data
   bits land on the 8 CB1 RISING edges. (Our VIA also shifts on CB1 rising — so the
   sampled edges are the SAME; the counter-init is NOT the divergence.)

2. **No leading idle byte in MAME.** CB2 is a ZERO-LATENCY combinational function of the
   HC05 PORTB write: BOTH `ports_w` and `ddrs_w` call `send_port`→`pb_w`→`write_via_data`
   **synchronously, in the same instruction** (m68hc05e1.cpp:117-132). So when the
   firmware flips DDRB bit5 to OUTPUT, the current PORTB-bit5 value is emitted to CB2
   immediately; when it writes the data bit, it's emitted immediately. The firmware sets
   the CB2 data bit BEFORE it toggles the CB1 edge that samples it. Hence the MSB of the
   first real response byte ($00) is valid on the very first sampling edge — no 8-clock
   idle window.

3. **MAME's diagnosis of OUR bug:** the extra idle byte must come from **our CB2 drive
   being registered/delayed relative to the CB1 clock the Egret emits**, or from the
   **DDR-flip not re-emitting the data value at turnaround**. In `egret_wrapper.sv`,
   `cuda_cb1=pb_out[4]` and `cuda_cb2=pb_out[5]` are BOTH the cen-registered `pb_out`
   (1-cen lag, same for both → relative order preserved), but `cuda_cb2_oe=pb_ddr[5]`
   is taken DIRECTLY from the (combinational, immediately-updated) `pb_ddr`. So at a
   DDR→output flip, `cuda_cb2_oe` rises one cen BEFORE `pb_out[5]` catches the new data
   — a turnaround skew worth measuring. (Pending [SRTRN] capture of pb_out[5]/pb_ddr[5].)

4. **HC05 trace recipe (no rebuild):** `wpset` on `:egret:egret` program addrs 0x01
   (PORTB) and 0x05 (DDRB), printing `wpdata`, bit4=CB1, bit5=CB2, DDRB bit5=oe, `.pc`,
   `.cycles`. Script saved at `/tmp/egret_pb_trace.txt`; run with `-debug -debugscript`.

## ROOT CAUSE CONFIRMED (2026-06-16) — Egret CB2 pin has no pull-up; ours read 1, not 0

Enriched the Verilator turnaround detector ([SRTRN]/[DDRT] in `sim_main.cpp`) to log the
Egret's CB2 output-enable (`egret_inst.pb_ddr[5]`), CB2 data (`pb_out[5]`) and the HC05 PC
(`egret_inst.last_pc`) across the OUT->IN turnaround (frames 114-121). Decisive findings:

- Command `01 07 00 F9` shifts OUT correctly (matches MAME). The response then comes back
  `FF 01 00 07 00` vs MAME `00 01 00 07 01` — and EVERY IN transaction starts with a
  spurious `FF`.
- During the ENTIRE first IN byte, `egr cb2=1 oe=0` — the Egret's CB2 is an INPUT
  (`pb_ddr[5]=0`). The HC05 is in its receive/turnaround bit-loop at PC `$1552-$1570`
  with DDRB=`$92` (CB2 tri-stated). It sets DDRB bit5=OUTPUT (`$92->$B2`) only later, at
  HC05 PC `$15CB`, then drives the real data (byte 2 onward shifts in correctly: `FE`,
  `FC`, ... = valid). So the firmware GENUINELY clocks one byte-period with CB2 as input
  at the receive->send turnaround — this is the SAME firmware MAME runs.
- Our VIA, when the Egret isn't driving CB2, was reading `cb2_i = kbddata_o` (the legacy
  soft-ADB-keyboard line, idle HIGH=1) -> shifted in `FF`. **MAME reads 0 there**: the
  Egret's HC05 PORTB bit5 has NO pull-up (`egret.cpp:90 set_pullups<1>(0x40)` = bit6
  only; `m_pullups` defaults to 0, `m68hc05e1.cpp:29`), so a tri-stated CB2 emits
  `(m_ports&ddr)|(m_pullups&~ddr) = 0`. Hence MAME's first response byte is a valid `00`,
  the ROM takes the `A4A374` branch, and the Egret handshake completes.

`FF` is an invalid Egret packet type, so our ROM branched to `A4A36C` (vs MAME `A4A374`)
and the `$A4A18C` packet loop never terminated -> derail -> `$00007FF8` wedge. The leading
byte being wrong cascades: it also corrupts the later bytes (read in the wrong code path).

## RTL changes

### 1. `rtl/dataController_top.sv` (~line 611): model the Egret CB2 pin's missing pull-up

```
-       .cb2_i      (cuda_cb2_oe ? cuda_cb2 : cb2_i),      // undriven -> kbddata_o (idle 1)
+       .cb2_i      (cuda_cb2_oe ? cuda_cb2 : 1'b0),       // undriven -> 0 (no pull-up, per MAME)
```

When the Egret tri-states CB2 (`cuda_cb2_oe==0`), the VIA now reads `0` (matching MAME's
pull-up-less HC05 PORTB bit5) instead of the vestigial soft-keyboard line `cb2_i`
(=`kbddata_o`, idle HIGH). This makes the turnaround "input" byte read `00` (valid) like
MAME, so the ROM takes the correct branch and the `$A4A18C` Egret handshake terminates.

Notes: the change is confined to the VIA's CB2 *input* mux. The OUT phase is unaffected
(the VIA drives CB2 then, and doesn't sample its own input for shifting). The soft-ADB
keyboard on CB2 (`kbddata_o`/`kbddat_i`) is legacy for pre-ADB Macs; on the LC II the
keyboard is ADB through the Egret, so disconnecting `kbddata_o` from the VIA CB2 input is
correct here. NOT a `via6522.sv` change (the VIA shifts faithfully) and NOT an
`egret_wrapper.sv` change (the HC05 timing is correct — the bug was the board-level pin
pull-up model in the wiring).

#### PARTIAL — corrects the byte, does NOT fix the boot (2026-06-16, re-verilate + runs)

VERIFIED improvements:
- First IN response byte is now **`00`** (was `FF`); the cmd-`07` response bytes 1-4
  (`00 01 00 07`) and all `0C` responses (`00 01 00 0C`) now MATCH MAME byte-for-byte.
- The Egret command sequence runs (`01 07 00 F9` then `0C` reads of `F0..FB`).

BUT the boot STILL derails (CORRECTION to an earlier optimistic note in this log): runs to
F160 and F240 both show the periodic PC dump go `...A47xxx/A4Axxx... -> PC=FFFFFFAA @F155
-> PC=00007FF8 @F179+` — i.e. the SAME `$FFFFFFAA -> $7FF8` wedge at the SAME frame as
before the fix. (My first F160 grep missed the `FFFFFFAA@F155` and `$7FF8` only starts at
F179, hence a false "wedge gone".) So fix #1 is a genuine, correct bug fix (the `FF` was
definitely wrong per MAME's pull-up model) but is **NECESSARY, NOT SUFFICIENT**. KEEP it;
the pre-Egret boot (chime, state machine) is intact (state machine still runs at `$A47xxx`
up to ~F149). (Re-verilate with Verilator 5.048 is fast — ~36 s total, NOT 14 min.)

Also note: even with byte1=`00`, our 68k reads it at pc `A4A36C` (MAME `A4A374`). So the
`A4A36C`-vs-`A4A374` divergence the old notes blamed on the `FF` is NOT caused by the byte
value — it is timing (where the 68k is polling when the SR byte completes). The byte value
mattered for packet validity; the pc difference is a separate timing effect.

### REMAINING ISSUE (next blocker) — multi-byte response framing on the `01 07 00 F9` init

After the fix the boot still does not complete: it **re-issues the whole sequence from
`01 07 00 F9` repeatedly** (3x in the F117-155 window) instead of proceeding. MAME issues
the `07` command only ONCE then continues with `0C`-only commands (its `01 07` appears ~2x
in a 200-byte window vs our 3x of the full restart). The trigger:

```
            cmd 01 07 00 F9       response
  MAME:     (once)                00 01 00 07 01     -> proceeds
  Ours:     (repeats)             00 01 00 07 00     -> 5th/status byte wrong -> retry
```

Only the `07`-command response differs, and only in its **5th (status) byte: ours `00`,
MAME `01`**.

#### Fix #2 hypothesis (VIA SR framing) — INVESTIGATED & DISPROVEN (2026-06-16)

A rigorous bit-level reconstruction of transaction 1 (parse of the clean [SRTRN] dir=IN
records) shows the VIA is FAITHFUL and the divergence is in the **Egret's own output**:

```
  byte  ours MAME  how OUR byte is produced (egret_inst pb_out[5]=egcb2, pb_ddr[5]=oe)
   1     00   00   turnaround: oe=0 (tri-stated) the whole byte -> reads pull-down 0  ✓
   2     01   01   Egret drives; TRAILING 1 (LSB) driven & captured correctly         ✓
   3     00   00   Egret drives 0                                                     ✓
   4     07   07   Egret drives ...00000111, captured                                 ✓
   5     00   01   Egret ACTIVELY DRIVES 00: oe=1 and egcb2=0 for ALL 8 bits          <-- diverge
```

Byte 2 proves the SR captures a trailing `1` correctly, so it is NOT a sampling/framing
bug. For byte 5 the Egret's `pb_out[5]` is 0 across all 8 shifted bits while `oe=1`
(actively driving) — i.e. **our Egret HC05 genuinely emits `00` where MAME's emits `01`**.
The VIA shifts in exactly what the Egret presents. Therefore a `via6522.sv` counter-init /
latched-cb2 change would be WRONG (and would risk regressing the now-correct bytes 1-4 and
the OUT phase). **Do NOT apply the VIA framing change.**

#### Real residual = Egret cmd-`07` response data/handshake divergence (next blocker)

The cmd-`07` response's last data byte is Egret-computed and differs (`00` vs `01`); the
`0C` PRAM-read responses match MAME exactly. Corroborating: MAME's 68k reads response
bytes 2-5 in one loop (4 iters at pc `A4A434`); ours reads bytes 2-4 in-loop (`A4A430`)
then byte 5 separately (`A4A42E`) — the Egret paces bytes via the TIP/BYTEACK handshake,
so our handshake timing during the response likely makes the HC05 emit one byte's data
differently (or one byte short + a trailing `00`). Investigation targets (Egret/handshake,
NOT the VIA):
- What the HC05 loads/computes for the cmd-`07` 5th response byte (trace HC05 RAM/reg
  reads in the send loop `$15CB-$1634` vs MAME); whether it depends on a handshake-paced
  state or an HC05 RAM/PRAM byte that diverged.
- The TIP/BYTEACK pacing during the multi-byte response: `via_tip_latched`
  (dataController_top.sv:665), `egret_wrapper` `via_tip`/`via_byteack_in` sync, and the
  per-byte handshake — a mistimed ack can make the Egret send a byte early/late.
Success criterion (unchanged): cmd-`07` response == `00 01 00 07 01`, the `01 07` command
issued once, and the boot leaving the `$A4A1xx-$A4A4xx` Egret routine into new code.

## Egret HC05 dig — cmd-07 = GET_PRAM; data divergence FIXED but derail persists (2026-06-16)

Disassembled the Egret HC05 ROM (unidasm m6805; CPU $0F00 = rom off 0) and traced cmd-07;
an independent protocol-research pass + MAME's nvram corroborate it:

- **Command 0x07 = GET_PRAM** (Cuda/Egret pseudo-cmd; 0x01=pseudo packet type, 0x0C=SET_PRAM).
  `01 07 00 F9` = read PRAM byte at addr 0x00F9. Handler `$1760` builds a RAM stub
  `LDA $A8A9 / RTS` at `$A7` and `jsr $A7` to read mem[$A8:$A9]; params `00 F9` -> addr
  **$01F9** = HC05 RAM CPU $0100-$01FF = the 256-byte PRAM = `pram[0xF9]`. Response
  `00 01 00 07 01` = [00 framing][01 type][00 status][07 echo][**01 = pram[0xF9]**]. The
  boot then SET_PRAMs 0xF0,F1,F2,F3,FA,FB (PRAM init/fix-up).
- **Divergence:** our `rtl/egret/egret.pram` is BLANK 0xF0-0xFF (all 00) so `pram[0xF9]=00`;
  MAME's Egret nvram (initialized XPRAM) has `pram[0xF9]=01` (+ F0=02 F1=EE F3=EC FB=8C).
- **Fix #2 (data, runtime-only — egret.pram is `$readmemh` at sim start, NO re-verilate):**
  replaced `rtl/egret/egret.pram` with MAME's 256-byte valid XPRAM (`nvram/maclc2/egret`).
  VERIFIED: cmd-07 response is now **`00 01 00 07 01` — byte-perfect with MAME**.
- **BUT the boot STILL derails at F155** (`PC=FFFFFFAA -> $00007FF8`), SAME frame, SAME
  `$A4A18C` 8-state cycle (A6: A4A18C->A4A1CA->A4A1D6->A4A1E0->A4A1EA->A4A20E->A4A440->
  A4A24C->repeat) at F149-150; command sequence unchanged (3x GET_PRAM, 20x SET_PRAM).

### CONCLUSION: the derail is NOT the Egret SR response data
Fix #1 (CB2 pull-up) + Fix #2 (PRAM) each corrected a REAL Egret data divergence and together
make the SR response IDENTICAL to MAME -- yet the boot derails identically. So the F155 derail
is a THIRD, data-independent blocker: the `$A4A18C` Egret/ADB state machine (`jmp (A6)`
coroutine at `$A4A454`) cycles its 8 states forever, never reaches a terminal state; eventually
`A6` <- `$FFFFFFAA` -> `jmp` to garbage -> `$7FF8`. This is the doc's ORIGINAL "loop never
terminates" blocker (MAME runs ~14 iters & EXITS). The loop's exit depends on a HANDSHAKE
condition (polls VIA PB3=TREQ + IFR bit2=SR-int; exits when the Egret signals done/TREQ
deasserts), NOT on the SR byte values. NEXT: the TREQ/BYTEACK/TIP handshake completion
(egret_wrapper `cuda_treq`/`via_tip`/`via_byteack`, dataController `via_tip_latched`:665) and/or
the 68k exit at `$A4A18C-$A4A24C` (how A6 gets `$FFFFFFAA` -- disassemble the fast-mem ROM there).

## bug #3 PINPOINTED (2026-06-16) — derail is the 68030 PMMU MMU-enable, NOT the chipset

Extended [JMP6] + added a [DERAIL] catcher and a 48-entry [RING] lead-up buffer (sim_main.cpp)
that flushes on the first abnormal PC. With fix#1+fix#2 the Egret SR response is byte-perfect
vs MAME, yet the boot still derails identically at F155 (PC=FFFFFFAA -> $7FF8@F179). The RING
trace shows the derail originates in the **68030 MMU/cache-enable routine at `$A41670`**
(disassembled as m68030):

```
a4167a: movec  CACR,D5
a4167e: ori.w  #$808,D5
a41682: movec  D5,CACR          ; enable caches
a41686: pmove  ($4,A3),srp      ; supervisor root pointer
a4168c: pmove  ($8,A3),crp      ; CPU root pointer   (A3=$003FFFB2; tables in top-of-RAM)
a416a0: movec  D5,VBR           ; vector base = 0
a416aa: pmove  (A6),crp
a416b2: pmove  (A3),tc          ; load Translation Control -> ENABLE the MMU
a416b6: jmp    (A5)             ; first MMU-translated jump
```

The RING shows: ...execute the pmoves... `$a416b2 pmove tc` (MMU enable) -> `$a416b6 jmp (A5)`
-> **PC = `000000`** (executes the low-mem reset vectors as garbage: 0020 2000 40A4 639A ...) ->
walks up -> abnormal `$FFFFFFA2` -> ... -> `$00007FF8` wedge. So the FIRST MMU-translated fetch
(`jmp (A5)` right after enabling the MMU) goes to `000000`.

This is a **CPU/PMMU bug, NOT the Egret/chipset** (the Egret response now matches MAME exactly;
fixes #1/#2 are real but the derail is downstream in the CPU). TG68K *does* have 68030 PMMU
(`rtl/tg68k/TG68K_PMMU_030.vhd`, `TG68K_Cache_030.vhd`, table-walker in `tg68k.v`, CPU=10). The
PMMU table-walk DEADLOCK was fixed earlier (`docs/findings_pmmu_walk_stall_2026-06-15.md`,
commit 35aa11b — phi-parity), and `docs/handoff_lcii_boot_postpmmu_2026-06-15.md` explicitly
SUSPECTED "a second bug after PMMU-enable" but couldn't locate it (no PC visibility past POST).
**This RING trace is that second bug, located:** the first MMU-translated `jmp (A5)` lands at
`000000` -> the PMMU translation (or the regs feeding `jmp (A5)`) is wrong right after the
`pmove tc` enable. Next: determine whether `A5`/`A2` is itself bad (instruction/regfile bug in
movec/pmove handling) or a valid `A5` is mistranslated to 0 by the PMMU (ATC/translation bug) —
i.e. a fix in `TG68K_PMMU_030.vhd` / the kernel's pmove handling, OR the in-progress real
MC68030 CPU (MacIIvi repo). The Egret/VIA SR path is exonerated.

### bug #3 sharpened (2026-06-16) — the failing translation is the 32-bit ROM alias $40A0010E

[RING] with A5/A2 logged: at `$a4169c movea.l A2,A5` -> **A5 = A2 = `$40A0010E`** (the 32-bit
ROM-alias virtual address the ROM expects to continue at once the MMU remaps it; pre-MMU the
ROM ran at `$00A0xxxx`). After `$a416b2 pmove (A3),tc` ENABLES the MMU, `$a416b6 jmp (A5)` with
A5=`$40A0010E` produces **PC=`000000`** (not `$40A0010E`). So the FIRST MMU-translated fetch —
the jump into the `$40xxxxxx` ROM-alias region — mistranslates to 0 (or faults to the VBR=0
zero vector), then garbage-walks to `$FFFFFFAA` -> `$7FF8`.

So: the PMMU table-WALK works (handoff: 20/20 sane descriptors), but the TRANSLATION RESULT for
the `$40xxxxxx` ROM-alias is wrong right after enable. Fix is CPU-side — `TG68K_PMMU_030.vhd` /
the kernel's translation+ATC for the ROM-alias region (or the in-progress real MC68030). The
Egret/VIA-SR chipset is fully exonerated (its SR response is byte-perfect vs MAME after fixes
#1/#2). Verify next: dump the PMMU descriptor/translation for VA `$40A0010E` (compare to MAME's
mapping) — expected to map to ROM physical, ours yields 0.

### bug #3 ROOT MECHANISM (2026-06-16, +define+PMMU_TRACE) — bus error on first translated fetch

Enabled the PMMU walker probe (`tg68k.v` `+define+PMMU_TRACE`) and ran to F157. At the
`jmp ($40A0010E)` (`$a416b6`, the first fetch after `pmove tc` enables the MMU) the trace shows:

```
PMMU REQ #0 addr=003fee00  (root)            -> ACK 0009fc0a
PMMU REQ #1 addr=003fee04                    -> ACK 003fedd0   (level-1 table pointer)
PMMU trap_berr addr=00a416b6                 <-- BUS ERROR on the jmp's translated fetch
... (later, the same VA re-walks and CAN resolve: 003fee00->003fedd0->003fedd4->00100019,
     i.e. a valid page descriptor -> physical ~0x00100000) ...
```

So: the page tables are VALID (a walk DOES resolve to a real page descriptor `00100019` =>
phys ~`$00100000`), but the FIRST MMU-translated access **spuriously bus-errors** (`trap_berr`
at `$a416b6`). Then — because `$a416a0 movec D5,VBR` set **VBR=0** — the 68030 bus-error
exception vector (#2) is at physical `$08`, which is in **zeroed RAM**, so the handler address
is `0` => PC jumps to `000000`, executes the reset vectors as garbage, and walks to `$FFFFFFAA`
-> `$00007FF8`.

TWO coupled CPU-side defects (both in `rtl/tg68k/`):
1. **Spurious bus error on the first MMU-translated fetch** — the translated physical access
   (phys `~$00100000`) or the table walk faults when it should succeed. Smells like the same
   bus-FSM / DTACK class as the earlier phi-parity walk-stall fix (`findings_pmmu_walk_stall`),
   not fully cured for the translated-data access; or the `$40xxxxxx` VA index/limit (TC IS)
   handling. Compare our walk to MAME's translation of `$40A0010E`.
2. **The fault is unrecoverable** because the exception vector table at physical `$0` is zeroed
   (VBR=0 + un-init low RAM), so any early bus error -> PC=0 -> wedge. (Stock ROM populates low
   RAM; the fast-mem patch path here apparently does not by this point — but the PRIMARY bug is
   #1: there should be no bus error.)

This is firmly a CPU/PMMU bug (`TG68K_PMMU_030.vhd` / `tg68k.v` bus FSM), NOT the Egret/chipset
(SR response byte-perfect vs MAME). It is the "second bug after PMMU-enable" the post-PMMU
handoff suspected, now mechanistically located. Next: trace WHY the translated fetch of
phys `~$0010010E` bus-errors (DTACK timing on the walk/translated access) vs MAME; dovetails
with the in-progress real MC68030 import (MacIIvi repo).
