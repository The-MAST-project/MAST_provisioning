"""Tests for prov.retention -- the pure keep-newest-N selector and the fs runner.

Mirrors server/tests/mast-log-archive.Tests.ps1 (the PowerShell original).
"""

import pytest

from prov.retention import run_id_timestamp, run_retention, select_prunable_runs


def test_run_id_timestamp_extracts_conforming():
    assert run_id_timestamp("run-20260712-091200") == "20260712-091200"


@pytest.mark.parametrize("bad", ["scratch", "run-2026", "run-20260712-0912", "run-x"])
def test_run_id_timestamp_rejects_nonconforming(bad):
    assert run_id_timestamp(bad) is None


def test_select_returns_nothing_at_or_under_retain():
    ids = ["run-20260712-010000", "run-20260712-020000", "run-20260712-030000"]
    assert select_prunable_runs(ids, 3) == []
    assert select_prunable_runs(ids, 5) == []


def test_select_keeps_newest_n_prunes_rest():
    ids = [
        "run-20260710-090000", "run-20260712-090000", "run-20260711-090000",
        "run-20260709-090000", "run-20260708-090000",
    ]
    prune = select_prunable_runs(ids, 2)
    assert set(prune) == {
        "run-20260710-090000", "run-20260709-090000", "run-20260708-090000",
    }
    assert "run-20260712-090000" not in prune
    assert "run-20260711-090000" not in prune


def test_select_never_prunes_nonconforming():
    ids = ["run-20260712-090000", "run-20260711-090000", "scratch", "manual-copy"]
    assert select_prunable_runs(ids, 1) == ["run-20260711-090000"]


def test_select_keeps_current_at_retain_1():
    ids = ["run-20260712-235959", "run-20260712-000000"]
    assert select_prunable_runs(ids, 1) == ["run-20260712-000000"]


def test_select_raises_below_1():
    with pytest.raises(ValueError):
        select_prunable_runs(["run-20260712-090000"], 0)


def test_run_retention_prunes_on_real_fs(tmp_path):
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    ids = [f"run-2026071{d}-090000" for d in range(2, 7)]  # 12..16 -> 5 dirs? no, 2..6
    for name in ids:
        d = sessions / name
        d.mkdir()
        (d / "run.log").write_text("x")
    (sessions / "scratch").mkdir()  # non-conforming, must survive

    warnings: list[str] = []
    removed = run_retention(sessions, retain=2, logger=warnings.append)

    remaining = sorted(p.name for p in sessions.iterdir())
    # Newest two conforming kept + the non-conforming dir.
    assert remaining == ["run-20260715-090000", "run-20260716-090000", "scratch"]
    assert set(removed) == {
        "run-20260712-090000", "run-20260713-090000", "run-20260714-090000",
    }
    assert warnings == []


def test_run_retention_missing_root_is_noop(tmp_path):
    assert run_retention(tmp_path / "nope", retain=5) == []
