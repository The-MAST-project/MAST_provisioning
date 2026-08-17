"""Tests for prov.transport -- the pure logic in the lifted WinRM/SSH transport.

Moved from vm/tests/test_vm_lib.py when the transport was lifted out of vm_lib
into prov.transport
(docs/decisions/2026-07-12-port-server-orchestration-to-python.md). The heartbeat test now patches
prov.transport (where _run_with_heartbeat reads its module globals), not vm_lib.
A re-export smoke test guards that the vm_lib shim still surfaces the API the
vm/ harness imports.
"""

import base64
import json
import re

import pytest
import winrm

from prov import transport as T


def test_winrm_encoded_cmd_len_matches_powershell_encoding():
    s = "Write-Host 'hi'"
    assert T.winrm_encoded_cmd_len(s) == len(base64.b64encode(s.encode("utf-16-le")))
    assert T.winrm_encoded_cmd_len("") == 0
    assert T.winrm_encoded_cmd_len("x" * 1000) > T.winrm_encoded_cmd_len("x" * 100)


def test_assert_inline_dispatchable_allows_small_scripts():
    T.assert_inline_dispatchable("Get-Service WinRM", label="ok")


def test_assert_inline_dispatchable_rejects_oversized_scripts():
    big = "A" * T.WINRM_ENCODED_CMD_MAX
    try:
        T.assert_inline_dispatchable(big, label="pull")
    except ValueError as e:
        msg = str(e)
        assert "too large for inline WinRM dispatch" in msg
        assert "file" in msg
        assert "[pull]" in msg
    else:
        raise AssertionError("oversized script should have raised ValueError")


def test_ps_escape_doubles_single_quotes():
    assert T._ps_escape("a'b") == "a''b"
    assert T._ps_escape("plain") == "plain"
    assert T._ps_escape("o'reilly's") == "o''reilly''s"


def test_candidate_users_offers_local_account_variants():
    assert "mast" in T._candidate_users("host", ".\\mast")
    assert ".\\mast" in T._candidate_users("host", "mast")
    assert any("\\" in c for c in T._candidate_users("192.168.56.113", "mast"))


def test_minify_ps_strips_comments_blanks_and_indent():
    raw = (
        "<# block\ncomment spanning lines #>\n# whole-line comment\n"
        "   Write-Host 'a'   \n\nGet-Service WinRM   # trailing comment is kept"
    )
    out = T._minify_ps(raw)
    assert out.splitlines() == ["Write-Host 'a'", "Get-Service WinRM   # trailing comment is kept"]
    assert "block" not in out
    assert "whole-line comment" not in out
    assert T.winrm_encoded_cmd_len(out) <= T.winrm_encoded_cmd_len(raw)


def test_run_with_heartbeat_escalates_and_rate_limits():
    import time

    keys = (
        "HEARTBEAT_INTERVAL_S",
        "HEARTBEAT_MAX_GAP_S",
        "HEARTBEAT_ESCALATE_S",
        "HEARTBEAT_ESCALATE_GAP_S",
        "_log",
    )
    orig = {k: getattr(T, k) for k in keys}
    logs: list[str] = []
    try:
        T.HEARTBEAT_INTERVAL_S = 0.1
        T.HEARTBEAT_MAX_GAP_S = 0.4
        T.HEARTBEAT_ESCALATE_S = 1
        T.HEARTBEAT_ESCALATE_GAP_S = 0.5
        T._log = lambda m: logs.append(m)

        def slow():
            time.sleep(1.6)
            return "done"

        assert T._run_with_heartbeat(slow, "ascom", timeout_s=100) == "done"
        assert len(logs) < 10, f"heartbeat not rate-limited: {len(logs)} lines"
        assert any("[WARN]" in m and "STILL running" in m for m in logs)

        raised = False
        try:
            T._run_with_heartbeat(lambda: time.sleep(1.0), "hang", timeout_s=0)
        except TimeoutError:
            raised = True
        assert raised, "hard timeout must still fire"
    finally:
        for k, v in orig.items():
            setattr(T, k, v)


