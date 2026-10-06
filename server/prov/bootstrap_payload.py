"""The bootstrap payload: every file a bare unit needs on its bootstrap medium.

A bare unit is brought up by running ``bootstrap.cmd`` from a USB stick that also
carries everything ``bootstrap.ps1`` reads beside itself: its util, the BIOS
power-policy reader and baseline, and the Npcap and OpenSSH installers. That set
is declared once, in ``client/bootstrap-payload.json``. This module resolves it
(repo first, then the machine-wide asset cache, as for any provider asset),
stages it flat onto a stick, and keeps each version on the relay as a
``bootstrap-payload/<hash>/`` snapshot, so the payload that built a unit can be
staged again after its installers have left the repo.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

from prov import hashing, relay, transport

BOOTSTRAP_PAYLOAD = Path("client/bootstrap-payload.json")
ASSETS = Path("server/data/assets.json")


class BootstrapPayloadError(Exception):
    """The bootstrap payload cannot be assembled as declared."""


def load_declared(repo: Path) -> list[str]:
    return [str(p) for p in transport.load_json_object(repo / BOOTSTRAP_PAYLOAD)["files"]]


def payload_files(repo: Path, cache: Path) -> list[relay.SnapshotFile]:
    """Each declared file, resolved and hashed, named by its leaf in the flat payload.

    A file the asset index knows must hash to its indexed digest: a stale cache
    copy would otherwise become the payload, and be snapshotted as if it were right.
    """
    indexed = {row["path"]: row["sha256"] for row in transport.load_json_object(repo / ASSETS)["files"]}
    files: list[relay.SnapshotFile] = []
    seen: set[str] = set()
    for rel in load_declared(repo):
        leaf = Path(rel).name
        if leaf in seen:
            raise BootstrapPayloadError(f"two bootstrap payload files are named {leaf}; the payload is flat")
        seen.add(leaf)
        source = repo / rel if (repo / rel).is_file() else cache / rel
        if not source.is_file():
            raise BootstrapPayloadError(f"{rel} is in neither the repo nor the asset cache; run tools/fetch-assets.sh")
        digest = hashing.sha256_of(source)
        if rel in indexed and digest != indexed[rel]:
            raise BootstrapPayloadError(f"{source} hashes to {digest}, not the indexed {indexed[rel]} for {leaf}")
        files.append(relay.SnapshotFile(leaf, digest, source.stat().st_size, source))
    return files


def payload_hash(files: list[relay.SnapshotFile]) -> str:
    """The payload's identity: its file names and contents, in no particular order."""
    lines = sorted(f"{f.sha256}  {f.path}" for f in files)
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def stage(files: list[relay.SnapshotFile], out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for f in files:
        shutil.copyfile(f.source, out / f.path)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Stage or snapshot the bootstrap payload (what a bare unit's USB stick carries)."
    )
    p.add_argument("--repo", type=Path, default=Path("."))
    p.add_argument("--cache", type=Path, required=True, help="the machine-wide asset cache, e.g. C:\\MAST\\provider-assets")
    sub = p.add_subparsers(dest="cmd", required=True)
    stage_p = sub.add_parser("stage", help="copy the payload flat into a folder, e.g. the root of a USB stick")
    stage_p.add_argument("--out", type=Path, required=True)
    snap = sub.add_parser("snapshot", help="keep this payload on the relay as bootstrap-payload/<hash>/")
    snap.add_argument("--site", default="ns", help="the staging host to keep it on (server/data/staging-hosts.json)")
    args = p.parse_args(argv)

    try:
        site = relay.staging_host(args.repo / relay.STAGING_HOSTS, args.site) if args.cmd == "snapshot" else None
        files = payload_files(args.repo, args.cache)
    except (BootstrapPayloadError, relay.UnknownSiteError) as exc:
        print(f"BOOTSTRAP_PAYLOAD_ERROR {exc}", file=sys.stderr)
        return 1
    digest = payload_hash(files)
    if site is None:
        stage(files, args.out)
        print(f"BOOTSTRAP_PAYLOAD_STAGED hash={digest} files={len(files)} -> {args.out}")
        return 0
    result = relay.sync_snapshot(kind=relay.SnapshotKind.BOOTSTRAP_PAYLOAD, snapshot_id=digest, files=files, relay=site)
    if not result.ok:
        print(f"BOOTSTRAP_PAYLOAD_SNAPSHOT_FAILED hash={digest} rc={result.returncode} {result.detail}", file=sys.stderr)
        return 1
    print(f"BOOTSTRAP_PAYLOAD_SNAPSHOT_OK hash={digest} {result.detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
