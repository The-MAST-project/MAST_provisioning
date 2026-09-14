#!/usr/bin/env python3
"""Content-addressed payload store on the staging relay (MAST_provisioning#202).

Runs ON THE RELAY (mast-ns-control), driven over ssh by prov.relay. Blobs are
named by their own SHA-256 and every payload is a tree of hardlinks into them, so
a build shares storage with every other build that contains the same bytes --
whatever their provenance, and with no notion of a "previous" version.

That last property is the requirement. The predecessor deduped with rsync's
``--link-dest`` pointed at the previous payload, which assumes a linear history:
once units sit on deliberately different stacks, "most recent" is an arbitrary
neighbour rather than an ancestor, and the saving degrades silently while the
mechanism models something false. Content addressing has no lineage to be wrong
about -- two versions share exactly the bytes they share, in any order.

``--link-dest`` could not be reused for this: rsync matches by relative PATH, so
a store keyed by hash is invisible to it. The assembly is therefore ours, and
rsync moves only the blobs the store lacks.

Layout under --root:

    store/<aa>/<sha256>              one copy of each distinct blob
    hosts/<host>/01-provisioning/    hardlinks into store; what SMB serves
    hosts/<host>/payload-manifest.json

Hardlinks cannot cross filesystems, so store/ and hosts/ must share one volume;
``assemble`` checks rather than assumes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

READ_CHUNK = 1024 * 1024


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(READ_CHUNK):
            h.update(chunk)
    return h.hexdigest()


def blob_path(root: Path, digest: str) -> Path:
    """Sharded by the first two characters: a flat store would hold tens of
    thousands of entries after a year of builds, which nothing needs."""
    return root / "store" / digest[:2] / digest


def read_manifest(stream) -> dict:
    data = json.load(stream)
    files = data.get("files")
    if not isinstance(files, list):
        raise SystemExit("manifest has no 'files' list")
    return data


def cmd_seed(root: Path, args) -> int:
    """Adopt existing trees into the store without transferring anything.

    The relay already holds every blob of every payload it has served, so the
    first store-backed sync should move nothing. Idempotent: a blob already
    present is left alone.
    """
    # Seeded files are hardlinked, not copied, so the store shares an inode with
    # the tree it adopted. Anything that then writes to that tree IN PLACE --
    # truncating rather than replacing -- rewrites the blob under its old name,
    # and the store silently stops being content-addressed. Seeded trees are
    # read-only from here on; a payload is rebuilt, never edited.
    added = linked = 0
    for src_dir in args.dirs:
        for dirpath, _dirnames, filenames in os.walk(src_dir, followlinks=True):
            for name in filenames:
                f = Path(dirpath) / name
                if not f.is_file():
                    continue
                digest = sha256_of(f)
                dest = blob_path(root, digest)
                if dest.exists():
                    linked += 1
                    continue
                dest.parent.mkdir(parents=True, exist_ok=True)
                try:
                    os.link(f, dest)
                    added += 1
                except OSError as exc:
                    print(f"seed: cannot link {f}: {exc}", file=sys.stderr)
    print(f"SEEDED added={added} already_present={linked}")
    return 0


def cmd_want(root: Path, _args) -> int:
    """Hashes from the manifest on stdin that the store does not hold.

    One line per missing digest; empty output means the payload is already
    entirely present and the build costs no transfer at all.
    """
    manifest = read_manifest(sys.stdin)
    missing = {e["sha256"] for e in manifest["files"] if not blob_path(root, e["sha256"]).exists()}
    for digest in sorted(missing):
        print(digest)
    return 0


def cmd_assemble(root: Path, args) -> int:
    """Materialise one host's payload as hardlinks into the store."""
    manifest = read_manifest(sys.stdin)
    target = root / "hosts" / args.host / "01-provisioning"
    target.mkdir(parents=True, exist_ok=True)

    if os.stat(root / "store").st_dev != os.stat(target).st_dev:
        raise SystemExit("store/ and hosts/ are on different filesystems; hardlinks cannot span them")

    wanted: set[Path] = set()
    for entry in manifest["files"]:
        blob = blob_path(root, entry["sha256"])
        if not blob.exists():
            raise SystemExit(f"assemble: store is missing {entry['sha256']} for {entry['path']}")
        dest = target / entry["path"]
        wanted.add(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Replace rather than trust: a path whose content changed between builds
        # must not keep pointing at the old blob.
        if dest.exists():
            if dest.stat().st_ino == blob.stat().st_ino:
                continue
            dest.unlink()
        os.link(blob, dest)

    removed = prune_to(target, wanted)
    (root / "hosts" / args.host / "payload-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    total = sum(e["size"] for e in manifest["files"])
    print(f"ASSEMBLED host={args.host} files={len(manifest['files'])} bytes={total} pruned={removed}")
    return 0


def prune_to(target: Path, wanted: set[Path]) -> int:
    """Remove anything the manifest does not name.

    An older payload's leftovers would otherwise sit in the tree the unit pulls,
    so its trim measurements and its disk guard would describe something other
    than what arrives.
    """
    removed = 0
    for dirpath, dirnames, filenames in os.walk(target, topdown=False):
        for name in filenames:
            path = Path(dirpath) / name
            if path not in wanted:
                path.unlink()
                removed += 1
        for name in dirnames:
            directory = Path(dirpath) / name
            if not any(directory.iterdir()):
                directory.rmdir()
    return removed


def cmd_gc(root: Path, _args) -> int:
    """Drop blobs nothing references.

    Retention is a refcount, not a policy: a blob is live while any *other* name
    points at the same inode, so a version can be dropped in any order without
    consulting a schedule or a lineage. That refcount is deliberately broad --
    the vendor mirror counts, so a seeded blob is never collected whether or not
    a payload currently wants it.
    """
    store = root / "store"
    freed = kept = 0
    freed_bytes = 0
    for shard in sorted(store.iterdir()) if store.exists() else []:
        if not shard.is_dir():
            continue
        for blob in sorted(shard.iterdir()):
            st = blob.stat()
            if st.st_nlink == 1:
                freed_bytes += st.st_size
                blob.unlink()
                freed += 1
            else:
                kept += 1
        if not any(shard.iterdir()):
            shard.rmdir()
    print(f"GC freed={freed} bytes_freed={freed_bytes} kept={kept}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Content-addressed payload store on the staging relay.")
    p.add_argument("--root", type=Path, required=True)
    sub = p.add_subparsers(dest="cmd", required=True)
    seed = sub.add_parser("seed")
    seed.add_argument("dirs", nargs="+")
    seed.set_defaults(fn=cmd_seed)
    sub.add_parser("want").set_defaults(fn=cmd_want)
    assemble = sub.add_parser("assemble")
    assemble.add_argument("--host", required=True)
    assemble.set_defaults(fn=cmd_assemble)
    sub.add_parser("gc").set_defaults(fn=cmd_gc)
    args = p.parse_args(argv)
    (args.root / "store").mkdir(parents=True, exist_ok=True)
    return args.fn(args.root, args)


if __name__ == "__main__":
    raise SystemExit(main())
