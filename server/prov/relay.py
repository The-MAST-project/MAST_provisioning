"""Staging the payload on a host the unit can actually reach (MAST_provisioning#186).

The unit pulls over SMB, so it must open TCP 445 to whichever host serves the
payload, and a site's units can do that only for a host on their own VLAN. That
is why a run driven from the institute stops at ``PREFLIGHT_UNIT_SMB_FAIL``: the
orchestrator is reachable by SSH but not by SMB.

A **staging host** breaks the two apart. The orchestrator builds locally and
rsyncs the payload to a declared relay on the units' VLAN; the unit pulls from
the relay exactly as it pulled from the orchestrator before. Only the address and
share name it is handed change -- the pull script, the per-module exclusions
(#195) and the destination verification (#189) are untouched.

**Why the WAN cost is small.** The relay keeps a blobstore and a host's payload
is a tree of hardlinks into it (#202, ``tools/blobstore.py``).
The build writes a per-file manifest; this module asks the blobstore which digests it
lacks, sends only those, and has the tree assembled from links. Two builds share
exactly the bytes they share, with no notion of a predecessor to be wrong about.
Measured on mast07: 5.5 s and one 41,800-byte blob for a 14,877,440,807-byte
payload that cost 1,959,264,676 bytes the day before.

**Three transport facts, each of which cost a diagnosis:**

* The ssh must be **cygwin's** (``/usr/bin/ssh``), not Windows OpenSSH. Under
  Task Scheduler cygwin rsync cannot hand its pipes to a native Windows child:
  ssh authenticates cleanly on its own and then rsync dies with ``connection
  unexpectedly closed (0 bytes received)``. Interactively it works, which is what
  makes it expensive to find.
* Cygwin ssh takes its home from ``/etc/passwd`` (``/home/<user>``, which does not
  exist on the build host), not ``$HOME`` -- so the identity is named explicitly
  and known-hosts is sent to ``/dev/null``.
* Attribute preservation has to be turned **off** (``--no-perms``/``--no-owner``/
  ``--no-group``/``--chmod``): Windows ACLs arriving through cygwin never
  reproduce, and rsync then rewrites blobs it should have left alone. Blobs are
  hardlinked into every host tree that names them, so a needless rewrite is not
  merely wasted bytes.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

# Two path vocabularies are in play and they are not interchangeable.
#
# The driver's Python on the build host is a NATIVE Windows interpreter, so
# anything it execs must be a Windows path: `/usr/bin/rsync` raises
# FileNotFoundError there. But the `-e` string is handed to cygwin rsync and
# interpreted by cygwin, so the ssh named inside it must be a CYGWIN path.
# The same binary therefore appears under both names, deliberately.
#: Exec'd by the driver (native Windows Python).
RSYNC_EXE = r"C:\cygwin64\bin\rsync.exe"
SSH_EXE = r"C:\cygwin64\bin\ssh.exe"
#: Named inside rsync's -e string, resolved by cygwin.
CYGWIN_SSH = "/usr/bin/ssh"
DEFAULT_IDENTITY = "/cygdrive/c/Users/labcomp2/.ssh/id_ed25519"
#: Directory entries the relay serves; the share points here, not at the root.
HOSTS_SUBDIR = "hosts"
READ_CHUNK = 1024 * 1024


@dataclass(frozen=True)
class StagingHost:
    """A declared per-site host that serves payloads to that site's units."""

    address: str
    share: str
    ssh_target: str
    root: str
    #: Which block of vault/creds.json the unit authenticates to the share with.
    creds_key: str = "shared"

    def unc(self, host: str) -> str:
        """The UNC the unit is handed. Same shape the orchestrator served."""
        return rf"\\{self.address}\{self.share}\{host}\01-provisioning"

    def host_dir(self, host: str) -> str:
        return f"{self.root}/{HOSTS_SUBDIR}/{host}/01-provisioning"


def load_staging_hosts(path: Path) -> dict[str, StagingHost]:
    """Declared staging hosts by site, or ``{}`` when the file is absent.

    Absent means no site has a relay and every run behaves as it did before --
    which is what the bench and the dev VM want. A *malformed* entry is an error:
    silently skipping it would point the unit back at the orchestrator, which
    looks exactly like a config that had not been picked up yet.
    """
    if not Path(path).is_file():
        return {}
    data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    sites = data.get("sites") or {}
    out: dict[str, StagingHost] = {}
    for site, entry in sites.items():
        try:
            out[site] = StagingHost(**entry)
        except TypeError as exc:
            raise ValueError(f"{path}: staging host for site '{site}' is malformed: {exc}") from exc
    return out