def test_unit_entry_matches_the_registry_template(tmp_path):
    # The template is what an operator copies, so it and UnitEntry must agree: a
    # key added to one and not the other is how the registry and the code that
    # reads it drift. `_comment` is documentation and is deliberately not a field.
    template = json.loads((T.REPO_ROOT / "server" / "unit-registry.json.template").read_text(encoding="utf-8-sig"))
    assert len(template) == 1
    keys = set(template[0]) - {"_comment"}
    declared = set(T.UnitEntry.__annotations__)
    assert keys <= declared, f"template keys absent from UnitEntry: {sorted(keys - declared)}"
    # Everything the loader requires must be in the template, or the copied entry
    # is rejected the first time it is read. Spelled out rather than taken from
    # UnitEntry.__required_keys__: prov.transport uses `from __future__ import
    # annotations`, so its annotations are strings and TypedDict cannot resolve
    # NotRequired at runtime -- __required_keys__ there reports every key. pyright
    # reads the source and gets it right, which is what actually gates the code;
    # do not trust runtime introspection of these TypedDicts.
    assert {"hostname", "site"} <= keys

    # And the template entry itself must load.
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps(template), encoding="utf-8")
    assert [e["hostname"] for e in T.load_unit_registry(p)] == [template[0]["hostname"]]


@pytest.mark.parametrize(
    ("entry", "expected"),
    [
        ({"site": "ns"}, "hostname"),
        ({"hostname": "mast01"}, "site"),
        ({"hostname": "mast01", "site": "   "}, "site"),
        ({"hostname": "mast01", "site": 7}, "site"),
        ({"hostname": "mast01", "site": "ns", "maintenance_window": {"start_hour": 0}}, "maintenance_window"),
        (
            {"hostname": "mast01", "site": "ns", "maintenance_window": {"start_hour": 0, "end_hour": "6"}},
            "maintenance_window",
        ),
    ],
    ids=["no hostname", "no site", "blank site", "non-string site", "half a window", "string hour"],
)
def test_load_unit_registry_rejects_a_malformed_entry(tmp_path, entry, expected):
    # Rejected at the read, naming the file: a registry the driver cannot trust
    # must not reach the phase that would provision from it.
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps([entry]), encoding="utf-8")
    with pytest.raises(TypeError, match=expected):
        T.load_unit_registry(p)


def test_load_unit_registry_accepts_the_optional_keys_absent(tmp_path):
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps([{"hostname": "mast01", "site": "ns"}]), encoding="utf-8")
    (entry,) = T.load_unit_registry(p)
    assert entry["hostname"] == "mast01"
    assert entry.get("mac") is None


def test_pull_staging_args_match_the_script():
    # The bug this exists for: -ProvServer was renamed -ProvAddress in the pull
    # script, the driver was updated, and the vm/ harness was not -- so it passed a
    # flag the script no longer declared. PowerShell put it in $args, $ProvAddress
    # came through empty, and the mount target degraded to \\\mast-staging. Every
    # dev VM cycle failed at transfer for six days, and nothing failed at review.
    ps1 = (T.REPO_ROOT / "client" / "mast-pull-staging.ps1").read_text(encoding="utf-8")
    block = ps1.split("param(", 1)[1].split(")", 1)[0]
    declared = set(re.findall(r"\$(\w+)", block))
    emitted = set(
        re.findall(
            r"-(\w+) '",
            T.pull_staging_args(
                prov_address="10.23.2.34",
                unit_hostname="mastw",
                smb_user="mast-transfer",
                smb_pass="pw",
                unit_stage=r"C:\mast-staging\run-1",
                src_unc=r"\\10.23.2.34\mast-staging\mastw\01-provisioning",
            ),
        )
    )
    assert emitted == declared, f"builder emits {sorted(emitted)}, script declares {sorted(declared)}"
    # And the script must reject an unknown flag rather than swallow it.
    assert "[CmdletBinding()]" in ps1


