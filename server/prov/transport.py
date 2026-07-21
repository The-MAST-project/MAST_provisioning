"""Platform-agnostic WinRM / SSH transport for driving Windows units.

This module is the single source of truth for the server-side transport layer
of MAST provisioning -- used by both the production driver (prov.driver) and the
vm/ test harness (vm_lib re-exports it). It is deliberately platform-agnostic:
pywinrm speaks WinRM over HTTP and paramiko speaks SSH, so the prov server can
run on any OS while the units stay Windows (see DECISIONS.md 2026-07-12).

It is the canonical source of truth for:
  * loading vault credentials
  * constructing a pywinrm Session (do NOT instantiate winrm.Session directly
    elsewhere -- see MAST_provisioning/CLAUDE.md DRY rules)
  * running a PowerShell snippet on a unit with heartbeat logging
  * waiting for WinRM to come back after boot/reboot (SSH fallback)
  * uploading a text file to a unit via base64 chunking

It is import-pure: importing this module does not touch the filesystem, the
network, or the logger. Long-running orchestrators can swap the log sinks by
assigning to ``transport.log_fn`` / ``transport.log_raw_fn`` after import; ad-hoc
scripts can ignore that and get plain timestamped prints for free.
"""

from __future__ import annotations

import base64
import json
import re
import socket
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

try:
    import winrm  # type: ignore[import]
    from winrm.exceptions import WinRMOperationTimeoutError  # type: ignore[import]
except ImportError as e:
    # Raise (catchable) rather than sys.exit at import time: this module claims
    # import-purity, and killing the process on import breaks any tool/test that
    # merely imports it. pywinrm is still a declared runtime dependency.
    raise ImportError(
        "pywinrm is required for prov.transport (the WinRM fallback transport). "
        "Install it with: pip install pywinrm"
    ) from e

# requests is a hard dependency of pywinrm, so this import is always safe.
import requests  # type: ignore[import]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parents[2]  # server/prov/transport.py -> repo
VAULT_CREDS = REPO_ROOT / "vault" / "creds.json"

WINRM_PORT = 5985
# Inline dispatch sends `powershell.exe -EncodedCommand <b64>`; cmd.exe caps the
# command line at ~8191 chars. Reject scripts whose base64 (UTF-16) exceeds this
# BEFORE sending, so the failure is immediate and local instead of a remote
# "The command line is too long". Larger scripts must be file-dispatched.
WINRM_ENCODED_CMD_MAX = 8000
WINRM_CALL_TIMEOUT_S = 60 * 60
WINRM_BOOT_TIMEOUT_S = 15 * 60
# Thread-join granularity: the timeout is still checked every HEARTBEAT_INTERVAL_S.
HEARTBEAT_INTERVAL_S = 30
# The heartbeat LOG cadence is separate and backs off (30s -> ... -> _MAX_GAP_S)
# so a long step does not scroll an identical "still running" line every 30s
# (mast04 ascom: 65 min of them). After _ESCALATE_S the line escalates to a WARN
# on a slower _ESCALATE_GAP_S cadence, so a genuinely stuck step stands out
# instead of blending into routine chatter.
HEARTBEAT_MAX_GAP_S = 120
HEARTBEAT_ESCALATE_S = 600
HEARTBEAT_ESCALATE_GAP_S = 300

# ---------------------------------------------------------------------------
# Logging hooks -- callers may rebind these
# ---------------------------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%SZ")


def _default_log(msg: str) -> None:
    print(f"[{_now()}] {msg}", flush=True)


def _default_log_raw(text: str) -> None:
    print(text, flush=True)


# Reassign these from a long-running orchestrator to tee into a session log.
log_fn: Callable[[str], None] = _default_log
log_raw_fn: Callable[[str], None] = _default_log_raw


def _log(msg: str) -> None:
    log_fn(msg)


def _log_raw(text: str) -> None:
    log_raw_fn(text)


def _fmt_mmss(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds}s"
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


# ---------------------------------------------------------------------------
# PS string helpers
# ---------------------------------------------------------------------------

def _ps_escape(s: str) -> str:
    """Escape a value for embedding inside a PowerShell single-quoted string."""
    return s.replace("'", "''")


# ---------------------------------------------------------------------------
# JSON helpers (BOM-tolerant)
# ---------------------------------------------------------------------------
# Windows PowerShell 5.1's `Out-File -Encoding UTF8` and `Set-Content -Encoding
# UTF8` both prepend a UTF-8 BOM. Python's plain `utf-8` codec leaves the BOM
# as a leading U+FEFF, which makes json.loads choke on the first character.
# Use these helpers anywhere we read JSON that may have been written by PS
# (commands.json, build-manifest.json, installed-manifest.json, creds.json
# touched by hand, etc.).

def load_json_file(path: Path) -> object:
    """Parse a JSON file, tolerating a leading UTF-8 BOM."""
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def parse_json_text(text: str) -> object:
    """Parse a JSON string, tolerating a leading UTF-8 BOM."""
    if text.startswith("\ufeff"):
        text = text[1:]
    return json.loads(text)


