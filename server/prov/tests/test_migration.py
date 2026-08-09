"""Tests for the stage-6 migration preconditions (#31).

These guard a destructive operation on a production unit, so the cases that
matter most are the refusals.
"""

from __future__ import annotations

from prov.migration import DEFAULT_TOP, MigrationState, UnitProbe, plan_migration

GOOD_APP = rf"{DEFAULT_TOP}\.venv\Scripts\python.exe"


def probe(**kw) -> UnitProbe:
    base = dict(
        host="mast01",
        legacy_present=True,
        legacy_dirs=("MAST_unit.2024-12-12", "MAST_common"),
        legacy_file_count=26,
        venv_python=True,
        mast_pth=True,
        common_init=True,
        present_dirs=("common", "unit", "claude"),
        service_registered=True,
        service_app=GOOD_APP,
        service_status="Stopped",
        expected_app=GOOD_APP,
    )
    base.update(kw)
    return UnitProbe(**base)


def test_a_fully_migrated_new_layout_is_ready():
    assert plan_migration(probe()).state is MigrationState.READY


def test_absent_legacy_tree_is_already_migrated():
    p = plan_migration(probe(legacy_present=False, legacy_dirs=(), legacy_file_count=0))
    assert p.state is MigrationState.ALREADY_MIGRATED
    assert not p.may_proceed


def test_missing_venv_blocks():
    """The old tree must never go while the new one cannot run anything."""
    p = plan_migration(probe(venv_python=False))
    assert p.state is MigrationState.BLOCKED
    assert any("venv interpreter" in b for b in p.blockers)


def test_missing_mast_pth_blocks():
    p = plan_migration(probe(mast_pth=False))
    assert p.state is MigrationState.BLOCKED
    assert any("mast.pth" in b for b in p.blockers)


def test_missing_common_init_blocks():
    """Landing on the abandoned 2-commit 'main' stub yields no __init__.py, and
    every 'from common.X import' on the unit then fails at service start."""
    p = plan_migration(probe(common_init=False))
    assert p.state is MigrationState.BLOCKED


def test_a_missing_clone_blocks_and_is_named():
    p = plan_migration(probe(present_dirs=("common", "unit")))
    assert p.state is MigrationState.BLOCKED
    assert any("claude" in b for b in p.blockers)


def test_service_still_on_the_old_interpreter_blocks():
    """The dangerous case: new tree looks fine, but the service runs the OLD
    venv, so deleting the old tree kills the running unit."""
    old = r"C:\MAST\repos\MAST_unit.2024-12-12\.venv\Scripts\python.exe"
    p = plan_migration(probe(service_app=old))
    assert p.state is MigrationState.BLOCKED
    assert any("still runs" in b for b in p.blockers)


def test_interpreter_comparison_is_case_insensitive():
    p = plan_migration(probe(service_app=GOOD_APP.upper()))
    assert p.state is MigrationState.READY


def test_an_unregistered_service_is_a_note_not_a_blocker():
    p = plan_migration(probe(service_registered=False, service_app="", service_status=""))
    assert p.state is MigrationState.READY
    assert any("not registered" in n for n in p.notes)


def test_unreadable_interpreter_is_a_note_not_a_blocker():
    p = plan_migration(probe(service_app=""))
    assert p.state is MigrationState.READY
    assert any("could not read" in n for n in p.notes)


def test_non_standard_legacy_entries_are_surfaced():
    """mast02 carries mast-claude-config and PlaneWave_PlateSolve3_Catalog under
    the legacy root. They go with the tree; the operator must see that first."""
    p = plan_migration(
        probe(legacy_dirs=("MAST_unit.2024-12-12", "MAST_common",
                           "mast-claude-config", "PlaneWave_PlateSolve3_Catalog"))
    )
    assert p.state is MigrationState.READY
    surfaced = " ".join(p.notes)
    assert "NON-STANDARD" in surfaced
    assert "PlaneWave_PlateSolve3_Catalog" in surfaced
    assert "mast-claude-config" in surfaced


def test_standard_clones_alone_produce_no_non_standard_warning():
    """The sidecar logs are always present and must not trip the warning -- there
    are ~26 of them and naming them buries the entries that matter."""
    p = plan_migration(probe())
    assert "NON-STANDARD" not in " ".join(p.notes)
    assert "26 loose file" in " ".join(p.notes)


def test_multiple_blockers_are_all_reported():
    p = plan_migration(probe(venv_python=False, mast_pth=False, common_init=False))
    assert len(p.blockers) >= 3
