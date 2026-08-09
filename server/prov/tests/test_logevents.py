"""Tests for prov.logevents -- server-root resolution, no-BOM atomic writes,
and the RunLog event/activity emitters."""

import json

import pytest

from prov import logevents as L


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("MAST_SERVER_ROOT", str(tmp_path))
    return tmp_path


def test_server_root_honors_env(root):
    assert L.server_root() == root


def test_prov_session_dir_is_under_root(root):
    d = L.prov_session_dir("run-20260712-120000")
    assert d == root / "logs" / "prov" / "sessions" / "run-20260712-120000"
    assert d.is_dir()


def test_now_utc_format():
    s = L.now_utc()
    assert s.endswith("Z") and "T" in s and len(s) == 20


def test_write_status_atomic_is_plain_utf8_no_bom(root):
    p = root / "status" / "last-run.json"
    p.parent.mkdir(parents=True)
    L.write_status_atomic(p, {"run_id": "run-x", "exit_code": 0})
    raw = p.read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf")  # no BOM
    assert json.loads(raw.decode("utf-8"))["run_id"] == "run-x"
    assert not (p.parent / "last-run.json.tmp").exists()  # tmp cleaned by rename


def test_fmt_event_shape():
    line = L._fmt_event("UNIT_OK", {"unit": "mast04", "payload_hash": "abc"})
    assert "  UNIT_OK  unit=mast04  payload_hash=abc" in line
    assert line.startswith("[")


def test_runlog_event_and_activity(root):
    rl = L.RunLog("run-20260712-130000", echo=False)
    rl.event("RUN_START", run_id=rl.run_id, trigger="manual")
    rl.activity("mast04", "OK", reason="updated", duration_s=42,
                payload_hash="h1", git_sha="s1")
    rl.activity("mast03", "FAIL", reason="smoke:x")

    log_text = rl.run_log_path.read_text()
    assert "RUN_START" in log_text and "trigger=manual" in log_text

    rows = rl.activity_csv.read_text().splitlines()
    assert rows[0].startswith("timestamp_utc,run_id,unit,outcome")
    assert any(",mast04,OK,updated,42,h1,s1" in r for r in rows)
    assert rl.unit_outcomes == {"mast04": "OK", "mast03": "FAIL"}


def test_runlog_reuses_existing_activity_csv_header_once(root):
    L.RunLog("run-a", echo=False).activity("mast00", "OK")
    L.RunLog("run-b", echo=False).activity("mast01", "OK")
    header_lines = [r for r in L.prov_activity_csv().read_text().splitlines()
                    if r.startswith("timestamp_utc")]
    assert len(header_lines) == 1  # header written once, not per RunLog
