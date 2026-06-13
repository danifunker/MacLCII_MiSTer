# FINDINGS: 7.x Welcome-screen wedge — it's LocalTalk, not SCSI

*2026-06-12 evening, MacBook MAME ground-truth session. Answers
docs/handoff_welcome_wedge_2026-06-12.md Q1–Q5. Branch
`scsi-fixes-from-lbmactwo`. Artifacts: `docs/welcome_wedge_2026-06-12/mame/`.*

## TL;DR

The 7.x "Welcome to Macintosh" wedge has **nothing to do with SCSI**. The
spin `tst.b $060A(A2) / bne.s` is the **LAP Manager (LocalTalk/.MPP) transmit
busy-flag wait**, entered when AppleTalk opens during early extension loading.
The flag is set/cleared **inline by the LAP transmit worker itself**; no SCSI
interrupt is involved anywhere. On our core the worker takes its **defer
path** ("line busy — retry on SCC interrupt") on every attempt because
`rtl/scc.v` **hardwires RR0 bit 4 (Sync/Hunt) to 0**, and the deferred resume
requires an SCC external/status interrupt our SCC can never generate → the
busy flag stays $FF forever → outer spin = the wedge. MAME boots both
fixtures fine because its z80scc reports an idle hunting line and the ~9–14
lapENQ probes complete synchronously, **without a single SCC interrupt**.

The morning's pseudovia SCSI IRQ/DRQ re-wire was chasing the wrong device;
the JTAG SCSI snapshot (bus idle, TCR=7, last read reg 7) showed a *healthy,
finished* SCSI engine.

## Q1 — the spin, located and identified

| | 7.1 | 7.5.5 |
|---|---|---|
| spin PC (MAME) | `$8B6E0` | `$A7DA8` |
| instruction | `tst.b $060A(A2)` | `tst.b $063E(A2)` |
| A2 (LAP globals) | `$8A860` | `$A6CB0` |
| flag byte | `$8AE6A` | `$A72EE` |
| first executed | F=1140 (t≈19.0 s) | F=1260 (t≈21.0 s) |

- A2 = LAP Manager globals, loaded from **ExpandMem+$70** (`movea.l $2b6.w,A2;
  movea.l ($70,A2),A2`). Flag offset differs per OS version ($60A vs $63E) —
  the 7.5.5 byte pattern is NOT identical to 7.1's (scan 7.5.5 with the
  wildcard `4A 2[8-F] xx xx 66 FA`, see tooling notes).
- The code is a decompressed System resource; single RAM copy; the FPGA wedge
  PC $8AA38 is the same code relocated.

## Q2 — who writes the flag (the "wake mechanism")

All writers are **inside the LAP module itself** (7.1 addresses; 7.5.5 is the
same shape at $A7DC4/$A7DCA):

```
$8b6ca: sync-send: D4 = retry count (E)            ; outer caller
$8b6da:   bsr $8b6fc
$8b6e0:   tst.b ($60a,A2) / bne.s  ← THE SPIN
$8b6e6:   cmpi.w #$8001,(A1)       ; result "pending/defer"?
$8b6ea:   dbeq D4, retry           ; ~60 ms apart (probe pacing)

$8b6fc: st    ($60a,A2)            ; flag := $FF   (sr=$2019, IPL 0)
$8b700: bsr   $8b75a               ; THE WORKER (LLAP transmit)
$8b702: clr.b ($60a,A2)            ; flag := $00   (sr=$2014, IPL 0)
```

The worker `$8B75A` **pops its return address into (A2+$600)** as a
continuation. Two exits:

- **Success** (`$8b890`): `movea.l ($600,A2),A0; jmp (A0)` → lands on the
  `clr.b` → flag cleared.
- **Defer** (`$8b8c4`, reached when the line looks busy): counts down a retry
  budget at (A2+$610); arms SCC **WR15=$88** (Break/Abort + DCD ext/status
  interrupt enables); sets "TX pending" bit 0 of (A2+$6C6), state byte
  (A2+$60B)=2; restores registers and **returns one level up WITHOUT
  clearing the flag**. The wake is then the **SCC ExtSts interrupt** —
  handler at `$8B90C` checks RR0 bit 7 (Break/Abort = LocalTalk line went
  idle) and resumes the deferred TX, whose success path finally clears the
  flag via the continuation.

**The FPGA wedge = deferred forever**: flag set, defer taken, ExtSts
interrupt never arrives. Matches the JTAG profile exactly (main thread
spinning at the flag; nobody parked in an SCC poll loop).

