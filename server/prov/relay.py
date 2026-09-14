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

**Why the WAN cost is small.** ``/Storage/mast-vendor`` already holds the four
vendored inputs -- 12,918,167,762 of the payload's 14,877,432,438 bytes -- and
``vendor-view`` presents them under their staging-root names. Passing that as a
``--link-dest`` lets rsync hardlink 87% of any host tree instead of transferring
it, so the first host costs the ~1.96 GB remainder and each later one costs the
few files that actually differ (measured: 199 bytes for a second host tree).

**Three transport facts, each of which cost a diagnosis:**

* The ssh must be **cygwin's** (``/usr/bin/ssh``), not Windows OpenSSH. Under
  Task Scheduler cygwin rsync cannot hand its pipes to a native Windows child:
  ssh authenticates cleanly on its own and then rsync dies with ``connection
  unexpectedly closed (0 bytes received)``. Interactively it works, which is what
  makes it expensive to find.
* Cygwin ssh takes its home from ``/etc/passwd`` (``/home/<user>``, which does not
  exist on the build host), not ``$HOME`` -- so the identity is named explicitly
  and known-hosts is sent to ``/dev/null``.
* ``--link-dest`` only hardlinks when *attributes* match as well as content, and
  Windows ACLs arriving through cygwin never match twice. Without the
  ``--no-perms``/``--no-owner``/``--no-group``/``--chmod`` set the sync silently
  degrades into a full copy of every host tree, every time, with no error.
"""

from __future__ import annotations

import json
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

#: Cygwin's rsync and ssh on the build host. Pinned rather than found on PATH for
#: the same reason the interpreter is: that machine has more than one of each.
CYGWIN_RSYNC = "/usr/bin/rsync"
CYGWIN_SSH = "/usr/bin/ssh"
DEFAULT_IDENTITY = "/cygdrive/c/Users/labcomp2/.ssh/id_ed25519"
#: Directory entries the relay serves; the share points here, not at the root.
HOSTS_SUBDIR = "hosts"


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

    def vendor_view(self) -> str:
        return f"{self.root}/vendor-view"


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


def rsync_argv(
    *,
    staging_dir: str | Path,
    host: str,
    relay: StagingHost,
    link_dests: Sequence[str] = (),
    identity: str = DEFAULT_IDENTITY,
) -> list[str]:
    """The rsync invocation that puts one host's payload on the relay.

    ``-rlt`` and not ``-a``: ``-a`` implies ``-pgoD``, which reinstates exactly the
    attribute comparison that stops ``--link-dest`` from linking.
    """
    src = cygwin_path(staging_dir).rstrip("/") + "/"
    argv = [
        CYGWIN_RSYNC,
        "-rltL",
        "--delete",
        "--no-perms",
        "--no-owner",
        "--no-group",
        "--chmod=D755,F644",
        "--stats",
    ]
    argv += [f"--link-dest={d}" for d in link_dests]
    argv += ["-e", ssh_spec(identity), src, f"{relay.ssh_target}:{relay.host_dir(host)}/"]
    return argv


@dataclass(frozen=True)
class SyncResult:
    ok: bool
    returncode: int
    detail: str


def sync(
    *,
    staging_dir: str | Path,
    host: str,
    relay: StagingHost,
    link_dests: Sequence[str] = (),
    identity: str = DEFAULT_IDENTITY,
    timeout_s: int = 7200,
    runner=subprocess.run,
) -> SyncResult:
    """Put one host's payload on the relay. Fails closed, like every other phase.

    rsync creates only the last component of a destination path, so the parent is
    made first -- otherwise the sync reports success having written nothing, which
    is how a relay ends up serving an empty directory.
    """
    mkdir = [CYGWIN_SSH, *ssh_spec(identity).split()[1:], relay.ssh_target, f"mkdir -p {relay.host_dir(host)}"]
    made = runner(mkdir, capture_output=True, text=True, timeout=timeout_s, check=False)
    if made.returncode != 0:
        return SyncResult(False, made.returncode, (made.stderr or made.stdout or "").strip()[:400])
    argv = rsync_argv(staging_dir=staging_dir, host=host, relay=relay, link_dests=link_dests, identity=identity)
    done = runner(argv, capture_output=True, text=True, timeout=timeout_s, check=False)
    detail = (done.stdout or "") + (done.stderr or "")
    return SyncResult(done.returncode == 0, done.returncode, detail.strip()[-600:])
