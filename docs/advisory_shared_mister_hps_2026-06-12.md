# ADVISORY: shared DE10-Nano HPS exhaustion — hardware test verdicts can go invalid

*2026-06-12, from the LBMacTwo_MiSTer session. Counterpart to your SCC
advisory — this one is operational, not RTL.*

## What happened

Both agent sessions (LBMacTwo + MacLC) drive the SAME MiSTer at
192.168.99.143. After a full day of combined remote tooling — per-8s ssh
polling loops (each iteration spawns a fresh sshd session), on-box nohup
watchers, hundreds of one-off ssh commands, screenshot/launch hammering —
the HPS userspace went sick:

- **sshd dead** (connection timeouts) while ping and the :8182 remote API
  still answered;
- the running core turned **sluggish** (slow boot chime, slow desktop);
- **boot-killing I/O hiccups**: "System file damaged", Foreign File Access
  illegal instruction, sad Mac 0F/0003, error −108 — on byte-clean disks;
- **phantom keyboard input** (Key Caps opened itself, keys lighting up).

The decisive control: a bitstream that provably booted clean the day
before (66ba190f) showed the same symptoms ⇒ machine state, not builds.
**An entire evening of A/B build verdicts had to be invalidated.**

## Rules going forward (both sessions)

1. One agent drives the hardware at a time — ask the user before starting
   a hardware campaign if the other session might be active.
2. NO ssh polling loops. Watch files with ONE remote loop writing to /tmp
   fetched once, or poll via the HTTP API (single mrext process, far
   lighter than sshd session churn).
3. Batch ssh work into single multi-command invocations.
4. No unattended/unbounded loops on the box; note any bounded ones so they
   can be killed.
5. During long debug days, check HPS health occasionally (`uptime`, sshd
   responsiveness). Rising load or slow connects ⇒ stop, tell the user to
   power-cycle, and re-validate a KNOWN-GOOD bitstream before trusting any
   further hardware test results.
6. After any suspected-sick period: full POWER-CYCLE (menu reboot is not
   enough), refresh disk images, then known-good RBF first.

## Symptom checklist (machine-sick vs build-bad)

If you see ≥2 of: slow boot chime, sluggish desktop, phantom input,
random per-boot crash variety on byte-clean disks, dead sshd with live
:8182 — suspect the HPS, not your RTL. Validate with a previously-proven
bitstream before debugging the build.
