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
import re
from pathlib import Path

import pytest

from prov import driver as D
from prov import transport as T

DEFAULT_PULL = 'PULLRESULT {"outcome": "OK", "rc": 1}'


class FakeSession(T.SshSession):
    """A unit session that returns canned stdout per phase (no paramiko)."""

    def __init__(self, responder) -> None:
        self._responder = responder
        self.scripts: list[str] = []

    def run_ps(self, script: str, timeout_s: float | None = None) -> T._SshResponse:
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
    lease: str = "",
    smoke: str = 'SMOKE {"git": "ok"}',
    proxy: str = "PROXY {}",
    inventory: str = "",
    smbreach: str = "SMBREACH ok",
):
    """Build a responder(script) -> (rc, stdout) keyed on recognizable phase
    scripts. Every phase has a sane default; a test overrides one to steer a
    branch. Non-matching scripts (json writes, reads, archive-check) return ''."""

    def responder(script: str) -> tuple[int, str]:
        s = script
        if "Get-NetAdapter" in s:
            return (0, inventory)
        # Pre-build reachability probe: can the unit open SMB to the staging
        # address (#70). Defaults to reachable so it does not gate other tests.
        if "SMBREACH" in s:
            return (0, smbreach)
        if "-Register" in s:
            return (0, register)
        if "execute-result.json" in s:
            return (0, execute)
        if "execute-lease.json" in s:
            return (0, lease)
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
    creds.write_text(
        json.dumps(
            {
                "unit": {"user": ".\\mast", "pass": "x"},
                "smb": {"user": "prov", "pass": "y"},
                "shared": {"user": "mast", "pass": "z"},
            }
        )
    )
    cfg = D.Config(repo_top=repo, unit_registry=reg, vault_creds=creds)
    drv = D.Driver(cfg)
    sess = FakeSession(responder)

    monkeypatch.setattr(T, "connect_unit", lambda host, cred, **kw: sess)
    monkeypatch.setattr(D.Driver, "_tcp_open", staticmethod(lambda host, port, timeout=5.0: True))

    def fake_build(self, unit, host, modules, dur):  # skip subprocess/PS build
        self._staging_dir = repo / "staging"
        self.log.event("BUILD_OK", unit=host, payload_hash="hash123", git_sha="sha")
        return "hash123", "sha", {}

    monkeypatch.setattr(D.Driver, "_build", fake_build)
    monkeypatch.setattr(D, "staging_payload_size", lambda d: type("S", (), {"files": 3, "bytes": 1000})())
    return drv, sess


def test_process_unit_happy_path(root, monkeypatch):
    drv, _sess = _make_driver(root, monkeypatch, make_responder())
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    for ev in ("BUILD_OK", "TRANSFER_OK", "EXECUTE_OK", "SMOKE_START", "UNIT_OK"):
        assert ev in log, f"missing {ev}\n{log}"
    assert drv.log.unit_outcomes.get("unit1") == "OK"


# --- finding #1: transfer must fail CLOSED on any non-OK / unparseable pull ---
@pytest.mark.parametrize(
    "pull,reason",
    [
        ("random text with no marker at all", "unrecognized_pull_result"),
        ("", "unrecognized_pull_result"),
        ('PULLRESULT {"outcome": "DISK_INSUFFICIENT", "rc": -2}', "disk_insufficient"),
        ('PULLRESULT {"outcome": "NET_USE_HUNG", "rc": -1}', "net_use_hung"),
    ],
)
def test_transfer_fails_closed_on_bad_pull(root, monkeypatch, pull, reason):
    drv, _sess = _make_driver(root, monkeypatch, make_responder(pull=pull))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "TRANSFER_FAIL" in log, log
    assert reason in log, f"expected reason {reason}\n{log}"
    # must NOT proceed to execute against an unverified staging dir
    assert "EXECUTE_START" not in log, f"executed after failed transfer\n{log}"
    assert drv.log.unit_outcomes.get("unit1") == "TRANSFER_FAIL"


@pytest.mark.parametrize(
    "pull",
    [
        'PULLRESULT {"outcome": "NET_USE_FAIL", "rc": 2}',
        'PULLRESULT {"outcome": "ROBOCOPY_ERROR", "rc": 8}',
    ],
)
def test_transfer_known_failure_outcomes_still_fail(root, monkeypatch, pull):
    drv, _sess = _make_driver(root, monkeypatch, make_responder(pull=pull))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "TRANSFER_FAIL" in log and "EXECUTE_START" not in log, log