def dump_json_file(path: Path, data: object, *, indent: int = 4) -> None:
    """Write JSON to a file as plain UTF-8 + LF, no BOM (the adopted standard;
    newline='\\n' stops a Windows server translating to CRLF)."""
    Path(path).write_text(json.dumps(data, indent=indent), encoding="utf-8", newline="\n")


# ---------------------------------------------------------------------------
# Credentials / WinRM
# ---------------------------------------------------------------------------

def load_creds() -> dict[str, dict[str, str]]:
    if not VAULT_CREDS.exists():
        raise RuntimeError(
            f"Credentials file not found: {VAULT_CREDS}\n"
            "Create vault/creds.json with the format:\n"
            '  { "unit": { "user": ".\\\\mast", "pass": "..." } }'
        )
    return load_json_file(VAULT_CREDS)  # type: ignore[return-value]


# WSMan per-Receive timeout. This is NOT the overall script timeout -- pywinrm
# loops Receive requests until the command finishes, and each Receive is a
# fresh HTTP request. Keeping this short means:
#   - the server returns an empty Receive every ~30s of stdout silence, so
#     pywinrm notices a dead TCP socket within ~40s instead of the next hour
#   - when the unit's powershell.exe exits, the next poll picks up
#     CommandState=Done immediately
# The overall script timeout is enforced by _run_with_heartbeat using
# timeout_s, not by these WSMan values.
#
# Previously these were sized to WINRM_CALL_TIMEOUT_S (3600s) "to match" long
# provisioning runs. That was the wrong knob: a 13-minute silent stretch during
# ASCOM install + a transient TCP glitch left pywinrm blocked inside a single
# 3630s recv on a half-dead socket, never observing CommandState=Done -- the
# host hung for the full hour after the unit had cleanly finished and exited.
# operation_timeout drives the WSMan poll cadence (the server waits up to this
# many seconds for new output before sending an empty Receive response).
# read_timeout is the requests-side HTTP timeout and MUST be comfortably larger
# than operation_timeout, otherwise the HTTP client gives up before the server
# replies. During heavy install IO (e.g. .NET 3.5 via SYSTEM DISM scheduled
# task while ASCOM Platform installs) the unit's WinRM HTTP listener can take
# tens of seconds to flush its response, so we want a healthy margin -- the
# earlier 30/40 pair tripped a Read-timeout mid-install.
_WSMAN_OP_TIMEOUT_S = 60
_WSMAN_READ_TIMEOUT_S = 120


def winrm_session(
    host: str,
    cred: dict[str, str],
    read_timeout_s: int | None = None,
    op_timeout_s: int | None = None,
) -> winrm.Session:
    return winrm.Session(
        f"http://{host}:{WINRM_PORT}/wsman",
        auth=(cred["user"], cred["pass"]),
        transport="basic",
        read_timeout_sec=read_timeout_s if read_timeout_s is not None else _WSMAN_READ_TIMEOUT_S,
        operation_timeout_sec=op_timeout_s if op_timeout_s is not None else _WSMAN_OP_TIMEOUT_S,
    )


def _dispose_winrm_session(sess: Any | None) -> None:
    """Close a unit session (best-effort). Handles both a pywinrm Session
    (close pooled HTTP connections) and an SshSession (close the transport)."""
    if sess is None:
        return
    if isinstance(sess, SshSession):
        sess.close()
        return
    try:
        sess.protocol.transport.close_session()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# SSH fallback transport
# ---------------------------------------------------------------------------
# After the end-of-provisioning reboot the unit's link-local NIC can regress to
# the Public network profile, which makes WinRM refuse unencrypted Basic auth
# (HTTP 401) even though the box is up and TCP 5985 is open. OpenSSH (installed
# by bootstrap-winrm.ps1, port 22, password auth) survives that regression, so
# it is the resilient channel for post-reboot reconnect and verification.
#
# SshSession.run_ps mirrors the parts of pywinrm's Response that the orchestrator
# uses (status_code, std_out, std_err as bytes), so it is a drop-in for
# ``session.run_ps(...)`` call sites. SSH exec is synchronous (paramiko blocks to
# completion) so there is no Receive loop to make resilient -- _resilient_run_ps
# detects an SshSession and calls run_ps directly.

SSH_PORT = 22


def _ssh_username(raw_user: str) -> str:
    """vault user may be '.\\mast' or 'HOST\\mast'; SSH wants the bare local name."""
    u = (raw_user or "").strip()
    if u.startswith(".\\"):
        return u[2:]
    if "\\" in u:
        return u.split("\\")[-1]
    return u


class _SshResponse:
    """Minimal stand-in for winrm.Response (status_code, std_out, std_err bytes)."""

    def __init__(self, status_code: int, std_out: bytes, std_err: bytes) -> None:
        self.status_code = status_code
        self.std_out = std_out
        self.std_err = std_err


