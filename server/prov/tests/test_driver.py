"""Tests for prov.driver helpers + the fatal-startup path (no units required).

The I/O-heavy per-unit orchestration is validated on the real VM run; here we
cover the pure decision helpers and that a missing registry/creds fails fast
with exit 2 and the right events.
"""
import json

import pytest

from prov import driver as D


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("MAST_SERVER_ROOT", str(tmp_path / "srv"))
    return tmp_path


def test_ps_lit_escapes_single_quotes():
    assert D._ps_lit("a'b") == "'a''b'"
    assert D._ps_lit("plain") == "'plain'"


def test_marker_json_extracts_payload():
    out = "noise line\nPULLRESULT {\"outcome\": \"OK\", \"rc\": 1}\ntrailing"
    res = D._marker_json(out, "PULLRESULT ")
    assert res == {"outcome": "OK", "rc": 1}
    assert D._marker_json("no marker here", "PULLRESULT ") is None


def test_parse_json_or_none_tolerates_bom_and_empty():
    assert D._parse_json_or_none("﻿{\"a\": 1}") == {"a": 1}
    assert D._parse_json_or_none("   ") is None
    assert D._parse_json_or_none("not json") is None


def _cfg(root, **kw):
    repo = root / "repo"
    (repo / "server" / "providers").mkdir(parents=True, exist_ok=True)
    base = dict(repo_top=repo, unit_registry=repo / "reg.json", vault_creds=repo / "creds.json")
    base.update(kw)
    return D.Config(**base)


def test_resolve_modules_precedence(root):
    drv = D.Driver(_cfg(root))
    # provider-dir fallback
    for name in ("ascom", "git", "mast"):
        (drv.cfg.repo_top / "server" / "providers" / name).mkdir(parents=True)
        (drv.cfg.repo_top / "server" / "providers" / name / "module.json").write_text("{}")
    assert drv._resolve_modules({"hostname": "m"}) == ["ascom", "git", "mast"]
    # A registry entry says what this unit's full set IS, so it wins over discovery.
    assert drv._resolve_modules({"hostname": "m", "modules": ["git"]}) == ["git"]


def test_resolve_modules_ignores_the_cli_subset(root):
    """--modules must not reach the build. This is #63.

    The build-manifest's module list is what the unit's fully_provisioned is
    judged against, so a subset build made the flag read true off a partial set
    and published the aggregate payload_hash with it -- after which a repeated
    identical subset run satisfied both halves of the already_current skip.
    """
    drv = D.Driver(_cfg(root))
    for name in ("ascom", "git", "mast"):
        (drv.cfg.repo_top / "server" / "providers" / name).mkdir(parents=True)
        (drv.cfg.repo_top / "server" / "providers" / name / "module.json").write_text("{}")
    drv.cfg.modules = ["git"]
    assert drv._resolve_modules({"hostname": "m"}) == ["ascom", "git", "mast"]
    # ...and it does not override a registry-declared full set either.
    assert drv._resolve_modules({"hostname": "m", "modules": ["ascom"]}) == ["ascom"]


def _write_module(root, name, order, always=False):
    d = root / "server" / "providers" / name
    d.mkdir(parents=True, exist_ok=True)
    body = {"name": name, "order": order}
    if always:
        body["always"] = True
    (d / "module.json").write_text(json.dumps(body), encoding="utf-8")


def _fleet(repo):
    _write_module(repo, "proxy", 100, always=True)
    _write_module(repo, "config-bootstrap", 150)
    _write_module(repo, "mast", 2200)
    _write_module(repo, "mast-services-finalize", 9500, always=True)
    _write_module(repo, "reboot", 9999, always=True)
    return ["proxy", "config-bootstrap", "mast", "mast-services-finalize", "reboot"]


