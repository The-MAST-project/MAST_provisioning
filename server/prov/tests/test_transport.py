"""Tests for prov.transport -- the pure logic in the lifted WinRM/SSH transport.

Moved from vm/tests/test_vm_lib.py when the transport was lifted out of vm_lib
into prov.transport (DECISIONS.md 2026-07-12). The heartbeat test now patches
prov.transport (where _run_with_heartbeat reads its module globals), not vm_lib.
A re-export smoke test guards that the vm_lib shim still surfaces the API the
vm/ harness imports.
"""
import base64

import pytest

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
    raw = "\n".join([
        "<# block",
        "comment spanning lines #>",
        "# whole-line comment",
        "   Write-Host 'a'   ",
        "",
        "Get-Service WinRM   # trailing comment is kept",
    ])
    out = T._minify_ps(raw)
    assert out.splitlines() == ["Write-Host 'a'", "Get-Service WinRM   # trailing comment is kept"]
    assert "block" not in out
    assert "whole-line comment" not in out
    assert T.winrm_encoded_cmd_len(out) <= T.winrm_encoded_cmd_len(raw)


def test_run_with_heartbeat_escalates_and_rate_limits():
    import time

    keys = (
        "HEARTBEAT_INTERVAL_S", "HEARTBEAT_MAX_GAP_S",
        "HEARTBEAT_ESCALATE_S", "HEARTBEAT_ESCALATE_GAP_S", "_log",
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
    monkeypatch.setattr(T, "upload_file_b64",
                        lambda s, p, c, label="file": b64_called.update(path=p, content=c))
    T.upload_file(object(), r"C:\MAST\y.ps1", "world", label="y")
    assert b64_called == {"path": r"C:\MAST\y.ps1", "content": "world"}


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
            self.exec_cmd = None

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

    class _FakeSsh(T.SshSession):
        def __init__(self):  # bypass paramiko connect
            self._client = type(
                "C", (), {"get_transport": lambda _s: type(
                    "Tr", (), {"open_session": lambda _s2: chan})()}
            )()

    r = _FakeSsh().run_ps("Write-Host OK")
    assert r.status_code == 0
    assert r.std_out == b"OK\r\n"
    assert r.std_err == b""
    assert chan.closed, "channel must be closed in finally"
    assert "-EncodedCommand" in chan.exec_cmd


def test_ssh_run_ps_deadline_bails_on_stuck_command():
    # Guards the #10 "bound the SSH exec channel" fix: a genuinely stuck command
    # never sends exit-status, so the loop must bail on timeout_s (raising) and
    # the finally must close the channel -- otherwise the daemon worker thread
    # + channel leak across --loop cycles.
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

    class _FakeSsh(T.SshSession):
        def __init__(self):
            self._client = type(
                "C", (), {"get_transport": lambda _s: type(
                    "Tr", (), {"open_session": lambda _s2: chan})()}
            )()

    with pytest.raises(TimeoutError):
        _FakeSsh().run_ps("Start-Sleep 999", timeout_s=0.2)
    assert chan.closed, "stuck channel must be closed on deadline"


def test_vm_lib_shim_reexports_transport_surface():
    # The vm/ harness imports these from vm_lib; the shim must still surface them.
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "vm"))
    import vm_lib
    for name in ("connect_unit", "run_ps", "winrm_session", "load_creds",
                 "check_rc", "wait_for_winrm", "WINRM_PORT", "REPO_ROOT",
                 "_ps_escape", "_run_with_heartbeat", "vbox", "vm_state"):
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
        sys.modules["winrm"] = None  # makes `import winrm` raise ImportError
        with pytest.raises(ImportError):
            importlib.reload(T)
    finally:
        if saved is not None:
            sys.modules["winrm"] = saved
        else:
            sys.modules.pop("winrm", None)
        importlib.reload(T)  # rebuild cleanly so downstream tests see a good module