class SshSession:
    """pywinrm-Session-compatible wrapper over a paramiko SSH connection.

    Only run_ps() is implemented -- the orchestrator never runs cmd.exe on the
    unit. Each run_ps() opens a fresh exec channel; the transport is reused
    across calls. Call close() when done (or hand to _dispose_winrm_session).
    """

    def __init__(
        self,
        host: str,
        cred: dict[str, str],
        port: int = SSH_PORT,
        connect_timeout_s: int = 30,
    ) -> None:
        try:
            import paramiko  # lazy: keep vm_lib import-pure and paramiko optional
        except ImportError as e:
            raise RuntimeError(
                "paramiko is required for the SSH fallback (pip install paramiko)."
            ) from e
        self.host = host
        self._user = _ssh_username(cred["user"])
        client = paramiko.SSHClient()
        # The unit's host key is not pre-pinned in this lab pipeline; accept it.
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            hostname=host,
            port=port,
            username=self._user,
            password=cred["pass"],
            timeout=connect_timeout_s,
            banner_timeout=connect_timeout_s,
            auth_timeout=connect_timeout_s,
            allow_agent=False,
            look_for_keys=False,
        )
        self._client = client

    def run_ps(self, script: str, timeout_s: float | None = None) -> _SshResponse:
        # Mirror pywinrm: hand powershell the script as a UTF-16LE base64
        # -EncodedCommand so quoting/newlines survive the SSH command line intact.
        enc = base64.b64encode(script.encode("utf_16_le")).decode("ascii")
        cmd = (
            "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass "
            f"-EncodedCommand {enc}"
        )
        # Key completion off the command's EXIT STATUS, not channel EOF. A
        # detached grandchild (a service started by mast-services-finalize/NSSM,
        # or the net-use Start-Job in mast-pull-staging.ps1) can inherit the
        # stdout handle and hold the pipe open long after the invoked
        # powershell.exe has exited; a `stdout.read()` to EOF then blocks until
        # the caller's timeout even though the command finished (observed as the
        # transfer/execute run_ps "hang" on 2026-07-21). exit_status_ready() goes
        # true when the command process exits regardless of the lingering handle,
        # so drain whatever is buffered and return on that -- never wait for EOF.
        #
        # timeout_s bounds the loop so a *genuinely* stuck command (one that
        # never sends exit-status) bails here rather than spinning forever: the
        # _run_with_heartbeat watchdog raises TimeoutError in the caller thread,
        # but this loop runs in a daemon worker thread that Python cannot kill,
        # so without its own deadline the thread + channel would leak across
        # --loop cycles (#10 "bound the SSH exec channel"). On the deadline we
        # raise and the finally tears the channel down.
        chan = self._client.get_transport().open_session()
        try:
            chan.exec_command(cmd)
            deadline = None if timeout_s is None else time.monotonic() + timeout_s
            out = bytearray()
            err = bytearray()
            while True:
                while chan.recv_ready():
                    out += chan.recv(65536)
                while chan.recv_stderr_ready():
                    err += chan.recv_stderr(65536)
                if chan.exit_status_ready():
                    while chan.recv_ready():
                        out += chan.recv(65536)
                    while chan.recv_stderr_ready():
                        err += chan.recv_stderr(65536)
                    break
                if deadline is not None and time.monotonic() >= deadline:
                    raise TimeoutError(
                        f"SSH run_ps exceeded {timeout_s}s with no exit status"
                    )
                time.sleep(0.1)
            rc = chan.recv_exit_status()
            return _SshResponse(rc, bytes(out), bytes(err))
        finally:
            chan.close()

    def put_file(self, remote_path: str, data: bytes) -> None:
        """Write bytes to a Windows path over SFTP. Avoids the base64-over-
        EncodedCommand upload, which busts cmd.exe's ~8191 command-line limit
        when OpenSSH's default shell is cmd.exe (seen uploading the pull script).
        Windows OpenSSH's sftp-server accepts forward-slash paths."""
        sftp = self._client.open_sftp()
        try:
            with sftp.file(remote_path.replace("\\", "/"), "wb") as f:
                f.write(data)
        finally:
            sftp.close()

    def close(self) -> None:
        try:
            self._client.close()
        except Exception:
            pass


def ssh_session(
    host: str, cred: dict[str, str], port: int = SSH_PORT, connect_timeout_s: int = 30
) -> SshSession:
    """Factory mirroring winrm_session(): construct an SSH session to the unit."""
    return SshSession(host, cred, port=port, connect_timeout_s=connect_timeout_s)


def wait_for_ssh(
    host: str, cred: dict[str, str], timeout: int = WINRM_BOOT_TIMEOUT_S, port: int = SSH_PORT
) -> SshSession:
    """Poll until an SSH session authenticates (unit booted + sshd up). Returns it."""
    _log(f"Waiting for SSH on {host}:{port} (up to {timeout}s)...")
    deadline = time.monotonic() + timeout
    last_err = ""
    while time.monotonic() < deadline:
        try:
            s = ssh_session(host, cred, port=port, connect_timeout_s=20)
            _log(f"SSH on {host} is ready (user={_ssh_username(cred['user'])!r}).")
            return s
        except Exception as e:
            last_err = f"{type(e).__name__}: {e}"
            time.sleep(5)
    raise TimeoutError(f"SSH on {host}:{port} not ready after {timeout}s. Last: {last_err}")


