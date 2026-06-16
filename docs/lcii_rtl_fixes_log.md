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

## RTL changes

_(none applied yet. Root cause is the Egret HC05/handshake CB2 timing, not the
VIA6522. VIA6522 changes are NOT required — it shifts correctly. Pending: an
egret_wrapper/HC05 CB2-vs-CB1 timing fix; deferred to a focused Egret-timing
session since it needs MAME bit-level co-sim to land precisely without
regressing the working pre-$A4A290 boot.)_
