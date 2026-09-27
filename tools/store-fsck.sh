#!/bin/bash
# Re-hash every blob in the relay's content store against its own filename.
#
# The store is content-addressed: a blob's name IS its SHA-256, which makes the
# claim *checkable* -- but until #218 nothing checked it, so it was an assumption.
# That matters because every other integrity check in this system compares
# something AGAINST this store: the build host's vendor cache (tools/vendor-verify.sh,
# #194) and a unit's landed payload (#189). If a blob rots, all of them agree with
# the rot and report success.
#
# Runs ON the build host and drives the relay over ssh, the same direction and for
# the same reason as vendor-verify.sh: mast-ns-control -> labcomp2:22 times out, so
# the site cannot initiate and a cron job on the Linux side is not an option.
#
# relay-store.py is shipped from the repo on every run rather than installed on the
# relay, so the check can never be an older copy of itself than the code it is
# checking -- prov.relay ships it the same way for the same reason.
set -uo pipefail

REPO_TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${VENDOR_MIRROR_DEST:-mast@10.23.1.181}"
STORE_ROOT="${VENDOR_STORE_ROOT:-/Storage/mast-provisioning}"
REMOTE_STORE=/tmp/mast-relay-store.py
SSH_KEY="${VENDOR_MIRROR_KEY:-/cygdrive/c/Users/labcomp2/.ssh/id_ed25519}"
# Cygwin ssh for the same reason vendor-mirror.sh uses it; see that script.
SSH="/usr/bin/ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=10"

# Scheduled runs have nowhere for stdout to go, and a corruption report nobody can
# read afterwards is the same as no report -- the lesson vendor-verify.sh learned
# the hard way on 2026-09-17.
LOG="${STORE_FSCK_LOG:-/cygdrive/c/MAST/logs/store-fsck.log}"
mkdir -p "$(dirname "$LOG")"
say() { local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; echo "$line"; echo "$line" >>"$LOG"; }

say "=== store fsck against $DEST:$STORE_ROOT"

if ! $SSH "$DEST" "cat > $REMOTE_STORE" < "${REPO_TOP}/tools/relay-store.py"; then
    say "STORE_FSCK_UNREACHABLE could not ship relay-store.py"
    echo "STORE-FSCK-COMPLETE status=2"
    exit 2
fi

# --names puts corrupt blob names on stdout; the human-readable summary and each
# CORRUPT line come back on stderr, so both are captured here.
out="$($SSH "$DEST" "python3 $REMOTE_STORE --root $STORE_ROOT fsck --names" 2>&1)"
rc=$?

while IFS= read -r line; do
    [ -n "$line" ] && say "  $line"
done <<<"$out"

case "$rc" in
    0)
        say "STORE_FSCK_OK every blob still hashes to its own name"
        echo "STORE-FSCK-COMPLETE status=0"
        ;;
    1)
        # Deliberately not repaired here. Unlinking a blob takes out every hardlink
        # into it across every host tree at once, and a bad byte is more
        # recoverable than a missing file -- re-seed the affected blob instead.
        say "STORE_FSCK_CORRUPT the store holds blobs that are not what their names say -- see MAST_provisioning#216"
        echo "STORE-FSCK-COMPLETE status=1"
        ;;
    *)
        say "STORE_FSCK_ERROR fsck could not complete (rc=$rc)"
        echo "STORE-FSCK-COMPLETE status=2"
        ;;
esac
exit $rc
