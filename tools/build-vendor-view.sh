#!/bin/bash
# Present the mirrored vendor inputs under the names they have in a staging root,
# as hardlinks, so rsync --link-dest can match them (MAST_provisioning#186).
#
# Runs ON THE RELAY (mast-ns-control), not on the provisioning server. The vendor
# store is a mirror of the build host's unbacked-up inputs (#194); this is a
# second set of NAMES for those same inodes, laid out the way a payload looks:
# the store keeps ps3-catalog/ as a directory, but the payload stages its two
# files at the root, and a name that does not match is a name rsync will transfer.
#
# Costs nothing. The files are not copied -- a hardlink is another directory entry
# for the same inode, so a 13 GB view occupies about 1 MB of directory blocks, and
# deleting either name leaves the other working. Re-runnable: the view is rebuilt
# from scratch each time, which is what you want after the mirror refreshes.
#
# Hardlinks cannot cross filesystems, so VENDOR and ROOT must be on one volume.
set -euo pipefail

VENDOR=${VENDOR:-/Storage/mast-vendor}
ROOT=${ROOT:-/Storage/mast-provisioning}
VIEW="$ROOT/vendor-view"

[ -d "$VENDOR" ] || { echo "vendor store not found: $VENDOR" >&2; exit 1; }
if [ "$(stat -c %d "$VENDOR")" != "$(stat -c %d "$(dirname "$ROOT")")" ]; then
    echo "$VENDOR and $ROOT are on different filesystems; hardlinks cannot span them" >&2
    exit 1
fi

mkdir -p "$ROOT"/{hosts,payload}
rm -rf "$VIEW"
mkdir -p "$VIEW"

# Directories keep their names. cp -al is a hardlink copy: directory entries only.
for d in mast-indexes cygwin-pkg-cache; do
    [ -d "$VENDOR/$d" ] || { echo "missing $VENDOR/$d" >&2; exit 1; }
    cp -al "$VENDOR/$d" "$VIEW/$d"
done

# Files staged at the payload root are linked under their STAGING names, which is
# the whole reason this view exists rather than pointing --link-dest at the store.
ln "$VENDOR/full-frame.fits"                             "$VIEW/full-frame.fits"
ln "$VENDOR/ps3-catalog/Setup_PlateSolve3_Catalog.exe"   "$VIEW/Setup_PlateSolve3_Catalog.exe"
ln "$VENDOR/ps3-catalog/Setup_PlateSolve3_Catalog-1.bin" "$VIEW/Setup_PlateSolve3_Catalog-1.bin"

echo "vendor-view rebuilt at $VIEW"
echo "  entries:        $(ls -A "$VIEW" | wc -l)"
echo "  apparent size:  $(du -sh --apparent-size "$VIEW" | cut -f1)"
echo "  actual added:   $(du -sh --total "$VENDOR" "$VIEW" | tail -1 | cut -f1) total across store + view"
