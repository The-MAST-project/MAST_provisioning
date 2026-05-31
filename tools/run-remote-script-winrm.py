#!/usr/bin/env python3
"""
Run a local .ps1 on a remote Windows unit over WinRM HTTP + Basic auth.

Uses chunked upload so command size stays under WinRM limits. Does not require elevation on
THIS machine (no TrustedHosts / Enable-PSRemoting). Matches production constraint: prov server
runs as an unprivileged service using pywinrm-style HTTP Basic.

Observability (guest):
  - Sets env MAST_RUN_ID, MAST_REMOTE_SCRIPT_REPO, MAST_REMOTE_SCRIPT_PATH, MAST_REMOTE_LOG_ROOT.
  - Writes transcript + JSON summary under <SystemDrive>\\MAST\\logs\\remote-runs\\<timestamp>_<run_id>\\
    (unless --no-remote-transcript; JSON is always written).
  - Emits ##MAST## lines on stdout; this driver mirrors them to stderr as [guest] lines.

Examples:
  python tools/run-remote-script-winrm.py --host mast01 --vault vault/creds.json \\
    --script client/prepare-mast-client.ps1 \\
    --invoke-args "-HostName mast01 -Provider 192.168.56.1"

  python tools/run-remote-script-winrm.py ... --write-local-meta meta-last-run.json

  # Fast connect only (no reboot wait):
  python tools/run-remote-script-winrm.py ... --wait-winrm-seconds 0

Credentials: vault/creds.json unit.user / unit.pass (same as run-prov-test.py).

Troubleshooting (orchestrator hangs after guest appears finished):
  - The wrapper no longer calls Stop-Transcript after your script (that call could hang forever under
    WinRM even when the child .ps1 finished). Guest scripts that recycle WinRM can still drop the
    session; prepare-mast-client.ps1 defers HTTPS listener work and emits ##MAST## prepare_safe_complete
    first (see autonomous-provisioning-requirements.md). Use --no-remote-transcript to skip
    Start-Transcript entirely if the transcript file causes trouble.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import winrm
from winrm.exceptions import InvalidCredentialsError

# Shared WinRM/PS helpers live in vm/vm_lib.py (canonical source of truth -- see
# CLAUDE.md DRY rules). tools/ is not on sys.path next to vm/, so add it.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vm"))
from vm_lib import _candidate_users, _ps_escape, winrm_session  # noqa: E402

CHUNK = 800
WINRM_PORT = 5985


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _ts() -> str:
    return datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def obs(msg: str, *, quiet: bool) -> None:
    if not quiet:
        print(f"[{_ts()}] {msg}", file=sys.stderr, flush=True)


def emit_guest_mast_lines(stdout: bytes, stderr: bytes) -> None:
    """Mirror ##MAST## lines from guest output to orchestrator stderr (structured observability)."""
    blob = b""
    if stdout:
        blob += stdout + b"\n"
    if stderr:
        blob += stderr
    for line in blob.decode(errors="replace").splitlines():
        if "##MAST##" not in line:
            continue
        # WinRM often embeds Write-Host output inside CLIXML; avoid dumping the entire XML blob.
        if "<Objs" in line or line.lstrip().startswith("<"):
            # Try to salvage just the marker payload if present.
            idx = line.find("##MAST##")
            if idx >= 0:
                msg = line[idx:].strip()
                # Trim any appended CLIXML fragments.
                cut = msg.find("<")
                if cut > 0:
                    msg = msg[:cut].rstrip()
                if msg:
                    print(f"[{_ts()}] [guest] {msg}", file=sys.stderr, flush=True)
            continue
        idx = line.find("##MAST##")
        msg = line[idx:].strip() if idx >= 0 else line.strip()
        # If CLIXML fragments are appended after the marker, trim at the first '<'.
        lt = msg.find("<")
        if lt > 0:
            msg = msg[:lt].rstrip()
        if msg:
            print(f"[{_ts()}] [guest] {msg}", file=sys.stderr, flush=True)


