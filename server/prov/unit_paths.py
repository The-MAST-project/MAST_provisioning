"""Literal paths of the state files the units keep under ``C:\\MAST``.

Windows string literals for the *unit*, never ``pathlib.Path`` -- the prov server
may be any OS, and a Path would mangle them there.

This module exists so the driver and the read-only tooling name the same file the
same way. It deliberately imports nothing: ``tools/fleet-drift-report.py`` runs
with no third-party dependencies in its ``--from-json`` mode, so it must be able
to reach these constants without pulling in ``prov.transport`` (paramiko/pywinrm).
"""

from __future__ import annotations

UNIT_STATUS_DIR = r"C:\MAST\status"
UNIT_AVAIL = r"C:\MAST\status\availability.json"

#: Written by client/execute-mast-provisioning.ps1 -- the cumulative per-module
#: record of what is installed (tier 1).
UNIT_INSTALLED = r"C:\MAST\installed-manifest.json"

#: Written by client/run-verify-only.ps1 -- computed live state from re-running
#: each provider's verify-*.ps1 (tier 2). Optional: absent means tier 2 has not
#: run on that unit, never that something failed.
UNIT_VALIDATION = r"C:\MAST\status\validation.json"

#: Per-module success markers written by execute as it runs each command.
UNIT_SMOKE_DIR = r"C:\MAST\logs\smoke"