def cygwin_path(windows_path: str | Path) -> str:
    """``C:\\MAST\\x`` -> ``/cygdrive/c/MAST/x``, for cygwin rsync's arguments."""
    text = str(windows_path).replace("\\", "/")
    if len(text) > 1 and text[1] == ":":
        return f"/cygdrive/{text[0].lower()}{text[2:]}"
    return text


def ssh_spec(identity: str = DEFAULT_IDENTITY) -> str:
    return (
        f"{CYGWIN_SSH} -i {identity} -o BatchMode=yes -o StrictHostKeyChecking=no "
        f"-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "
        f"-o ServerAliveInterval=30 -o ServerAliveCountMax=10"
    )


@dataclass(frozen=True)
class SyncResult:
    """Outcome of putting a payload on the relay. Fails closed, like every phase."""

    ok: bool
    returncode: int
    detail: str


# --- blobstore (#202) -------------------------------------------------------
#
# Replaces the --link-dest passes. Those deduped against a tree we guessed was
# similar, which meant the previous payload -- a linear-history assumption that
# stops holding the moment two units sit on deliberately different stacks. The
# store has no lineage to be wrong about: a build shares exactly the bytes it
# shares with every other build, in any order.
#
# rsync could not be reused for the dedupe itself: it matches by relative PATH,
# so a store keyed by content hash is invisible to --link-dest. rsync stays the
# blob mover, carrying only what the relay lacks.

#: Where the relay-side script lands. Shipped every run like the pull script, so
#: the relay cannot be running an older copy than the driver expects.
RELAY_STORE_REMOTE = "/tmp/mast-blobstore.py"


def _ssh_argv(relay: StagingHost, identity: str, remote_cmd: str) -> list[str]:
    return [SSH_EXE, *ssh_spec(identity).split()[1:], relay.ssh_target, remote_cmd]


def _store_cmd(relay: StagingHost, *args: str) -> str:
    return " ".join(["python3", RELAY_STORE_REMOTE, "--root", relay.root, *args])


def sync_payload(
    *,
    manifest_path: str | Path,
    staging_dir: str | Path,
    host: str,
    relay: StagingHost,
    identity: str = DEFAULT_IDENTITY,
    timeout_s: int = 7200,
    runner=subprocess.run,
    script_path: str | Path | None = None,
) -> SyncResult:
    """Put one host's payload on the relay, transferring only unheld blobs.

    Four steps, each failing closed: ship the relay script, ask which hashes are
    missing, send exactly those, assemble. An empty want-list means the payload
    is already there in full and nothing crosses the wire.
    """
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8-sig"))
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        return SyncResult(False, -1, f"{manifest_path}: no file list to assemble from")
    staging = Path(staging_dir)
    sources = {e["sha256"]: staging / e["path"] for e in entries}
    return _sync(
        manifest=manifest,
        sources=sources,
        final=("assemble", "--host", host),
        relay=relay,
        identity=identity,
        timeout_s=timeout_s,
        runner=runner,
        script_path=script_path,
    )


@dataclass(frozen=True)
class SnapshotFile:
    """One file of a pack: where it sits in the snapshot, what it must hash to, and
    where its bytes are on this machine."""

    path: str
    sha256: str
    size: int
    source: Path


def sync_snapshot(
    *,
    kind: str,
    snapshot_id: str,
    files: Sequence[SnapshotFile],
    relay: StagingHost,
    identity: str = DEFAULT_IDENTITY,
    timeout_s: int = 7200,
    runner=subprocess.run,
    script_path: str | Path | None = None,
) -> SyncResult:
    """Record a pack as a snapshot on the relay, sending only the blobs it lacks.

    Unlike a payload, a snapshot's sources were not just built: they come out of
    a cache, so each is hashed before anything is sent. A blob uploaded under a
    digest it does not have would be served to every tree that links that digest.
    """
    for f in files:
        actual = _sha256(f.source) if f.source.is_file() else "absent"
        if actual != f.sha256:
            return SyncResult(False, -1, f"{f.path}: {f.source} is {actual}, not {f.sha256}")
    manifest = {"files": [{"path": f.path, "size": f.size, "sha256": f.sha256} for f in files]}
    return _sync(
        manifest=manifest,
        sources={f.sha256: f.source for f in files},
        final=("snapshot", "--kind", kind, "--id", snapshot_id),
        relay=relay,
        identity=identity,
        timeout_s=timeout_s,
        runner=runner,
        script_path=script_path,
    )


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(READ_CHUNK):
            h.update(chunk)
    return h.hexdigest()


