#!/usr/bin/env python3
"""Push (optional) and launch a MiSTer core by driving the main-menu OSD.

Reusable across cores and machines: every machine-specific value (host, port, ssh
key, core filename, folder) is a CLI flag or environment variable, so nothing
personal is baked into this file.

The OSD keystroke sequence is GENERATED at run time from the LIVE menu listing
(POST /api/menu/view), so a core dropped into the folder under ANY new filename is
found correctly -- just pass its filename via --core. No menu position is ever
hard-coded; adding/removing cores (e.g. the downloader re-populating _Unstable)
recomputes the row counts on the next run.

What it does (each step optional):
  1. --push FILE : scp FILE into the folder on the MiSTer (md5-verified).
  2. reboot      : POST /api/settings/system/reboot (clean core exit -> main menu),
                   then poll until the web service returns. --no-reboot to skip.
  3. select      : POST /api/menu/view to read root + the folder, compute
                   down*N/confirm keystrokes, send them over ws /api/ws.
  4. verify      : read the coreRunning broadcast to confirm what launched.

IMPORTANT -- sorting: /api/menu/view returns items in BYTE (case-SENSITIVE) order,
which does NOT match the on-screen OSD. The OSD is case-INSENSITIVE (verified on
hardware: "ao486" sorts among the "A"s; a core named "MacLC" is the first "M",
before "MSX"). So we ignore the API order and re-sort filenames ourselves. A fresh
subfolder opens with the cursor on its <UP-DIR> row, so the core's real row is its
index + 1 (auto-derived from the listing's `up` field; override --updir-rows).

The screenshot API does not capture the OSD, so this can't see the cursor; it
computes row counts from the live listing and verifies the result after launch.

Examples:
  # Launch a core already present (uses MISTER_HOST/MISTER_HTTP_PORT from env):
  python launch_unstable_core.py --core MacLC.rbf
  # Push a fresh build then launch it, explicit host + key:
  python launch_unstable_core.py --host 192.168.1.50 --ssh-key ~/.ssh/mister \
      --push ./output_files/MacLC.rbf --core MacLC.rbf
  # Preview the generated keystrokes without touching anything:
  python launch_unstable_core.py --core MacLC.rbf --dry-run
"""
import argparse
import asyncio
import hashlib
import json
import os
import posixpath
import shlex
import subprocess
import sys
import time
import urllib.request

import websockets


# --------------------------------------------------------------------------- API
def api_post(host, port, path, body, parse=True, timeout=10):
    url = f"http://{host}:{port}/api{path}"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    return json.loads(data) if parse else data.decode(errors="replace")


def osd_order(filenames):
    """Order entries the way the MiSTer OSD does: case-INSENSITIVE, raw bytes as the
    tie-break (matches how same-name/different-case cores fall out by date)."""
    return sorted(filenames, key=lambda n: (n.lower(), n))


def menu_view(host, port, path):
    return api_post(host, port, "/menu/view", {"path": path})


def folder_entry(host, port, folder):
    """Return the root menu entry (dict) for `folder`, or exit with a clear error.
    The main menu lists only the '_'-prefixed folders by their full filename."""
    view = menu_view(host, port, "")
    by_name = {it["filename"]: it for it in view["items"]}
    if folder not in by_name:
        sys.exit(f"ERROR: folder {folder!r} not in the main menu. Present: "
                 f"{sorted(by_name)}")
    return by_name[folder]


def plan(host, port, path, target):
    """(row, total, has_updir) of `target` within the menu folder at `path`."""
    view = menu_view(host, port, path)
    names = [it["filename"] for it in view["items"]]
    order = osd_order(names)
    if target not in order:
        sys.exit(f"ERROR: {target!r} not listed under menu path {path or '<root>'!r} "
                 f"({len(order)} entries present)")
    return order.index(target), len(order), bool(view.get("up"))


def updir_for(has_updir, override):
    if override is not None:
        return override
    return 1 if has_updir else 0