def test_pull_staging_args_quote_every_value():
    # Values reach the unit inside a PowerShell command line, so each one is a
    # quoted literal with embedded quotes doubled -- the SMB password in
    # particular is arbitrary text.
    args = T.pull_staging_args(
        prov_address="10.23.2.34",
        unit_hostname="mastw",
        smb_user="mast-transfer",
        smb_pass="pa'ss",
        unit_stage="C:\\s",
        src_unc="\\\\h\\s",
    )
    assert "-SmbPass 'pa''ss'" in args
    assert args.count("'") % 2 == 0


def test_unit_response_protocol_covers_both_transports():
    # UnitResponse is what the shared run paths (run_ps, _resilient_run_ps) return,
    # because the SSH path yields _SshResponse and the WinRM path a winrm.Response.
    # The two annotated bindings are the real guard and the type checker enforces
    # them: add a member to UnitResponse that one class lacks, or drop one from
    # either class, and this file fails `basedpyright` at review rather than at the
    # first SSH-path caller that reads it. The asserts below cover the runtime half
    # -- that the members carry what the callers expect, in pywinrm's tuple order.
    ssh: T.UnitResponse = T._SshResponse(0, b"out", b"err")
    wire: T.UnitResponse = winrm.Response((b"out", b"err", 0))
    for r in (ssh, wire):
        assert r.status_code == 0
        assert r.std_out == b"out"
        assert r.std_err == b"err"


def test_upload_file_routes_ssh_to_sftp_else_b64(monkeypatch):
    # SSH sessions upload via SFTP (no cmd.exe command-line limit); anything else
    # falls back to the base64-over-run_ps path.
    class _FakeSsh(T.SshSession):
        def __init__(self):  # bypass paramiko connect
            self.put_calls = []

        def put_file(self, remote_path, data):
            self.put_calls.append((remote_path, data))

    ssh = _FakeSsh()
    T.upload_file(ssh, r"C:\MAST\x.ps1", "hello", label="x")
    assert ssh.put_calls == [(r"C:\MAST\x.ps1", b"hello")]

    b64_called = {}
    monkeypatch.setattr(T, "upload_file_b64", lambda s, p, c, label="file": b64_called.update(path=p, content=c))
    T.upload_file(object(), r"C:\MAST\y.ps1", "world", label="y")
    assert b64_called == {"path": r"C:\MAST\y.ps1", "content": "world"}


def _make_fake_ssh(chan, active=True):
    """A SshSession whose paramiko client hands out `chan` and whose transport
    reports active/inactive per `active` (bool or 0-arg callable)."""
    is_active = active if callable(active) else (lambda: active)

    class _Tr:
        def open_session(self):
            return chan

        def is_active(self):
            return is_active()

    class _Client:
        def get_transport(self):
            return _Tr()

    class _FakeSsh(T.SshSession):
        def __init__(self):  # bypass paramiko connect
            self._client = _Client()

    return _FakeSsh()