def test_transfer_ok_rc_zero_is_success(root, monkeypatch):
    # rc 0 (no changes) and rc 2-7 (robocopy info) are still OK outcomes.
    drv, _sess = _make_driver(root, monkeypatch, make_responder(pull='PULLRESULT {"outcome": "OK", "rc": 0}'))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    assert "TRANSFER_OK" in log and "no_changes" in log, log


# --- other failure branches (broaden phase-flow coverage) --------------------
def test_execute_nonzero_exit_fails(root, monkeypatch):
    drv, _sess = _make_driver(root, monkeypatch, make_responder(execute='{"status": "done", "exit_code": 3}'))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "EXECUTE_FAIL" in log and "exit_code=3" in log, log
    assert drv.log.unit_outcomes.get("unit1") == "EXECUTE_FAIL"


def test_execute_register_failure_fails(root, monkeypatch):
    drv, _sess = _make_driver(root, monkeypatch, make_responder(register="something-not-the-marker"))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "detached_register_failed" in log, log


def test_smoke_missing_module_fails(root, monkeypatch):
    drv, _sess = _make_driver(root, monkeypatch, make_responder(smoke="SMOKE {}"))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "smoke_failures" in log and "UNIT_FAIL" in log, log


def test_unreachable_unit_fails_without_session(root, monkeypatch):
    drv, _sess = _make_driver(root, monkeypatch, make_responder())
    monkeypatch.setattr(D.Driver, "_tcp_open", staticmethod(lambda host, port, timeout=5.0: False))
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_UNIT_FAIL, log
    assert "UNIT_UNREACHABLE" in log, log


# --- per-module targeted update (issue #22 stage 3) --------------------------


def _drift_driver(root, monkeypatch, installed: dict | None, build: dict, validation: dict | None = None):
    """Driver whose unit reports ``installed`` (+ optional tier-2 ``validation``)
    and whose build yields ``build``.

    The manifest reads and the build are stubbed, so the test exercises the real
    phase-5 comparison and the real cfg written for the detached runner. Smoke
    answers OK for every module the build declares, so the run reaches its
    natural end and the exit code is meaningful -- otherwise phase 9 fails the
    unit on a missing marker and masks everything downstream.
    """
    smoke = "SMOKE " + json.dumps({m: "ok" for m in build.get("modules", [])})
    responder = make_responder(smoke=smoke)

    def with_manifests(script: str) -> tuple[int, str]:
        if "installed-manifest.json" in script:
            return (0, json.dumps(installed) if installed is not None else "")
        if "validation.json" in script:
            return (0, json.dumps(validation) if validation is not None else "")
        return responder(script)

    drv, sess = _drift_make(root, monkeypatch, with_manifests, build)
    return drv, sess


def _drift_make(root, monkeypatch, responder, build: dict):
    drv, sess = _make_driver(root, monkeypatch, responder, unit={**UNIT, "modules": list(build.get("modules", []))})

    def fake_build(self, unit, host, modules, dur):
        self._staging_dir = root / "repo" / "staging"
        self.log.event("BUILD_OK", unit=host, payload_hash=build["payload_hash"], git_sha="sha")
        return build["payload_hash"], "sha", build

    monkeypatch.setattr(D.Driver, "_build", fake_build)
    return drv, sess


def _detached_cfg(sess) -> dict:
    """The detached-run.json the driver wrote, parsed out of the fake session."""
    for script in reversed(sess.scripts):
        if "detached-run.json" in script and "{" in script:
            start = script.index("{")
            end = script.rindex("}") + 1
            return json.loads(script[start:end].replace("''", "'"))
    raise AssertionError("no detached-run.json write seen")


BUILD_TWO = {
    "payload_hash": "agg-new",
    "modules": ["git", "python"],
    "module_state": {"git": {"version": "1", "hash": "h-git"}, "python": {"version": "1", "hash": "h-py-NEW"}},
}