# -------------------------------------------------------------------------- push
def _md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _ssh_opts(key):
    opts = ["-o", "StrictHostKeyChecking=no"]
    if key:
        opts += ["-i", os.path.expanduser(key)]
    return opts


def push_rbf(local_path, host, user, key, remote_path):
    if not os.path.isfile(local_path):
        sys.exit(f"ERROR: --push file not found: {local_path}")
    target = f"{user}@{host}:{remote_path}"
    print(f"[push] scp {local_path} -> {target}")
    subprocess.run(["scp", "-q", *_ssh_opts(key), local_path, target], check=True)
    local = _md5(local_path)
    out = subprocess.run(
        ["ssh", *_ssh_opts(key), f"{user}@{host}", f"md5sum {shlex.quote(remote_path)}"],
        check=True, capture_output=True, text=True).stdout
    remote = out.split()[0] if out else ""
    if local != remote:
        sys.exit(f"ERROR: md5 mismatch after scp (local {local} != remote {remote})")
    print(f"[push] md5 verified: {local}")


# ------------------------------------------------------------------------ reboot
def reboot_and_wait(host, port, wait):
    print("[reboot] POST /api/settings/system/reboot")
    try:
        api_post(host, port, "/settings/system/reboot", {}, parse=False, timeout=5)
    except Exception as e:
        print(f"[reboot] (request ended as expected while it reboots: {e})")
    print("[reboot] waiting for it to go down, then polling for the web service...")
    time.sleep(12)
    deadline = time.time() + wait
    while time.time() < deadline:
        try:
            menu_view(host, port, "")
            print("[reboot] web service back; letting the menu settle")
            time.sleep(6)
            return
        except Exception:
            time.sleep(4)
    sys.exit(f"ERROR: MiSTer web service did not return within {wait}s")


# -------------------------------------------------------------------------- keys
async def _drain(ws, timeout):
    try:
        while True:
            await asyncio.wait_for(ws.recv(), timeout=timeout)
    except asyncio.TimeoutError:
        pass


async def _read_core_running(ws, total):
    loop = asyncio.get_event_loop()
    end = loop.time() + total
    last = None
    while loop.time() < end:
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=max(0.1, end - loop.time()))
        except asyncio.TimeoutError:
            break
        if isinstance(msg, bytes):
            msg = msg.decode(errors="replace")
        if msg.startswith("coreRunning:"):
            last = msg.split(":", 1)[1]
            if last:
                return last
    return last


async def send_keys(host, port, keys, delay):
    url = f"ws://{host}:{port}/api/ws"
    async with websockets.connect(url) as ws:
        await _drain(ws, 0.5)
        for k in keys:
            if k.startswith("sleep:"):
                await asyncio.sleep(float(k.split(":", 1)[1]))
                continue
            await ws.send(f"kbd:{k}")
            await asyncio.sleep(delay)


async def read_running(host, port):
    url = f"ws://{host}:{port}/api/ws"
    async with websockets.connect(url) as ws:   # fresh connect -> server pushes state
        return await _read_core_running(ws, 6.0)


def verify(host, port, expect):
    print("[osd] keys sent; waiting for the core to come up...")
    time.sleep(7)
    try:
        running = asyncio.run(read_running(host, port))
    except Exception as e:
        print(f"[osd] WARN: could not reconnect to verify launch: {e}")
        return 0
    if running is None:
        print("[osd] WARN: no coreRunning broadcast seen - could not verify launch")
        return 0
    if running == "":
        print("[osd] FAIL: coreRunning is empty - still at the menu, the selection "
              "missed the core. Re-check --updir-rows or the folder listing.")
        return 1
    exp, r = expect.lower(), running.lower()
    if exp == r or exp in r or r in exp:
        print(f"[osd] OK: coreRunning='{running}' - {expect} launched")
        return 0
    print(f"[osd] launched coreRunning='{running}', but expected '{expect}'. Core "
          f"names can differ from filenames; confirm on screen (or pass --no-verify).")
    return 0


