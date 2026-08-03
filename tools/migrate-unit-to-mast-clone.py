#!/usr/bin/env python3
"""Retire a unit's pre-mast-clone ``C:\\MAST\\repos`` tree. Supervised, one unit at a time.

This is stage 6 of the mast-clone adoption (#31) and is deliberately NOT part of
the autonomous loop: it stops a service and takes away a source tree, one-time
destructive work that should not live in the routine cycle. Run it per unit,
watch it, move on.

Order of operations, and why:

  1. PROBE the unit and decide with prov.migration.plan_migration. It refuses
     unless the NEW layout is demonstrably good -- venv, mast.pth, the role's
     clones, ``common`` importable, and the service already re-pointed. A unit
     that fails any check still has a working old tree; taking it away would
     leave it with neither.
  2. STOP mast-unit if it is running, so nothing holds a handle in the old tree.
     Its StartType is never touched: mast-services-finalize owns run state and
     deliberately leaves MAST services Manual at this stage of development.
  3. RETIRE the tree. Default is a RENAME to ``C:\\MAST\\repos.retired-<stamp>``,
     which satisfies every consumer (nothing looks for that name) and is
     reversible on a production unit for the cost of a few GB. ``--purge``
     deletes outright.
  4. RESTORE the service to the run state it had, not to "running".
  5. RE-PROBE and report. The tool exits non-zero if the post-state is not what
     it intended, so a half-migration cannot read as success.

Dry-run by default: prints the plan and changes nothing. ``--apply`` acts.

Usage:
    python tools/migrate-unit-to-mast-clone.py --host mast-wis-01
    python tools/migrate-unit-to-mast-clone.py --host mast01 --apply
    python tools/migrate-unit-to-mast-clone.py --host mast01 --apply --purge
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT / "server"))

from prov import transport as T  # noqa: E402
from prov.migration import (  # noqa: E402
    DEFAULT_TOP,
    LEGACY_ROOT,
    UNIT_ROLE_DIRS,
    MigrationState,
    UnitProbe,
    plan_migration,
)


def _out(session, ps: str) -> str:
    return T.run_ps(session, ps).std_out.decode("utf-8", "replace").strip()


def _bool(session, ps: str) -> bool:
    return _out(session, ps).strip().lower().endswith("true")


def probe_unit(session, host: str, top: str) -> UnitProbe:
    venv_python = rf"{top}\.venv\Scripts\python.exe"
    entries = _out(
        session,
        f"if (Test-Path '{LEGACY_ROOT}') {{ Get-ChildItem '{LEGACY_ROOT}' -Force "
        "| ForEach-Object { $_.Name } }",
    )
    present = _out(
        session,
        f"if (Test-Path '{top}') {{ Get-ChildItem '{top}' -Force -Directory "
        "| ForEach-Object { $_.Name } }",
    )
    registered = _bool(session, "[bool](Get-Service mast-unit -ErrorAction SilentlyContinue)")
    status = _out(session, "(Get-Service mast-unit -ErrorAction SilentlyContinue).Status")
    app = ""
    if registered:
        app = _out(
            session,
            r"$n='C:\Program Files\nssm\nssm.exe'; if (Test-Path $n) "
            r"{ ((& $n get mast-unit Application) -join '').Trim([char]0,' ',[char]13,[char]10) }",
        )
        # nssm emits UTF-16LE through the pipe; strip the interleaved NULs.
        app = app.replace("\x00", "").strip()
    return UnitProbe(
        host=host,
        legacy_present=bool(entries) or _bool(session, f"Test-Path '{LEGACY_ROOT}'"),
        legacy_entries=tuple(e for e in entries.splitlines() if e.strip()),
        venv_python=_bool(session, f"Test-Path '{venv_python}'"),
        mast_pth=_bool(session, rf"Test-Path '{top}\.venv\Lib\site-packages\mast.pth'"),
        common_init=_bool(session, rf"Test-Path '{top}\common\__init__.py'"),
        present_dirs=tuple(d for d in present.splitlines() if d.strip()),
        service_registered=registered,
        service_app=app,
        service_status=status,
        expected_app=venv_python,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True, help="Unit hostname (e.g. mast01, mast-wis-01)")
    ap.add_argument("--top", default=DEFAULT_TOP, help=f"New source root (default: {DEFAULT_TOP})")
    ap.add_argument("--apply", action="store_true", help="Actually migrate (default: dry run)")
    ap.add_argument(
        "--purge",
        action="store_true",
        help="Delete the legacy tree instead of renaming it to repos.retired-<stamp>",
    )
    args = ap.parse_args()

    print(f"[migrate] {args.host}: connecting")
    session = T.connect_unit(args.host, T.load_creds()["unit"])
    try:
        probe = probe_unit(session, args.host, args.top)
        plan = plan_migration(probe)

        print(f"[migrate] legacy {LEGACY_ROOT} present : {probe.legacy_present}")
        print(f"[migrate] new layout dirs             : {', '.join(probe.present_dirs) or '(none)'}")
        print(f"[migrate] service                     : "
              f"{'registered' if probe.service_registered else 'absent'} "
              f"status={probe.service_status or '-'} app={probe.service_app or '-'}")
        for n in plan.notes:
            print(f"[migrate] note: {n}")
        for b in plan.blockers:
            print(f"[migrate] BLOCKER: {b}")
        print(f"[migrate] state: {plan.state}")

        if plan.state is MigrationState.ALREADY_MIGRATED:
            return 0
        if plan.state is MigrationState.BLOCKED:
            print("[migrate] refusing: the new layout is not proven good; the old tree stays.")
            return 2
        if not args.apply:
            action = "DELETE" if args.purge else "RENAME"
            print(f"[migrate] DRY RUN -- would {action} {LEGACY_ROOT}. Re-run with --apply.")
            return 0

        was_running = probe.service_status.lower() == "running"
        if was_running:
            print("[migrate] stopping mast-unit (StartType untouched)")
            _out(session, "Stop-Service -Name mast-unit -Force -ErrorAction SilentlyContinue")

        if args.purge:
            print(f"[migrate] deleting {LEGACY_ROOT}")
            _out(session, f"Remove-Item -LiteralPath '{LEGACY_ROOT}' -Recurse -Force -ErrorAction Stop")
        else:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            dest = f"{LEGACY_ROOT}.retired-{stamp}"
            print(f"[migrate] renaming {LEGACY_ROOT} -> {dest}")
            _out(session, f"Move-Item -LiteralPath '{LEGACY_ROOT}' -Destination '{dest}' -Force -ErrorAction Stop")

        if was_running:
            print("[migrate] restoring mast-unit to Running (its prior state)")
            _out(session, "Start-Service -Name mast-unit -ErrorAction SilentlyContinue")

        after = probe_unit(session, args.host, args.top)
        ok = True
        if after.legacy_present:
            print(f"[migrate] POST-CHECK FAILED: {LEGACY_ROOT} still present")
            ok = False
        for d in UNIT_ROLE_DIRS:
            if d not in after.present_dirs:
                print(f"[migrate] POST-CHECK FAILED: clone '{d}' vanished from the new layout")
                ok = False
        if not after.venv_python:
            print("[migrate] POST-CHECK FAILED: venv interpreter gone")
            ok = False
        if was_running and after.service_status.lower() != "running":
            print(f"[migrate] POST-CHECK FAILED: mast-unit was Running, now {after.service_status}")
            ok = False
        print(f"[migrate] {'OK -- unit migrated' if ok else 'FAILED -- inspect the unit'}")
        return 0 if ok else 1
    finally:
        session.close()


if __name__ == "__main__":
    sys.exit(main())
