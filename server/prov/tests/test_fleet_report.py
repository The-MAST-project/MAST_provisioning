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
    assert spec and spec.loader
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


_GOLDEN = Path(__file__).parent / "data" / "fleet_report_golden.txt"


#: Elements for the golden fixture. Mixed classifications on purpose: the
#: work-order split (self-heals / needs a console visit / neither) only renders
#: when a unit's missing list spans more than one kind.
GOLDEN_ELEMENTS = {
    "current_version": 3,
    "elements": [
        {"id": "firewall-off", "since": 1, "description": "x", "reassert": "routine"},
        {"id": "mast-admin-account", "since": 1, "description": "x", "reassert": "console"},
        {"id": "service-trim", "since": 3, "description": "x", "reassert": "routine"},
        {"id": "npcap", "since": 3, "description": "x", "reassert": "console"},
        {"id": "openssh-from-msi", "since": 3, "description": "x", "reassert": "on-demand"},
        {"id": "execution-policy", "since": 3, "description": "x", "reassert": "provider", "provider": "execution-policy"},
    ],
}


def _golden_fixture(fdr):
    """A fleet that exercises every section render() can emit.

    Deliberately rich: a reference column, a drifted unit, an in-sync unit, an
    unreachable one carrying an error, tier-2 results both present and never-run,
    repo divergence with an unhonoured pin, and all three bootstrap states. If a
    section stops being reachable from this fixture, the golden stops covering it.
    """

    def entry(h, v="1.0"):
        return {"version": v, "hash": h, "provide": "pass", "verify": "pass"}

    repos = {
        "common": {"repo": "MAST_common", "branch": "master", "rev": "", "resolved_sha": "aaaaaaaaaaaa", "head": "master"},
        "unit": {"repo": "MAST_unit", "branch": "main", "rev": "v1.2", "resolved_sha": "bbbbbbbbbbbb", "head": "main"},
    }
    repos_drift = dict(repos)
    repos_drift["unit"] = {**repos["unit"], "resolved_sha": "cccccccccccc"}

    u1 = fdr.UnitRecord(
        host="mast01",
        status="ok",
        payload_hash="agg1234567890",
        git_sha="gitsha123456",
        installed_at="2026-08-01T10:00:00Z",
        modules={
            "git": entry("h-git"),
            "desktop-shortcuts": entry("OLD"),
            "mongodb-client": {
                **entry("h-mongo"),
                "facts": {
                    "compass_version": "1.49.14",
                    "compass_installer_version": "1.43.0",
                    "observed_at": "2026-08-23T12:00:00Z",
                },
            },
        },
        bootstrap_version=3,
        repos=repos,
        validated_at="2026-08-02T09:00:00Z",
        validation={"git": "pass", "desktop-shortcuts": "fail"},
    )
    u2 = fdr.UnitRecord(
        host="mast02",
        status="ok",
        payload_hash="agg1234567890",
        git_sha="gitsha123456",
        installed_at="2026-08-01T11:00:00Z",
        modules={
            # Behind on bootstrap_version, yet every routine element was applied
            # this morning: the 'behind but converging' case the annotation exists
            # for. It must NOT clear the flag -- console work is still outstanding.
            "bootstrap-reassert": {
                **entry("h-reassert"),
                "facts": {
                    "reassert_state": "applied",
                    "reassert_at": "2026-08-25T06:59:44Z",
                    "reassert_applied_count": 2,
                    "observed_at": "2026-08-25T06:59:48Z",
                },
            },
            "git": entry("h-git"),
            "desktop-shortcuts": entry("NEW"),
            "mongodb-client": {
                **entry("h-mongo"),
                "facts": {
                    "compass_version": "1.43.0",
                    "compass_installer_version": "1.43.0",
                    "observed_at": "2026-08-23T13:00:00Z",
                },
            },
        },
        bootstrap_version=2,
        repos=repos_drift,
    )
    u3 = fdr.UnitRecord(host="mast03", status="unreachable", error="no route to host")
    ref = fdr.UnitRecord(
        host="BUILD (reference)",
        status="ok",
        payload_hash="agg1234567890",
        git_sha="gitsha123456",
        installed_at="2026-08-01T09:00:00Z",
        modules={"git": entry("h-git"), "desktop-shortcuts": entry("NEW"), "mongodb-client": entry("h-mongo")},
    )
    # .facts is lifted out of the module entries by _manifest_from_obj when a
    # manifest is parsed; these records are built directly, so mirror it here.
    for u in (u1, u2):
        u.facts = {m: e["facts"] for m, e in u.modules.items() if "facts" in e}
    units = [u1, u2, u3]
    build = {
        "payload_hash": "agg1234567890",
        "modules": ["git", "desktop-shortcuts", "mongodb-client"],
        "module_state": {
            "git": {"version": "2.52", "hash": "h-git"},
            "desktop-shortcuts": {"version": "1.0", "hash": "NEW"},
            "mongodb-client": {"version": "mongosh-2.2.6/tools-100.9.4", "hash": "h-mongo"},
        },
    }
    return {
        "units": units,
        "reference": ref,
        "cmp": fdr.compare_to_build(units, build),
        "boot": fdr.bootstrap_gaps(units, GOLDEN_ELEMENTS),
        "repo_boot_v": 4,
        "repos": fdr.compare_repos(units, ref, expected={"common", "unit"}),
        "facts": fdr.compare_facts(units),
    }