def _strip_powershell_clixml(text: str) -> str:
    """Remove WinRM/PowerShell CLIXML noise from output.

    pywinrm often returns progress/information records encoded as CLIXML (starts with '#< CLIXML').
    That blob is not human-friendly and can dwarf the real output. Keep only the plain-text portion.
    """
    idx = text.find("#< CLIXML")
    if idx >= 0:
        text = text[:idx]
    # Some hosts still include raw <Objs ...> without the '#< CLIXML' sentinel.
    lines: list[str] = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith("<Objs ") or s.startswith("<Obj ") or s.startswith("</Objs>"):
            continue
        lines.append(ln)
    return "\n".join(lines) + ("\n" if lines else "")


def _drop_mast_marker_lines(text: str) -> str:
    """Remove lines containing ##MAST## (already mirrored to stderr as [guest])."""
    kept: list[str] = []
    for ln in text.splitlines():
        if "##MAST##" in ln:
            continue
        kept.append(ln)
    return "\n".join(kept) + ("\n" if kept else "")


def _decode_and_clean(b: bytes | None, *, drop_markers: bool) -> str:
    if not b:
        return ""
    s = b.decode(errors="replace")
    s = _strip_powershell_clixml(s)
    if drop_markers:
        s = _drop_mast_marker_lines(s)
    return s


def _guest_log_root_default() -> str:
    # C:\MAST\logs\remote-runs\<stamp>_<run_id>\ on typical installs.
    # (Some environments may not have C: as SystemDrive; we'll print actual paths used.)
    return r"(Join-Path $env:SystemDrive 'MAST\logs\remote-runs')"


def print_guest_remote_runs_listing(session: winrm.Session, *, quiet: bool) -> None:
    """Best-effort: show where remote-runs would be and what's present."""
    ps = (
        "$root = "
        + _guest_log_root_default()
        + "; "
        'Write-Host ("##MAST## kind=remote_runs_root root=" + $root); '
        "if (Test-Path -LiteralPath $root) { "
        "  $items = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | "
        "            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 20); "
        '  Write-Host ("##MAST## kind=remote_runs_list count=" + $items.Count); '
        "  foreach ($it in $items) { "
        '    Write-Host ("##MAST## kind=remote_runs_item name=" + $it.FullName + " bytes=" + $it.Length + " mtime=" + ($it.LastWriteTime.ToUniversalTime().ToString(\'yyyy-MM-ddTHH:mm:ssZ\'))); '
        "  } "
        "} else { "
        '  Write-Host "##MAST## kind=remote_runs_list count=0 missing=true"; '
        "}"
    )
    try:
        r = run_ps_interruptible(session, ps, quiet=quiet, label="list guest remote-runs")
        emit_guest_mast_lines(r.std_out or b"", r.std_err or b"")
        out = _decode_and_clean(r.std_out, drop_markers=True)
        err = _decode_and_clean(r.std_err, drop_markers=True)
        if out:
            sys.stdout.write(out)
        if err:
            sys.stderr.write(err)
    except Exception as e:
        obs(f"warning: failed to list guest remote-runs: {e!r}", quiet=quiet)


