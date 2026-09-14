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

from prov.relay import StagingHost, cygwin_path, load_staging_hosts, rsync_argv

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


def argv(**kw) -> list[str]:
    base = {
        "staging_dir": r"C:\repo\staging\mast07\01-provisioning",
        "host": "mast07",
        "relay": StagingHost(**NS),
        "link_dests": ["/Storage/mast-provisioning/vendor-view"],
    }
    return rsync_argv(**{**base, **kw})


def test_junctions_are_dereferenced():
    # mast-indexes and cygwin-pkg-cache are junctions into C:\MAST\; cygwin sees
    # them as symlinks, so without -L the relay gets dangling links and the unit
    # pulls an empty directory.
    flags = argv()
    short = next(t for t in flags if t.startswith("-") and not t.startswith("--") and t != "-e")
    assert "L" in short, f"dereference flag missing from {short}"


def test_ownership_and_permission_flags_are_present():
    # --link-dest only hardlinks when attributes match too, and Windows ACLs
    # arriving through cygwin never match twice. Without these the sync silently
    # degrades to a full copy of every host tree, with no error at all.
    flags = argv()
    assert "--no-perms" in flags and "--no-owner" in flags and "--no-group" in flags
    assert any(f.startswith("--chmod=") for f in flags)
    assert "-a" not in flags, "-a implies -pgoD and undoes the flags above"


def test_every_link_dest_is_passed():
    a = argv(link_dests=["/Storage/mast-provisioning/vendor-view", "/Storage/mast-provisioning/payload/abc"])
    assert a.count("--link-dest") == 0  # passed as --link-dest=<path>, not two tokens
    assert "--link-dest=/Storage/mast-provisioning/vendor-view" in a
    assert "--link-dest=/Storage/mast-provisioning/payload/abc" in a


def test_the_source_is_a_cygwin_path_and_the_destination_is_the_relay():
    a = argv()
    # argv[0] is deliberately a Windows path -- the driver's Python execs it. It
    # is the ARGUMENTS that must be cygwin's, since rsync resolves those.
    assert a[0].lower().endswith("rsync.exe"), "the driver must exec a Windows path"
    assert not any("C:\\" in tok for tok in a[1:]), f"a Windows path reached rsync's arguments: {a}"
    assert a[-2] == "/cygdrive/c/repo/staging/mast07/01-provisioning/"
    assert a[-1] == "mast@10.23.1.181:/Storage/mast-provisioning/hosts/mast07/01-provisioning/"


def test_the_source_has_a_trailing_slash():
    # rsync copies the directory ITSELF without one, nesting the tree a level
    # deeper and leaving the unit's UNC pointing at nothing.
    assert argv()[-2].endswith("/")


def test_the_ssh_transport_is_cygwins_and_carries_an_explicit_identity():
    # Under Task Scheduler cygwin rsync cannot hand its pipes to a native
    # Windows child: ssh authenticates, then rsync dies with "connection
    # unexpectedly closed (0 bytes received)". And cygwin ssh takes its home
    # from /etc/passwd, not $HOME, so the key must be named.
    a = argv()
    spec = a[a.index("-e") + 1]
    assert spec.startswith("/usr/bin/ssh"), "rsync resolves -e through cygwin, so this one is a cygwin path"
    assert "-i /cygdrive/c/" in spec
    assert "UserKnownHostsFile=/dev/null" in spec


def test_the_shipped_declaration_loads():
    # A typo here would not fail until a run reached a site, and the failure
    # would look like a relay that had not been configured yet.
    from prov import transport as T

    hosts = load_staging_hosts(T.REPO_ROOT / "server" / "data" / "staging-hosts.json")
    ns = hosts["ns"]
    assert ns.unc("mast07") == r"\\10.23.1.181\mast-provisioning\mast07\01-provisioning"
    assert ns.host_dir("mast07") == "/Storage/mast-provisioning/hosts/mast07/01-provisioning"
    assert ns.vendor_view() == "/Storage/mast-provisioning/vendor-view"
    assert "wis" not in hosts, "the bench pulls from the orchestrator itself"
