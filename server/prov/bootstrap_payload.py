"""The bootstrap payload: the USB kit for a bare unit, as one pack.

A bare unit is brought up by running ``bootstrap.cmd`` from a USB stick that also
carries everything ``bootstrap.ps1`` reads beside itself: its util, the BIOS
power-policy reader and baseline, and the Npcap and OpenSSH installers. That set
is declared once, in ``client/bootstrap-payload.json``. This module resolves it
(repo first, then the machine-wide asset cache, as for any provider asset),
stages it flat onto a stick, and keeps each kit on the relay as a
``bootstrap-payload/<hash>/`` snapshot, so the kit that built a unit can be cut
again after its installers have left the repo.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

from prov import relay, transport

KIT = Path("client/bootstrap-payload.json")
ASSETS = Path("server/data/assets.json")
STAGING_HOSTS = Path("server/data/staging-hosts.json")
SNAPSHOT_KIND = "bootstrap-payload"
READ_CHUNK = 1024 * 1024


class BootstrapPayloadError(Exception):
    """The kit cannot be assembled as declared."""


def load_kit(repo: Path) -> list[str]:
    return [str(p) for p in transport.load_json_object(repo / KIT)["files"]]


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(READ_CHUNK):
            h.update(chunk)
    return h.hexdigest()


def kit_files(repo: Path, cache: Path) -> list[relay.SnapshotFile]:
    """Each declared file, resolved and hashed, named by its leaf in the flat kit.

    A file the asset index knows must hash to its indexed digest: a stale cache
    copy would otherwise become the kit, and be snapshotted as if it were right.
    """
    indexed = {row["path"]: row["sha256"] for row in transport.load_json_object(repo / ASSETS)["files"]}
    files: list[relay.SnapshotFile] = []
    seen: set[str] = set()
    for rel in load_kit(repo):
        leaf = Path(rel).name
        if leaf in seen:
            raise BootstrapPayloadError(f"two kit files are named {leaf}; the kit is flat")
        seen.add(leaf)
        source = repo / rel if (repo / rel).is_file() else cache / rel
        if not source.is_file():
            raise BootstrapPayloadError(f"{rel} is in neither the repo nor the asset cache; run tools/fetch-assets.sh")
        digest = _sha256(source)
        if rel in indexed and digest != indexed[rel]:
            raise BootstrapPayloadError(f"{source} hashes to {digest}, not the indexed {indexed[rel]} for {leaf}")
        files.append(relay.SnapshotFile(leaf, digest, source.stat().st_size, source))
    return files


def kit_hash(files: list[relay.SnapshotFile]) -> str:
    """The kit's identity: its file names and contents, in no particular order."""
    lines = sorted(f"{f.sha256}  {f.path}" for f in files)
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def stage(files: list[relay.SnapshotFile], out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for f in files:
        shutil.copyfile(f.source, out / f.path)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Stage or snapshot the bootstrap payload (the USB kit for a bare unit).")
    p.add_argument("--repo", type=Path, default=Path("."))
    p.add_argument("--cache", type=Path, required=True, help="the machine-wide asset cache, e.g. C:\\MAST\\provider-assets")
    sub = p.add_subparsers(dest="cmd", required=True)
    stage_p = sub.add_parser("stage", help="copy the kit flat into a folder, e.g. the root of a USB stick")
    stage_p.add_argument("--out", type=Path, required=True)
    snap = sub.add_parser("snapshot", help="keep this kit on the relay as bootstrap-payload/<hash>/")
    snap.add_argument("--site", default="ns", help="the staging host to keep it on (server/data/staging-hosts.json)")
    args = p.parse_args(argv)

    try:
        files = kit_files(args.repo, args.cache)
    except BootstrapPayloadError as exc:
        print(f"BOOTSTRAP_PAYLOAD_ERROR {exc}", file=sys.stderr)
        return 1
    digest = kit_hash(files)
    if args.cmd == "stage":
        stage(files, args.out)
        print(f"BOOTSTRAP_PAYLOAD_STAGED hash={digest} files={len(files)} -> {args.out}")
        return 0
    site = relay.load_staging_hosts(args.repo / STAGING_HOSTS)[args.site]
    result = relay.sync_snapshot(kind=SNAPSHOT_KIND, snapshot_id=digest, files=files, relay=site)
    if not result.ok:
        print(f"BOOTSTRAP_PAYLOAD_SNAPSHOT_FAILED hash={digest} rc={result.returncode} {result.detail}", file=sys.stderr)
        return 1
    print(f"BOOTSTRAP_PAYLOAD_SNAPSHOT_OK hash={digest} {result.detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
