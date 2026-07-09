"""Fast, mock-free unit tests for PURE logic in vm_lib.

Why these exist (see vm/tests/README.md): the failure modes that bit us are
decision/encoding logic, not I/O orchestration -- e.g. the WinRM inline-dispatch
size limit, which an e2e run only surfaces as a remote "The command line is too
long". That logic is pure and cheap to test directly. vm_lib is import-pure
(it touches nothing at import), so importing it here costs nothing and needs NO
mocking of WinRM/SSH/VBox/SMB. Logic that needs the ecosystem is left to the
e2e tests (run-prov-test.py / test-suite.py) on purpose -- we do not mock the
ecosystem to fake a provision.

Run with pytest:   python -m pytest vm/tests/
Or standalone:     python vm/tests/test_vm_lib.py
"""
import base64
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import vm_lib  # noqa: E402


def test_winrm_encoded_cmd_len_matches_powershell_encoding():
    # PowerShell -EncodedCommand is UTF-16LE then base64; the helper must agree.
    s = "Write-Host 'hi'"
    assert vm_lib.winrm_encoded_cmd_len(s) == len(base64.b64encode(s.encode("utf-16-le")))
    assert vm_lib.winrm_encoded_cmd_len("") == 0
    assert vm_lib.winrm_encoded_cmd_len("x" * 1000) > vm_lib.winrm_encoded_cmd_len("x" * 100)


def test_assert_inline_dispatchable_allows_small_scripts():
    # A normal small script must NOT raise.
    vm_lib.assert_inline_dispatchable("Get-Service WinRM", label="ok")


def test_assert_inline_dispatchable_rejects_oversized_scripts():
    # This is the regression guard: a script past the cmd.exe ~8191 EncodedCommand
    # limit must fail FAST and LOCALLY (previously only seen remotely as
    # "The command line is too long", requiring a remote-log dig).
    big = "A" * vm_lib.WINRM_ENCODED_CMD_MAX  # ~2.67x once UTF-16+base64 -> well over
    try:
        vm_lib.assert_inline_dispatchable(big, label="pull")
    except ValueError as e:
        msg = str(e)
        assert "too large for inline WinRM dispatch" in msg
        assert "file" in msg          # points operator at file-dispatch
        assert "[pull]" in msg        # includes the label for context
    else:
        raise AssertionError("oversized script should have raised ValueError")


def test_ps_escape_doubles_single_quotes():
    assert vm_lib._ps_escape("a'b") == "a''b"
    assert vm_lib._ps_escape("plain") == "plain"
    assert vm_lib._ps_escape("o'reilly's") == "o''reilly''s"


def test_candidate_users_offers_local_account_variants():
    # '.\\mast' should also offer bare 'mast', and vice versa, so Basic-auth
    # quirks across hosts are covered without the caller guessing.
    assert "mast" in vm_lib._candidate_users("host", ".\\mast")
    assert ".\\mast" in vm_lib._candidate_users("host", "mast")
    # An IPv4 host adds a workgroup-style 'host\\user' candidate.
    assert any("\\" in c for c in vm_lib._candidate_users("192.168.56.113", "mast"))


def test_minify_ps_strips_comments_blanks_and_indent():
    raw = "\n".join([
        "<# block",
        "comment spanning lines #>",
        "# whole-line comment",
        "   Write-Host 'a'   ",
        "",
        "Get-Service WinRM   # trailing comment is kept",
    ])
    out = vm_lib._minify_ps(raw)
    # block comment, whole-line comment, and blank line all gone; lines dedented;
    # a trailing (mid-line) # comment is preserved.
    assert out.splitlines() == ["Write-Host 'a'", "Get-Service WinRM   # trailing comment is kept"]
    assert "block" not in out
    assert "whole-line comment" not in out
    # Minifying must shrink (or equal) the payload -- it never grows it.
    assert vm_lib.winrm_encoded_cmd_len(out) <= vm_lib.winrm_encoded_cmd_len(raw)


def test_run_with_heartbeat_escalates_and_rate_limits():
    # A long step must not scroll an identical "still running" line every
    # interval (mast04 ascom: 65 min of them). The log cadence backs off and
    # escalates to a WARN past the threshold, while the hard timeout still fires.
    import time

    keys = (
        "HEARTBEAT_INTERVAL_S", "HEARTBEAT_MAX_GAP_S",
        "HEARTBEAT_ESCALATE_S", "HEARTBEAT_ESCALATE_GAP_S", "_log",
    )
    orig = {k: getattr(vm_lib, k) for k in keys}
    logs: list[str] = []
    try:
        vm_lib.HEARTBEAT_INTERVAL_S = 0.1
        vm_lib.HEARTBEAT_MAX_GAP_S = 0.4
        vm_lib.HEARTBEAT_ESCALATE_S = 1        # elapsed is int-seconds
        vm_lib.HEARTBEAT_ESCALATE_GAP_S = 0.5
        vm_lib._log = lambda m: logs.append(m)

        def slow():
            time.sleep(1.6)
            return "done"

        assert vm_lib._run_with_heartbeat(slow, "ascom", timeout_s=100) == "done"
        # Rate-limited: far fewer than the ~16 a fixed 0.1s cadence would emit.
        assert len(logs) < 10, f"heartbeat not rate-limited: {len(logs)} lines"
        # Escalated to a WARN once past the threshold.
        assert any("[WARN]" in m and "STILL running" in m for m in logs)

        # The hard timeout still fires with the new cadence.
        raised = False
        try:
            vm_lib._run_with_heartbeat(lambda: time.sleep(1.0), "hang", timeout_s=0)
        except TimeoutError:
            raised = True
        assert raised, "hard timeout must still fire"
    finally:
        for k, v in orig.items():
            setattr(vm_lib, k, v)


def _run_all() -> int:
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception as e:  # noqa: BLE001 - standalone runner wants all failures
            failed += 1
            print(f"FAIL {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(_run_all())