def _winrm_probe_once(
    host: str, cred: dict[str, str], users: list[str]
) -> tuple[winrm.Session | None, str]:
    """One WinRM reachability probe. Returns (session, state) where state is:
    'ok' (session usable, returned), 'auth_rejected' (TCP open, Basic refused --
    the post-reboot Public-profile regression), or 'down' (TCP closed / other)."""
    try:
        with socket.create_connection((host, WINRM_PORT), timeout=5):
            pass
    except OSError:
        return (None, "down")
    rejected = False
    for usr in users:
        s: winrm.Session | None = None
        try:
            s = winrm.Session(
                f"http://{host}:{WINRM_PORT}/wsman",
                auth=(usr, cred["pass"]),
                transport="basic",
                read_timeout_sec=30,
                operation_timeout_sec=20,
            )
            r = s.run_cmd("echo", ["ping"])
            if r.status_code == 0:
                cred["user"] = usr
                # Hand back a fresh session with default timeouts for real work.
                return (winrm_session(host, cred), "ok")
        except winrm.exceptions.InvalidCredentialsError:
            rejected = True
        except Exception:
            pass
        finally:
            _dispose_winrm_session(s)
    return (None, "auth_rejected" if rejected else "down")


def connect_unit(
    host: str,
    cred: dict[str, str],
    winrm_wait_s: int = WINRM_BOOT_TIMEOUT_S,
    allow_ssh_fallback: bool = True,   # kept for call-site compat; unused when prefer='ssh'
    prefer: str = "ssh",
) -> Any:
    """Return a unit session exposing .run_ps() -- an SshSession by default, a
    pywinrm Session only as fallback.

    SSH-first (the adopted direction, DECISIONS.md 2026-07-12): SSH is encrypted,
    uniform across server OSes, and already the channel that survives the
    post-reboot Public-profile 401 that makes WinRM Basic refuse. WinRM is kept
    as a fallback until item 6's detached-execute lands, after which it retires
    (pass prefer='winrm' to force the legacy order). Keeps waiting up to
    winrm_wait_s while the unit is still booting; raises if neither comes up."""
    _log(f"Connecting to unit {host} ({prefer}-first, {'WinRM' if prefer == 'ssh' else 'SSH'} fallback)...")
    deadline = time.monotonic() + winrm_wait_s
    users = _candidate_users(host, cred.get("user", "")) or [cred.get("user", "")]
    while time.monotonic() < deadline:
        if prefer == "ssh":
            try:
                s = ssh_session(host, cred, connect_timeout_s=20)
                _log(f"Connected to {host} over SSH (user={_ssh_username(cred['user'])!r}).")
                return s
            except Exception as e:
                _log(f"  SSH not ready yet ({type(e).__name__}: {e}); trying WinRM fallback...")
            sess, state = _winrm_probe_once(host, cred, users)
            if state == "ok":
                _log(f"Connected to {host} over WinRM fallback (user={cred['user']!r}).")
                return sess
        else:  # legacy WinRM-first (post-reboot 401 -> SSH)
            sess, state = _winrm_probe_once(host, cred, users)
            if state == "ok":
                _log(f"Connected to {host} over WinRM (user={cred['user']!r}).")
                return sess
            if state == "auth_rejected" and allow_ssh_fallback:
                try:
                    s = ssh_session(host, cred, connect_timeout_s=20)
                    _log(f"Connected to {host} over SSH (user={_ssh_username(cred['user'])!r}).")
                    return s
                except Exception as e:
                    _log(f"  SSH not ready yet ({type(e).__name__}: {e}); will keep trying.")
        time.sleep(5)
    _log(f"Neither channel usable within {winrm_wait_s}s; final SSH attempt...")
    return wait_for_ssh(host, cred, timeout=60)


def _candidate_users(host: str, raw_user: str) -> list[str]:
    # vault/creds.json user may be '.\\mast'. pywinrm on some hosts accepts 'mast' instead.
    # Try a small set of common equivalences without guessing domains.
    u = (raw_user or "").strip()
    if not u:
        return []
    candidates: list[str] = [u]
    if u.startswith(".\\"):
        candidates.append(u[2:])
    elif "\\" in u:
        candidates.append(u.split("\\")[-1])
    else:
        # Bare local user (e.g. 'mast'): also try the explicit local-machine
        # form '.\\mast' that some hosts require for Basic auth.
        candidates.append(f".\\{u}")
    # If host is an IPv4, try <host>\\user (workgroup-style).
    if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", host):
        base = u[2:] if u.startswith(".\\") else (u.split("\\")[-1] if "\\" in u else u)
        candidates.append(f"{host}\\{base}")
    # de-dupe preserving order
    seen: set[str] = set()
    out: list[str] = []
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return out