In healthy MAME boots the defer path is never taken: the flag toggles
FF→00 in clean inline pairs ~57–65 ms apart — the **lapENQ node-ID probes**
(7.1: 14 pairs, countdown $E→$1; 7.5.5: 9 pairs, countdown $8→$1), then LAP
open completes and the boot proceeds.

## Q3 — is the spin entered in a healthy boot?

Yes, briefly: 7.5.5 numbers (full clean boot): spin instruction executed
from 10 contexts, **flag read (spin iterations) 591 total, flag writes 23**.
It always exits because the worker completes synchronously.

(Caveat for posterity: two earlier runs reported `fires=0` — that was a tap
bug, **MAME `install_read_tap` end addresses must have the low 2 bits set**
or the install throws and silently kills the rest of the Lua frame callback.
Fixed in wedge_trace.lua; errors now logged as TAPERR lines.)

## Q4 — NCR completion choreography (SCSI exonerated)

Full healthy-boot register profile (7.1, 9000 frames): reads r4(CSR)=4.2M,
r5(BSR)=27k, r1=6.2k, r0=3.7k, **r7(Reset Parity/IRQ)=1249 ≈ one per
command**; writes MR ∈ {$00,$01,$02} only — **MONITOR BUSY (MR bit 2) is
never set**, killing the lbmactwo loss-of-BSY-IRQ theory. Per command:
selection → polled CDB via reg0+ICR ACK toggles → DMA via write reg7
(StartDMARecv, pc=$A0759E) → STATUS and MSG_IN polled via reg0 → bus free.
Everything from ROM $A074xx–$A079xx, pure polling; the reg-7 *read* clears
the phase-mismatch IRQ latch after each DMA chunk. Our FPGA snapshot ("last
read = reg 7, TCR=7, bus idle, irq_latch=0") is exactly a **completed**
command epilogue. No SCSI wait of any kind at the wedge stage.

## Q5 — DACK byte counts at the probe moment

7.1: probes run at **dack=657,920 bytes** (F≈1132–1190). 7.5.5: probes at
**dack=1,148,416** (F=1260). DACK is frozen during the entire probe window
(no disk traffic while LAP opens) — same signature as the FPGA wedge.

## The SCC choreography (the spec a fixed rtl/scc.v must satisfy)

Channel B (= printer port, ctl $50F04000, data $50F04004). Per lapENQ probe,
all polled, from `wedge_71e.txt.gz` (SCW=write, SCR=read-transition):

```
WR14←$41 ×4 (~100 µs apart)   ; DPLL "reset missing clock" + BRG enable
read RR10 → MUST be $00       ; bit7 (one clock missing) set ⇒ defer
WR5←$62, WR5←$60              ; RTS pulse (TX still disabled)
WR5←$6B                       ; TX enable (+RTS, 8-bit, TxCRC)
WR3←$D0                       ; RX off, ENTER HUNT
WR0←$80                       ; reset Tx CRC
per frame byte (01 01 81 = dst, src, lapENQ):
    poll RR0 until bit2 (TxEmpty)=1   ; MAME returns $54
    write byte → $F04004              ; TxEmpty drops ($50), returns ($54)
WR0←$C0                       ; reset Tx underrun/EOM latch
poll RR0 until bit6 (EOM)=1   ; underrun ⇒ CRC+closing flag sent
poll RR0 until bit2 (TxEmpty)=1
WR5←$62, WR5←$60              ; TX off
WR14←$41; WR3←$DD             ; RX re-enable, hunt, address search
```

Gate at worker entry (`$8b794`): `btst #4,(A0)` — **RR0 bit 4 (Sync/Hunt)
must be 1** (receiver hunting = idle line). bit4==0 ⇒ branch chain
`$8b798→$8b7dc→$8b8c4` = **defer**. MAME's RR0 during the whole window:
$54/$50 — bit4 always set, bit6 mostly set, bit2 per TX state.

## rtl/scc.v gap analysis

1. **RR0 bit 4 hardwired 0** (`scc.v` ~line 895, comment "Sync/Hunt — async:
   always 0"). Correct for async, **wrong in SDLC hunt mode** → every LAP TX
   defers → wedge. THE root cause.
2. **post_loopback TxEmpty trap** (`scc.v:861-874`, commit a89c671, built so
   the 6.0.8 boot-ROM 'atlk' self-test "stalls and gives up"): once local
   loopback is used and cleared, RR0 TxEmpty is forced 0 **forever**. Even
   with (1) fixed, this deadlocks the LLAP byte-TX poll (`$8ba6a`) if 7.x
   ever ran loopback first. Must be scoped (e.g. async-mode only) — with a
   mandatory 6.0.8 regression test (see docs/bootproblems.md:138-156).
3. WR0 commands $80 (Reset Tx CRC) / $C0 (Reset Tx underrun/EOM) and the
   EOM-latch SDLC semantics (set on underrun after last byte ⇒ "CRC+flag
   out") need to hold for the bit-6 poll to exit. RR10 already reads $00 ✓.
4. SCC ExtSts interrupts (WR15) are not generated, and the V8 routing
   (MAME `v8.cpp:325`: SCC IRQ → pseudovia `slot_irq_w<0x20>` + IPL) has no
   equivalent in our pseudovia (`slot_status` has no SCC bit). **Not needed
   for the boot fix** (healthy boot uses zero SCC interrupts) — needed only
   for real multi-node LocalTalk later.

### Minimal fix proposal (boot-unblocking, hardware-faithful)

In `rtl/scc.v`: add a per-channel `hunt` latch — set on WR3 write with bit 4
(Enter Hunt), and (since we model no SDLC receive data) never self-clearing;
expose it as RR0 bit 4 **when the channel is in a sync mode** (WR4 stop-bit
field = 00). Keep async behavior exactly as-is. Verify TxEmpty/EOM behave
through the probe sequence above (the existing async TX sink may already
suffice if post_loopback gating is scoped away from this path). Result: LAP
probes complete synchronously exactly as in MAME; defer never taken; no
interrupt plumbing required.

Diagnostic lever (not a fix): AppleTalk on/off lives in PRAM — flipping it
off in egret.pram would skip .MPP open and dodge the wedge; first Chooser
re-enable would wedge again. Useful as an HW A/B confirmation only.

### Validation

- Verilator: boot the 7.1 SCSI fixture to the Welcome stage (slow — the LAP
  open happens ~19 s emulated; consider `--skipramtest` ROM) and confirm the
  FF→00 probe pairs appear (sim `$display` on the flag write address, or
  just confirm boot passes the extension stage).
- HW: 7.1 + 7.5.5 fixtures must reach the desktop; **6.0.8 must still boot**
  (post_loopback scope regression).

## Tooling notes (new, all in verilator/mame/wedge_trace.lua)

- One-pass tracer: RAM pattern scan (`read_range`+`string.find`; WILD=1 for
  `tst.b d16(An)/bne.s -6` wildcard), fetch tap on matches (captures An →
  flag addr), flag read/write taps (writer PC + SR + stack peek), NCR
  read-transition log, SCC full-write/read-transition log (SCCTAP=1), DACK
  byte counter, periodic snapshots, code hexdump around matches (MEM lines →
  `xxd -r -p` → `unidasm -arch m68020 -basepc`).
- **Tap-range gotcha**: install_*_tap end addresses need low 2 bits set
  (dword-aligned end) or MAME throws and the frame callback dies mid-flight.
- `RET_AT=<frame>` posts Return via `natkeyboard:post("\n")` — needed for
  7.5.5's "not shut down properly" dialog (our force-killed runs dirty the
  volume; the dialog blocks the Finder, NOT the LAP open at F≈1260).
- The 7.1 fixture auto-opens "About This Macintosh" and **shuts the machine
  down** (~t=56 s at idle desktop) — MAME exits cleanly on the Egret
  power-off; don't mistake it for a crash.
- Runs (deterministic-ish; disk images mutate per run):
  `MAME=~/repos/mame/maclc ROMPATH=~/repos/mame/roms RAMSIZE=10M
  TR_OUT=/tmp/wedge_71.txt [WILD=1] [SCCTAP=1] [RET_AT=3400]
  verilator/mame/run_mame.sh -hard /tmp/MacLC_7-1.hd
  -autoboot_script verilator/mame/wedge_trace.lua
  -snapshot_directory /tmp/snap -seconds_to_run 240`

## Artifacts (docs/welcome_wedge_2026-06-12/mame/)

- `wedge_71.txt.gz` — run 1: NCR Q4 profile, full 9000-frame healthy boot.
- `wedge_71c.txt.gz` — run 3: SPIN + FW flag timeline (7.1).
- `wedge_71e.txt.gz` — run 5: SCC choreography (SCW/SCR transitions).
- `wedge_755b.txt.gz` — 7.5.5: wildcard SPIN/FW + SCC + desktop proof.
- `wedge_code_wide.bin` + `lap_module_8b000_dasm.txt` — LAP module dump
  $8B000–$8CCFF and unidasm disassembly (spin $8B6E0, worker $8B75A, defer
  $8B8C4, ExtSts ISR $8B90C, TX tail $8BB1A, RX ISR $8BB7A).
- `boot71_desktop_f3300.png`, `boot755_final.png` — healthy-boot proof.
