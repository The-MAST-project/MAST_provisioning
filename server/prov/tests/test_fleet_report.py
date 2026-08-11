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


# --- #75: the report must show which upstream revisions each unit installed ----
#
# The fixtures use the real 2026-08-11 SHAs on purpose: three units came out of one
# fleet run on two different MAST_common commits and two different MAST_unit
# commits, every run reporting success, and the report called them IN SYNC.
_COMMON_NEW = "b4991791aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_COMMON_OLD = "86ab89e6bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
_UNIT_NEW = "1cf92164cccccccccccccccccccccccccccccccc"
_UNIT_OLD = "abb17241dddddddddddddddddddddddddddddddd"


def _repo_row(dir_: str, sha: str, rev: str = "", head: str = "master", repo: str = "R") -> dict:
    return {"dir": dir_, "repo": repo, "branch": "master", "rev": rev, "resolved_sha": sha, "head": head}


def _unit_with_repos(fdr, host: str, rows: list[dict]):
    u = fdr.UnitRecord(host=host, status="ok")
    u.repos = {r["dir"]: r for r in rows}
    return u


def test_repos_parsed_from_the_manifest(fdr):
    rec = fdr._manifest_from_obj("mast01", {"repos": [_repo_row("common", _COMMON_NEW), _repo_row("unit", _UNIT_NEW)]})
    assert sorted(rec.repos) == ["common", "unit"]
    assert rec.repos["common"]["resolved_sha"] == _COMMON_NEW


@pytest.mark.parametrize("bad", [None, {}, "nope", [1, 2], [{"no_dir": "x"}]])
def test_a_malformed_repos_block_degrades_to_empty(fdr, bad):
    # This is a diagnostic; it must survive the unit state it exists to diagnose.
    rec = fdr._manifest_from_obj("mast01", {"repos": bad})
    assert rec.repos == {}


def test_a_consistent_fleet_reports_all_ok(fdr):
    units = [
        _unit_with_repos(fdr, h, [_repo_row("common", _COMMON_NEW), _repo_row("unit", _UNIT_NEW)])
        for h in ("mast01", "mast02", "mast04")
    ]
    out = fdr.compare_repos(units, None)
    assert out["consistent_count"] == out["total_count"] == 2
    assert out["divergent_dirs"] == []
    assert all(s == fdr.REPO_OK for row in out["matrix"] for s in row["states"].values())


def test_the_2026_08_11_divergence_is_reported(fdr):
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW), _repo_row("unit", _UNIT_NEW)]),
        _unit_with_repos(fdr, "mast02", [_repo_row("common", _COMMON_NEW), _repo_row("unit", _UNIT_NEW)]),
        _unit_with_repos(fdr, "mast03", [_repo_row("common", _COMMON_OLD), _repo_row("unit", _UNIT_OLD)]),
    ]
    out = fdr.compare_repos(units, None)

    assert sorted(out["divergent_dirs"]) == ["common", "unit"]
    assert out["consistent_count"] == 0
    # The majority is the baseline, so the odd unit out is the one flagged.
    for row in out["matrix"]:
        assert row["states"]["mast03"] == fdr.REPO_DIFFERS
        assert row["states"]["mast01"] == fdr.REPO_OK
    assert out["drift_repos_by_host"]["mast03"] == ["common", "unit"]
    assert out["drift_repos_by_host"]["mast01"] == []


def test_a_repo_the_unit_never_pulled_is_absent_not_divergent(fdr):
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW), _repo_row("gui", "aaa")]),
        _unit_with_repos(fdr, "mast02", [_repo_row("common", _COMMON_NEW)]),
    ]
    out = fdr.compare_repos(units, None)
    gui = next(r for r in out["matrix"] if r["dir"] == "gui")
    assert gui["states"]["mast02"] == fdr.REPO_ABSENT
    # absent is not drift: a role that does not pull gui is not a problem.
    assert out["drift_repos_by_host"]["mast02"] == []


def test_a_pin_not_honoured_is_its_own_state(fdr):
    # Same SHA as the baseline, but on a branch while a rev was requested: the pin
    # was displaced (an override, or a clone predating it). Distinct from DIFFERS
    # because the cause and the fix are different.
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW, rev="v1.0.0", head="HEAD")]),
        _unit_with_repos(fdr, "mast02", [_repo_row("common", _COMMON_NEW, rev="v1.0.0", head="master")]),
    ]
    out = fdr.compare_repos(units, None)
    row = out["matrix"][0]
    assert row["states"]["mast01"] == fdr.REPO_OK
    assert row["states"]["mast02"] == fdr.REPO_UNPINNED
    assert row["pinned_rev"] == "v1.0.0"


def test_no_repo_data_is_distinguished_from_consistent(fdr):
    units = [fdr.UnitRecord(host="mast01", status="ok"), fdr.UnitRecord(host="mast02", status="ok")]
    out = fdr.compare_repos(units, None)
    assert out["any_data"] is False
    assert out["total_count"] == 0


def test_the_result_line_calls_out_repo_divergence(fdr):
    # The regression that matters: every module matching the build while the units
    # run different upstream commits used to render "all units in sync".
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW)]),
        _unit_with_repos(fdr, "mast03", [_repo_row("common", _COMMON_OLD)]),
    ]
    cmp = fdr.compare(units, None)
    boot = fdr.bootstrap_gaps(units, {"current_version": 1, "elements": []})
    repos = fdr.compare_repos(units, None)

    text = fdr.render(units, None, cmp, boot, None, repos)

    assert "upstream repo divergence" in text
    assert "=== Upstream repos" in text
    assert "all units in sync and bootstrap current" not in text


def test_the_csv_carries_the_repo_columns(fdr, tmp_path):
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW)]),
        _unit_with_repos(fdr, "mast03", [_repo_row("common", _COMMON_OLD)]),
    ]
    cmp = fdr.compare(units, None)
    boot = fdr.bootstrap_gaps(units, {"current_version": 1, "elements": []})
    repos = fdr.compare_repos(units, None)

    out = tmp_path / "r.csv"
    fdr.write_csv(out, units, cmp, boot, repos)
    rows = list(csv.DictReader(out.open(encoding="utf-8")))

    assert "repo:common" in rows[0]
    by_host = {r["host"]: r for r in rows}
    assert by_host["mast01"]["repo:common"] == _COMMON_NEW
    assert by_host["mast03"]["repo:common"] == _COMMON_OLD


def test_absent_alone_does_not_make_a_repo_divergent(fdr):
    # Found by rendering a realistic fleet: 'claude' was reported divergent purely
    # because one unit's role never pulls it, while every unit that HAD it agreed.
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW), _repo_row("claude", "3f2a1c8")]),
        _unit_with_repos(fdr, "mast02", [_repo_row("common", _COMMON_NEW), _repo_row("claude", "3f2a1c8")]),
        _unit_with_repos(fdr, "mast04", [_repo_row("common", _COMMON_NEW)]),
    ]
    out = fdr.compare_repos(units, None)
    assert out["divergent_dirs"] == []
    assert out["consistent_count"] == out["total_count"] == 2
