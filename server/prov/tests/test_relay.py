"""Tests for prov.relay -- staging the payload on a host the unit can reach
(MAST_provisioning#186 stage 2).

The unit pulls over SMB, so it must open TCP 445 to whatever serves the payload.
A site's units can do that only for a host on their own VLAN, which is why a run
driven from the institute dies at PREFLIGHT_UNIT_SMB_FAIL today. The relay is a
declared per-site staging host the orchestrator rsyncs to and the unit pulls
from; the orchestrator itself no longer has to be on that VLAN.
"""

from __future__ import annotations

import hashlib
import json
import subprocess

import pytest

from prov.relay import SnapshotFile, StagingHost, cygwin_path, load_staging_hosts, sync_snapshot

NS = {
    "address": "10.23.1.181",
    "share": "mast-provisioning",
    "ssh_target": "mast@10.23.1.181",
    "root": "/Storage/mast-provisioning",
}


def write(tmp_path, sites: dict):
    p = tmp_path / "staging-hosts.json"
    p.write_text(json.dumps({"sites": sites}), encoding="utf-8")
    return p


def test_a_site_with_no_entry_has_no_relay(tmp_path):
    # The bench and the dev VM keep pulling from the orchestrator itself, so an
    # undeclared site must behave exactly as it did before this existed.
    hosts = load_staging_hosts(write(tmp_path, {"ns": NS}))
    assert hosts.get("wis") is None
    assert hosts["ns"].address == "10.23.1.181"


def test_an_absent_file_means_no_relays_anywhere(tmp_path):
    assert load_staging_hosts(tmp_path / "nope.json") == {}


def test_a_malformed_entry_is_an_error_not_a_silent_skip(tmp_path):
    # Silently ignoring a typo would send the unit at the orchestrator, which is
    # the failure this exists to remove -- and it would look like a config that
    # simply had not been picked up.
    with pytest.raises(ValueError, match="ns"):
        load_staging_hosts(write(tmp_path, {"ns": {"address": "10.23.1.181"}}))


def test_the_unit_facing_unc_is_built_from_the_relay():
    relay = StagingHost(**NS)
    assert relay.unc("mast07") == r"\\10.23.1.181\mast-provisioning\mast07\01-provisioning"


def test_windows_paths_become_cygwin_paths():
    # rsync is cygwin's; its source argument must be a cygwin path even though
    # everything else on that machine speaks C:\.
    assert cygwin_path(r"C:\MAST\staging\mast07") == "/cygdrive/c/MAST/staging/mast07"
    assert cygwin_path(r"D:\x") == "/cygdrive/d/x"


def test_the_shipped_declaration_loads():
    # A typo here would not fail until a run reached a site, and the failure
    # would look like a relay that had not been configured yet.
    from prov import transport as T

    hosts = load_staging_hosts(T.REPO_ROOT / "server" / "data" / "staging-hosts.json")
    ns = hosts["ns"]
    assert ns.unc("mast07") == r"\\10.23.1.181\mast-provisioning\mast07\01-provisioning"
    assert ns.host_dir("mast07") == "/Storage/mast-provisioning/hosts/mast07/01-provisioning"
    assert "wis" not in hosts, "the bench pulls from the orchestrator itself"


def _files(tmp_path, bodies: dict[str, bytes]) -> list[SnapshotFile]:
    out = []
    for name, body in bodies.items():
        src = tmp_path / "cache" / "deep" / name
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(body)
        out.append(SnapshotFile(name, hashlib.sha256(body).hexdigest(), len(body), src))
    return out


class FakeRunner:
    """Answers the four relay steps; ``want`` reports ``missing`` as lacking."""

    def __init__(self, missing: set[str]):
        self.missing = missing
        self.calls: list[tuple[list[str], str | None]] = []

    def __call__(self, argv, input=None, **_kw):
        self.calls.append((argv, input))
        out = "\n".join(sorted(self.missing)) if argv[-1].endswith(" want") else ""
        return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="")


def test_sync_snapshot_sends_only_what_is_missing_and_records_the_snapshot(tmp_path):
    files = _files(tmp_path, {"a.msu": b"lcu", "b.msu": b"dotnet"})
    runner = FakeRunner({files[0].sha256})
    result = sync_snapshot(
        kind="windows-os-baseline", snapshot_id="19044-2026-09", files=files, relay=StagingHost(**NS), runner=runner
    )
    assert result.ok, result.detail
    assert "blobs_sent=1" in result.detail
    final_cmd, final_input = runner.calls[-1]
    assert final_cmd[-1].endswith("snapshot --kind windows-os-baseline --id 19044-2026-09")
    assert final_input is not None
    assert {e["path"] for e in json.loads(final_input)["files"]} == {"a.msu", "b.msu"}


def test_sync_snapshot_refuses_a_source_that_is_not_its_digest(tmp_path):
    # Uploading it would put wrong bytes under a name that claims they are right,
    # and every tree that ever links that digest would inherit them.
    files = _files(tmp_path, {"a.msu": b"lcu"})
    bad = [SnapshotFile(files[0].path, hashlib.sha256(b"other").hexdigest(), 3, files[0].source)]
    runner = FakeRunner(set())
    result = sync_snapshot(kind="windows-os-baseline", snapshot_id="x", files=bad, relay=StagingHost(**NS), runner=runner)
    assert not result.ok
    assert "a.msu" in result.detail
    assert runner.calls == [], "nothing is sent once a source fails its digest"
