"""Tests for tools/fleet-drift-report.py.

The tool is a hyphenated script rather than a module, so it is loaded by path.
It lives under tools/ but is tested here because this is the suite that runs in
CI-equivalent form and because it shares prov.drift with the driver -- the two
must not disagree about what has drifted.
"""

from __future__ import annotations

import csv
import importlib.util
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]


def _load_report_module():
    sys.path.insert(0, str(_REPO_ROOT / "server"))
    spec = importlib.util.spec_from_file_location("fleet_drift_report", _REPO_ROOT / "tools" / "fleet-drift-report.py")
    mod = importlib.util.module_from_spec(spec)
    # Register before exec: the module defines dataclasses, and @dataclass looks
    # its own module up in sys.modules while the class body is being processed.
    sys.modules["fleet_drift_report"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def fdr():
    return _load_report_module()


def _unit(fdr, host: str, **modules):
    return fdr.UnitRecord(host=host, status="ok", modules=dict(modules))


def _entry(hash_: str, version: str = "1.0") -> dict:
    return {"version": version, "hash": hash_, "provide": "pass", "verify": "pass"}


BUILD = {
    "payload_hash": "agg",
    "modules": ["git", "desktop-shortcuts"],
    "module_state": {"git": {"version": "2.52", "hash": "h-git"}, "desktop-shortcuts": {"version": "1.0", "hash": "NEW"}},
}


def test_status_matrix_keys_on_hash_not_version(fdr):
    """The case that motivated hash-keyed reporting: this PR's desktop-shortcuts
    change altered the verify command with no version bump, so a version matrix
    shows nothing while the module is genuinely stale."""
    stale = _unit(fdr, "mast01", git=_entry("h-git", "2.52"), **{"desktop-shortcuts": _entry("OLD", "1.0")})
    current = _unit(fdr, "mast02", git=_entry("h-git", "2.52"), **{"desktop-shortcuts": _entry("NEW", "1.0")})
    cmp = fdr.compare_to_build([stale, current], BUILD)
    assert cmp["verdicts"] == {"mast01": "DRIFT", "mast02": "IN SYNC"}
    cells = {r["module"]: r["cells"] for r in cmp["matrix"]}
    assert cells["desktop-shortcuts"] == {"mast01": "STALE", "mast02": "ok"}


def test_csv_and_text_report_agree(fdr, tmp_path):
    """One run must not emit a text report saying STALE and a CSV saying nothing."""
    stale = _unit(fdr, "mast01", **{"desktop-shortcuts": _entry("OLD")})
    build = {
        "payload_hash": "agg",
        "modules": ["desktop-shortcuts"],
        "module_state": {"desktop-shortcuts": {"version": "1.0", "hash": "NEW"}},
    }
    cmp = fdr.compare_to_build([stale], build)
    out = tmp_path / "r.csv"
    fdr.write_csv(out, [stale], cmp, fdr.bootstrap_gaps([stale], {}))
    rows = list(csv.reader(out.open()))
    assert rows[0][-1] == "desktop-shortcuts"
    assert rows[1][-1] == "STALE"


def test_a_missing_module_renders_as_missing(fdr):
    partial = _unit(fdr, "mast01", git=_entry("h-git"))
    cmp = fdr.compare_to_build([partial], BUILD)
    cells = {r["module"]: r["cells"] for r in cmp["matrix"]}
    assert cells["desktop-shortcuts"]["mast01"] == "MISSING"


def test_tier2_failure_renders_as_repair(fdr):
    unit = _unit(fdr, "mast01", git=_entry("h-git"), **{"desktop-shortcuts": _entry("NEW")})
    unit.validation = {"git": "fail"}
    unit.validated_at = "2026-08-02T10:00:00Z"
    cmp = fdr.compare_to_build([unit], BUILD)
    cells = {r["module"]: r["cells"] for r in cmp["matrix"]}
    assert cells["git"]["mast01"] == "REPAIR"


def test_legacy_manifest_module_versions_still_parse(fdr):
    """A unit not yet reprovisioned carries the pre-stage-2 shape."""
    rec = fdr._manifest_from_obj("mast01", {"payload_hash": "old", "module_versions": {"git": "2.44"}})
    assert rec.module_versions == {"git": "2.44"}
    assert rec.modules == {}


def test_new_manifest_yields_both_modules_and_versions(fdr):
    rec = fdr._manifest_from_obj(
        "mast01", {"payload_hash": "new", "fully_provisioned": True, "modules": {"git": {"version": "2.52", "hash": "h"}}}
    )
    assert rec.modules["git"]["hash"] == "h"
    assert rec.module_versions == {"git": "2.52"}
    assert rec.fully_provisioned is True


def test_an_unreadable_validation_report_is_unknown_not_failed(fdr):
    """Garbled tier-2 data must not manufacture drift."""
    assert fdr._parse_validation("not json at all") == ({}, None)
    assert fdr._parse_validation("") == ({}, None)


def test_validation_report_parses_modules_and_timestamp(fdr):
    mods, at = fdr._parse_validation('{"checked_at": "2026-08-02T10:00:00Z", "modules": {"git": "fail"}}')
    assert mods == {"git": "fail"}
    assert at == "2026-08-02T10:00:00Z"
