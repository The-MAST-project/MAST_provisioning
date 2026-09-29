"""A unit's OS patch level against its build's baseline (MAST_provisioning#15, stage 2).

``probe-mast08-2026-09-29.json`` is what server/lib/mast-os-patch-probe.ps1 printed
on mast08 that day: 19044.4529, the June 2024 factory image, with a file-rename
reboot pending. ``baseline-19044-2026-09.json`` is the first committed baseline.
Both are copies, so a later baseline landing in server/data/ cannot move these
tests.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest
from pydantic import ValidationError

from prov import os_drift, os_updates
from prov.os_drift import Blocker, DotnetState, Finding, OsPatchState, OsProbe
from prov.os_updates import Baseline

DATA = Path(__file__).parent / "data" / "os_drift"
REPO = Path(__file__).resolve().parents[3]


def probe(**changes) -> OsProbe:
    raw = json.loads((DATA / "probe-mast08-2026-09-29.json").read_text(encoding="utf-8"))
    for key, value in changes.items():
        head, _, tail = key.partition("__")
        if tail:
            raw[head][tail] = value
        else:
            raw[key] = value
    return OsProbe.model_validate(raw)


def baseline(**changes) -> Baseline:
    b = Baseline.model_validate_json((DATA / "baseline-19044-2026-09.json").read_text(encoding="utf-8"))
    return b.model_copy(update=changes)


BUILDS = os_updates.load_os_builds(REPO / os_updates.OS_BUILDS)
SEP = {19044: [baseline()]}


def test_mast08_on_the_factory_image_is_behind_with_a_reboot_pending():
    a = os_drift.assess(probe(), BUILDS, SEP)
    assert a.state is OsPatchState.BEHIND
    assert (a.build, a.ubr, a.target_ubr, a.baseline_id) == (19044, 4529, 7725, "19044-2026-09")
    assert a.lcu_installed == "2024-06-13"
    assert (a.dotnet, a.dotnet_version, a.dotnet_target) == (DotnetState.BEHIND, "4.8.4724.0", "4.8.4806.0")
    # A queued file rename is reported but does not hold servicing back.
    assert a.blockers == ()
    assert a.pending_reboot == ("PendingFileRenameOperations",)
    assert a.findings == ()
    assert a.secure_boot is False


@pytest.mark.parametrize(("ubr", "state"), [(7725, OsPatchState.UP_TO_DATE), (7801, OsPatchState.AHEAD)])
def test_ubr_against_the_target(ubr: int, state: OsPatchState):
    assert os_drift.assess(probe(ubr=ubr), BUILDS, SEP).state is state


def test_the_newest_committed_baseline_is_the_reference():
    older = baseline(baseline_id="19044-2026-08", msrc_release_date="2026-08-11T07:00:00Z", target_ubr=7600)
    a = os_drift.assess(probe(ubr=7600), BUILDS, {19044: [older, baseline()]})
    assert (a.state, a.baseline_id) == (OsPatchState.BEHIND, "19044-2026-09")


def test_a_declared_build_with_nothing_committed_has_no_baseline():
    a = os_drift.assess(probe(pending_reboot=["CBS RebootPending"]), BUILDS, {})
    assert a.state is OsPatchState.NO_BASELINE
    assert a.target_ubr is None
    # Blockers do not depend on having a baseline: they are what the unit IS.
    assert a.blockers == (Blocker.PENDING_REBOOT,)


@pytest.mark.parametrize(
    ("reasons", "blocked"),
    [
        (["PendingFileRenameOperations"], False),
        (["CBS RebootPending"], True),
        (["WindowsUpdate RebootRequired"], True),
        (["PendingFileRenameOperations", "CBS RebootPending"], True),
    ],
)
def test_only_a_servicing_reboot_blocks(reasons: list[str], blocked: bool):
    assert (Blocker.PENDING_REBOOT in os_drift.assess(probe(pending_reboot=reasons), BUILDS, SEP).blockers) is blocked


def test_an_undeclared_build_is_unknown():
    assert os_drift.assess(probe(current_build=26100), BUILDS, SEP).state is OsPatchState.UNKNOWN_BUILD


def test_a_clean_unit_has_no_blockers():
    assert os_drift.assess(probe(pending_reboot=[]), BUILDS, SEP).blockers == ()


@pytest.mark.parametrize(
    ("changes", "blocker"),
    [
        ({"component_store": "repairable"}, Blocker.COMPONENT_STORE),
        ({"component_store": "unknown"}, Blocker.COMPONENT_STORE),
        ({"free_c_bytes": os_drift.MIN_FREE_C_BYTES - 1}, Blocker.LOW_DISK),
    ],
)
def test_blockers(changes: dict, blocker: Blocker):
    assert os_drift.assess(probe(pending_reboot=[], **changes), BUILDS, SEP).blockers == (blocker,)


@pytest.mark.parametrize(
    ("changes", "finding"),
    [
        ({"lockdown__no_auto_update": None}, Finding.LOCKDOWN_OFF),
        ({"lockdown__task_state": None}, Finding.LOCKDOWN_OFF),
        ({"winre": "Disabled"}, Finding.WINRE_DISABLED),
    ],
)
def test_findings(changes: dict, finding: Finding):
    assert os_drift.assess(probe(**changes), BUILDS, SEP).findings == (finding,)


def test_wuauserv_back_on_manual_is_not_a_finding():
    # WaaSMedicSvc flips it back between the lockdown's daily runs; the policy is the lever.
    assert os_drift.assess(probe(lockdown__wuauserv="Manual"), BUILDS, SEP).findings == ()


@pytest.mark.parametrize(
    ("changes", "state"),
    [
        ({"dotnet__mscorlib_version": "4.8.4806.0"}, DotnetState.UP_TO_DATE),
        ({"dotnet__mscorlib_version": "4.8.4900.0"}, DotnetState.AHEAD),
        (
            {"dotnet__release": os_drift.DOTNET_481_MIN_RELEASE, "dotnet__mscorlib_version": "4.8.9300.0"},
            DotnetState.OTHER_LINE,
        ),
        ({"dotnet__mscorlib_version": None}, DotnetState.UNKNOWN),
    ],
)
def test_dotnet_against_the_baseline(changes: dict, state: DotnetState):
    assert os_drift.assess(probe(**changes), BUILDS, SEP).dotnet is state


def test_the_probe_contract_is_closed():
    raw = json.loads((DATA / "probe-mast08-2026-09-29.json").read_text(encoding="utf-8"))
    raw["new_field"] = 1
    with pytest.raises(ValidationError):
        OsProbe.model_validate(raw)


def test_load_baselines_reads_every_build_directory(tmp_path: Path):
    d = tmp_path / os_updates.BASELINES_DIR / "19044"
    d.mkdir(parents=True)
    shutil.copy(DATA / "baseline-19044-2026-09.json", d / "19044-2026-09.json")
    got = os_drift.load_baselines(tmp_path)
    assert [b.baseline_id for b in got[19044]] == ["19044-2026-09"]


def test_the_committed_baselines_all_load():
    for items in os_drift.load_baselines(REPO).values():
        assert all(b.target_ubr > 0 for b in items)
