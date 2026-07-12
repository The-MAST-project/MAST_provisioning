#!/usr/bin/env python3
"""CLI entry for the platform-agnostic Python provisioning driver.

Thin argparse wrapper over prov.driver. Replaces server/check-and-provision.ps1
(kept alongside until the Python driver is validated on a real run). Run from
anywhere:

    python server/check_and_provision.py [--only-hosts mast04] [--dry-run] ...

Exit codes: 0 all OK/SKIPPED, 1 one or more units failed, 2 fatal startup error.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # make `prov` importable

from prov.driver import Config, Driver, run_loop  # noqa: E402


def _parse_args(argv: list[str] | None = None):
    repo_top_default = Path(__file__).resolve().parents[1]
    p = argparse.ArgumentParser(description="MAST autonomous provisioning driver (Python).")
    p.add_argument("--repo-top", type=Path, default=repo_top_default)
    p.add_argument("--unit-registry", type=Path, default=None)
    p.add_argument("--vault-creds", type=Path, default=None)
    p.add_argument("--modules", default="", help="comma-separated module override")
    p.add_argument("--only-hosts", default="", help="comma-separated hostname whitelist")
    p.add_argument("--proxy-mode", choices=("weizmann", "direct"), default="weizmann")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--force", action="store_true")
    p.add_argument("--test-mode", action="store_true")
    p.add_argument("--maint-window-start", type=int, default=-1)
    p.add_argument("--maint-window-end", type=int, default=-1)
    p.add_argument("--retain-runs", type=int, default=60)
    p.add_argument("--loop", action="store_true",
                   help="run provisioning cycles on a cadence (the supervised -Loop service mode)")
    p.add_argument("--interval-seconds", type=int, default=1800,
                   help="seconds between cycles in --loop mode (default 1800)")
    p.add_argument("--max-cycles", type=int, default=None,
                   help="--loop mode: stop after this many cycles (default: run until stopped)")
    return p.parse_args(argv)


def _build_config(argv: list[str] | None = None) -> Config:
    a = _parse_args(argv)
    repo_top = a.repo_top.resolve()
    return Config(
        repo_top=repo_top,
        unit_registry=a.unit_registry or (repo_top / "server" / "unit-registry.json"),
        vault_creds=a.vault_creds or (repo_top / "vault" / "creds.json"),
        modules=[m for m in a.modules.split(",") if m],
        only_hosts=[h for h in a.only_hosts.split(",") if h],
        proxy_mode=a.proxy_mode,
        dry_run=a.dry_run,
        force=a.force,
        test_mode=a.test_mode,
        maint_window_start=a.maint_window_start,
        maint_window_end=a.maint_window_end,
        retain_runs=a.retain_runs,
    )


def _install_stop_event():
    """Return a threading.Event set on SIGINT/SIGTERM, for graceful service
    shutdown. Used as both the stop check (ev.is_set) and the interruptible
    inter-cycle sleep (ev.wait), so a stop signal wakes the loop immediately
    instead of waiting out the interval."""
    import signal
    import threading
    ev = threading.Event()

    def _handler(*_):
        ev.set()

    signal.signal(signal.SIGINT, _handler)
    try:
        signal.signal(signal.SIGTERM, _handler)  # not deliverable the same way on Windows
    except (ValueError, AttributeError, OSError):
        pass
    return ev


def main(argv: list[str] | None = None) -> int:
    a = _parse_args(argv)
    cfg = _build_config(argv)
    if a.loop:
        ev = _install_stop_event()
        run_loop(cfg, a.interval_seconds, max_cycles=a.max_cycles,
                 stop=ev.is_set, sleep_fn=ev.wait)
        return 0
    return Driver(cfg).run()


if __name__ == "__main__":
    raise SystemExit(main())
