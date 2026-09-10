"""Tests for prov.payload -- which staged assets a targeted run may leave behind
(MAST_provisioning#186 tier 1).

The manifest is COMPLETE: every staged root entry is either claimed by at least
one module (``module_payload``) or declared always-ship (``payload_always``).
There is no catch-all for an unrecorded entry -- the build refuses to write a
manifest that leaves one, so an unrecorded name here is a bug, not a default.
"""

from __future__ import annotations

import pytest

from prov.payload import IncompletePayloadManifestError, exclusions


def mod(files: list[str] | None = None, dirs: list[str] | None = None) -> dict:
    return {"files": files or [], "dirs": dirs or []}


ALWAYS = {"files": ["commands.json", "provisioning.psm1", "verify-jupyter.ps1"], "dirs": []}

FLEET = {
    "modules": ["imdisk", "jupyter", "astrometry", "mast-validation"],
    "module_payload": {
        "imdisk": mod(["ImDiskTk-x64.zip"], ["mast-indexes"]),
        "jupyter": mod(["requirements.txt"], ["wheels"]),
        "astrometry": mod(["astrometry.tgz", "full-frame.fits"]),
        "mast-validation": mod(["full-frame.fits"]),
    },
    "payload_always": ALWAYS,
}


def transferred(build: dict, targets: list[str]) -> set[str]:
    """Every recorded entry minus what this target set excludes."""
    recorded = {n for e in build["module_payload"].values() for n in e["files"] + e["dirs"]}
    recorded |= set(build["payload_always"]["files"]) | set(build["payload_always"]["dirs"])
    r = exclusions(build, targets)
    return recorded - set(r.files) - set(r.dirs)


def test_force_and_targeting_every_module_transfer_the_same_set():
    """The two ways of saying "send everything" must agree.

    ``--force`` sends everything by the empty-target rule, which is a shortcut.
    Targeting every module sends everything by attribution alone, with nothing
    falling through. If these differ, the recording is incomplete -- some entry
    is reaching the unit only because no rule named it.
    """
    forced = transferred(FLEET, [])
    every_module = transferred(FLEET, list(FLEET["module_payload"]))
    assert forced == every_module
    assert not exclusions(FLEET, list(FLEET["module_payload"]))


def test_forced_transfer_is_the_whole_recorded_payload():
    forced = transferred(FLEET, [])
    assert forced == {
        "ImDiskTk-x64.zip", "mast-indexes", "requirements.txt", "wheels",
        "astrometry.tgz", "full-frame.fits",
        "commands.json", "provisioning.psm1", "verify-jupyter.ps1",
    }


def test_no_targets_excludes_nothing():
    assert not exclusions(FLEET, [])


def test_untargeted_module_loses_its_assets():
    r = exclusions(FLEET, ["jupyter"])
    assert "ImDiskTk-x64.zip" in r.files
    assert "mast-indexes" in r.dirs
    assert "astrometry.tgz" in r.files


def test_targeted_module_keeps_its_assets():
    r = exclusions(FLEET, ["jupyter"])
    assert "requirements.txt" not in r.files
    assert "wheels" not in r.dirs


def test_one_targeted_claimant_keeps_a_shared_entry():
    assert "full-frame.fits" not in exclusions(FLEET, ["astrometry"]).files
    assert "full-frame.fits" not in exclusions(FLEET, ["mast-validation"]).files
    assert "full-frame.fits" in exclusions(FLEET, ["jupyter"]).files


def test_always_entries_survive_every_target_set():
    # The scripts, commands.json and build-manifest.json. Excluding one breaks
    # the run outright, and run-verify-only.ps1 needs every verify script even
    # for modules this run did not touch.
    for targets in ([], ["jupyter"], ["reboot"], list(FLEET["module_payload"])):
        r = exclusions(FLEET, targets)
        assert "commands.json" not in r.files
        assert "provisioning.psm1" not in r.files
        assert "verify-jupyter.ps1" not in r.files


def test_unknown_target_excludes_every_module_asset_but_no_always_entry():
    r = exclusions(FLEET, ["reboot"])
    assert set(r.dirs) == {"mast-indexes", "wheels"}
    assert "full-frame.fits" in r.files
    assert "commands.json" not in r.files


def test_entries_keep_build_order_and_do_not_repeat():
    r = exclusions(FLEET, ["reboot"])
    assert r.dirs == ("mast-indexes", "wheels")
    assert r.files.count("full-frame.fits") == 1


def test_a_manifest_without_the_fields_is_an_error_not_a_free_pass():
    # Phase 4 always builds, so the field is always present. Its absence means
    # the driver and the build script disagree, and guessing "send everything"
    # would hide that behind a silently expensive run.
    with pytest.raises(IncompletePayloadManifestError):
        exclusions({"modules": ["imdisk"]}, ["jupyter"])


def test_a_malformed_entry_is_an_error_not_a_skip():
    # Without the catch-all, quietly dropping a malformed entry means quietly
    # not transferring what it named.
    bad = {"module_payload": {"a": {"files": "notalist", "dirs": []}}, "payload_always": ALWAYS}
    with pytest.raises(IncompletePayloadManifestError):
        exclusions(bad, ["z"])
