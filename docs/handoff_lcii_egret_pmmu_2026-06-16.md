# Handoff: Mac LC II boot — Egret SR fixed (matches MAME), blocker is the 68030 PMMU

**Date:** 2026-06-16
**Branch:** `030_LCii` (MacLC_MiSTer)
**Commits this session:** `b0d8af7` (the two Egret fixes + diagnostics),
`f2d4fb4` (bug #3 root-mechanism docs). This handoff = a third commit.
**Status:** The Egret↔VIA shift-register transaction is now **byte-perfect vs MAME**
(two real chipset bugs fixed). The boot still does **not** complete — but the remaining
blocker is now **root-caused to the 68030 PMMU** (a CPU-core bug), not the chipset.

---

## TL;DR

The LC II boot was failing in the Egret/ADB init (`$A4A290`) → `$00007FF8` wedge. This
session decomposed that into **three** bugs:

1. **bug #1 — Egret CB2 has no pull-up (FIXED, committed `b0d8af7`).**
   `rtl/dataController_top.sv:611`: when the Egret tri-states CB2 at the receive→send
   turnaround, the VIA must read **0** (MAME models PORTB bit5 with no pull-up —
   `egret.cpp:90 set_pullups<1>(0x40)` pulls up only bit6). Ours read the vestigial
   soft-keyboard line `kbddata_o` (idle **1**) → first response byte `FF` (an invalid
   Egret packet type). Fix: `.cb2_i(cuda_cb2_oe ? cuda_cb2 : 1'b0)`.

2. **bug #2 — blank top-of-XPRAM (FIXED, committed `b0d8af7`).**
   Cmd `0x07` = GET_PRAM (`01 07 00 F9` reads `pram[0xF9]`; decode in
   `docs/lcii_rtl_fixes_log.md`). `rtl/egret/egret.pram` was zero in `0xF0..0xFF`;
   MAME's initialized XPRAM has `pram[0xF9]=01` (+`F0=02 F1=EE F3=EC FB=8C`). Seeded
   those from MAME's `nvram/maclc2/egret`. (Runtime `$readmemh`, **no re-verilate**.)
   NOTE: the boot does `bset #0,D1` on the GET_PRAM result so the *value* barely
   matters — this fix makes the SR response match MAME but is **not** the boot blocker.

   **Result of #1+#2:** the cmd-07 Egret response is now `00 01 00 07 01` =
   MAME, byte-for-byte. The whole Egret/VIA-SR path is **exonerated**.

3. **bug #3 — 68030 PMMU bus-errors on the first MMU-translated fetch (NOT fixed; CPU-core).**
   This is the actual boot blocker and the rest of this doc.

---

## bug #3 — the real blocker (root-caused, mechanism in hand)

After the Egret transactions, the boot runs the **68030 MMU/cache-enable routine at
`$A41670`** (disassemble the fast-mem ROM as m68030; ROM is at CPU `$A00000`, so
`$A41670` = file offset `$41670`):

```
a4167a: movec  CACR,D5
a41682: movec  D5,CACR          ; enable caches
a41686: pmove  ($4,A3),srp      ; A3=$003FFFB2; page tables in top-of-RAM
a4168c: pmove  ($8,A3),crp
a416a0: movec  D5,VBR           ; **VBR = 0**
a416aa: pmove  (A6),crp
a416b2: pmove  (A3),tc          ; **ENABLE the MMU**
a416b6: jmp    (A5)             ; A5 = A2 = $40A0010E  (32-bit ROM-alias continuation VA)
```

`jmp (A5=$40A0010E)` is the **first MMU-translated fetch**. With `+define+PMMU_TRACE`:

```
PMMU REQ 003fee00 → 0009fc0a            (root descriptor)
PMMU REQ 003fee04 → 003fedd0            (level-1 table pointer)
PMMU trap_berr addr=00a416b6           ← BUS ERROR on the translated fetch
... later the same VA re-walks and RESOLVES: 003fee00→003fedd0→003fedd4→00100019
    (a valid early-termination page descriptor → physical ~$00100000) ...
```

So **two coupled CPU-side defects**:

1. **Spurious bus error on the first MMU-translated access.** The page tables are
   *valid* (the VA does resolve to a real page descriptor `00100019` → phys
   `~$00100000` on a later walk), yet the first translated fetch `trap_berr`s. Smells
   like the same bus-FSM/DTACK family as the earlier phi-parity *walk-stall* fix
   (`docs/findings_pmmu_walk_stall_2026-06-15.md`, commit `35aa11b`), not fully cured
   for the translated **data** access — or a `$40xxxxxx` VA index/limit/TC-IS handling
   issue in the walker.
2. **The fault is unrecoverable.** `movec D5,VBR` set **VBR=0**, so the 68030
   bus-error exception (#2) vectors through physical `$08`, which is **zeroed RAM** →
   handler `0` → **PC=`000000`** → executes the reset vectors as garbage
   (`0020 2000 40A4 639A …`) → walks up → `$FFFFFFAA` → **`$00007FF8` wedge**.

This is exactly the *"second bug after PMMU-enable"* that
`docs/handoff_lcii_boot_postpmmu_2026-06-15.md` suspected but couldn't locate. The
earlier session fixed the PMMU **walk deadlock**; this session shows the **translated
access** still faults.

### Recommended next steps (CPU-side, `rtl/tg68k/`)
- **Compare to MAME:** does MAME translate `$40A0010E` to phys `~$00100000` and DTACK
  the fetch cleanly? (MAME boots the fast-mem ROM — see oracle below.) If yes, our
  walker/bus-FSM is faulting where MAME doesn't.
- **Bus-FSM/DTACK:** check whether the `tg68k.v` s_state↔phi parity fix (line ~126)
  needs to extend to the **post-walk translated data/fetch access** (not just the
  walker's descriptor reads). The `trap_berr` fires *after* the root read but *before*
  the table-entry read on the FIRST walk — a transition/first-access timing smell.
- **Walker index/limit:** decode the root descriptor `0009fc0a` (limit field?) and the
  TC (loaded from `[A3]=$3FFFB2`) IS/PS fields; verify the `$40A0010E` index doesn't
  trip a spurious limit violation. Add a PMMU_TRACE line for the VA + computed indices.
- **Strategic:** you're importing a real **MC68030 (PMMU+caches)** in the MacIIvi repo.
  This derail is very likely exactly what that core resolves — the highest-leverage
  path is probably the MC68030 import rather than another TG68K-PMMU patch.

---

## What is solid / ruled out (don't re-litigate)

- **The Egret/VIA SR path is correct.** After #1+#2 the SR command+response match MAME
  byte-for-byte (`01 07 00 F9` → `00 01 00 07 01`). Verified bit-level (the VIA faithfully
  shifts what the Egret drives; the Egret's HC05 firmware is the same 341S08xx as MAME).
- **The earlier "$A4A18C loop never terminates / handshake" framing is superseded.** The
  loop spins/derails *independently* of the SR data (it's identical with the response
  matching MAME). The derail is downstream in the PMMU, not the Egret handshake.
- **Egret cmd decode (from the HC05 ROM disasm):** `0x01`=pseudo packet, `0x07`=GET_PRAM,
  `0x0C`=SET_PRAM; cmd-07 handler `$1760` builds a `LDA $A8A9/RTS` stub at `$A7` and
  `jsr $A7` to read `mem[$A8:$A9]` (for `00 F9` → `$01F9` = `pram[0xF9]`). Full writeup +
  protocol sources in `docs/lcii_rtl_fixes_log.md`.
- **Null-RAM-table, cmp flag-race** — both previously disproven (measurement artifacts).
- **Sim speed ~0.6 FPS is inherent** (see memory `maclc-verilator-sim-speed`).

---

## Tooling / how to reproduce

**ROMs (`releases/`):** `boot0.rom` is the committed **stock** LC II ROM (sha `d5786182`).
For sim testing use the **fast-mem** ROM (clamps the slow RAM march, reaches the PMMU
stage fast and matches MAME's boot):
```
cp releases/boot0-fastmem.rom releases/boot0.rom      # sha 7edb1a10; RESTORE stock before committing
```
(`boot0-nomemcheck.rom` skips the RAM test entirely — reaches PMMU even faster but then
runs into zeroed low RAM; a *skip artifact*, per the post-pmmu handoff.)

**Build / run (Verilator 5.048 — re-verilate is only ~36s, NOT 14 min):**
```
cd verilator
make                                                  # full build/re-verilate ~36s
./obj_dir/Vemu --headless --no-cpu-trace --verbose --stop-at-frame 158 > x.log 2>&1
```
Timeline: chime ~F94, first Egret txn ~F117, MMU-enable + derail **~F153–155**,
`$7FF8` wedge from ~F179. macOS has no `timeout`; bound with `--stop-at-frame`.

**Diagnostic detectors (committed in `verilator/sim_main.cpp`, gated/capped):**
- `[SRTRN]`/`[DDRT]` — Egret CB1/CB2/oe SR turnaround (frames 114-121).
- `[HC5]` — one-shot HC05 PC+regA trace of the first cmd-07 txn (F117).
- `[JMP6]` — the `$A4A2xx`/`$A4A4xx` coroutine flow (jmp(A6)/EXIT(A3)).
- `[DERAIL]` — fires when the 68k PC enters `$FFxx00` (NOTE: `mpc = debug_pc & 0xFFFFFF`
  is masked to 24-bit, so the derail PC `$FFFFFFAA` shows as `mpc=$FFFFAA`).
- `[RING]` — 48-entry instruction lead-up buffer; flushes on the first abnormal PC →
  shows the exact jmp/rts that derailed + regs. **This is what found `$A41670`.**

**PMMU walker trace:** uncomment `+define+PMMU_TRACE` in `verilator/Makefile:23`,
re-verilate, run to F157, then `grep -aE 'PMMU (REQ|ACK|berr)' x.log`. (Revert the
Makefile line afterward — it's a debug-only define.)

**Disassembler:** `unidasm <bin> -arch m68030 -basepc <addr>` for 68k (handles pmove/
movec/F-line); `-arch m6805` for the Egret HC05 ROM. Build a CPU-address-aligned 68k
bin with `dd if=releases/boot0.rom bs=1 skip=$((0xOFFSET)) ...` where offset = CPU addr −
`$A00000`. HC05 ROM: pad `rtl/egret/egret_rom.hex` into a `$2000` bin with the ROM at
offset `$0F00` (CPU `$0F00`→rom off 0).

**MAME-on-our-ROM oracle (boots the fast-mem ROM cleanly):**
```
# split releases/boot0-fastmem.rom into 4 byte-interleaved chips in /tmp/patchroms/maclc2/
/opt/homebrew/bin/mame maclc2 -rompath '/tmp/patchroms;/private/tmp/goodroms' -ramsize 4M \
  -nothrottle -video none -nowindow -sound none -skip_gameinfo -autoboot_delay 0 -seconds_to_run 4
```
MAME's Egret PRAM image is `nvram/maclc2/egret` (256 bytes; `pram[0xF9]=01`). The HC05 is
the named CPU `:egret:egret` (M68HC05E1); PORTB=prog addr `$01`, DDRB=`$05`.

---

## Key addresses (bug #3)
- MMU-enable routine: `$A41670` (movec/pmove); MMU enabled at `$a416b2 pmove (A3),tc`;
  faulting jump `$a416b6 jmp (A5=$40A0010E)`.
- Page tables: root walked at `003fee00` → table `003fedd0`; resolved page desc
  `00100019` (phys `~$00100000`). TC/SRP/CRP loaded from `A3=$003FFFB2` (`[A3]`/`[A3+4]`/
  `[A3+8]`). `VBR=0` (set at `$a416a0`). Bus-error vector #2 at phys `$08` (zeroed).
- Derail: `trap_berr @ $a416b6` → PC `000000` → `$FFFFFFAA` → `$00007FF8` wedge (~F155→F179).

## Files touched / committed this session
- `rtl/dataController_top.sv` — fix #1 (CB2 pull-up). **committed**
- `rtl/egret/egret.pram` — fix #2 (XPRAM 0xF0-0xFF). **committed**
- `verilator/sim_main.cpp` — diagnostics. **committed**
- `docs/lcii_rtl_fixes_log.md` — full evidence trail (read this first). **committed**
- `releases/boot0.rom` — left as committed **stock** (use `boot0-fastmem.rom` to test).
- Memory: `lcii-boot-blocker-ramtable` updated with all three bugs.