def _run_with_heartbeat(
    fn: Any,
    label: str,
    timeout_s: int = WINRM_CALL_TIMEOUT_S,
    step_timer: list[float] | None = None,
) -> Any:
    result: list[Any] = []
    exc: list[BaseException] = []

    def worker() -> None:
        try:
            result.append(fn())
        except BaseException as e:
            exc.append(e)

    t = threading.Thread(target=worker, daemon=True)
    start = time.monotonic()
    t.start()
    last_log = start
    log_gap = HEARTBEAT_INTERVAL_S
    while t.is_alive():
        t.join(timeout=HEARTBEAT_INTERVAL_S)
        if t.is_alive():
            now = time.monotonic()
            elapsed = int(now - start)
            # Timeout is checked every interval, but LOG on a backing-off /
            # escalating cadence so a long step does not repeat identically.
            if (now - last_log) >= log_gap:
                step_start = step_timer[0] if step_timer is not None else start
                step = int(now - step_start)
                if elapsed >= HEARTBEAT_ESCALATE_S:
                    _log(
                        f"  [WARN] {label} STILL running after {_fmt_mmss(elapsed)} "
                        f"(step {_fmt_mmss(step)}) - unusually long, may be stuck"
                    )
                    log_gap = HEARTBEAT_ESCALATE_GAP_S
                else:
                    _log(f"  ... {label} still running ({_fmt_mmss(elapsed)} elapsed, step {_fmt_mmss(step)})")
                    log_gap = min(HEARTBEAT_MAX_GAP_S, log_gap * 2)
                last_log = now
            if elapsed >= timeout_s:
                raise TimeoutError(
                    f"{label} exceeded {timeout_s}s timeout - likely hung"
                )
    if exc:
        raise exc[0]
    return result[0]


def _unescape_clixml_fragment(s: str) -> str:
    s = s.replace("_x000D__x000A_", " ").replace("_x000A_", " ").replace("_x000D_", " ")
    return " ".join(s.split())


def _format_winrm_stderr(text: str, max_len: int = 900) -> str:
    """Turn noisy WinRM / CLIXML stderr into one readable line for the host log."""
    t = text.strip()
    if not t:
        return ""
    # Remote PowerShell often prefixes the CLIXML envelope on stderr.
    t = re.sub(r"^#<\s*CLIXML\s*", "", t, flags=re.IGNORECASE).strip()
    if not t:
        return ""

    if "<Objs" in t:
        chunks: list[str] = []
        for tag in ("Error", "Warning"):
            for m in re.findall(rf'<S S="{tag}">(.*?)</S>', t, flags=re.DOTALL):
                chunks.append(_unescape_clixml_fragment(m))
        if chunks:
            t = " ".join(chunks)
        else:
            # Progress / Information CLIXML on stderr (no Error or Warning stream).
            # It duplicates normal host messages and floods the log; drop it.
            return ""

    for marker in ("At line:", "At ", "    + CategoryInfo", "    + FullyQualifiedErrorId"):
        if marker in t:
            t = t.split(marker)[0].rstrip()
            break
    t = " ".join(t.split())
    if len(t) > max_len:
        return t[: max_len - 3] + "..."
    return t


# How long we keep retrying Receive against the same shell_id+command_id when
# the unit's WinRM service is transiently unresponsive (HTTP read/connect
# timeouts, transport errors). The shell and command stay alive on the server
# through its IdleTimeout window, so a fresh Receive picks up wherever the
# previous one was cut off -- no work is lost, no state on the unit is
# disturbed. 10 minutes comfortably covers the worst stretch observed during
# heavy install IO (.NET 3.5 via SYSTEM DISM scheduled task + ASCOM Platform
# installer hammering the box for several minutes with no output, sometimes
# wedging the WinRM listener for 2+ minutes per stall).
_TRANSIENT_RETRY_BUDGET_S = 10 * 60
# Brief backoff between retry attempts. Short enough that recovery is prompt,
# long enough that we don't hammer a wedged WinRM listener.
_TRANSIENT_RETRY_BACKOFF_S = 3

# Exception types that pywinrm/requests raise when the underlying HTTP call
# to the WinRM listener fails or times out. The shell on the unit is unaware
# of any of these -- they only mean "this particular Receive request didn't
# get a reply" -- so the safe response is to retry the Receive (against the
# same shell+command IDs), not to tear down the shell.
#
# winrm.exceptions.WinRMTransportError covers 5xx / proxy / transport hiccups
# from the listener; auth failures and fatal protocol errors raise different
# exception types and will propagate.
_TRANSIENT_RECEIVE_EXCEPTIONS: tuple[type[BaseException], ...] = (
    requests.exceptions.ReadTimeout,
    requests.exceptions.ConnectTimeout,
    requests.exceptions.ConnectionError,
    requests.exceptions.ChunkedEncodingError,
    winrm.exceptions.WinRMTransportError,
)


