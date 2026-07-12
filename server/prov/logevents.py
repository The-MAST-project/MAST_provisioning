"""Server-side logging, telemetry, and status files (port of the controller
half of server/lib/mast-log.ps1).

Platform-agnostic: the driver's OWN logs/status live under a configurable server
root (``MAST_SERVER_ROOT``; default ``<SystemDrive>\\MAST`` on Windows,
``/var/lib/mast`` elsewhere) -- NOT the unit-side ``C:\\MAST`` (units are
Windows; that path is a literal string sent to the unit, never derived here).

Everything written here is plain UTF-8 + LF, no BOM (the standard adopted
2026-07-12); status files are written atomically via os.replace. Reads of
PowerShell-written JSON stay BOM-tolerant via prov.transport.load_json_file.
"""

from __future__ import annotations

import csv
import io
import json
import os
from datetime import datetime, timezone
from pathlib import Path

# activity.csv columns -- must match the PowerShell header for append-compat.
_ACTIVITY_HEADER = [
    "timestamp_utc", "run_id", "unit", "outcome",
    "reason", "duration_s", "payload_hash", "git_sha",
]


def now_utc() -> str:
    """UTC timestamp in the driver's canonical form (matches PS Now-Utc)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def server_root() -> Path:
    """Base dir for the driver's OWN logs/status (server-side, platform-neutral).

    Overridable with MAST_SERVER_ROOT; defaults to <SystemDrive>\\MAST on Windows
    and /var/lib/mast elsewhere. This is the server's root, distinct from the
    unit-side C:\\MAST.
    """
    env = os.environ.get("MAST_SERVER_ROOT")
    if env:
        return Path(env)
    if os.name == "nt":
        return Path((os.environ.get("SystemDrive") or "C:") + "\\MAST")
    return Path("/var/lib/mast")


def prov_logs_base() -> Path:
    d = server_root() / "logs" / "prov"
    d.mkdir(parents=True, exist_ok=True)
    return d


def prov_session_dir(run_id: str) -> Path:
    d = prov_logs_base() / "sessions" / run_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def prov_activity_csv() -> Path:
    return prov_logs_base() / "activity.csv"


def prov_last_err_log() -> Path:
    return prov_logs_base() / "last-error.log"


def status_base() -> Path:
    d = server_root() / "status"
    d.mkdir(parents=True, exist_ok=True)
    return d


def last_run_path() -> Path:
    return status_base() / "last-run.json"


def write_status_atomic(path: Path, obj: object) -> None:
    """Write ``obj`` as JSON to ``path`` atomically, plain UTF-8 + LF, no BOM."""
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8", newline="\n")
    os.replace(tmp, path)  # atomic on Windows and POSIX


def _fmt_event(event_type: str, fields: dict[str, object]) -> str:
    """Render one event line: '[utc]  TYPE  k=v  k=v' (two-space separated),
    matching the PowerShell Log-Event format."""
    parts = [f"[{now_utc()}]", event_type]
    parts += [f"{k}={v}" for k, v in fields.items()]
    return "  ".join(parts)


class RunLog:
    """Per-run logging + telemetry state (the driver's Log-Event / Log-Activity).

    Holds the run's log dir + paths, tees events to the run log and stdout, and
    installs itself as prov.transport's log sink so transport heartbeats land in
    the same run log. ``unit_outcomes`` feeds the end-of-run last-run.json.
    """

    def __init__(self, run_id: str, *, echo: bool = True) -> None:
        self.run_id = run_id
        self.log_root = prov_session_dir(run_id)
        self.run_log_path = self.log_root / f"{run_id}.log"
        self.activity_csv = prov_activity_csv()
        self.last_err_log = prov_last_err_log()
        self.unit_outcomes: dict[str, str] = {}
        self._echo = echo
        if not self.activity_csv.exists():
            with self.activity_csv.open("w", encoding="utf-8", newline="") as fh:
                csv.writer(fh).writerow(_ACTIVITY_HEADER)

    def _append_run_log(self, line: str) -> None:
        with self.run_log_path.open("a", encoding="utf-8", newline="\n") as fh:
            fh.write(line + "\n")
        if self._echo:
            print(line, flush=True)

    def event(self, event_type: str, **fields: object) -> None:
        self._append_run_log(_fmt_event(event_type, fields))

    def raw(self, text: str) -> None:
        """Tee arbitrary text (e.g. transport heartbeat / remote stdout) into the
        run log. Bound to prov.transport.log sinks by install_as_transport_sink."""
        if not text:
            return
        self._append_run_log(text)

    def activity(
        self,
        unit: str,
        outcome: str,
        reason: str = "",
        duration_s: int = 0,
        payload_hash: str = "",
        git_sha: str = "",
    ) -> None:
        row = [now_utc(), self.run_id, unit, outcome, reason,
               str(duration_s), payload_hash, git_sha]
        buf = io.StringIO()
        csv.writer(buf).writerow(row)
        with self.activity_csv.open("a", encoding="utf-8", newline="") as fh:
            fh.write(buf.getvalue())
        self.unit_outcomes[unit] = outcome

    def install_as_transport_sink(self) -> None:
        """Route prov.transport's heartbeat/stdout log sinks into this run log so
        transport chatter and driver events share one timeline."""
        from prov import transport
        transport.log_fn = lambda m: self._append_run_log(f"[{now_utc()}] {m}")
        transport.log_raw_fn = self.raw
