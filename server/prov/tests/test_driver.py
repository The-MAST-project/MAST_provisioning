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
    # unit registry entry overrides discovery
    assert drv._resolve_modules({"hostname": "m", "modules": ["git"]}) == ["git"]
    # CLI --modules overrides everything (and splits comma lists)
    drv.cfg.modules = ["git,mast"]
    assert drv._resolve_modules({"hostname": "m", "modules": ["ascom"]}) == ["git", "mast"]


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