def test_only_the_drifted_module_is_sent_to_execute(root, monkeypatch):
    """One module changed -> execute gets -Modules python, not the full payload."""
    installed = {
        "payload_hash": "agg-old",
        "modules": {
            "git": {"version": "1", "hash": "h-git", "provide": "pass", "verify": "pass"},
            "python": {"version": "1", "hash": "h-py-OLD", "provide": "pass", "verify": "pass"},
        },
    }
    drv, sess = _drift_driver(root, monkeypatch, installed, BUILD_TWO)
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    assert "MODULE_DRIFT" in log, log
    assert "targets=python" in log, log
    assert _detached_cfg(sess)["modules"] == "python"


def test_legacy_unit_runs_the_full_set(root, monkeypatch):
    """A pre-modules manifest is state-unknown: every module is a target."""
    legacy = {"payload_hash": "agg-old", "git_sha": "abc"}
    drv, sess = _drift_driver(root, monkeypatch, legacy, BUILD_TWO)
    code = drv.run()
    assert code == D.EXIT_OK, drv.log.run_log_path.read_text()
    assert _detached_cfg(sess)["modules"] == "git,python"


def test_aggregate_drift_with_no_module_drift_runs_the_full_set(root, monkeypatch):
    """The payload changed outside the per-module boundary (a vendored asset).

    Not nothing -- fall through to a full run rather than skipping, since the
    aggregate hash is the broader check.
    """
    installed = {
        "payload_hash": "agg-old",
        "modules": {
            "git": {"version": "1", "hash": "h-git", "provide": "pass", "verify": "pass"},
            "python": {"version": "1", "hash": "h-py-NEW", "provide": "pass", "verify": "pass"},
        },
    }
    drv, sess = _drift_driver(root, monkeypatch, installed, BUILD_TWO)
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    assert "MODULE_DRIFT_NONE" in log, log
    assert _detached_cfg(sess)["modules"] == ""


def test_force_bypasses_the_per_module_compare(root, monkeypatch):
    """--force means "run everything", so no targeting is applied."""
    installed = {
        "payload_hash": "agg-old",
        "modules": {
            "git": {"version": "1", "hash": "h-git", "provide": "pass", "verify": "pass"},
            "python": {"version": "1", "hash": "h-py-OLD", "provide": "pass", "verify": "pass"},
        },
    }
    drv, sess = _drift_driver(root, monkeypatch, installed, BUILD_TWO)
    drv.cfg.force = True
    code = drv.run()
    assert code == D.EXIT_OK, drv.log.run_log_path.read_text()
    assert _detached_cfg(sess)["modules"] == ""


CURRENT_INSTALLED = {
    "payload_hash": "agg-new",
    "fully_provisioned": True,
    "modules": {
        "git": {
            "version": "1",
            "hash": "h-git",
            "provide": "pass",
            "verify": "pass",
            "installed_at": "2026-08-01T00:00:00Z",
        },
        "python": {
            "version": "1",
            "hash": "h-py-NEW",
            "provide": "pass",
            "verify": "pass",
            "installed_at": "2026-08-01T00:00:00Z",
        },
    },
}


def test_a_fully_current_unit_is_skipped(root, monkeypatch):
    drv, _sess = _drift_driver(root, monkeypatch, CURRENT_INSTALLED, BUILD_TWO)
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    assert "already_current" in log, log


def test_tier2_failure_breaks_the_already_current_skip(root, monkeypatch):
    """Runtime drift on an otherwise-current unit must NOT be skipped.

    The unit is fully provisioned, so it publishes an aggregate payload_hash that
    matches the build -- which is exactly the state a needs-repair arises in (the
    payload did not change; a service died). Gating on that hash before
    classifying made needs-repair unreachable for its own motivating case.
    """
    validation = {"checked_at": "2026-08-02T00:00:00Z", "failures": 1, "modules": {"git": "pass", "python": "fail"}}
    drv, sess = _drift_driver(root, monkeypatch, CURRENT_INSTALLED, BUILD_TWO, validation)
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    assert "already_current" not in log, log
    assert "NEEDS_REPAIR" in log, log
    assert _detached_cfg(sess)["modules"] == "python"


