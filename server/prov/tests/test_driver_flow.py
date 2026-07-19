"""In-process flow tests for Driver._process_unit via a fake unit session.

FakeSession subclasses transport.SshSession so the real transport plumbing
(transport.run_ps, upload_file, _dispose_winrm_session) routes to it, but it
answers scripted per-phase output instead of touching paramiko. This exercises
the real orchestration -- phase order, marker parsing, transfer/execute/smoke
verdicts, activity outcomes, exit codes -- with no live unit, which is the layer
the earlier suite left to the VM run.
"""
from __future__ import annotations

import json

import pytest

from prov import driver as D
from prov import transport as T

DEFAULT_PULL = 'PULLRESULT {"outcome": "OK", "rc": 1}'


class FakeSession(T.SshSession):
    """A unit session that returns canned stdout per phase (no paramiko)."""

    def __init__(self, responder) -> None:  # noqa: D107 -- bypass SshSession.connect
        self._responder = responder
        self.scripts: list[str] = []

    def run_ps(self, script: str) -> T._SshResponse:
        self.scripts.append(script)
        rc, out = self._responder(script)
        return T._SshResponse(rc, out.encode("utf-8"), b"")

    def put_file(self, remote_path: str, data: bytes) -> None:  # SFTP upload no-op
        pass

    def close(self) -> None:
        pass


def make_responder(
    *,
    pull: str = DEFAULT_PULL,
    register: str = "DETACHED_REGISTERED",
    execute: str = '{"status": "done", "exit_code": 0}',
    smoke: str = 'SMOKE {"git": "ok"}',
    proxy: str = "PROXY {}",
    inventory: str = "",
):
    """Build a responder(script) -> (rc, stdout) keyed on recognizable phase
    scripts. Every phase has a sane default; a test overrides one to steer a
    branch. Non-matching scripts (json writes, reads, archive-check) return ''."""

    def responder(script: str) -> tuple[int, str]:
        s = script
        if "Get-NetAdapter" in s:
            return (0, inventory)
        if "-Register" in s:
            return (0, register)
        if "execute-result.json" in s:
            return (0, execute)
        if "schtasks /delete" in s:
            return (0, "")
        if "mast-pull-staging.ps1" in s:
            return (0, pull)
        if "-smoke.txt" in s:
            return (0, smoke)
        if "netsh winhttp" in s:
            return (0, proxy)
        return (0, "")

    return responder


UNIT = {
    "hostname": "unit1",
    "site": "ns",
    "modules": ["git"],
    "maintenance_window": {"start_hour": 0, "end_hour": 24},
    "timezone": "Asia/Jerusalem",
}


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("MAST_SERVER_ROOT", str(tmp_path / "srv"))
    return tmp_path


def _make_driver(root, monkeypatch, responder, unit=UNIT):
    repo = root / "repo"
    (repo / "server" / "providers").mkdir(parents=True, exist_ok=True)
    # The driver reads these client scripts off disk before uploading them; the
    # upload itself is a no-op here, so the content is irrelevant.
    (repo / "client").mkdir(parents=True, exist_ok=True)
    (repo / "client" / "mast-pull-staging.ps1").write_text("# stub pull script\n")
    (repo / "client" / "mast-run-detached.ps1").write_text("# stub detached runner\n")
    reg = repo / "reg.json"
    reg.write_text(json.dumps([unit]))
    creds = repo / "creds.json"
    creds.write_text(json.dumps({
        "unit": {"user": ".\\mast", "pass": "x"},
        "smb": {"user": "prov", "pass": "y"},
    }))
    cfg = D.Config(repo_top=repo, unit_registry=reg, vault_creds=creds)
    drv = D.Driver(cfg)
    sess = FakeSession(responder)

    monkeypatch.setattr(T, "connect_unit", lambda host, cred, **kw: sess)
    monkeypatch.setattr(D.Driver, "_tcp_open",
                        staticmethod(lambda host, port, timeout=5.0: True))

    def fake_build(self, unit, host, modules, dur):  # skip subprocess/PS build
        self._staging_dir = repo / "staging"
        self.log.event("BUILD_OK", unit=host, payload_hash="hash123", git_sha="sha")
        return "hash123", "sha"

    monkeypatch.setattr(D.Driver, "_build", fake_build)
    monkeypatch.setattr(D, "staging_payload_size",
                        lambda d: type("S", (), {"files": 3, "bytes": 1000})())
    return drv, sess