# -------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(
        description="Push + launch a MiSTer core via the main-menu OSD (no hard-coded "
                    "positions; sequence generated from the live menu).")
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST", "MiSTer.local"),
                    help="MiSTer hostname/IP (env MISTER_HOST; default MiSTer.local)")
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("MISTER_HTTP_PORT", "8182")),
                    help="MiSTer Remote port (env MISTER_HTTP_PORT; default 8182)")
    ap.add_argument("--core", default=os.environ.get("RBF_NAME"),
                    help="core filename to launch, e.g. MacLC.rbf (env RBF_NAME)")
    ap.add_argument("--folder", default=os.environ.get("MISTER_CORE_FOLDER", "_Unstable"),
                    help="top-level '_' folder holding the core (default _Unstable)")
    ap.add_argument("--push", metavar="FILE",
                    help="scp FILE into the folder (md5-verified) before launching")
    ap.add_argument("--ssh-key", default=os.environ.get("MISTER_SSH_KEY"),
                    help="ssh identity for --push (env MISTER_SSH_KEY)")
    ap.add_argument("--ssh-user", default=os.environ.get("MISTER_SSH_USER", "root"),
                    help="ssh user for --push (default root)")
    ap.add_argument("--no-reboot", action="store_true",
                    help="don't reboot first (default reboots for a clean menu state)")
    ap.add_argument("--reboot-wait", type=int, default=180,
                    help="seconds to wait for the web service after reboot")
    ap.add_argument("--delay", type=float, default=0.3, help="seconds between key presses")
    ap.add_argument("--updir-rows", type=int,
                    default=(int(os.environ["MISTER_OSD_UPDIR_ROWS"])
                             if os.environ.get("MISTER_OSD_UPDIR_ROWS") else None),
                    help="override the auto-derived <UP-DIR> row offset for subfolders")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the post-launch coreRunning check")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the generated keystrokes; push/reboot/send nothing")
    args = ap.parse_args()

    if not args.core:
        ap.error("--core is required (or set RBF_NAME)")

    # Resolve the folder's real path on the device from the live menu (no /media/fat
    # assumption), used both for --push and for the folder listing.
    entry = folder_entry(args.host, args.port, args.folder)
    folder_path = entry["path"]

    # 1. push (skipped on dry-run)
    if args.push and not args.dry_run:
        remote = posixpath.join(folder_path, args.core)
        push_rbf(args.push, args.host, args.ssh_user, args.ssh_key, remote)
    elif args.push:
        print(f"[push] (dry-run) would scp {args.push} -> "
              f"{args.ssh_user}@{args.host}:{posixpath.join(folder_path, args.core)}")

    # 2. reboot (skipped on dry-run)
    if not args.no_reboot and not args.dry_run:
        reboot_and_wait(args.host, args.port, args.reboot_wait)

    # 3. plan from the (post-reboot) live listing
    f_row, f_total, f_updir = plan(args.host, args.port, "", args.folder)
    c_row, c_total, c_updir = plan(args.host, args.port, folder_path, args.core)
    f_steps = f_row + updir_for(f_updir, args.updir_rows)
    c_steps = c_row + updir_for(c_updir, args.updir_rows)
    keys = (["down"] * f_steps + ["confirm", "sleep:1.2"]
            + ["down"] * c_steps + ["confirm"])

    print(f"[osd] {args.folder}: OSD row {f_row}/{f_total} "
          f"(updir={'yes' if f_updir else 'no'}) -> down x{f_steps}, confirm")
    print(f"[osd] {args.core}: OSD row {c_row}/{c_total} "
          f"(updir={'yes' if c_updir else 'no'}) -> down x{c_steps}, confirm")
    print(f"[osd] sequence: {' '.join(keys)}")

    if args.dry_run:
        return 0

    # 4. send + verify
    asyncio.run(send_keys(args.host, args.port, keys, args.delay))
    if args.no_verify:
        return 0
    return verify(args.host, args.port, os.path.splitext(args.core)[0])


if __name__ == "__main__":
    sys.exit(main() or 0)