def test_a_validation_report_older_than_the_repair_is_ignored(root, monkeypatch):
    """Nothing clears validation.json, so a stale 'fail' must not re-target forever.

    The report predates the module's installed_at, i.e. it describes a build no
    longer on the unit.
    """
    validation = {
        "checked_at": "2026-07-01T00:00:00Z",  # before installed_at
        "failures": 1,
        "modules": {"python": "fail"},
    }
    drv, _sess = _drift_driver(root, monkeypatch, CURRENT_INSTALLED, BUILD_TWO, validation)
    code = drv.run()
    log = drv.log.run_log_path.read_text()
    assert code == D.EXIT_OK, log
    assert "already_current" in log, log


BUILD_WITH_ALWAYS = {
    "payload_hash": "agg-new",
    "modules": ["git", "python", "reboot"],
    "always_modules": ["reboot"],
    "module_state": {
        "git": {"version": "1", "hash": "h-git"},
        "python": {"version": "1", "hash": "h-py-NEW"},
        "reboot": {"version": "1", "hash": "h-reboot"},
    },
}


def test_a_targeted_run_still_includes_the_always_modules(root, monkeypatch):
    """reboot must close every run that installed anything, or a pending reboot
    left by an installer is never detected and no flag is dropped."""
    installed = {
        "payload_hash": "agg-old",
        "modules": {
            "git": {"version": "1", "hash": "h-git", "provide": "pass", "verify": "pass"},
            "python": {"version": "1", "hash": "h-py-OLD", "provide": "pass", "verify": "pass"},
            "reboot": {"version": "1", "hash": "h-reboot", "provide": "pass", "verify": "pass"},
        },
    }
    drv, sess = _drift_driver(root, monkeypatch, installed, BUILD_WITH_ALWAYS)
    code = drv.run()
    assert code == D.EXIT_OK, drv.log.run_log_path.read_text()
    # Build order, not alphabetical: reboot is order-terminal and must come last.
    assert _detached_cfg(sess)["modules"] == "python,reboot"


# --- issue #25: the operational-share credential -----------------------------
def test_missing_shared_creds_is_fatal(root, monkeypatch):
    """Without shared.user/pass the mast-shared-mount provider cannot map Z:, and the
    unit silently writes exposures to C:. Fail the run rather than provision a unit
    whose operational store is wrong."""
    drv, _sess = _make_driver(root, monkeypatch, make_responder())
    creds = json.loads(drv.cfg.vault_creds.read_text())
    del creds["shared"]
    drv.cfg.vault_creds.write_text(json.dumps(creds))
    assert drv.run() == D.EXIT_FATAL
    assert "creds_shared_missing" in drv.log.run_log_path.read_text()


def test_shared_cred_is_planted_as_a_blob_never_on_a_command_line(root, monkeypatch):
    """The password reaches the unit as an uploaded file that is then DPAPI-protected
    in place; it must never appear as a command-line argument."""
    drv, sess = _make_driver(root, monkeypatch, make_responder())
    assert drv.run() == D.EXIT_OK, drv.log.run_log_path.read_text()

    protect = [s for s in sess.scripts if "shared-cred.dpapi" in s]
    assert protect, "no shared-cred blob write seen"
    assert "ProtectedData" in protect[0] and "LocalMachine" in protect[0]
    # The temp plaintext is overwritten and removed by the same script.
    assert "Remove-Item" in protect[0] and "shared-cred.tmp" in protect[0]
    assert not any(tok == "z" for s in sess.scripts for tok in s.split("'")), (
        "the shared password appears in a script argument"
    )


def test_execute_no_longer_carries_an_smb_credential(root, monkeypatch):
    """execute maps no drive now, so the detached config holds no credential and no
    prov-server hint for it to map one with."""
    drv, sess = _make_driver(root, monkeypatch, make_responder())
    assert drv.run() == D.EXIT_OK, drv.log.run_log_path.read_text()
    cfg = _detached_cfg(sess)
    assert "smb_user" not in cfg and "prov_server" not in cfg, cfg
    assert not any("smb-cred.dpapi" in s for s in sess.scripts)