def test_ssh_run_ps_returns_on_exit_status_not_eof():
    # Guards the general fix (2026-07-21): a detached grandchild (a service
    # started by mast-services-finalize/NSSM, or the net-use Start-Job in
    # mast-pull-staging.ps1) can inherit the stdout handle and hold the pipe
    # open so channel EOF never arrives. run_ps must complete on the command's
    # exit status and drain buffered output -- never block on read()-to-EOF.
    class _FakeChan:
        def __init__(self):
            self._out = [b"OK\r\n"]
            self._err = []
            self.closed = False
            self.exec_cmd = ""

        def exec_command(self, cmd):
            self.exec_cmd = cmd

        def recv_ready(self):
            return bool(self._out)

        def recv(self, _n):
            return self._out.pop(0)

        def recv_stderr_ready(self):
            return bool(self._err)

        def recv_stderr(self, _n):
            return self._err.pop(0)

        def exit_status_ready(self):
            # Command exited (exit-status sent) though a lingering child keeps
            # the pipe from ever reaching EOF -- a read()-to-EOF would hang here.
            return True

        def recv_exit_status(self):
            return 0

        def close(self):
            self.closed = True

    chan = _FakeChan()
    r = _make_fake_ssh(chan).run_ps("Write-Host OK")
    assert r.status_code == 0
    assert r.std_out == b"OK\r\n"
    assert r.std_err == b""
    assert chan.closed, "channel must be closed in finally"
    assert "-EncodedCommand" in chan.exec_cmd


def test_ssh_run_ps_deadline_bails_on_stuck_command():
    # Guards the #10 "bound the SSH exec channel" fix: a genuinely stuck command
    # (transport alive, never sends exit-status) must bail on timeout_s (raising)
    # and the finally must close the channel -- otherwise the daemon worker
    # thread + channel leak across --loop cycles.
    class _StuckChan:
        def __init__(self):
            self.closed = False

        def exec_command(self, _cmd):
            pass

        def recv_ready(self):
            return False

        def recv_stderr_ready(self):
            return False

        def exit_status_ready(self):
            return False  # never exits

        def close(self):
            self.closed = True

    chan = _StuckChan()
    with pytest.raises(TimeoutError):
        _make_fake_ssh(chan, active=True).run_ps("Start-Sleep 999", timeout_s=0.2)
    assert chan.closed, "stuck channel must be closed on deadline"


def test_ssh_run_ps_raises_connectionerror_on_dead_transport():
    # Guards the keepalive/drop-detection fix (2026-07-22): a silent/half-open
    # drop leaves the loop with no data + no exit-status + no close event. The
    # keepalive flips transport.is_active() False; run_ps must raise
    # ConnectionError (so _resilient_run_ps reconnects) rather than spin to the
    # deadline.
    class _DeadChan:
        def __init__(self):
            self.closed = False

        def exec_command(self, _cmd):
            pass

        def recv_ready(self):
            return False

        def recv_stderr_ready(self):
            return False

        def exit_status_ready(self):
            return False

        def close(self):
            self.closed = True

    chan = _DeadChan()
    with pytest.raises(ConnectionError):
        _make_fake_ssh(chan, active=False).run_ps("x", timeout_s=30)
    assert chan.closed


def test_resilient_run_ps_reconnects_and_retries_on_ssh_drop(monkeypatch):
    # A dropped control channel must trigger reconnect + one re-run of the
    # (idempotent) command, not a hard failure.
    monkeypatch.setattr(T.time, "sleep", lambda *_a, **_k: None)
    monkeypatch.setattr(T, "_log", lambda *_a, **_k: None)

    class _FlakySsh(T.SshSession):
        def __init__(self):
            self.calls = 0
            self.reconnects = 0

        def run_ps(self, script, timeout_s=None):
            self.calls += 1
            if self.calls == 1:
                raise ConnectionError("dropped")
            return T._SshResponse(0, b"ok", b"")

        def reconnect(self, max_wait_s: float = 0.0):
            self.reconnects += 1

    s = _FlakySsh()
    r = T._resilient_run_ps(s, "Write-Host hi", log_label="t", timeout_s=5)
    assert r.status_code == 0 and r.std_out == b"ok"
    assert s.calls == 2, "should re-run once after the drop"
    assert s.reconnects == 1, "should reconnect before the retry"