def _evict_winrm_connection_pool(protocol: Any) -> None:
    """Close the requests.Session backing this pywinrm protocol so the next
    request dials a fresh TCP connection.

    Why: a stale half-dead pooled connection (e.g. surviving a NAT/firewall
    idle-drop on the host side) makes every retry hit the same broken socket
    and time out identically; rebuilding the local pool is the in-code
    equivalent of the "reboot the host" cure. The WSMan shell state is
    server-side and keyed by shell_id GUID, so a fresh socket carrying a
    Receive for the same shell continues exactly where the previous one
    was cut off.
    """
    try:
        protocol.transport.session.close()
    except Exception:
        # Whatever requests/urllib3 version is in use, close() is best-effort.
        # If it raises, the next .post() will rebuild the pool anyway.
        pass


def _resilient_get_command_output(
    protocol: Any,
    shell_id: str,
    command_id: str,
    *,
    log_label: str,
    transient_retry_budget_s: int,
) -> tuple[bytes, bytes, int]:
    """pywinrm's Receive loop, but tolerant of transient HTTP failures.

    pywinrm's built-in Protocol.get_command_output silently swallows
    WinRMOperationTimeoutError (the expected WSMan-level "no output yet,
    just keep polling" signal). It does NOT handle requests-level errors
    such as ReadTimeout / ConnectTimeout, which surface whenever the unit's
    WinRM listener stalls during heavy install IO. When that happens we
    evict the local connection pool and issue another Receive against the
    same shell+command IDs -- the server has the output buffered and
    waiting -- and pick up exactly where we left off. Budget tracks total
    time spent in the *failed* state and resets on every successful Receive,
    so each fresh glitch gets the full grace window.
    """
    stdout_chunks: list[bytes] = []
    stderr_chunks: list[bytes] = []
    return_code = 0
    command_done = False
    transient_deadline: float | None = None
    transient_first_err: str | None = None

    while not command_done:
        try:
            stdout, stderr, return_code, command_done = (
                protocol._raw_get_command_output(shell_id, command_id)
            )
            stdout_chunks.append(stdout)
            stderr_chunks.append(stderr)
            if transient_deadline is not None:
                _log(f"  ... {log_label} WinRM recovered after transient errors")
            transient_deadline = None
            transient_first_err = None
        except WinRMOperationTimeoutError:
            # Expected: server returned an empty Receive because no new output
            # arrived within operation_timeout_sec. The command is still alive
            # on the unit; just issue another Receive immediately.
            continue
        except _TRANSIENT_RECEIVE_EXCEPTIONS as e:
            now = time.monotonic()
            if transient_deadline is None:
                transient_deadline = now + transient_retry_budget_s
                transient_first_err = f"{type(e).__name__}: {e}"
                _log(
                    f"  ... {log_label} transient WinRM error ({transient_first_err}); "
                    f"will retry up to {transient_retry_budget_s}s against the same shell"
                )
            elif now >= transient_deadline:
                raise RuntimeError(
                    f"{log_label} gave up after {transient_retry_budget_s}s of "
                    f"transient WinRM errors (first: {transient_first_err}; last: "
                    f"{type(e).__name__}: {e})"
                ) from e
            _evict_winrm_connection_pool(protocol)
            time.sleep(_TRANSIENT_RETRY_BACKOFF_S)

    return b"".join(stdout_chunks), b"".join(stderr_chunks), return_code


def _resilient_run_ps(
    session: winrm.Session,
    script: str,
    *,
    log_label: str,
    transient_retry_budget_s: int = _TRANSIENT_RETRY_BUDGET_S,
    timeout_s: float | None = None,
) -> winrm.Response:
    """Drop-in replacement for ``session.run_ps`` that survives transient
    WinRM HTTP failures without abandoning the running command on the unit.

    Mirrors pywinrm's Session.run_ps (UTF-16 LE base64 encoding so the unit's
    powershell.exe accepts the script as an -EncodedCommand) but drives the
    Receive loop ourselves via the lower-level Protocol API so we can retry
    transient HTTP failures against the same shell + command IDs.

    Shell and command IDs are released in finally blocks; the WinRM listener
    will also reap the shell on its idle timer if cleanup itself fails.

    An SshSession is synchronous (paramiko exec blocks to completion) and has no
    Receive loop to make resilient, so it is run directly via its own run_ps.
    """
    if isinstance(session, SshSession):
        return session.run_ps(script, timeout_s=timeout_s)

    encoded = base64.b64encode(script.encode("utf_16_le")).decode("ascii")
    command_line = f"powershell -encodedcommand {encoded}"

    protocol = session.protocol
    shell_id = protocol.open_shell()
    try:
        command_id = protocol.run_command(shell_id, command_line)
        try:
            stdout, stderr, return_code = _resilient_get_command_output(
                protocol,
                shell_id,
                command_id,
                log_label=log_label,
                transient_retry_budget_s=transient_retry_budget_s,
            )
        finally:
            try:
                protocol.cleanup_command(shell_id, command_id)
            except Exception as e:
                _log(f"  ... {log_label} cleanup_command failed (ignored): {e}")
    finally:
        try:
            protocol.close_shell(shell_id)
        except Exception as e:
            _log(f"  ... {log_label} close_shell failed (ignored): {e}")

    # Match pywinrm's stderr post-processing for parity with session.run_ps.
    if stderr:
        stderr = session._clean_error_msg(stderr)  # type: ignore[attr-defined]
    return winrm.Response((stdout, stderr, return_code))