def test_filtered_targets_still_get_the_always_modules(root):
    """A --modules run must close out like a drift-targeted one does.

    DriftReport.targets folds the ``always: true`` modules into any non-empty
    target set; the CLI path bypassed that, so a targeted run skipped proxy
    (posture), mast-services-finalize (leaves the unit quiescent) and reboot
    (pending-reboot detection the orchestrator acts on). Observed 2026-08-09:
    three runs with --modules left mast-unit Running on three production units
    and reported exit_code=0 (#60).
    """
    drv = D.Driver(_cfg(root))
    full = _fleet(drv.cfg.repo_top)
    drv.cfg.modules = ["config-bootstrap,mast"]

    got = drv._filter_targets(["config-bootstrap", "mast"], full)

    assert got == ["proxy", "config-bootstrap", "mast", "mast-services-finalize", "reboot"], got


def test_filter_intersects_the_drift_targets_with_the_named_set(root):
    # Named but not drifted -> excluded. Drifted but not named -> excluded.
    drv = D.Driver(_cfg(root))
    full = _fleet(drv.cfg.repo_top)
    drv.cfg.modules = ["config-bootstrap,mast"]

    got = drv._filter_targets(["mast"], full)

    assert got == ["proxy", "mast", "mast-services-finalize", "reboot"], got


def test_filter_treats_empty_targets_as_the_full_set(root):
    # target_modules == [] means "run everything" upstream, so the intersection
    # is just the named set -- not everything.
    drv = D.Driver(_cfg(root))
    full = _fleet(drv.cfg.repo_top)
    drv.cfg.modules = ["mast"]

    got = drv._filter_targets([], full)

    assert got == ["proxy", "mast", "mast-services-finalize", "reboot"], got


def test_filter_returns_empty_when_no_named_module_needs_work(root):
    """Empty means nothing to do -- NOT "run the always-modules alone".

    reboot is an always-module, so synthesising a run out of an empty
    intersection would reboot a unit for a run that had no work in it.
    _process_unit logs MODULE_TARGET_EMPTY and returns.
    """
    drv = D.Driver(_cfg(root))
    full = _fleet(drv.cfg.repo_top)
    drv.cfg.modules = ["config-bootstrap"]

    assert drv._filter_targets(["mast"], full) == []


def test_filter_does_not_duplicate_a_named_always_module(root):
    drv = D.Driver(_cfg(root))
    full = _fleet(drv.cfg.repo_top)
    drv.cfg.modules = ["mast,proxy"]

    got = drv._filter_targets(["mast", "proxy"], full)

    assert got.count("proxy") == 1, got
    assert got == ["proxy", "mast", "mast-services-finalize", "reboot"], got


def test_filter_splits_comma_lists(root):
    drv = D.Driver(_cfg(root))
    full = _fleet(drv.cfg.repo_top)
    drv.cfg.modules = ["config-bootstrap", "mast,proxy"]
    got = drv._filter_targets([], full)
    assert got == ["proxy", "config-bootstrap", "mast", "mast-services-finalize", "reboot"], got


def test_run_fatal_on_missing_registry(root):
    cfg = _cfg(root)  # reg.json / creds.json do not exist
    drv = D.Driver(cfg)
    assert drv.run() == D.EXIT_FATAL
    log = drv.log.run_log_path.read_text()
    assert "RUN_START" in log
    assert "FATAL" in log and "unit_registry_missing" in log


def test_run_fatal_on_missing_creds(root):
    cfg = _cfg(root)
    cfg.unit_registry.parent.mkdir(parents=True, exist_ok=True)
    cfg.unit_registry.write_text(json.dumps([{"hostname": "mast04"}]))
    drv = D.Driver(cfg)
    assert drv.run() == D.EXIT_FATAL
    assert "vault_creds_missing" in drv.log.run_log_path.read_text()


def test_cli_config_builder_parses_args():
    import check_and_provision as cli
    cfg = cli._build_config(["--only-hosts", "mast04,mast03", "--dry-run",
                             "--proxy-mode", "direct", "--retain-runs", "10"])
    assert cfg.only_hosts == ["mast04", "mast03"]
    assert cfg.dry_run is True
    assert cfg.proxy_mode == "direct"
    assert cfg.retain_runs == 10
    assert cfg.unit_registry.name == "unit-registry.json"