def test_reconnect_retries_until_channel_returns(monkeypatch):
    # Patient reconnect: keep probing (gentle backoff) until _connect succeeds,
    # so a transient VM-under-load drop is ridden out.
    monkeypatch.setattr(T.time, "sleep", lambda *_a, **_k: None)

    class _S(T.SshSession):
        def __init__(self):
            self.attempts = 0
            self.closed = False

        def close(self):
            self.closed = True

        def _connect(self, connect_timeout_s=None):
            self.attempts += 1
            if self.attempts < 3:
                raise OSError("VM still unreachable")

    s = _S()
    s.reconnect(max_wait_s=180)
    assert s.closed, "reconnect must tear down the dead client first"
    assert s.attempts == 3, "should keep probing until the channel returns"


def test_reconnect_gives_up_after_max_wait(monkeypatch):
    # If the channel never comes back inside the window, reconnect raises the
    # last connection error rather than hanging forever.
    monkeypatch.setattr(T.time, "sleep", lambda *_a, **_k: None)

    class _S(T.SshSession):
        def __init__(self):
            self.attempts = 0

        def close(self):
            pass

        def _connect(self, connect_timeout_s=None):
            self.attempts += 1
            raise OSError("down")

    s = _S()
    with pytest.raises(OSError):
        s.reconnect(max_wait_s=0)
    assert s.attempts >= 1


def test_resilient_run_ps_does_not_retry_on_timeout(monkeypatch):
    # A genuinely stuck (alive) command hits the deadline as TimeoutError; it
    # must NOT be reconnected/re-run (re-running a live 42-min execute is wrong).
    monkeypatch.setattr(T.time, "sleep", lambda *_a, **_k: None)
    monkeypatch.setattr(T, "_log", lambda *_a, **_k: None)

    class _StuckSsh(T.SshSession):
        def __init__(self):
            self.calls = 0
            self.reconnects = 0

        def run_ps(self, script, timeout_s=None):
            self.calls += 1
            raise TimeoutError("stuck")

        def reconnect(self, max_wait_s: float = 0.0):
            self.reconnects += 1

    s = _StuckSsh()
    with pytest.raises(TimeoutError):
        T._resilient_run_ps(s, "x", log_label="t", timeout_s=5)
    assert s.calls == 1, "a live-but-stuck command must not be re-run"
    assert s.reconnects == 0


def test_vm_lib_shim_reexports_transport_surface():
    # The vm/ harness imports these from vm_lib; the shim must still surface them.
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "vm"))
    import vm_lib

    for name in (
        "connect_unit",
        "run_ps",
        "winrm_session",
        "load_creds",
        "check_rc",
        "wait_for_winrm",
        "WINRM_PORT",
        "REPO_ROOT",
        "_ps_escape",
        "_run_with_heartbeat",
        "vbox",
        "vm_state",
    ):
        assert hasattr(vm_lib, name), f"vm_lib missing re-export: {name}"


def test_dump_json_file_writes_no_bom_and_lf(tmp_path):
    p = tmp_path / "x.json"
    T.dump_json_file(p, {"a": 1, "b": [2, 3]})
    raw = p.read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf"), "no UTF-8 BOM"
    assert b"\r" not in raw, "LF only, never CRLF (adopted no-BOM+LF standard)"
    assert T.load_json_file(p) == {"a": 1, "b": [2, 3]}


def test_missing_pywinrm_raises_importerror_not_systemexit():
    # A missing optional dependency must raise a catchable ImportError, not
    # sys.exit at import time (which would kill any tool/test that imports the
    # module and breaks the module's import-purity contract).
    import importlib
    import sys

    saved = sys.modules.get("winrm")
    try:
        # A None entry in sys.modules is the documented way to force ImportError;
        # the annotation says ModuleType, so this one stays suppressed for good.
        sys.modules["winrm"] = None  # pyright: ignore[reportArgumentType]
        with pytest.raises(ImportError):
            importlib.reload(T)
    finally:
        if saved is not None:
            sys.modules["winrm"] = saved
        else:
            sys.modules.pop("winrm", None)
        importlib.reload(T)  # rebuild cleanly so downstream tests see a good module