def winrm_encoded_cmd_len(script: str) -> int:
    """Length of the base64 -EncodedCommand argument PowerShell receives for
    `script` over WinRM (encoded UTF-16LE, then base64).

    Pure function -- unit-testable without a live session, which is the point:
    the inline-dispatch size limit is logic we want covered by fast unit tests,
    not only discovered by an e2e run failing remotely.
    """
    return len(base64.b64encode(script.encode("utf-16-le")))


def assert_inline_dispatchable(script: str, label: str = "") -> None:
    """Raise ValueError if `script` is too large for inline WinRM EncodedCommand
    dispatch (cmd.exe caps the command line at ~8191 chars).

    Lets callers fail fast and LOCALLY instead of sending an oversized command
    that the WinRM service rejects remotely with 'The command line is too long'
    (which forces a remote-log dig to diagnose). Large scripts must be
    file-dispatched (upload + invoke by path), e.g. run-prov-test.phase_transfer.
    """
    n = winrm_encoded_cmd_len(script)
    if n > WINRM_ENCODED_CMD_MAX:
        tag = f"[{label}] " if label else ""
        raise ValueError(
            f"{tag}script too large for inline WinRM dispatch: {n} encoded chars "
            f"> {WINRM_ENCODED_CMD_MAX} ({len(script)} source chars). Dispatch it "
            f"by file (upload + invoke by path) instead."
        )


def _minify_ps(raw: str) -> str:
    """Strip block comments (<#...#>), whole-line # comments, blank lines, and
    leading whitespace from a PowerShell script, shrinking an inline-dispatched
    payload toward the EncodedCommand limit without changing behavior. Mid-line
    trailing # comments are NOT stripped (some are syntactic). Pure -- unit-
    testable, and paired with assert_inline_dispatchable() above.
    """
    s = re.sub(r"<#.*?#>", "", raw, flags=re.DOTALL)
    out: list[str] = []
    for ln in s.splitlines():
        stripped = ln.strip()
        if not stripped or stripped.startswith("#"):
            continue
        out.append(stripped)
    return "\n".join(out)


def run_ps(
    session: winrm.Session,
    script: str,
    *,
    label: str = "",
    timeout_s: int = WINRM_CALL_TIMEOUT_S,
    echo: bool = True,
    tee_stdout: bool = True,
    step_timer: list[float] | None = None,
) -> winrm.Response:
    """Run a PowerShell script via WinRM with heartbeat logging and a hard timeout.

    Uses _resilient_run_ps under the hood so a transient WinRM hiccup during
    a long-running command (e.g. WinRM listener wedged during heavy install
    IO) does not abandon the running command on the unit. The hard ceiling
    is still enforced by _run_with_heartbeat via timeout_s.

    tee_stdout=False suppresses echoing the remote stdout to the log sink -- use
    it for internal probes whose stdout is a marker/JSON payload the caller parses
    (e.g. inventory, smoke, proxy, the base64 archive pull), so those do not flood
    the controller log; the caller still gets the bytes on the returned Response.
    """
    tag = f"[{label}] " if label else ""
    # Fail fast & locally on oversized inline dispatch. This applies to SSH too:
    # Windows OpenSSH's exec runs the command through cmd.exe (~8191-char limit),
    # so a large -EncodedCommand busts it there as well (seen uploading the pull
    # script -- now sent via SFTP). Large payloads must be file/SFTP-dispatched.
    assert_inline_dispatchable(script, label)
    if echo:
        _log(f"{tag}>>> {script[:120].rstrip()}")
    r = _run_with_heartbeat(
        lambda: _resilient_run_ps(
            session, script, log_label=f"{tag}run_ps", timeout_s=timeout_s
        ),
        label=f"{tag}run_ps",
        timeout_s=timeout_s,
        step_timer=step_timer,
    )
    if tee_stdout and r.std_out:
        _log_raw(r.std_out.decode(errors="replace").rstrip())
    if r.std_err:
        brief = _format_winrm_stderr(r.std_err.decode(errors="replace"))
        if brief:
            _log_raw(f"[stderr] {brief}")
    return r


def check_rc(r: winrm.Response, phase: str) -> None:
    if r.status_code != 0:
        raise RuntimeError(f"{phase} failed with exit code {r.status_code}")


