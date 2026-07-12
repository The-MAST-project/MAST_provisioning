"""Tests for prov.transport -- the pure logic in the lifted WinRM/SSH transport.

Moved from vm/tests/test_vm_lib.py when the transport was lifted out of vm_lib
into prov.transport (DECISIONS.md 2026-07-12). The heartbeat test now patches
prov.transport (where _run_with_heartbeat reads its module globals), not vm_lib.
A re-export smoke test guards that the vm_lib shim still surfaces the API the
vm/ harness imports.
"""
import base64

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