def test_lease_held_is_a_refusal_not_a_failure(root, monkeypatch):
    """Exit 10 from execute means another run holds the lease and is progressing.

    It used to arrive as a plain exit 1, indistinguishable from a real failure, so a
    live run was misdiagnosed as dead and an issue filed claiming no lease guard
    existed when the guard had worked perfectly (#47). The cycle must not be marked
    failed, and the loop must not reprovision over a healthy run.
    """
    responder = make_responder(
        execute='{"status": "done", "exit_code": 10}',
        lease='{"run_id": "exec-1", "pid": 6824, "expires_utc": "2026-08-10T12:00:00Z"}',
    )
    drv, _sess = _make_driver(root, monkeypatch, responder)
    code = drv.run()
    log = drv.log.run_log_path.read_text()

    assert "EXECUTE_LEASE_HELD" in log, log
    assert "EXECUTE_FAIL" not in log, log
    assert code == D.EXIT_OK, log
    # Naming the holder is most of the point: "a run is in progress" without saying
    # which one is what let a healthy run be read as a dead one.
    assert "holder_run=exec-1" in log, log
    assert "holder_pid=6824" in log, log
    # A refusal changed nothing, so the unit is handed straight back rather than left
    # flagged unavailable until some later run happens to succeed.
    assert "AVAIL_SET" in log and "available=true" in log, log
    assert "provisioning_incomplete" not in log, log


def test_execute_lease_held_code_matches_the_powershell_constant():
    """The refusal code is duplicated across the language boundary; assert it agrees.

    The driver decides what the number means and execute-mast-provisioning.ps1 emits
    it, so a silent divergence turns every refusal back into an EXECUTE_FAIL -- the
    exact confusion #47 is about.
    """
    ps_path = Path(D.__file__).resolve().parents[2] / "client" / "execute-mast-provisioning.ps1"
    ps = ps_path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"MAST_EXIT_LEASE_HELD\s+-Value\s+(\d+)", ps)
    assert m, f"MAST_EXIT_LEASE_HELD constant not found in {ps_path}"
    assert int(m.group(1)) == D.EXECUTE_EXIT_LEASE_HELD


# --- #63: --modules must filter EXECUTE, never shrink the BUILD --------------
# A unit with no registry-declared module list, so discovery supplies the full set.
UNIT_NO_MODULES = {k: v for k, v in UNIT.items() if k != "modules"}


def _write_provider(repo, name, order, always=False):
    d = repo / "server" / "providers" / name
    d.mkdir(parents=True, exist_ok=True)
    body = {"name": name, "order": order}
    if always:
        body["always"] = True
    (d / "module.json").write_text(json.dumps(body), encoding="utf-8")


def test_modules_flag_does_not_shrink_the_build(root, monkeypatch):
    """The build must declare the unit's FULL set even on a --modules run.

    The build-manifest's module list is what the unit's fully_provisioned is
    judged against (client/mast-installed-manifest.ps1). A subset build made the
    flag read true off a partial set and published the aggregate payload_hash
    with it, after which a repeated identical subset run satisfied both halves of
    the already_current skip and the unit was reported current having never been
    checked against the full set. mast03 read fully_provisioned=True off six
    modules this way (#63).
    """
    drv, _sess = _make_driver(root, monkeypatch, make_responder(), unit=UNIT_NO_MODULES)
    repo = drv.cfg.repo_top
    for name, order in (("config-bootstrap", 150), ("git", 500), ("mast", 2200)):
        _write_provider(repo, name, order)
    _write_provider(repo, "proxy", 100, always=True)
    _write_provider(repo, "reboot", 9999, always=True)

    seen: dict[str, list[str]] = {}

    def capturing_build(self, unit, host, modules, dur):
        seen["build"] = list(modules)
        self._staging_dir = repo / "staging"
        self.log.event("BUILD_OK", unit=host, payload_hash="hash123", git_sha="sha")
        return "hash123", "sha", {}

    monkeypatch.setattr(D.Driver, "_build", capturing_build)
    drv.cfg.modules = ["mast"]

    drv.run()

    assert seen["build"] == ["config-bootstrap", "git", "mast", "proxy", "reboot"], seen
    assert "mast" in seen["build"] and len(seen["build"]) > 1