def test_render_output_is_byte_for_byte_unchanged(fdr):
    """The report IS the interface -- an operator reads it, and #72's refactor of
    render() must not move a single space. Regenerate deliberately with
    tools/../make it fail, read the diff, and only then update the golden.
    """
    got = fdr.render(**_golden_fixture(fdr))
    expected = _GOLDEN.read_text(encoding="utf-8").rstrip("\n")
    assert got == expected, "render() output changed; diff it against the golden before updating"


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


def test_a_repo_the_role_never_pulls_is_na_not_drift(fdr):
    # 'gui' is control-only, so its absence on a unit means nothing.
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW), _repo_row("gui", "aaa")]),
        _unit_with_repos(fdr, "mast02", [_repo_row("common", _COMMON_NEW)]),
    ]
    out = fdr.compare_repos(units, None, expected={"common"})
    gui = next(r for r in out["matrix"] if r["dir"] == "gui")
    assert gui["states"]["mast02"] == fdr.REPO_NA
    assert out["drift_repos_by_host"]["mast02"] == []


def test_a_repo_the_role_does_pull_is_missing_and_is_drift(fdr):
    # The case Eli caught: 'claude' has roles unit,control,spec, so a unit without
    # it is missing something it should have. Treating that as benign hid a real gap.
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW), _repo_row("claude", "3f2a1c8")]),
        _unit_with_repos(fdr, "mast04", [_repo_row("common", _COMMON_NEW)]),
    ]
    out = fdr.compare_repos(units, None, expected={"common", "claude"})
    claude = next(r for r in out["matrix"] if r["dir"] == "claude")

    assert claude["states"]["mast04"] == fdr.REPO_MISSING
    assert out["drift_repos_by_host"]["mast04"] == ["claude"]
    assert "claude" in out["divergent_dirs"]


def test_a_repo_absent_from_every_unit_still_gets_a_row(fdr):
    # Otherwise a repo nobody cloned vanishes from the report entirely, which is the
    # least visible way to be missing something.
    units = [_unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW)])]
    out = fdr.compare_repos(units, None, expected={"common", "claude"})
    assert "claude" in out["dirs"]
    assert next(r for r in out["matrix"] if r["dir"] == "claude")["states"]["mast01"] == fdr.REPO_MISSING


def test_expected_repo_dirs_reads_the_real_manifest(fdr):
    want = fdr.expected_repo_dirs(_REPO_ROOT, "unit")
    # From tools/mast-repos.tsv: common/unit/claude are unit-role; gui is control-only.
    assert {"common", "unit", "claude"} <= want
    assert "gui" not in want


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


def test_an_unexpected_repo_absence_does_not_make_a_repo_divergent(fdr):
    # Found by rendering a realistic fleet: a repo was reported divergent purely
    # because one unit lacked it, while every unit that had it agreed. Only holds for
    # a repo the role does not pull -- see the MISSING test above for the other half.
    units = [
        _unit_with_repos(fdr, "mast01", [_repo_row("common", _COMMON_NEW), _repo_row("gui", "3f2a1c8")]),
        _unit_with_repos(fdr, "mast02", [_repo_row("common", _COMMON_NEW), _repo_row("gui", "3f2a1c8")]),
        _unit_with_repos(fdr, "mast04", [_repo_row("common", _COMMON_NEW)]),
    ]
    out = fdr.compare_repos(units, None, expected={"common"})
    assert out["divergent_dirs"] == []
    assert out["consistent_count"] == out["total_count"] == 2


# --- Module-reported facts (#137) -------------------------------------------
# The fleet answer to "which Compass is on each unit". Facts are free-form, so
# these pin the comparison rules rather than any particular fact's meaning.


