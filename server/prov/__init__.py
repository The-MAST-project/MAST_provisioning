"""MAST provisioning server orchestration (platform-agnostic Python).

This package is the Python port of the server-side autonomous provisioning
driver, formerly server/check-and-provision.ps1. The orchestration control
plane (scheduling, session management, logging/telemetry, retention) lives here
and is platform-agnostic; the Windows-tethered steps it *drives* -- build
(build-mast.ps1), the SMB-pull transfer, and execute-mast-provisioning.ps1 --
stay in PowerShell and run on the Windows prov host / units. See DECISIONS.md
(2026-07-12, "Port the provisioning server orchestration to Python").
"""

from __future__ import annotations

__all__: list[str] = []
