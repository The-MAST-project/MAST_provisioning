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

from prov.driver import Config, Driver  # noqa: E402


def _build_config(argv: list[str] | None = None) -> Config:
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
    a = p.parse_args(argv)

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


def main(argv: list[str] | None = None) -> int:
    return Driver(_build_config(argv)).run()


if __name__ == "__main__":
    raise SystemExit(main())
