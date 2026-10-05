#!/bin/bash
# Populate the machine-wide asset cache from the relay's blobstore.
#
# ONE cache for everything a payload needs that the build does not author: the
# binaries leaving git-LFS and the build-host inputs that were never in git, which
# used to sit in four separate C:\MAST\ directories with their own index, their own
# mirror job and their own verify (MAST_provisioning#48). server/data/assets.json
# is the index, keyed by the repo-relative path each file would have if it were
# tracked, and the blobstore on the relay already holds every one of those digests.
#
# Idempotent by construction: a file that already hashes to the manifest's sha256
# is skipped, so this is equally the first-run fetch, the repair path, and the
# verify -- which is why it, rather than a report-only job, is what the daily task
# runs. Noticing rot and fixing it are the same pass.
#
# Runs ON the build host, pulling FROM the relay, the same direction as every
# other job here: mast-ns-control -> labcomp2:22 times out.
set -uo pipefail

REPO_TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${VENDOR_MIRROR_DEST:-mast@10.23.1.181}"
STORE_ROOT="${VENDOR_STORE_ROOT:-/Storage/mast-provisioning}"
CACHE="${MAST_ASSET_CACHE:-/cygdrive/c/MAST/provider-assets}"
MANIFEST="${ASSET_MANIFEST:-${REPO_TOP}/server/data/assets.json}"
PYTHON="${MAST_PYTHON:-/cygdrive/c/Program Files/Python312/python.exe}"
SSH_KEY="${VENDOR_MIRROR_KEY:-/cygdrive/c/Users/labcomp2/.ssh/id_ed25519}"
# CYGWIN ssh, not Windows OpenSSH. Under Task Scheduler (a non-console session)
# cygwin tools cannot hand their pipes to a native Windows child: ssh authenticates
# fine on its own, then the transfer dies with "connection unexpectedly closed (0
# bytes received)". Interactively the identical command works, which is what makes
# it expensive to diagnose. -i is explicit and UserKnownHostsFile is /dev/null
# because cygwin ssh takes its home from /etc/passwd (/home/<user>), absent here.
SSH="/usr/bin/ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=10"

LOG="${FETCH_ASSETS_LOG:-/cygdrive/c/MAST/logs/fetch-assets.log}"
mkdir -p "$(dirname "$LOG")"
say() { local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; echo "$line"; echo "$line" >>"$LOG"; }

[ -f "$MANIFEST" ] || { say "FETCH_ASSETS_ERROR no manifest at $MANIFEST"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

say "=== provider-asset cache: $CACHE"

# 1) What is missing or wrong? Hashing locally is the whole check -- the manifest
#    records the sha256 the pointer recorded, so a file that hashes right IS the
#    asset, whatever its mtime or how it got here.
"$PYTHON" -c "
import hashlib, json, os, sys
manifest, cache, out = sys.argv[1], sys.argv[2], sys.argv[3]
need = []
have = 0
for row in json.load(open(manifest, encoding='utf-8'))['files']:
    dest = os.path.join(cache, row['path'].replace('/', os.sep))
    if os.path.isfile(dest) and os.path.getsize(dest) == row['size']:
        h = hashlib.sha256()
        with open(dest, 'rb') as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b''):
                h.update(chunk)
        if h.hexdigest() == row['sha256']:
            have += 1
            continue
    need.append((row['sha256'], row['path'], row['size']))
with open(out, 'w', encoding='utf-8') as fh:
    for sha, path, size in need:
        fh.write(f'{sha}\t{path}\t{size}\n')
print(f'{have} present, {len(need)} to fetch, {sum(s for _,_,s in need)} bytes', file=sys.stderr)
" "$(cygpath -w "$MANIFEST")" "$(cygpath -w "$CACHE")" "$(cygpath -w "$WORK/need.tsv")" 2> "$WORK/summary" || {
    say "FETCH_ASSETS_ERROR could not read the manifest"; exit 2; }
say "$(cat "$WORK/summary")"

if [ ! -s "$WORK/need.tsv" ]; then
    say "FETCH_ASSETS_OK cache already complete"
    echo "FETCH-ASSETS-COMPLETE status=0 fetched=0"
    exit 0
fi

# 2) One ssh, one tar stream. 418 separate transfers would spend minutes on
#    handshakes alone, and the link is the slow part already.
cut -f1 "$WORK/need.tsv" | sed 's|^\(..\)|blobstore/\1/&|' > "$WORK/blobs.txt"
if ! $SSH "$DEST" "tar -cf - -C '$STORE_ROOT' -T -" < "$WORK/blobs.txt" | tar -xf - -C "$WORK"; then
    say "FETCH_ASSETS_ERROR blob transfer failed"
    echo "FETCH-ASSETS-COMPLETE status=2"
    exit 2
fi

# 3) Place each blob at the path the manifest names, verifying as we go: a blob
#    that arrives wrong must not be installed under a name that claims it is right.
fetched=0; bad=0
while IFS=$'\t' read -r sha path size; do
    blob="$WORK/blobstore/${sha:0:2}/$sha"
    dest="$CACHE/$path"
    if [ ! -f "$blob" ]; then say "  MISSING from blobstore: $path ($sha)"; bad=$((bad+1)); continue; fi
    actual=$(sha256sum "$blob" | cut -d' ' -f1)
    if [ "$actual" != "$sha" ]; then say "  CORRUPT in transit: $path"; bad=$((bad+1)); continue; fi
    mkdir -p "$(dirname "$dest")"
    mv -f "$blob" "$dest" && fetched=$((fetched+1))
done < "$WORK/need.tsv"

if [ "$bad" = 0 ]; then
    say "FETCH_ASSETS_OK fetched=$fetched"
    echo "FETCH-ASSETS-COMPLETE status=0 fetched=$fetched"
    exit 0
fi
say "FETCH_ASSETS_INCOMPLETE fetched=$fetched failed=$bad"
echo "FETCH-ASSETS-COMPLETE status=1 fetched=$fetched failed=$bad"
exit 1