def wait_for_winrm(host: str, cred: dict[str, str], timeout: int = WINRM_BOOT_TIMEOUT_S) -> None:
    _log(f"Waiting for WinRM on {host} (up to {timeout}s)...")
    deadline = time.monotonic() + timeout
    users = _candidate_users(host, cred.get("user", ""))
    last_diag = 0.0
    while time.monotonic() < deadline:
        tcp_ok = False
        try:
            with socket.create_connection((host, WINRM_PORT), timeout=5):
                tcp_ok = True
        except OSError:
            pass

        auth_errors: list[str] = []
        if tcp_ok:
            for usr in users or [cred.get("user", "")]:
                s: winrm.Session | None = None
                try:
                    s = winrm.Session(
                        f"http://{host}:{WINRM_PORT}/wsman",
                        auth=(usr, cred["pass"]),
                        transport="basic",
                        read_timeout_sec=30,
                        operation_timeout_sec=20,
                    )
                    r = s.run_cmd("echo", ["ping"])
                    if r.status_code == 0:
                        cred["user"] = usr
                        _log(f"WinRM on {host} is ready (user={usr!r}).")
                        return
                except Exception as e:
                    auth_errors.append(f"{usr!r}:{type(e).__name__}")
                    continue
                finally:
                    _dispose_winrm_session(s)

        now = time.monotonic()
        if now - last_diag >= 60:
            if tcp_ok:
                tail = "; ".join(auth_errors[-4:]) if auth_errors else "no auth attempts"
                _log(
                    f"WinRM: TCP {WINRM_PORT} open on {host} but Basic auth not accepted yet ({tail}). "
                    "Confirm vault/creds.json matches the unit mast password and that bootstrap-winrm.ps1 "
                    "finished (a Public network profile can also make WinRM Basic return 401)."
                )
            else:
                _log(f"WinRM: TCP {WINRM_PORT} not open on {host} yet (still booting or wrong host?).")
            last_diag = now
        time.sleep(5)
    raise TimeoutError(f"WinRM on {host} did not become reachable within {timeout}s")


# ---------------------------------------------------------------------------
# File transfer
# ---------------------------------------------------------------------------

def upload_file_b64(
    session: winrm.Session,
    remote_path: str,
    content: str,
    label: str = "file",
    chunk_size: int = 10000,
) -> None:
    """Upload text content to a Windows path via base64 chunks over WinRM.

    Avoids PowerShell single-quote escaping issues that arise when passing
    raw source files inline. The content is split into chunk_size base64
    segments and reassembled remotely before being decoded and written.
    """
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    chunks = [b64[i:i + chunk_size] for i in range(0, len(b64), chunk_size)]
    ps_lines = ["$chunks = @()"]
    for chunk in chunks:
        ps_lines.append(f"$chunks += '{chunk}'")
    remote_path_ps = _ps_escape(remote_path)
    ps_lines += [
        "$b64 = [string]::Join('', $chunks)",
        "$bytes = [Convert]::FromBase64String($b64)",
        f"[System.IO.File]::WriteAllBytes('{remote_path_ps}', $bytes)",
        f"Write-Host 'Wrote {_ps_escape(label)} ({len(content)} chars)'",
    ]
    ps = "\n".join(ps_lines)
    r = session.run_ps(ps)
    out = (r.std_out or b"").decode(errors="replace").strip()
    if out:
        _log_raw(out)
    if r.status_code != 0:
        err = (r.std_err or b"").decode(errors="replace").strip()
        raise RuntimeError(f"upload_file_b64 failed for {label}: exit {r.status_code}: {err}")


def upload_file(session: Any, remote_path: str, content: str, label: str = "file") -> None:
    """Upload text content to a Windows path, transport-appropriately: SFTP over
    SSH (no command-line-length limit), base64-over-run_ps over WinRM (WSMan has
    no cmd.exe limit). Prefer this over upload_file_b64 at call sites."""
    if isinstance(session, SshSession):
        session.put_file(remote_path, content.encode("utf-8"))
        _log(f"Uploaded {label} via SFTP ({len(content)} chars)")
    else:
        upload_file_b64(session, remote_path, content, label=label)


# ---------------------------------------------------------------------------
# Public API. vm_lib re-exports this surface (plus a few underscored helpers it
# and its tests use) so existing `from vm_lib import ...` call sites keep working.
# ---------------------------------------------------------------------------
__all__ = [
    # constants
    "REPO_ROOT", "VAULT_CREDS", "WINRM_PORT", "WINRM_ENCODED_CMD_MAX",
    "WINRM_CALL_TIMEOUT_S", "WINRM_BOOT_TIMEOUT_S", "SSH_PORT",
    "HEARTBEAT_INTERVAL_S", "HEARTBEAT_MAX_GAP_S",
    "HEARTBEAT_ESCALATE_S", "HEARTBEAT_ESCALATE_GAP_S",
    # log sinks (rebindable)
    "log_fn", "log_raw_fn",
    # json helpers
    "load_json_file", "parse_json_text", "dump_json_file",
    # creds + transport
    "load_creds", "winrm_session", "ssh_session", "wait_for_ssh",
    "connect_unit", "wait_for_winrm", "run_ps", "check_rc",
    "upload_file", "upload_file_b64", "winrm_encoded_cmd_len", "assert_inline_dispatchable",
    "SshSession",
]
