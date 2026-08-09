"""Tests for prov.driver.run_loop (item 8, the -Loop service mode)."""

import pytest

from prov import driver as D


@pytest.fixture
def cfg(tmp_path, monkeypatch):
    monkeypatch.setenv("MAST_SERVER_ROOT", str(tmp_path / "srv"))
    repo = tmp_path / "repo"
    (repo / "server" / "providers").mkdir(parents=True)
    return D.Config(repo_top=repo, unit_registry=repo / "reg.json", vault_creds=repo / "creds.json")


def test_run_loop_runs_max_cycles(cfg, monkeypatch):
    calls = {"n": 0}

    class FakeDriver:
        def __init__(self, _cfg):
            pass

        def run(self):
            calls["n"] += 1
            return 0

    monkeypatch.setattr(D, "Driver", FakeDriver)
    slept = []
    D.run_loop(cfg, 5, max_cycles=3, sleep_fn=slept.append)
    assert calls["n"] == 3
    # sleeps only BETWEEN cycles, not after the last.
    assert slept == [5, 5]


def test_run_loop_stops_on_stop_callable(cfg, monkeypatch):
    calls = {"n": 0}

    class FakeDriver:
        def __init__(self, _cfg):
            pass

        def run(self):
            calls["n"] += 1
            return 0

    monkeypatch.setattr(D, "Driver", FakeDriver)
    # stop() returns True after the first cycle's post-check.
    state = {"c": 0}

    def stop():
        state["c"] += 1
        return state["c"] > 2  # allow the first cycle, then stop

    D.run_loop(cfg, 1, sleep_fn=lambda _: None, stop=stop)
    assert calls["n"] == 1


def test_run_loop_survives_a_cycle_exception(cfg, monkeypatch):
    calls = {"n": 0}

    class FakeDriver:
        def __init__(self, _cfg):
            pass

        def run(self):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("boom")  # first cycle blows up
            return 0

    monkeypatch.setattr(D, "Driver", FakeDriver)
    # Must not propagate; must continue to cycle 2.
    D.run_loop(cfg, 0, max_cycles=2, sleep_fn=lambda _: None)
    assert calls["n"] == 2