def build_remote_invoke(
    invoke_tail: str,
    run_id: str,
    script_repo_rel: str,
    *,
    transcript: bool,
) -> str:
    """PowerShell executed on the unit after the staged script is decoded to $ps1.

    Sets MAST_RUN_ID, optional Start-Transcript, runs the script, writes JSON summary on unit,
    and prints ##MAST## marker lines for the orchestrator and log processors.

    Does not call Stop-Transcript in finally (can hang indefinitely under WinRM after the child
    script returns). Transcript file handles close when the remote process exits after remote_run_end.
    """
    rid = _ps_escape(run_id)
    repo = _ps_escape(script_repo_rel.replace("\\", "/"))
    mast_skip = "$true" if not transcript else "$false"
    # invoke_tail is appended raw after & $ps1 (same as legacy behavior).
    return (
        "$mastSkipTx = "
        + mast_skip
        + "; "
        "$env:MAST_RUN_ID = '"
        + rid
        + "'; "
        "$env:MAST_REMOTE_INVOKER = 'run-remote-script-winrm.py'; "
        "$env:MAST_REMOTE_SCRIPT_REPO = '"
        + repo
        + "'; "
        "$mastRunId = $env:MAST_RUN_ID; "
        "$mastStamp = Get-Date -Format 'yyyyMMdd-HHmmss'; "
        "$mastLogRoot = Join-Path $env:SystemDrive ('MAST\\logs\\remote-runs\\' + $mastStamp + '_' + $mastRunId); "
        "$env:MAST_REMOTE_LOG_ROOT = $mastLogRoot; "
        "$null = New-Item -ItemType Directory -Force -Path $mastLogRoot; "
        "$mastLog = Join-Path $mastLogRoot ('remote-' + $env:COMPUTERNAME + '-' + $mastRunId + '.log'); "
        "$mastMeta = Join-Path $mastLogRoot ('remote-' + $env:COMPUTERNAME + '-' + $mastRunId + '.json'); "
        "$b64 = Join-Path $env:TEMP 'mast-remote.b64'; "
        "$ps1 = Join-Path $env:TEMP 'mast-remote.ps1'; "
        "$t = [IO.File]::ReadAllText($b64); "
        "[IO.File]::WriteAllBytes($ps1, [Convert]::FromBase64String($t)); "
        "Remove-Item -LiteralPath $b64 -Force; "
        "$env:MAST_REMOTE_SCRIPT_PATH = $ps1; "
        "Write-Host ('##MAST## kind=remote_run_start run_id=' + $mastRunId + ' script_repo=' + $env:MAST_REMOTE_SCRIPT_REPO + ' transcript=' + $mastLog + ' meta_json=' + $mastMeta); "
        "$mastSw = [System.Diagnostics.Stopwatch]::StartNew(); "
        "$mastRc = 0; "
        "$mastErr = ''; "
        "try { "
        "  Set-ExecutionPolicy Bypass -Scope Process -Force; "
        "  if (-not $mastSkipTx) { Start-Transcript -Path $mastLog -Append -IncludeInvocationHeader -ErrorAction SilentlyContinue | Out-Null }; "
        f"  & $ps1{invoke_tail}; "
        "  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $mastRc = [int]$LASTEXITCODE } "
        "} catch { "
        "  $mastRc = 1; "
        "  $mastErr = $_.Exception.Message; "
        "  Write-Host ('##MAST## kind=remote_error run_id=' + $mastRunId + ' message=' + $mastErr) "
        "} finally { "
        "  $mastSw.Stop(); "
        "  $mastTxPath = $(if ($mastSkipTx) { '' } else { $mastLog }); "
        "  $summary = @{ "
        "    kind = 'mast_remote_run'; "
        "    run_id = $mastRunId; "
        "    computer = $env:COMPUTERNAME; "
        "    script_repo = $env:MAST_REMOTE_SCRIPT_REPO; "
        "    script_path = $env:MAST_REMOTE_SCRIPT_PATH; "
        "    exit_code = [int]$mastRc; "
        "    duration_ms = [int]$mastSw.ElapsedMilliseconds; "
        "    transcript = $mastTxPath; "
        "    error = $mastErr; "
        "    finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') "
        "  }; "
        "  ($summary | ConvertTo-Json -Compress) | Set-Content -LiteralPath $mastMeta -Encoding UTF8 -Force; "
        "  Write-Host ('##MAST## kind=remote_run_end run_id=' + $mastRunId + ' exit_code=' + [int]$mastRc + ' duration_ms=' + [int]$mastSw.ElapsedMilliseconds + ' meta_json=' + $mastMeta) "
        "}; "
        "exit $mastRc"
    )


