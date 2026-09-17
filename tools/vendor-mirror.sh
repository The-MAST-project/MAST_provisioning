#!/bin/bash
# Mirror the build host's vendor inputs to the canonical store on mast-ns-control.
#
# These are the five things a payload needs that are not in this repo: if the
# provisioning server were lost, this is the set that would have to be rebuilt by
# hand (MAST_provisioning#194). server/data/vendor-inputs.json says what they are
# and why; this ships the bytes and the provenance that travels with them.
#
# Runs ON the provisioning server, under cygwin, from the canonical clone. The
# direction is fixed and is not a preference: mast-ns-control -> labcomp2:22 times
# out, so the site cannot initiate and a cron job on the Linux side is not an
# option. This end pushes.
#
# It lived in an agent task folder until 2026-09-17 -- a directory the workspace
# contract tears down with `rm -rf` -- and was registered One Time Only, so it had
# run exactly once and had no next run. That is why it is in the repo now.
set -uo pipefail

REPO_TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${VENDOR_MIRROR_DEST:-mast@10.23.1.181}"
DESTDIR="${VENDOR_MIRROR_DESTDIR:-/Storage/mast-vendor}"
PYTHON="${MAST_PYTHON:-/cygdrive/c/Program Files/Python312/python.exe}"
RSYNC=/usr/bin/rsync
LOG="${VENDOR_MIRROR_LOG:-/cygdrive/c/MAST/logs/vendor-mirror.log}"
LOCK="${VENDOR_MIRROR_LOCK:-/cygdrive/c/MAST/logs/vendor-mirror.lock}"

# CYGWIN ssh, not Windows OpenSSH. Under Task Scheduler (a non-console session)
# cygwin rsync cannot hand its pipes to a native Windows child: ssh authenticates
# fine on its own, then rsync dies with "connection unexpectedly closed (0 bytes
# received)". Interactively the identical command works, which is what makes it
# expensive to diagnose. Both ends of the pipe must be cygwin.
#
# -i is explicit and UserKnownHostsFile is /dev/null because cygwin ssh takes its
# home from /etc/passwd (/home/<user>), which does not exist here.
SSH_KEY="${VENDOR_MIRROR_KEY:-/cygdrive/c/Users/labcomp2/.ssh/id_ed25519}"
SSH="/usr/bin/ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=10"

# MIRROR_SOURCES_BEGIN
# Kept in step with server/data/vendor-inputs.json by
# server/prov/tests/test_vendor_inputs.py. An input declared there and absent here
# is exactly how nomachine-licenses fell out of the automated mirror and reached
# the store by hand instead.
SOURCES=(
  "mast-indexes:/cygdrive/c/MAST/mast-indexes"
  "ps3-catalog:/cygdrive/c/MAST/ps3-catalog"
  "cygwin-pkg-cache:/cygdrive/c/MAST/cygwin-pkg-cache"
  "full-frame.fits:/cygdrive/c/MAST/full-frame.fits"
  "nomachine-licenses:${REPO_TOP}/vault/nomachine-licenses"
)
# MIRROR_SOURCES_END

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
say() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

if ! mkdir "$LOCK" 2>/dev/null; then say "ALREADY RUNNING (lock held) - exiting"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

say "=== vendor mirror START -> $DEST:$DESTDIR"
$SSH "$DEST" "mkdir -p $DESTDIR" || { say "FATAL: cannot mkdir on the store"; exit 1; }

overall=0

# Provenance first, so a mirror that then fails part way still carries the answer
# to "where did this come from" for what did land.
PROV_DIR="$(mktemp -d)"
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$PROV_DIR"' EXIT
if "$PYTHON" "$(cygpath -w "${REPO_TOP}/tools/write-vendor-provenance.py")" \
       --inputs "$(cygpath -w "${REPO_TOP}/server/data/vendor-inputs.json")" \
       --out "$(cygpath -w "$PROV_DIR")"; then
  $RSYNC -rlt --no-perms --no-owner --no-group --chmod=D755,F644 \
         -e "$SSH" "$PROV_DIR/" "$DEST:$DESTDIR/" && say "provenance: OK" || { say "provenance: FAILED to ship"; overall=1; }
else
  say "provenance: FAILED to generate"; overall=1
fi

for pair in "${SOURCES[@]}"; do
  name="${pair%%:*}"
  SRC="${pair#*:}"
  [ -e "$SRC" ] || { say "SKIP $name (missing at $SRC)"; overall=1; continue; }
  say "--- $name: starting"
  ok=0
  for attempt in 1 2 3 4 5; do
    # -rlt: recurse, no symlink dereference, keep mtimes.
    # --no-perms/owner/group + --chmod: Windows ACLs are meaningless on Linux and
    #       would make every later comparison miss.
    # --partial: a WAN blip resumes instead of restarting a 9.9 GB file.
    $RSYNC -rlt --partial --stats --human-readable \
           --no-perms --no-owner --no-group --chmod=D755,F644 \
           -e "$SSH" "$SRC" "$DEST:$DESTDIR/" && { ok=1; break; }
    rc=$?
    say "    attempt $attempt failed (rsync rc=$rc); retrying in 60s"
    sleep 60
  done
  if [ "$ok" = 1 ]; then say "--- $name: OK"; else say "--- $name: FAILED after 5 attempts"; overall=1; fi
done

say "=== remote totals ==="
$SSH "$DEST" "du -sh $DESTDIR/*; echo TOTAL: \$(du -sh $DESTDIR | cut -f1)"
say "=== vendor mirror DONE status=$overall"
echo "MIRROR-COMPLETE status=$overall"
exit $overall
