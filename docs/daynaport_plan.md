# Plan: "shared" desktop volume via emulated DaynaPort SCSI-Ethernet + netatalk (AFP)

**Date:** 2026-06-09
**Branch context:** `new-video-technique-part-2` (feature is independent of video work)
**Goal:** A `shared` AppleShare/AFP volume appears as a **desktop disk icon** inside Mac OS,
backed by `/media/fat/games/MacLC/shared` on the MiSTer. **Live, bidirectional**, working on
**System 6.0.5 → 7.5.5** (the full range this Mac supports).

---

## 1. Decision record (why this design)

We evaluated several ways to expose host files to the emulated Mac:

| Option | Desktop icon? | Bidirectional/live? | OS 6.0.5–7.5.5 | "Hack"? |
|---|---|---|---|---|
| HFS disk image packed from folder | mounted snapshot | regen + remount; write-back parses image | ✅ | yes (static) |
| Custom HW mailbox + bespoke Mac app | no (lives in an app) | ✅ | app: ✅ / FS-driver: 7.5+ | yes (non-standard) |
| ao486-style network redirector (EtherDFS) | drive, not native | ✅ | — | bespoke |
| **DaynaPort SCSI-Ethernet + netatalk/AFP** | **real AFP volume** | **✅ native** | **✅** | **none — it's the standard** |

**Chosen: emulate a DaynaPort SCSI/Link Ethernet adapter.** This is exactly how the vintage-Mac
community networks real machines today (PiSCSI/RaSCSI and BlueSCSI v2 both emulate a DaynaPort
SCSI/Link), using the **stock Dayna Mac driver** + **stock Apple AppleShare**. It is *more* native
than ao486's own MiSTerFS, which uses a bespoke DOS redirector — we use the Mac's real networking
stack and real period drivers.

User decisions captured during planning:
- **Path:** native DaynaPort + netatalk (AFP). Desktop icon is the goal.
- **Sync:** bidirectional from the start (AFP is inherently bidirectional).
- **Transport (core ↔ Linux):** **EXT_BUS + a MiSTer `Main` support module** (the ao486 mechanism).
- **Where it runs:** on the MiSTer itself.

### Why AppleTalk (not TCP/FTP) for the icon
The DaynaPort card is a real Ethernet interface, so **MacTCP (TCP/IP) rides on it too** and FTP
(vsftpd + Fetch) would work across the whole range. **But TCP/IP cannot give a mounted desktop
icon on System 6/7.0** — the only thing that does is **AFP**, and AFP-over-TCP needs Open Transport
(7.1+). So for the icon across 6.0.5–7.5.5 we must serve **AFP over AppleTalk/DDP**, which means
**netatalk 2.x** (netatalk 3 dropped DDP). FTP can be added later on the *same* card/bridge as a
bonus, but it is not required for the icon.

---

## 2. Architecture

```
 Guest (Mac OS 6.0.5–7.5.5)
   Dayna SCSI/Link driver (extension)  +  EtherTalk (Network cdev)  +  AppleShare (Chooser)
        │  SCSI vendor commands: INQUIRY, send-packet, recv-packet, get-MAC, set-mode
        ▼
 rtl/ncr5380.sv  (initiator/controller; muxes target_*[i])
        │
        ▼
 rtl/daynaport.sv  (NEW SCSI *target*, sibling of rtl/scsi.v disk targets)
   - responds to INQUIRY as "DAYNA   SCSI/Link"
   - DATA-OUT phase = Ethernet frame the Mac is sending  → TX FIFO
   - DATA-IN  phase = Ethernet frame for the Mac to read ← RX FIFO
        │  Ethernet frames over EXT_BUS register/FIFO channel  (NEW in MacLC.sv)
        ▼
 sys/hps_io.sv  EXT_BUS  ──►  MiSTer `Main` support module  (NEW, support/maclc/)
        │  read TX frames → write to tap0 ; read tap0 → push RX frames
        ▼
 Linux tap0 (private host-only subnet)  ──►  netatalk 2.x (atalkd + afpd, AFP/DDP)
        ▼
 /media/fat/games/MacLC/shared   ←─ bidirectional ─→  "shared" volume icon on the Mac desktop
```