def run_ps_interruptible(
    session: winrm.Session,
    script: str,
    *,
    quiet: bool,
    label: str,
) -> Any:
    """Run WinRM run_ps in a thread so the main thread can handle Ctrl+C (SIGINT).

    Without this, pywinrm blocks inside urllib3 for up to read_timeout_sec with no chance
    to process KeyboardInterrupt until the HTTP response completes.
    """
    result: list[Any] = []
    error: list[BaseException] = []

    def worker() -> None:
        try:
            result.append(session.run_ps(script))
        except BaseException as e:
            error.append(e)

    th = threading.Thread(target=worker, daemon=True)
    th.start()
    try:
        while th.is_alive():
            th.join(timeout=0.2)
    except KeyboardInterrupt:
        obs(f"Interrupted during: {label}", quiet=quiet)
        print(
            "\n[!] Ctrl+C received - exiting the client. "
            "The remote PowerShell may still run on the guest until it finishes.",
            file=sys.stderr,
            flush=True,
        )
        os._exit(130)
    if error:
        raise error[0]
    return result[0]


def load_vault(path: Path) -> tuple[str, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return data["unit"]["user"], data["unit"]["pass"]


def open_session(host: str, raw_user: str, password: str, *, quiet: bool) -> winrm.Session:
    # Candidate user forms (local '.\\user', bare, and '<ip>\\user' for IPv4
    # hosts) are generated by the canonical vm_lib._candidate_users helper.
    try_order = _candidate_users(host, raw_user)
    last_err: Exception | None = None
    t0 = time.perf_counter()
    obs(f"WinRM connect http://{host}:{WINRM_PORT}/wsman (trying {len(try_order)} user form(s))...", quiet=quiet)
    for usr in try_order:
        try:
            obs(f"  attempt user {usr!r} ...", quiet=quiet)
            # Long timeouts: this driver calls session.run_ps directly (no
            # resilient-Receive loop), so a single Receive must outlast a whole
            # provisioning run rather than relying on vm_lib's short defaults.
            s = winrm_session(
                host,
                {"user": usr, "pass": password},
                read_timeout_s=3700,
                op_timeout_s=3600,
            )
            run_ps_interruptible(
                s,
                "1",
                quiet=quiet,
                label=f"WinRM auth probe ({usr!r})",
            )
            obs(f"WinRM session OK ({usr!r}) after {time.perf_counter() - t0:.1f}s", quiet=quiet)
            return s
        except InvalidCredentialsError as e:
            last_err = e
            obs(f"  auth rejected for {usr!r}", quiet=quiet)
            continue
    raise RuntimeError(f"WinRM auth failed for {try_order}: {last_err}")


def wait_for_winrm_ready(
    host: str,
    raw_user: str,
    password: str,
    *,
    timeout_s: int,
    poll_s: float,
    quiet: bool,
) -> winrm.Session:
    """Wait until TCP :WINRM_PORT accepts and WinRM Basic auth succeeds (e.g. after reboot)."""
    if timeout_s <= 0:
        return open_session(host, raw_user, password, quiet=quiet)

    deadline = time.monotonic() + timeout_s
    obs(
        f"Waiting up to {timeout_s}s for WinRM on {host!r}:{WINRM_PORT} "
        f"(poll every {poll_s}s; unit may still be booting)...",
        quiet=quiet,
    )
    attempt = 0
    while True:
        attempt += 1
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                f"WinRM on {host!r} did not become ready within {timeout_s}s"
            )
        try:
            sock_timeout = min(5.0, max(1.0, remaining))
            with socket.create_connection((host, WINRM_PORT), timeout=sock_timeout):
                pass
        except OSError as e:
            obs(
                f"  [{attempt}] TCP {WINRM_PORT} not open (~{max(0, int(remaining))}s left): {e!r}",
                quiet=quiet,
            )
            time.sleep(min(poll_s, max(0.2, remaining)))
            continue

        try:
            return open_session(host, raw_user, password, quiet=quiet)
        except RuntimeError as e:
            # Wrong password also fails here; user must fix creds (wait will time out).
            obs(
                f"  [{attempt}] WinRM auth not ready yet (~{max(0, int(remaining))}s left): {e}",
                quiet=quiet,
            )
        except Exception as e:
            obs(
                f"  [{attempt}] WinRM probe failed (~{max(0, int(remaining))}s left): {e!r}",
                quiet=quiet,
            )
        time.sleep(min(poll_s, max(0.2, remaining)))