def test_process_unit_happy_path(root, monkeypatch):
    drv, sess = _make_driver(root, monkeypatch, make_responder())
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    for ev in ("BUILD_OK", "TRANSFER_OK", "EXECUTE_OK", "SMOKE_START", "UNIT_OK"):
        assert ev in log, f"missing {ev}\n{log}"
    assert drv.log.unit_outcomes.get("unit1") == "OK"


# --- finding #1: transfer must fail CLOSED on any non-OK / unparseable pull ---
@pytest.mark.parametrize("pull,reason", [
    ("random text with no marker at all", "unrecognized_pull_result"),
    ("", "unrecognized_pull_result"),
    ('PULLRESULT {"outcome": "DISK_INSUFFICIENT", "rc": -2}', "disk_insufficient"),
    ('PULLRESULT {"outcome": "NET_USE_HUNG", "rc": -1}', "net_use_hung"),
])
def test_transfer_fails_closed_on_bad_pull(root, monkeypatch, pull, reason):
    drv, sess = _make_driver(root, monkeypatch, make_responder(pull=pull))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "TRANSFER_FAIL" in log, log
    assert reason in log, f"expected reason {reason}\n{log}"
    # must NOT proceed to execute against an unverified staging dir
    assert "EXECUTE_START" not in log, f"executed after failed transfer\n{log}"
    assert drv.log.unit_outcomes.get("unit1") == "TRANSFER_FAIL"


@pytest.mark.parametrize("pull", [
    'PULLRESULT {"outcome": "NET_USE_FAIL", "rc": 2}',
    'PULLRESULT {"outcome": "ROBOCOPY_ERROR", "rc": 8}',
])
def test_transfer_known_failure_outcomes_still_fail(root, monkeypatch, pull):
    drv, sess = _make_driver(root, monkeypatch, make_responder(pull=pull))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "TRANSFER_FAIL" in log and "EXECUTE_START" not in log, log


def test_transfer_ok_rc_zero_is_success(root, monkeypatch):
    # rc 0 (no changes) and rc 2-7 (robocopy info) are still OK outcomes.
    drv, sess = _make_driver(root, monkeypatch,
                             make_responder(pull='PULLRESULT {"outcome": "OK", "rc": 0}'))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    assert "TRANSFER_OK" in log and "no_changes" in log, log


# --- other failure branches (broaden phase-flow coverage) --------------------
def test_execute_nonzero_exit_fails(root, monkeypatch):
    drv, sess = _make_driver(root, monkeypatch,
                             make_responder(execute='{"status": "done", "exit_code": 3}'))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "EXECUTE_FAIL" in log and "exit_code=3" in log, log
    assert drv.log.unit_outcomes.get("unit1") == "EXECUTE_FAIL"


def test_execute_register_failure_fails(root, monkeypatch):
    drv, sess = _make_driver(root, monkeypatch,
                             make_responder(register="something-not-the-marker"))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "detached_register_failed" in log, log


def test_smoke_missing_module_fails(root, monkeypatch):
    drv, sess = _make_driver(root, monkeypatch, make_responder(smoke="SMOKE {}"))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "smoke_failures" in log and "UNIT_FAIL" in log, log


def test_unreachable_unit_fails_without_session(root, monkeypatch):
    drv, sess = _make_driver(root, monkeypatch, make_responder())
    monkeypatch.setattr(D.Driver, "_tcp_open",
                        staticmethod(lambda host, port, timeout=5.0: False))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "UNIT_UNREACHABLE" in log, log