def _sync(
    *,
    manifest: dict,
    sources: dict[str, Path],
    final: tuple[str, ...],
    relay: StagingHost,
    identity: str,
    timeout_s: int,
    runner,
    script_path: str | Path | None,
) -> SyncResult:
    script = Path(script_path) if script_path else Path(__file__).resolve().parents[2] / "tools" / "blobstore.py"
    sent = runner(
        _ssh_argv(relay, identity, f"cat > {RELAY_STORE_REMOTE}"),
        input=script.read_text(encoding="utf-8"),
        capture_output=True,
        text=True,
        timeout=timeout_s,
        check=False,
    )
    if sent.returncode != 0:
        return SyncResult(False, sent.returncode, f"shipping blobstore.py: {(sent.stderr or '').strip()[:300]}")

    payload = json.dumps(manifest)
    want = runner(
        _ssh_argv(relay, identity, _store_cmd(relay, "want")),
        input=payload,
        capture_output=True,
        text=True,
        timeout=timeout_s,
        check=False,
    )
    if want.returncode != 0:
        return SyncResult(False, want.returncode, f"want: {(want.stderr or '').strip()[:300]}")
    missing = {line.strip() for line in want.stdout.splitlines() if line.strip()}

    if missing:
        staged = upload_blobs(
            missing=missing,
            sources=sources,
            relay=relay,
            identity=identity,
            timeout_s=timeout_s,
            runner=runner,
        )
        if not staged.ok:
            return staged

    done = runner(
        _ssh_argv(relay, identity, _store_cmd(relay, *final)),
        input=payload,
        capture_output=True,
        text=True,
        timeout=timeout_s,
        check=False,
    )
    if done.returncode != 0:
        return SyncResult(False, done.returncode, f"{final[0]}: {(done.stderr or '').strip()[:300]}")
    return SyncResult(True, 0, f"blobs_sent={len(missing)} {done.stdout.strip()}")


def upload_blobs(
    *,
    missing: set[str],
    sources: dict[str, Path],
    relay: StagingHost,
    identity: str = DEFAULT_IDENTITY,
    timeout_s: int = 7200,
    runner=subprocess.run,
) -> SyncResult:
    """Send exactly the blobs the relay lacks, named by their hash.

    Built as a hardlink farm in a temp directory rather than a copy: the staging
    tree is on the same volume, so naming 2 GB by hash costs directory entries.
    The farm mirrors the blobstore's own sharding so rsync can write straight into
    it without an ingest step.
    """
    by_hash = {digest: src for digest, src in sources.items() if digest in missing}
    if len(by_hash) != len(missing):
        return SyncResult(False, -1, "manifest does not name every missing hash")

    with tempfile.TemporaryDirectory(prefix="mast-blobs-") as tmp:
        farm = Path(tmp)
        for digest, src in by_hash.items():
            shard = farm / digest[:2]
            shard.mkdir(exist_ok=True)
            try:
                os.link(src, shard / digest)
            except OSError:
                # Different volume, or a filesystem without links: copying is
                # slower but correct, and the transfer cost is identical.
                shutil.copy2(src, shard / digest)
        argv = [
            RSYNC_EXE,
            "-rlt",
            "--no-perms",
            "--no-owner",
            "--no-group",
            "--chmod=D755,F644",
            "-e",
            ssh_spec(identity),
            cygwin_path(farm).rstrip("/") + "/",
            f"{relay.ssh_target}:{relay.root}/blobstore/",
        ]
        done = runner(argv, capture_output=True, text=True, timeout=timeout_s, check=False)
    if done.returncode != 0:
        return SyncResult(False, done.returncode, f"blob upload: {(done.stdout or '') + (done.stderr or '')}"[:400])
    return SyncResult(True, 0, f"uploaded {len(by_hash)} blobs")