def _facts_unit(fdr, host: str, **facts):
    return fdr.UnitRecord(host=host, status="ok", facts={"mongodb-client": dict(facts)})


def test_facts_are_lifted_out_of_the_module_entries(fdr):
    rec = fdr._manifest_from_obj(
        "mast07",
        {
            "modules": {
                "git": {"version": "1.0", "hash": "h"},
                "mongodb-client": {"version": "1.0", "hash": "h", "facts": {"compass_version": "1.49.14"}},
            }
        },
    )
    assert rec.facts == {"mongodb-client": {"compass_version": "1.49.14"}}


def test_a_manifest_without_facts_reports_none(fdr):
    rec = fdr._manifest_from_obj("mast01", {"modules": {"git": {"version": "1.0", "hash": "h"}}})
    assert rec.facts == {}


def test_divergent_fact_is_flagged(fdr):
    cmp = fdr.compare_facts(
        [_facts_unit(fdr, "mast01", compass_version="1.49.14"), _facts_unit(fdr, "mast02", compass_version="1.43.0")]
    )
    assert cmp["divergent_count"] == 1
    assert cmp["rows"][0]["divergent"] is True


def test_agreeing_fact_is_not_flagged(fdr):
    cmp = fdr.compare_facts(
        [_facts_unit(fdr, "mast01", compass_version="1.43.0"), _facts_unit(fdr, "mast02", compass_version="1.43.0")]
    )
    assert cmp["divergent_count"] == 0


def test_observed_at_never_counts_as_divergence(fdr):
    # It differs on every unit by construction; counting it would mark every
    # module divergent and bury the rows that mean something.
    cmp = fdr.compare_facts(
        [
            _facts_unit(fdr, "mast01", compass_version="1.43.0", observed_at="2026-08-23T12:00:00Z"),
            _facts_unit(fdr, "mast02", compass_version="1.43.0", observed_at="2026-08-23T13:00:00Z"),
        ]
    )
    assert [r["key"] for r in cmp["rows"]] == ["compass_version"]
    assert cmp["divergent_count"] == 0


def test_a_unit_that_reported_nothing_is_not_a_disagreement(fdr):
    # Absent is unknown, not a different answer -- one unit reporting is not drift.
    cmp = fdr.compare_facts([_facts_unit(fdr, "mast01", compass_version="1.43.0"), _unit(fdr, "mast02")])
    row = cmp["rows"][0]
    assert row["cells"]["mast02"] is None
    assert row["divergent"] is False
    assert row["reported_by"] == 1


def test_unreachable_units_are_excluded(fdr):
    cmp = fdr.compare_facts(
        [_facts_unit(fdr, "mast01", compass_version="1.43.0"), fdr.UnitRecord(host="mast03", status="unreachable")]
    )
    assert "mast03" not in cmp["rows"][0]["cells"]


def test_no_facts_anywhere_renders_no_section(fdr):
    # A fleet that has not re-provisioned since #137 must not gain an empty
    # section -- which is also what keeps the golden report byte-stable.
    cmp = fdr.compare_facts([_unit(fdr, "mast01"), _unit(fdr, "mast02")])
    assert cmp["any_data"] is False
    assert fdr._render_facts_matrix(cmp, [_unit(fdr, "mast01")]) == []


def test_facts_reach_the_csv(fdr, tmp_path):
    units = [_facts_unit(fdr, "mast01", compass_version="1.49.14"), _facts_unit(fdr, "mast02", compass_version="1.43.0")]
    build = {"payload_hash": "p", "modules": [], "module_state": {}}
    cmp = fdr.compare_to_build(units, build)
    facts = fdr.compare_facts(units)
    out = tmp_path / "r.csv"
    fdr.write_csv(out, units, cmp, fdr.bootstrap_gaps(units, {"current_version": 1, "elements": {}}), None, facts)
    rows = list(csv.DictReader(out.open(encoding="utf-8")))
    col = "fact:mongodb-client.compass_version"
    assert {r["host"]: r[col] for r in rows} == {"mast01": "1.49.14", "mast02": "1.43.0"}


# --- BIOS power policy section ------------------------------------------------
# Its own section rather than a row in the facts matrix, because that matrix
# deliberately does not warn: a differing fact is usually an observation. A unit
# that will not power itself back on after a mains event is not an observation.


def _bios_unit(fdr, host: str, **bios):
    rec = _unit(fdr, host, **{"power-management": {"version": "1.0", "hash": "h"}})
    rec.facts = {"power-management": dict(bios)}
    return rec


