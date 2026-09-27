"""The one index of every file a payload needs that the build does not author.

Two sets used to be tracked apart: the binaries git-LFS carried, and the five
build-host inputs too large or too un-redistributable to commit. They had two
index files, two caches, two stores and two fetch paths, and the build read them
through eight bespoke blocks. They are one set here (MAST_provisioning#48).

Every row is keyed by the repo-relative path the file WOULD have if it were
tracked, so the machine-wide cache mirrors the repo tree and one rule covers
both: an asset lives at ``server/providers/<module>/assets/...``, in the repo or
in the cache.

Two halves feed it. The LFS rows are DERIVED -- a pointer already records the
``oid sha256`` and ``size`` of the object it stands for, so retiring LFS is
mechanical rather than a transcription exercise, and the two cannot disagree
while both exist. The build-host rows are DECLARED in ``vendor-inputs.json``,
because nothing in the repo can derive a file the repo does not contain.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

_OID = re.compile(rb"^oid sha256:([0-9a-f]{64})$", re.MULTILINE)
_SIZE = re.compile(rb"^size (\d+)$", re.MULTILINE)
#: server/providers/<module>/assets/... -- the per-provider layout.
_PROVIDER = re.compile(r"^server/providers/([^/]+)/assets/")
#: client/assets/... -- the bootstrap payload, which belongs to no provider.
_CLIENT = re.compile(r"^client/assets/")

VENDOR_INPUTS = Path("server/data/vendor-inputs.json")
LFS_SOURCE = "git-lfs"


class ManifestError(Exception):
    """The manifest cannot be built as asked."""


def module_of(path: str) -> str | None:
    """Which provider owns an asset, for a drift report a person has to read."""
    m = _PROVIDER.match(path)
    if m:
        return m.group(1)
    return "client" if _CLIENT.match(path) else None


def _git(repo: Path, *args: str, stdin: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], cwd=repo, input=stdin, capture_output=True, check=True).stdout


def discover_lfs_paths(repo: Path) -> set[str]:
    try:
        out = _git(repo, "lfs", "ls-files", "-n")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return set()
    return {line for line in out.decode("utf-8", "surrogateescape").splitlines() if line}


def _pointers(repo: Path, paths: list[str]) -> dict[str, bytes]:
    """Every pointer blob in ONE git call; see prov.tree_integrity for why."""
    if not paths:
        return {}
    req = "".join(f"HEAD:{p}\n" for p in paths).encode("utf-8", "surrogateescape")
    out = _git(repo, "cat-file", "--batch", stdin=req)
    blobs: dict[str, bytes] = {}
    pos = 0
    for path in paths:
        nl = out.index(b"\n", pos)
        header = out[pos:nl].split()
        if len(header) < 3:
            pos = nl + 1
            continue
        size = int(header[2])
        start = nl + 1
        blobs[path] = out[start : start + size]
        pos = start + size + 1
    return blobs


def _lfs_rows(repo: Path, lfs_paths: set[str] | None) -> list[dict[str, Any]]:
    ordered = sorted(discover_lfs_paths(repo) if lfs_paths is None else lfs_paths)
    pointers = _pointers(repo, ordered)
    rows = []
    for path in ordered:
        blob = pointers.get(path)
        if blob is None:
            continue
        oid, size = _OID.search(blob), _SIZE.search(blob)
        if not (oid and size):
            # Tracked as LFS but not a pointer in HEAD: nothing to record, and
            # guessing a hash here would put a wrong one in the index.
            continue
        rows.append(
            {
                "path": path,
                "sha256": oid.group(1).decode(),
                "size": int(size.group(1)),
                "module": module_of(path),
                "source": LFS_SOURCE,
            }
        )
    return rows


def _declared(repo: Path) -> dict[str, Any]:
    path = repo / VENDOR_INPUTS
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ManifestError(f"{VENDOR_INPUTS} is missing; the build-host inputs cannot be derived") from exc


def _sources_and_rows(declared: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    sources: list[dict[str, Any]] = [
        {
            "name": LFS_SOURCE,
            "cached": True,
            "used_by": [],
            "origin": "Tracked in this repository via git-LFS; the rows are derived from the pointers.",
            "reacquire": "git lfs pull, while LFS is still in place; afterwards, the content store.",
        }
    ]
    rows: list[dict[str, Any]] = []
    for entry in declared.get("inputs", []):
        source = {
            k: entry[k]
            for k in ("name", "cached", "used_by", "why_not_in_repo", "origin", "reacquire", "prefix")
            if k in entry
        }
        sources.append(source)
        for f in entry.get("files", []):
            rows.append({**f, "module": module_of(f["path"]), "source": entry["name"]})
    return sources, rows


def build_manifest(repo: Path, *, lfs_paths: set[str] | None = None) -> dict[str, Any]:
    """Index of every asset: path, sha256, size, owning module, and where it came from.

    No timestamp and no host. This file is committed and regenerated, so anything
    that changes when nothing changed would churn the diff and teach the reader to
    skip it -- the same reason the provenance generator is byte-stable.
    """
    repo = Path(repo)
    declared = _declared(repo)
    sources, declared_rows = _sources_and_rows(declared)
    rows = _lfs_rows(repo, lfs_paths) + declared_rows

    seen: dict[str, str] = {}
    for row in rows:
        other = seen.get(row["path"])
        if other is not None:
            raise ManifestError(
                f"{row['path']} is claimed by both '{other}' and '{row['source']}'. "
                "One path is one file; the cache cannot hold two."
            )
        seen[row["path"]] = row["source"]

    return {
        "_comment": (
            "Generated by prov.asset_manifest -- do not hand-edit. One row per file a payload "
            "needs that the build does not author, keyed by the repo-relative path it would "
            "have if it were tracked. LFS rows are derived from the pointers; build-host rows "
            "are declared in vendor-inputs.json. See MAST_provisioning#48."
        ),
        "sources": sources,
        "not_cached": declared.get("not_vendor_inputs", []),
        "files": sorted(rows, key=lambda r: r["path"]),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=Path, default=Path.cwd())
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args(argv)
    manifest = build_manifest(a.repo)
    a.out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    total = sum(f["size"] for f in manifest["files"])
    print(f"wrote {len(manifest['files'])} assets ({total / 2**30:.2f} GiB) to {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
