"""Tests for prov.relay -- staging the payload on a host the unit can reach
(MAST_provisioning#186 stage 2).

The unit pulls over SMB, so it must open TCP 445 to whatever serves the payload.
A site's units can do that only for a host on their own VLAN, which is why a run
driven from the institute dies at PREFLIGHT_UNIT_SMB_FAIL today. The relay is a
declared per-site staging host the orchestrator rsyncs to and the unit pulls
from; the orchestrator itself no longer has to be on that VLAN.
"""

from __future__ import annotations

import json

import pytest

from prov.relay import StagingHost, cygwin_path, load_staging_hosts

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