def main() -> int:
    root = repo_root()
    ap = argparse.ArgumentParser(description="Run a PS1 on a unit via WinRM HTTP (no local admin).")
    ap.add_argument("--host", required=True, help="DNS name or IP of the unit (mast01 in prod).")
    ap.add_argument(
        "--script",
        required=True,
        help="Path to .ps1 under repo (e.g. client/prepare-mast-client.ps1).",
    )
    ap.add_argument(
        "--vault",
        default=str(root / "vault" / "creds.json"),
        help="Path to creds.json (default: repo vault/creds.json).",
    )
    ap.add_argument(
        "--invoke-args",
        default="",
        help="Literal argument string appended after the script path (PowerShell), e.g. "
        '\'-HostName mast01 -Provider 192.168.56.1\'',
    )
    ap.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress messages on stderr (remote stdout/stderr still print).",
    )
    ap.add_argument(
        "--run-id",
        default="",
        help="Correlation id for this run (default: random hex). Sets env MAST_RUN_ID on the unit.",
    )
    ap.add_argument(
        "--no-remote-transcript",
        action="store_true",
        help="Do not Start-Transcript on the unit (still writes mast_remote_run JSON). Default "
        "transcript path omits explicit Stop-Transcript because it can hang under WinRM.",
    )
    ap.add_argument(
        "--write-local-meta",
        default="",
        metavar="PATH",
        help="Write orchestrator-side JSON summary to PATH after the run (hostname, run_id, exit code).",
    )
    ap.add_argument(
        "--show-remote-runs",
        action="store_true",
        help="After the run, query the guest for the remote-runs folder and list recent files.",
    )
    ap.add_argument(
        "--wait-winrm-seconds",
        type=int,
        default=900,
        metavar="N",
        help="Keep polling until WinRM answers on port %s (0 = no wait). Default 900. "
        "Use after a unit reboot." % WINRM_PORT,
    )
    ap.add_argument(
        "--wait-winrm-poll-seconds",
        type=float,
        default=5.0,
        metavar="SEC",
        help="Seconds between retries while waiting for WinRM (default 5).",
    )
    args = ap.parse_args()
    quiet: bool = args.quiet

    script_path = (root / args.script).resolve()
    if not script_path.is_file():
        print(f"ERROR: script not found: {script_path}", file=sys.stderr)
        return 2

    vault_path = Path(args.vault)
    if not vault_path.is_file():
        print(f"ERROR: vault not found: {vault_path}", file=sys.stderr)
        return 2

    raw_user, password = load_vault(vault_path)

    raw = script_path.read_bytes()
    b64 = base64.b64encode(raw).decode("ascii")
    chunks = [b64[i : i + CHUNK] for i in range(0, len(b64), CHUNK)]
    nchunks = len(chunks)

    run_id = (args.run_id or "").strip() or uuid.uuid4().hex
    run_start = time.perf_counter()
    obs(
        f"run-remote-script-winrm starting run_id={run_id} host={args.host!r} "
        f"script={args.script!r} bytes={len(raw)} chunks={nchunks} "
        f"(~{nchunks} WinRM round-trips for upload; remote logs under "
        f"<SystemDrive>\\\\MAST\\\\logs\\\\remote-runs\\\\<timestamp>_<run_id>\\\\)",
        quiet=quiet,
    )

    try:
        s = wait_for_winrm_ready(
            args.host,
            raw_user,
            password,
            timeout_s=args.wait_winrm_seconds,
            poll_s=args.wait_winrm_poll_seconds,
            quiet=quiet,
        )
    except TimeoutError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 124
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    obs("Clear remote temp b64 file...", quiet=quiet)
    init = (
        "$p = Join-Path $env:TEMP 'mast-remote.b64'; "
        "if (Test-Path $p) { Remove-Item $p -Force }; "
        "[IO.File]::WriteAllText($p, [string]::Empty)"
    )
    r = run_ps_interruptible(s, init, quiet=quiet, label="clear remote temp b64")
    if r.status_code != 0:
        sys.stderr.write(r.std_err.decode(errors="replace"))
        return r.status_code

    step = max(1, nchunks // 12)
    upload_start = time.perf_counter()
    for i, ch in enumerate(chunks):
        es = _ps_escape(ch)
        line = (
            "$p = Join-Path $env:TEMP 'mast-remote.b64'; "
            f"[IO.File]::AppendAllText($p, '{es}')"
        )
        if nchunks <= 24 or i == 0 or (i + 1) % step == 0 or i == nchunks - 1:
            pct = 100 * (i + 1) // max(1, nchunks)
            obs(f"upload chunk {i + 1}/{nchunks} ({pct}%)...", quiet=quiet)
        r = run_ps_interruptible(
            s,
            line,
            quiet=quiet,
            label=f"upload chunk {i + 1}/{nchunks}",
        )
        if r.status_code != 0:
            sys.stderr.write(r.std_err.decode(errors="replace"))
            return r.status_code
    obs(f"upload done in {time.perf_counter() - upload_start:.1f}s", quiet=quiet)

    ia = args.invoke_args.strip()
    invoke_tail = f" {ia}" if ia else ""

    obs(
        "decode base64 + run script on guest (transcript + JSON summary unless "
        "--no-remote-transcript; this step may take minutes)...",
        quiet=quiet,
    )
    run_prep = build_remote_invoke(
        invoke_tail,
        run_id,
        args.script,
        transcript=not args.no_remote_transcript,
    )
    exec_start = time.perf_counter()
    r = run_ps_interruptible(
        s,
        run_prep,
        quiet=quiet,
        label="decode and execute script on guest",
    )
    exec_s = time.perf_counter() - exec_start
    obs(f"guest script finished status_code={r.status_code} in {exec_s:.1f}s", quiet=quiet)
    emit_guest_mast_lines(r.std_out or b"", r.std_err or b"")
    if r.std_out:
        out = _decode_and_clean(r.std_out, drop_markers=True)
        if out:
            sys.stdout.write(out)
    if r.std_err:
        err = _decode_and_clean(r.std_err, drop_markers=True)
        if err:
            sys.stderr.write(err)

    if args.show_remote_runs:
        print_guest_remote_runs_listing(s, quiet=quiet)

    if args.write_local_meta:
        local_path = Path(args.write_local_meta).resolve()
        local_path.parent.mkdir(parents=True, exist_ok=True)
        local_meta = {
            "kind": "mast_orchestrator_run",
            "run_id": run_id,
            "host": args.host,
            "script": args.script,
            "status_code": int(r.status_code),
            "duration_exec_s": round(exec_s, 3),
            "finished_local_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "remote_note": "See unit <SystemDrive>\\MAST\\logs\\remote-runs\\<timestamp>_<run_id>\\remote-<host>-<run_id>.json",
        }
        local_path.write_text(json.dumps(local_meta, indent=2), encoding="utf-8")
        obs(f"wrote local meta {local_path}", quiet=quiet)

    obs(f"total wall time {time.perf_counter() - run_start:.1f}s", quiet=quiet)
    return int(r.status_code)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n[!] Interrupted.", file=sys.stderr, flush=True)
        sys.exit(130)