def test_no_unit_reports_bios_renders_no_section(fdr):
    assert fdr._render_bios_policy([_unit(fdr, "mast01", git={"version": "1.0", "hash": "h"})]) == []


def test_matching_units_report_no_warning(fdr):
    out = "\n".join(
        fdr._render_bios_policy(
            [
                _bios_unit(fdr, "mast01", bios_check="match", needs_attention=False, baseboard="PE2100U"),
                _bios_unit(fdr, "mast03", bios_check="match", needs_attention=False, baseboard="PE2100U"),
            ]
        )
    )
    assert "[WARN]" not in out
    assert "All reporting units match their baseline power policy." in out


def test_field_drift_warns_about_not_powering_back_on(fdr):
    out = "\n".join(
        fdr._render_bios_policy(
            [_bios_unit(fdr, "mast02", bios_check="field-drift", needs_attention=True, field_restore_ac_power_loss=0)]
        )
    )
    assert "[WARN] mast02" in out
    assert "may not power itself" in out


def test_unknown_baseline_warns_that_it_is_unverified_not_wrong(fdr):
    # New hardware is the expected case, so the wording must not accuse the
    # board of being misconfigured -- only of being unverifiable.
    out = "\n".join(
        fdr._render_bios_policy(
            [_bios_unit(fdr, "mast09", bios_check="unknown-baseline", needs_attention=True, baseboard="NEWBOARD")]
        )
    )
    assert "[WARN] mast09" in out
    assert "NOT verified" in out
    assert "may not power itself" not in out


def test_blob_drift_is_noted_but_never_warned(fdr):
    out = "\n".join(fdr._render_bios_policy([_bios_unit(fdr, "mast04", bios_check="blob-drift", needs_attention=False)]))
    assert "[WARN]" not in out
    assert "[note] mast04" in out


# --- Bootstrap gaps as a work order (#143 stage 5) ---------------------------

_WO_ELEMENTS = {
    "current_version": 3,
    "elements": [
        {"id": "firewall-off", "since": 1, "description": "x", "reassert": "routine"},
        {"id": "mast-admin-account", "since": 1, "description": "x", "reassert": "console"},
        {"id": "service-trim", "since": 3, "description": "x", "reassert": "routine"},
        {"id": "npcap", "since": 3, "description": "x", "reassert": "console"},
    ],
}


def _boot_unit(fdr, host, version, **facts):
    rec = _unit(fdr, host, git={"version": "1.0", "hash": "h"})
    rec.bootstrap_version = version
    if facts:
        rec.facts = {"bootstrap-reassert": dict(facts)}
    return rec


def test_an_unstamped_unit_reports_every_element_as_unverified(fdr):
    # Not an empty list: without a stamped version there is nothing to compare
    # 'since' against, so nothing is KNOWN to be applied. Reporting zero made the
    # unit whose state is least known the one the report had least to say about.
    gaps = fdr.bootstrap_gaps([_boot_unit(fdr, "mast02", None)], _WO_ELEMENTS)["by_host"]["mast02"]
    assert gaps["state"] == "unstamped"
    assert sorted(gaps["missing"]) == ["firewall-off", "mast-admin-account", "npcap", "service-trim"]


def test_missing_elements_are_split_by_who_can_fix_them(fdr):
    gaps = fdr.bootstrap_gaps([_boot_unit(fdr, "mast03", 2)], _WO_ELEMENTS)["by_host"]["mast03"]
    assert gaps["state"] == "outdated"
    assert gaps["self_healing"] == ["service-trim"]
    assert gaps["needs_console"] == ["npcap"]


def test_a_current_unit_has_nothing_to_do(fdr):
    gaps = fdr.bootstrap_gaps([_boot_unit(fdr, "mast01", 3)], _WO_ELEMENTS)["by_host"]["mast01"]
    assert gaps["state"] == "current"
    assert gaps["missing"] == []
    assert gaps["needs_console"] == []


def test_a_recent_re_assert_annotates_but_does_not_clear_the_flag(fdr):
    # The whole point of annotate-not-suppress: console work is still outstanding,
    # so the unit stays flagged however recently it converged.
    unit = _boot_unit(
        fdr, "mast02", 2, reassert_state="applied", reassert_at="2026-08-25T06:59:44Z", reassert_applied_count=1
    )
    boot = fdr.bootstrap_gaps([unit], _WO_ELEMENTS)
    gaps = boot["by_host"]["mast02"]
    assert gaps["state"] == "outdated"
    assert gaps["needs_console"] == ["npcap"]
    assert gaps["reassert"]["state"] == "applied"
    rendered = "\n".join(fdr._render_bootstrap([unit], boot, None))
    assert "re-asserted 2026-08-25T06:59:44Z" in rendered
    assert "OUTDATED" in rendered
    assert "NEEDS A CONSOLE VISIT" in rendered