Key structural facts (verified in code):
- `rtl/scsi.v` header literally says *"implements a target only scsi device"* and already has a
  `cmd_inquiry` / `inquiry_dout` mechanism → mirror it for the DAYNA identity string.
- `rtl/ncr5380.sv` muxes `target_bsy[i]/target_cd[i]/...` → add the DaynaPort as another target ID.
- The DaynaPort target is **not a block device** (no `sd_lba`/`img_mounted`), so `VDNUM`/`SCSI_DEVS`
  for the HPS disk slots are unchanged; it only consumes a SCSI *bus ID* → **ID 4** (6/5 = disks,
  7 = initiator). Instantiated standalone like the existing `scsi_empty_cd #(.ID(3'd3))` stub.
- `EXT_BUS` is currently **unused** in `MacLC.sv` (only `HPS_BUS` is passed to `hps_io`). We light it
  up for the first time — see `sys/hps_io.sv` `inout [35:0] EXT_BUS` and the `EXT_BUS[32]` mux.

---

## 3. Components & responsibilities

### 3.1 Core RTL
- **`rtl/daynaport.sv`** — new SCSI target. Minimum command set (per the DaynaPort SCSI/Link spec
  as implemented by PiSCSI `scsi_daynaport`):
  - `INQUIRY (0x12)` → vendor "DAYNA", product "SCSI/Link" so the stock driver binds.
  - `READ (0x08)` → return one queued RX Ethernet frame (length-prefixed, with the driver's flag byte).
  - `WRITE (0x0A)` → accept one TX Ethernet frame from the DATA-OUT phase.
  - `0x09` (get device stats / MAC) → return the 6-byte MAC (Dayna OUI prefix the driver expects).
  - `0x0C` / `0x0E` (set mode / multicast / enable) → ack; configure RX filter.
  - `TEST UNIT READY` / `REQUEST SENSE` → standard.
- **EXT_BUS frame channel** — RX FIFO (host→core) + TX FIFO (core→host) + a small register map
  (cmd/status, length, data port) exposed through `EXT_BUS`. Sized for at least one full
  1514-byte Ethernet frame each way plus a few frames of slack.
- **CONF_STR** — add `O<bit>,Network,Off,On;` so the card can be disabled when unused (keeps the
  SCSI bus clean for users who don't want it).

**SCSI ID — DECIDED: ID 4.** Disks are at ID 6 / ID 5 (`scsi #(.ID(3'd6 - i))` generate loop in
`ncr5380.sv`), Mac initiator = ID 7 → **ID 4 is free** and the stock Dayna driver scans the bus for
the DAYNA INQUIRY match regardless of ID.

**Integration recipe (verified in `rtl/ncr5380.sv`):** instantiate `daynaport #(.ID(3'd4))`
*outside* the disk `generate` loop — the existing **`scsi_empty_cd #(.ID(3'd3))`** stub (a disabled
CD-ROM target, `ENABLE_EMPTY_CD=0`) is the **structural template**: a non-block SCSI target wired with
`sel/atn/ack/din(scsi_bus_data)` and folded into the bus by (a) adding `dayna_bsy` to the BSY
wired-OR and (b) one more `if (dayna_bsy)` override block in the `/* Mux target signals */` `always`
(lines ~350–384) driving `scsi_cd/io/msg/req/din*`. No `img_mounted/io_lba/sd_buff` ports — those are
replaced by the EXT_BUS frame ports. `scsi.v` already builds an INQUIRY response inline (lines
~280–331), so `daynaport.sv` returns "DAYNA   SCSI/Link" the same way.

**Command decode — DECIDED: in-RTL** (not CDB passthrough). The command set is tiny and the codebase
already implements SCSI targets in RTL (`scsi.v`, `scsi_empty_cd`), so in-RTL keeps EXT_BUS a clean
"frames-only" pipe and matches existing structure. Revisit only if RTL cost balloons.

### 3.2 MiSTer `Main` support module (`support/maclc/`, forked Main)
- Registered for core name `MACLC`. Pumps frames **EXT_BUS ↔ tap0**.
- Brings up `tap0` on a private subnet; ensures `atalkd`/`afpd` (netatalk 2.x) are running, bound to
  `tap0`, serving `/media/fat/games/MacLC/shared` with guest access.
- Mirrors ao486's `support/x86/` shared-folder server. We ship a patched `MiSTer` binary (or upstream).

### 3.3 Host packages
- **AppleTalk + TUN/TAP kernel support** — `appletalk` (DDP stack netatalk needs) + `tun` (tap
  interface the bridge injects frames into). Both are tristate; three ways to provide them, in order
  of preference:
  1. **Upstream (durable, recommended for distribution):** PR `CONFIG_ATALK=m` + `CONFIG_TUN=m` into
     `MiSTer-devel/Linux-Kernel_MiSTer` `MiSTer_defconfig`. TUN is broadly useful (NFS etc.), ATALK is
     tiny → official kernel carries both forever; zero per-user install, zero treadmill.
  2. **Built-in `=y` (simplest for dev now):** rebuild the kernel from the device's *matching* commit
     with `CONFIG_ATALK=y` + `CONFIG_TUN=y`, replace `/media/fat/linux/zImage_dtb`. No vermagic/module
     dance; built-ins don't touch `/lib/modules` so existing rootfs modules still load. **Caveat:**
     MiSTer's Update script overwrites the kernel on official bumps → must re-flash.
  3. **Shipped `.ko` modules:** build `appletalk.ko`/`tun.ko` out-of-tree from `../Linux-Kernel_MiSTer`
     (5.15.1) with the MiSTer ARM toolchain; auto-load via `/media/fat/linux/user-startup.sh` (no Main
     fork needed to `insmod`). Vermagic must match the running kernel → rebuild per kernel release.
  Note: both #2 and #3 break on official kernel updates; only #1 is maintenance-free.
- **netatalk 2.x** cross-compiled for the MiSTer ARM (armv7). Volume `shared` →
  `/media/fat/games/MacLC/shared`; AppleDouble sidecars preserve resource forks / type-creator.
  Track the **saybur/rdmark netatalk-2.x** forks (maintained specifically for this retro use case).

### 3.4 Guest (Mac OS) — baked once into a setup image
- Install the **Dayna SCSI/Link driver** extension into the System Folder.
- Enable **EtherTalk** in the Network control panel.
- **Chooser → AppleShare → server → mount `shared`**; optionally auto-mount at startup (alias in
  Startup Items + saved password). One-time; invisible thereafter.
- Provide pre-baked images for 6.0.5, 7.0/7.1, and 7.5.5.

---

## 4. Phased build (each phase ends at a demonstrable milestone)

**Phase 0 — Study & de-risk (no behavior change).**
- Read `rtl/scsi.v`, `rtl/ncr5380.sv` target arbitration; confirm how to add a target ID and how
  pseudo-DMA DATA-IN/OUT phases move bytes. Pick the DaynaPort SCSI ID (free vs the two disks).
- Confirm the `EXT_BUS`/`user_io` register protocol Main expects (study an existing EXT_BUS core).
- AppleTalk/DDP kernel story — **DONE (2026-06-09, see §5):** stock 5.15.1 kernel lacks `CONFIG_ATALK`
  *and* `CONFIG_TUN`, but both are in-tree, module-capable, `CONFIG_MODULES=y`/no MODVERSIONS → build
  `appletalk.ko` + `tun.ko` out-of-tree and `insmod` at runtime; no kernel reflash.
- Deliverable: `docs/daynaport_design.md` + the in-RTL-vs-passthrough decision + SCSI-ID choice.

**Phase 1 — DaynaPort SCSI target + EXT_BUS channel (RTL).**
- Add `rtl/daynaport.sv` + wire into `ncr5380` target mux; add EXT_BUS RX/TX FIFOs + reg map in
  `MacLC.sv`; CONF_STR `Network` toggle.
- **Milestone:** Verilator — the Dayna driver enumerates the card (INQUIRY match) and reads the MAC;
  `check_boot.sh` still PASSES (no regression to the existing HD0 SCSI boot). Mirror the sim split
  into `verilator/sim.v` per `docs/verilator_differences.md`.

**Phase 2 — Host bridge + first packet (Main module + TAP).**
- Implement `support/maclc/` EXT_BUS↔tap0 pump; bring up `tap0`.
- **Milestone (transport proven before any file server):** `tcpdump -i tap0` on the MiSTer shows the
  Mac's EtherTalk/AARP frames, and an **EtherTalk AEP ping / NBP lookup round-trips**. This validates
  the entire path end-to-end with zero AFP complexity.

**Phase 3 — netatalk → the desktop icon.**
- Cross-compile + package netatalk 2.x; auto-start from the support module; config `shared` volume.
- **Milestone:** Chooser → AppleShare → server appears → mount → **`shared` disk icon on the desktop**;
  drag a file in (host sees it) and out (Mac sees it). Validate on 7.1, then 6.0.5 and 7.5.5.

**Phase 4 — Guest packaging & docs.**
- Ship ready-to-use boot/installer images (Dayna driver + EtherTalk + auto-mount) for each OS tier.
- Document the user flow in `readme.md` + `docs/shared_folder.md`.
- Optional: enable **vsftpd** on the same bridge for TCP/IP/FTP power users.

**Phase 5 — polish / fidelity.**
- Type/creator mapping so host files open by double-click; HFS 31-char filename handling; large files.
- Frame-FIFO depth / EXT_BUS throughput tuning (AFP is chatty). Reconnect cleanly across warm boot.

---

## 5. Risks & open questions
- **AppleTalk/DDP on the MiSTer kernel — RESOLVED (2026-06-09).** Stock kernel = Linux **5.15.1 (ARM)**;
  `# CONFIG_ATALK is not set` *and* `# CONFIG_TUN is not set`. **But both are in-tree and module-capable**
  (`net/appletalk/` → `appletalk.ko`; `drivers/net/tun.c` → `tun.ko`), and `CONFIG_MODULES=y`,
  `CONFIG_MODULE_UNLOAD=y`, `# CONFIG_MODVERSIONS is not set`, deps satisfied (`CONFIG_LLC=y`, INET).
  → **No kernel reflash.** Build `appletalk.ko` + `tun.ko` out-of-tree (`CONFIG_ATALK=m`, `CONFIG_TUN=m`)
  from the *exact* running-kernel source/commit (vermagic must match — verify with `uname -a`/`/proc/version`
  on-device) and `insmod` them from the support module before starting netatalk. Source clone is at
  `../Linux-Kernel_MiSTer`.
- **Patched `Main` maintenance** — shipping/maintaining a forked `MiSTer` for this core (ao486
  precedent, but a real burden). Prefer upstreaming the support module.
- **EXT_BUS throughput/latency** — AFP is chatty; size FIFOs and the Main poll loop accordingly.
  Quantify during Phase 2.
- **SCSI target splice must not regress disk boot** — the existing SCSI/pseudo-DMA path is delicate
  (see prior SCSI handoffs). Phase 1 must keep `check_boot.sh` green.
- **Warm-boot/reset interaction** — there is an open warm-boot grey-screen bug
  (`core-reset-needs-full-reboot`); make sure the card's reset state is sane and doesn't worsen it.
- **Verilator coverage** — sim can unit-test SCSI command responses and frame FIFO movement, but full
  EtherTalk/AFP validation is hardware-side.

---

## 6. Rough effort
- P0 study/de-risk: 1–2 d · P1 RTL target+EXT_BUS: 3–5 d · P2 bridge+ping: 2–4 d (risk concentrates
  here) · P3 netatalk: 2–4 d · P4 packaging: 1–2 d · P5 polish: ongoing.

## 7. References
- PiSCSI DaynaPort SCSI/Link emulation (command set): https://github.com/PiSCSI/piscsi/wiki/Dayna-Port-SCSI-Link
- RaSCSI DaynaPort (Applefritter mirror): https://git.applefritter.com/Macintosh-HW/RASCSI/wiki/Dayna-Port-SCSI-Link
- netatalk 2.x (AppleTalk/DDP for System 6/7), maintained forks: https://github.com/rdmark/netatalk-2.x , https://github.com/saybur/Netatalk-2.x
- netatalk (AppleTalk required for System 6.0–7.6): https://netatalk.io/readme
- ao486 MiSTerFS (precedent: core-specific file service in Main): https://github.com/MiSTer-devel/ao486_MiSTer
- hfsutils / libhfs (fallback HFS-image route, if ever needed): https://www.mars.org/home/rob/proj/hfs/
