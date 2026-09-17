#!/bin/bash
# Check the build host's vendor cache against the canonical content store.
#
# A backup is a copy nobody reads until the day it is needed, so its corruption is
# discovered at the worst possible moment. This repo has that on record: an LFS
# pointer outside the filter checked out as 132 bytes of text while `git lfs pull`
# exited 0, and nothing noticed. This is what makes the build host's copy a cache
# rather than an unexamined original (MAST_provisioning#194).
#
# It needs no checksum list of its own. Every vendor byte is already a blob in the
# content-addressed store (#202) whose filename IS its SHA-256 -- verified
# 2026-09-17, 266 files and 12.03 GiB at 100% coverage -- so the check is: hash
# what is local, ask the store which of those digests it does not hold, and report
# the answer. A digest the store lacks is a local file whose content is not what
# the canonical copy has.
#
# Verification is by checksum and never by re-transfer: the measured WAN rate is
# 3.4-6 MB/s, so re-pulling 12.2 GB to compare it would take 35-60 minutes.
set -uo pipefail

REPO_TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${VENDOR_MIRROR_DEST:-mast@10.23.1.181}"
STORE_ROOT="${VENDOR_STORE_ROOT:-/Storage/mast-provisioning}"
PYTHON="${MAST_PYTHON:-/cygdrive/c/Program Files/Python312/python.exe}"
REMOTE_STORE=/tmp/mast-relay-store.py
SSH_KEY="${VENDOR_MIRROR_KEY:-/cygdrive/c/Users/labcomp2/.ssh/id_ed25519}"
# Cygwin ssh for the same reason vendor-mirror.sh uses it; see that script.
SSH="/usr/bin/ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=10"

# This runs as a scheduled task, where stdout goes nowhere. A verify whose drift
# report cannot be read afterwards is the same as no verify -- the task's exit
# code says something was wrong but never which file. Found 2026-09-17 by running
# the registered task and finding it had left no trace.
LOG="${VENDOR_VERIFY_LOG:-/cygdrive/c/MAST/logs/vendor-verify.log}"
mkdir -p "$(dirname "$LOG")"

# Same list, same reason, same guard as vendor-mirror.sh.
# MIRROR_SOURCES_BEGIN
SOURCES=(
  "mast-indexes:/cygdrive/c/MAST/mast-indexes"
  "ps3-catalog:/cygdrive/c/MAST/ps3-catalog"
  "cygwin-pkg-cache:/cygdrive/c/MAST/cygwin-pkg-cache"
  "full-frame.fits:/cygdrive/c/MAST/full-frame.fits"
  "nomachine-licenses:${REPO_TOP}/vault/nomachine-licenses"
)
# MIRROR_SOURCES_END

# Both, always: the log is what a scheduled run leaves behind, stdout is what a
# person running it by hand watches.
say() { local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; echo "$line"; echo "$line" >>"$LOG"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "=== vendor cache verify against $DEST:$STORE_ROOT"

# 1) Hash every local file. sha256sum emits "<digest>  <path>".
: >"$WORK/local.sums"
missing_src=0
for pair in "${SOURCES[@]}"; do
  name="${pair%%:*}"
  SRC="${pair#*:}"
  if [ ! -e "$SRC" ]; then
    say "VENDOR_CACHE_MISSING name=$name path=$SRC"
    missing_src=1
    continue
  fi
  if [ -d "$SRC" ]; then
    find "$SRC" -type f -print0 | xargs -0 -r sha256sum >>"$WORK/local.sums"
  else
    sha256sum "$SRC" >>"$WORK/local.sums"
  fi
done
total=$(wc -l <"$WORK/local.sums" | tr -d ' ')
say "hashed $total local file(s)"

# 2) Shape them as the manifest relay-store.py already reads.
# sha256sum writes '<digest>  <path>' in text mode and '<digest> *<path>' in
# binary mode, and cygwin picks binary here. Split on the first whitespace run
# rather than on two spaces, so both forms parse and a path containing spaces
# survives; then drop the binary marker.
"$PYTHON" -c "
import json, sys
files = []
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.rstrip('\n')
    if not line:
        continue
    digest, path = line.split(None, 1)
    files.append({'path': path.lstrip('*'), 'sha256': digest})
json.dump({'files': files}, open(sys.argv[2], 'w', encoding='utf-8'))
" "$(cygpath -w "$WORK/local.sums")" "$(cygpath -w "$WORK/manifest.json")" || {
  say "FATAL: could not build the manifest"; exit 2; }

# 3) Ask the store. 'want' prints one digest per line for what it does not hold;
#    silence means the cache matches the canonical copy byte for byte.
$SSH "$DEST" "cat > $REMOTE_STORE" < "${REPO_TOP}/tools/relay-store.py" || {
  say "FATAL: could not ship relay-store.py"; exit 2; }
if ! $SSH "$DEST" "python3 $REMOTE_STORE --root $STORE_ROOT want" \
        < "$WORK/manifest.json" > "$WORK/missing.txt"; then
  say "FATAL: the store could not answer"; exit 2
fi

drift=$(wc -l <"$WORK/missing.txt" | tr -d ' ')
if [ "$drift" = 0 ] && [ "$missing_src" = 0 ]; then
  say "VENDOR_CACHE_OK files=$total"
  say "VENDOR-VERIFY-COMPLETE status=0 files=$total drift=0"
  exit 0
fi

# 4) Name the files, not just the digests. A digest alone is not actionable.
say "VENDOR_CACHE_DRIFT files=$total drifted=$drift"
while read -r digest; do
  [ -n "$digest" ] || continue
  grep -F "$digest" "$WORK/local.sums" | while read -r _ path; do
    say "  DRIFT $path"
  done
done <"$WORK/missing.txt"
say "re-pull from $DEST:/Storage/mast-vendor/ -- the store's copy is canonical"
say "VENDOR-VERIFY-COMPLETE status=1 files=$total drift=$drift"
exit 1
