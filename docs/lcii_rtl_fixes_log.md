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

## RTL changes

_(none yet — diagnosis points at the VIA shift-in / Egret-CB2 turnaround timing;
capturing bit-level CB1/CB2 timing at the turnaround before the targeted edit.)_
