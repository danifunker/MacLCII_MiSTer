#!/usr/bin/env bash
# Deploy MacLC.rbf to MiSTer, cold-load, take periodic screenshots.
# Usage: bash scripts/deploy_screenshot.sh [tag]
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi

: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_HTTP_PORT:=8182}"
: "${RBF_NAME:=MacLC.rbf}"

TAG="${1:-turn}"
MISTER=$MISTER_HOST
SSHKEY=$MISTER_SSH_KEY
HTTP="http://$MISTER:$MISTER_HTTP_PORT"
CAPDIR=scratch/iter_capture/$(date +%Y%m%d_%H%M%S)_${TAG}
mkdir -p "$CAPDIR"
LOG="$CAPDIR/deploy.log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

log "=== Verify build artifact ==="
if [ ! -f output_files/$RBF_NAME ]; then
    log "ERROR: output_files/$RBF_NAME does not exist - build failed?"
    exit 1
fi
# Refuse to deploy if the latest build was a failed Quartus run that left
# a stale rbf behind. We trust output_files/MacLC.fit.summary's first line
# ("Fitter Status : Successful" vs "...: Failed") and the log file's
# trailing "Compile exit=N" line. The previous mtime check was too strict
# — Quartus writes the rbf, then our build.sh appends "Compile exit=N" to
# the log, so the log is always a few seconds newer than the rbf even
# after a clean build.
FIT_STATUS=$(awk 'NR==1' output_files/MacLC.fit.summary 2>/dev/null)
LATEST_LOG=$(ls -1t output_files/auto_compile_*.log 2>/dev/null | head -1)
LAST_EXIT_LINE=$(grep -E "^\[.+\] Compile exit=" "$LATEST_LOG" 2>/dev/null | tail -1)
case "$FIT_STATUS" in
    *Successful*) ;;
    *Failed*)
        log "ERROR: Quartus Fitter reported Failed in MacLC.fit.summary:"
        log "  $FIT_STATUS"
        log "  Inspect $LATEST_LOG."
        exit 1 ;;
    *)
        log "WARN: no parseable Fitter Status in MacLC.fit.summary. Build state unknown."
        log "  Continuing — but $LATEST_LOG should have the last exit line: $LAST_EXIT_LINE" ;;
esac
LOCAL_MD5=$(md5sum output_files/$RBF_NAME | awk '{print $1}')
log "local rbf md5 = $LOCAL_MD5"

log "=== SCP rbf to MiSTer ==="
scp -i "$SSHKEY" -o StrictHostKeyChecking=no -q \
    output_files/$RBF_NAME \
    root@$MISTER:/media/fat/_Unstable/$RBF_NAME
REMOTE_MD5=$(ssh -i "$SSHKEY" -o StrictHostKeyChecking=no root@$MISTER \
    "md5sum /media/fat/_Unstable/$RBF_NAME" | awk '{print $1}')
log "remote rbf md5 = $REMOTE_MD5"
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
    log "ERROR: md5 mismatch local vs remote"
    exit 1
fi

log "=== Clear stale config (so saved OSD settings don't override defaults) ==="
ssh -i "$SSHKEY" -o StrictHostKeyChecking=no root@$MISTER \
    "rm -f /media/fat/config/MacLC.cfg /media/fat/config/MacLC.s0 /media/fat/config/MacLC.s1" 2>/dev/null

log "=== Cold-load MacLC core ==="
curl -s -X POST -H 'Content-Type: application/json' \
     -d "{\"path\":\"_Unstable/$RBF_NAME\"}" \
     "$HTTP/api/launch" -w "HTTP %{http_code}\n" 2>&1 | tee -a "$LOG"
sleep 12

grab() {
    local label="$1"
    curl -s -X POST "$HTTP/api/screenshots" >/dev/null
    sleep 2
    local p=$(curl -s "$HTTP/api/screenshots" \
        | python -c "import sys,json;d=json.load(sys.stdin);d.sort(key=lambda x:x['modified']);print(d[-1]['path'])" 2>/dev/null)
    if [ -n "$p" ]; then
        curl -s -o "$CAPDIR/${label}.png" "$HTTP/api/screenshots/$p"
        log "saved $CAPDIR/${label}.png (from $p)"
    else
        log "WARN: no screenshot path returned for $label"
    fi
}

osd_keys() {
    python scripts/mister_ws.py --delay 0.4 "$@" 2>&1 | tee -a "$LOG"
}

log "=== Stage 1: t≈14s after launch ==="
grab "01_default"

log "=== Stage 2: navigate OSD to V8 Test Pat, cycle pattern via confirm ==="
# Item order (selectable only, skipping dashes):
#  1: F1 (Pri Floppy)    2: F2 (Sec Floppy)
#  3: SC0 (SCSI-6)       4: SC1 (SCSI-5)
#  5: O78 (Aspect)       6: OBC (Scale)
#  7: OFG (Video Mode)   8: OAB (Monitor)
#  9: ODE (CPU)          10: O4 (Memory)
#  11: O6 (Palette Test) 12: O5 (V8 Bypass Test)
#  13: OHI (V8 Test Pat) 14: R0 (Reset)
# 12 downs from menu open → V8 Test Pat. Use 'confirm' (Return) to cycle.
osd_keys osd sleep:0.8 \
    down down down down down down down down down down down down \
    sleep:0.4 confirm sleep:0.5 osd
sleep 3
grab "02_after_confirm_pat"

log "=== Stage 3: cycle V8 Test Pat again ==="
# Cursor position is remembered across OSD open/close on MiSTer
osd_keys osd sleep:0.6 confirm sleep:0.5 osd
sleep 3
grab "03_after_confirm_pat2"

log "=== Stage 4: cycle once more ==="
osd_keys osd sleep:0.6 confirm sleep:0.5 osd
sleep 3
grab "04_after_confirm_pat3"

log "=== Stage 5: cycle once more ==="
osd_keys osd sleep:0.6 confirm sleep:0.5 osd
sleep 3
grab "05_after_confirm_pat4"

log "=== DONE — capture dir: $CAPDIR ==="
ls -la "$CAPDIR/" | tee -a "$LOG"