def test_a_failed_re_assert_is_warned_about(fdr):
    unit = _boot_unit(fdr, "mast02", 3, reassert_state="failed", reassert_at="2026-08-25T06:59:44Z")
    boot = fdr.bootstrap_gaps([unit], _WO_ELEMENTS)
    rendered = "\n".join(fdr._render_bootstrap([unit], boot, None))
    assert "[WARN] last re-assert FAILED" in rendered


def test_result_line_names_only_the_units_needing_a_person(fdr):
    healing = _boot_unit(fdr, "mast01", 2)
    only_routine = {
        "current_version": 3,
        "elements": [{"id": "service-trim", "since": 3, "description": "x", "reassert": "routine"}],
    }
    boot = fdr.bootstrap_gaps([healing], only_routine)
    cmp = fdr.compare([healing], None)
    out = "\n".join(fdr._render_result([healing], cmp, boot, None))
    assert "every bootstrap gap self-heals" in out
    assert "needs a console visit" not in out


# --- NoMachine certificates (#153) -------------------------------------------


def _nm_unit(fdr, host, **facts):
    rec = _unit(fdr, host, nomachine={"version": "1.0", "hash": "h"})
    rec.facts = {"nomachine": dict(facts)}
    return rec


def test_no_unit_reports_a_certificate_renders_no_section(fdr):
    assert fdr._render_nomachine([_unit(fdr, "mast01", git={"version": "1.0", "hash": "h"})]) == []


def test_current_certificates_warn_about_nothing(fdr):
    units = [
        _nm_unit(fdr, "mast01", nomachine_state="ok", nomachine_expiry="Thu Jul 01 2027", nomachine_days_left=310),
        _nm_unit(fdr, "mast02", nomachine_state="ok", nomachine_expiry="Thu Jul 01 2027", nomachine_days_left=310),
    ]
    out = "\n".join(fdr._render_nomachine(units))
    assert "[WARN]" not in out
    assert "All reporting units hold a current certificate." in out


def test_units_sharing_an_expiry_collapse_to_one_line(fdr):
    # Every seat the fleet owns expires the same day; ten lines would say one
    # renewal ten times.
    units = [
        _nm_unit(fdr, f"mast0{n}", nomachine_state="expiring", nomachine_expiry="Thu Jul 01 2027", nomachine_days_left=47)
        for n in range(1, 6)
    ]
    lines = [ln for ln in fdr._render_nomachine(units) if "unit(s) expire" in ln]
    assert len(lines) == 1
    assert lines[0].strip().startswith("5 unit(s) expire")


def test_an_expiring_certificate_warns_with_the_lead_time_reason(fdr):
    out = "\n".join(
        fdr._render_nomachine(
            [_nm_unit(fdr, "mast01", nomachine_state="expiring", nomachine_expiry="x", nomachine_days_left=40)]
        )
    )
    assert "[WARN]" in out
    assert "lead time" in out


def test_an_expired_certificate_says_the_unit_refuses_connections_now(fdr):
    # The operational fact that matters: it does not degrade, it stops.
    out = "\n".join(
        fdr._render_nomachine(
            [_nm_unit(fdr, "mast06", nomachine_state="expired", nomachine_expiry="x", nomachine_days_left=-55)]
        )
    )
    assert "EXPIRED" in out
    assert "mast06" in out


def test_the_most_urgent_group_is_listed_first(fdr):
    units = [
        _nm_unit(fdr, "mast01", nomachine_state="ok", nomachine_expiry="far", nomachine_days_left=310),
        _nm_unit(fdr, "mast02", nomachine_state="expiring", nomachine_expiry="near", nomachine_days_left=20),
    ]
    lines = [ln for ln in fdr._render_nomachine(units) if "unit(s) expire" in ln]
    assert "near" in lines[0]


def test_an_unreadable_expiry_warns_rather_than_passing(fdr):
    out = "\n".join(
        fdr._render_nomachine([_nm_unit(fdr, "mast01", nomachine_state="unknown", nomachine_expiry="(unreported)")])
    )
    assert "[WARN]" in out
    assert "could not be read" in out
