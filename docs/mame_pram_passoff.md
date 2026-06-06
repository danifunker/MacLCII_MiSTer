# Pass-off → MacBook (MAME): how does Mac LC PRAM persistence actually work?

Paste everything below into a fresh Claude Code session on the MacBook (which has MAME +
the `verilator/mame/` tooling; the Windows/Quartus box does not). It is self-contained.

---

## Your mission
We are debugging **PRAM persistence on the MacLC_MiSTer FPGA core**. On hardware, a saved
PRAM image does NOT restore across reboots: the 68k ROM's `InitUtil` **reinitializes PRAM
on every boot** even though a valid `'NuMc'` signature and `SPValid=0xA8` are present in the
PRAM the 68k reads. We need MAME (`maclc`) as ground truth to find **what makes the ROM
accept persisted PRAM as valid** (so it does NOT reinit) — i.e. what our core is failing to
provide. Your job is to investigate in MAME and **pass back a structured report** (format at
the end) so the FPGA-side session can continue.

## Read first (in this repo, on the Mac)
- `docs/mame_compare.md` — how to run/trace MAME `maclc` here (`verilator/mame/`:
  `run_mame.sh`, `tap.lua`, `snap.lua`, `trace.dbg`), plus gotchas (debugger defaults to the
  Egret HC05 not the 68020; macOS has no `timeout`; MAME PCs are 8-digit `00Axxxxx`).
- `docs/findings_pram_load_broken_2026-06-06.md` — the full bug write-up (what we tested).
- `docs/MacLC_ROM_Boot_Sequence_Analysis.md` §"PRAM Layout / Validity" — the ROM model we
  have: validity = `'NuMc'`(0x4E754D63) at XPRAM `0x0C–0x0F` **and** `SPValid=0xA8` at XPRAM
  `0x10`; if missing, `InitUtil` writes `'NuMc'`, clears XPRAM `0x20–0xFF` (+`0x00–0x07`),
  writes `PRAMInitTbl` defaults to `0x76–0x89`, preserves `0x08–0x1F`.

## Key facts from the FPGA side (so you know what to compare against)
- Core is **Mac LC** with the **Egret HC05** (`USE_EGRET_CPU`); MAME `maclc` emulates the
  same Egret + ROM, so it is a faithful reference.
- Symptom is `InitUtil`-every-boot: we inject `0xAA` into XPRAM `0x20–0xFF` reserved bytes,
  reboot, and they always read back `0x00` (cleared), with the rest reverting to a fixed
  default — **independent of what PRAM we load.** Both our loaded images and our default now
  carry valid `'NuMc'`+`0xA8`, yet `InitUtil` still runs. So validity is failing for a reason
  **beyond** `NuMc`/`SPValid` (a checksum? the clock/time? an Egret power/reset status bit?).
- Our 256-byte PRAM "good" image (`nvr0`, the value the Mac itself converges to). Non-zero
  bytes, `offset=value` (hex, XPRAM-relative; everything else `00`):
  `01=80 02=4f 03=48 08=13 09=88 0B=4c 0C=4e 0D=75 0E=4d 0F=63 10=a8 14=cc 15=0a 16=cc 17=0a
  1D=02 1E=63 57=29 58=80 59=a6 5A=06 77=01 78=ff 79=ff 7A=ff 7B=df`
  (`0C–0F`='NuMc', `10`=SPValid, `58`=screen depth: `80`=2bpp / `81`=1bpp.)
- Leading hypotheses for why our ROM reinits despite valid `NuMc`:
  1. The Egret reports a **power-on / clock-invalid status** every boot → OS zaps PRAM.
  2. The validity check uses **more than NuMc/SPValid** (a checksum, or a 1904-epoch clock
     sanity test). Our boot-copy reseeds RTC seconds from the host Unix `TIMESTAMP` each boot.
  3. The HC05 firmware re-initializes its PRAM region **after** our boot-copy.

## Tasks (in MAME `maclc`)
1. **Does MAME persist PRAM at all?** Find MAME's nvram for `maclc` (e.g. `nvram/maclc/…` —
   Egret/Cuda PRAM + RTC). Run `maclc` once (boot to desktop), exit cleanly, then list/dump
   the nvram file(s): path, size, and a hex dump of the PRAM. Note format/epoch.
2. **Round-trip a setting.** Boot, change a PRAM-backed setting (e.g. Monitors depth, or beep
   volume), exit (saves nvram), relaunch, and confirm the setting **persists** across the
   restart. Report whether it does, and which nvram bytes changed.
3. **Does `InitUtil` run every boot, or only when invalid?** Use the MAME debugger to watch
   the boot PRAM path on the **maincpu (68k)** — set the CPU correctly (debugger defaults to
   the Egret), then trace/breakpoint the PRAM-validity routine and the Egret `Read PRAM`
   (cmd 0x03) / time / status traffic. Determine: on a **second** boot (with valid saved
   nvram), does the ROM SKIP the reinit (clears do NOT happen) — confirming persistence — or
   does it reinit anyway?
4. **Pin down the exact validity gate.** What does the ROM actually compare to decide
   "PRAM valid"? Capture the addresses/values: the `'NuMc'` check, the `SPValid` check, AND
   anything else — a **checksum** over PRAM, a **time/clock sanity** check, or an **Egret
   status/power byte** (does the ROM query the Egret for a "valid clock / didn't lose power"
   status, and what value makes it pass?). This is the crux: name the specific condition our
   core must satisfy.
5. **Capture a known-good persisted PRAM** from MAME (full 256-byte XPRAM hex) and **diff it
   against our `nvr0` bytes above** — call out any byte that differs (especially a checksum
   byte, the clock area, or `0x08–0x1F`).
6. **Egret responses.** Dump what MAME's Egret returns for: PRAM read, the RTC time (value +
   epoch), and any status/power command the ROM issues at boot. This tells us what our Egret
   model must mimic.

## Deliverable — write `docs/mame_pram_findings.md` AND print this summary to paste back
Fill in every field; "unknown" is allowed but say why.

```
MAME PRAM PERSISTENCE FINDINGS
1. MAME version + maclc ROM set (sha if handy):
2. PRAM persists across MAME restarts? (yes/no) + nvram path + size + format/epoch:
3. Setting round-trip (task 2): setting changed, persisted? which bytes changed:
4. Does InitUtil/PRAM-reinit run EVERY boot, or skipped when nvram valid? (evidence: trace
   snippet / addresses showing the clear of 0x20-0xFF happening or NOT):
5. EXACT validity gate(s) the ROM uses (addresses + the compared values): NuMc? SPValid?
   checksum (formula/where)? clock/time sanity? Egret power/status byte (which cmd, which
   value = "valid")?:
6. Known-good 256-byte XPRAM hex from MAME:
7. Diff vs our nvr0 (bytes that differ + meaning):
8. Egret RTC: time value returned + epoch (1904 vs 1970) + does a bad time trigger reinit?:
9. Egret status/power: does the ROM read a "didn't lose power / clock valid" status, and what
   must our Egret return so the ROM trusts PRAM?:
10. BOTTOM LINE: the single specific thing our FPGA core must do so the ROM stops zapping
    PRAM every boot (e.g. "Egret must report status bit X=0", "PRAM needs checksum at 0xNN",
    "clock must be a valid 1904-epoch value", etc.):
```

If the repos are git-synced, commit `docs/mame_pram_findings.md` on a branch and push so the
FPGA session can pull it; otherwise just paste the summary block back.