def test_modules_flag_filters_what_executes(root, monkeypatch):
    drv, _sess = _make_driver(root, monkeypatch, make_responder(), unit=UNIT_NO_MODULES)
    repo = drv.cfg.repo_top
    for name, order in (("config-bootstrap", 150), ("mast", 2200)):
        _write_provider(repo, name, order)
    _write_provider(repo, "proxy", 100, always=True)
    _write_provider(repo, "reboot", 9999, always=True)
    drv.cfg.modules = ["mast"]

    drv.run()
    log = drv.log.run_log_path.read_text()

    assert "MODULE_TARGET_FILTERED" in log, log
    # proxy/reboot ride along so the run still closes itself out (#60);
    # config-bootstrap was not asked for and must not execute.
    assert "targets=proxy,mast,reboot" in log, log


def test_modules_flag_skips_when_no_named_module_needs_work(root, monkeypatch):
    """Nothing named needs work -> skip, rather than run the always-modules alone.

    reboot is an always-module, so synthesising a run out of an empty
    intersection would reboot a unit for a run with no work in it.
    """
    drv, _sess = _make_driver(root, monkeypatch, make_responder(), unit=UNIT_NO_MODULES)
    repo = drv.cfg.repo_top
    _write_provider(repo, "config-bootstrap", 150)
    _write_provider(repo, "mast", 2200)
    _write_provider(repo, "reboot", 9999, always=True)

    # Drift says only config-bootstrap needs work; the operator asked for mast.
    monkeypatch.setattr(
        D.drift,
        "classify",
        lambda installed, bm, val: type(
            "R",
            (),
            {
                "current": False,
                "targets": ["config-bootstrap"],
                "summary": lambda self: "1 drifted",
            },
        )(),
    )
    drv.cfg.modules = ["mast"]

    code = drv.run()
    log = drv.log.run_log_path.read_text()

    assert "MODULE_TARGET_EMPTY" in log, log
    assert "EXECUTE_START" not in log, f"executed despite nothing to do\n{log}"
    assert code == D.EXIT_OK, log


# --- #70: address for transport, name for identity ---------------------------
def test_staging_unc_uses_the_derived_address_and_lease_keeps_the_name(root, monkeypatch):
    """The two roles must stay split.

    They were one value (`prov_server`, this machine's COMPUTERNAME), which the
    unit then had to resolve -- via a hand-placed hosts entry nothing maintains.
    Three units pinned it to a dead APIPA address and every transfer failed with
    net.exe error 53 (#70). The lease's held_by is the one place a NAME is right:
    it identifies who holds the run, and outlives a DHCP change.
    """
    drv, sess = _make_driver(root, monkeypatch, make_responder())
    monkeypatch.setattr(D.transport, "local_address_for", lambda peer_ip: "10.23.2.34")
    drv.prov_identity = "AP-PC-PF62XRLL"

    drv.run()
    log = drv.log.run_log_path.read_text()

    assert "PROV_ADDR" in log and "address=10.23.2.34" in log, log
    assert r"src_unc=\\10.23.2.34\mast-staging" in log, log
    assert "AP-PC-PF62XRLL" not in log.split("TRANSFER_START")[1].split("\n")[0], (
        "the staging UNC must not carry this machine's name\n" + log
    )
    # ...while the execute lease still identifies the holder by name.
    planted = [s for s in sess.scripts if "held_by" in s]
    assert planted, "no lease/detached-config write seen"
    assert any("AP-PC-PF62XRLL" in s for s in planted), planted[:1]


def test_unreachable_staging_fails_before_the_build(root, monkeypatch):
    """A run that cannot transfer must not build first.

    The #70 failure spent ~3 minutes building and planning a 403-file transfer
    before net.exe reported error 53.
    """
    built = {"n": 0}

    def counting_build(self, unit, host, modules, dur):
        built["n"] += 1
        self._staging_dir = self.cfg.repo_top / "staging"
        self.log.event("BUILD_OK", unit=host, payload_hash="h", git_sha="s")
        return "h", "s", {}

    drv, _sess = _make_driver(root, monkeypatch, make_responder(smbreach="SMBREACH timeout"))
    monkeypatch.setattr(D.Driver, "_build", counting_build)

    code = drv.run()
    log = drv.log.run_log_path.read_text()

    assert "PREFLIGHT_UNIT_SMB_FAIL" in log, log
    assert built["n"] == 0, "built a payload the unit cannot pull"
    assert "BUILD_START" not in log, log
    assert code == D.EXIT_UNIT_FAIL, log
