"""The driver's stand-down set must match the unit-side authority.

``tools/mast-service-names.ps1`` is the single source of truth for which MAST
services provisioning must leave Disabled: both unit-side providers read it. The
driver cannot -- it stands the unit down before any payload has been transferred,
so it carries its own copy of the list. This pins the two together, so adding a
service to the PowerShell table without teaching the driver fails here rather
than leaving a service the run never stands down.
"""

from __future__ import annotations

import re
from pathlib import Path

from prov import driver as D

_TABLE = Path(__file__).resolve().parents[3] / "tools" / "mast-service-names.ps1"

#: 'mast-unit'      = 'Disabled'
_ROW = re.compile(r"^\s*'(?P<name>[a-z0-9-]+)'\s*=\s*'(?P<mode>\w+)'\s*$", re.MULTILINE)


def _expectations() -> dict[str, str]:
    rows = _ROW.findall(_TABLE.read_text(encoding="utf-8"))
    assert rows, f"no service rows parsed out of {_TABLE}"
    return {name: mode for name, mode in rows}


def test_stand_down_set_matches_the_powershell_table() -> None:
    expected = tuple(n for n, mode in _expectations().items() if mode == "Disabled")
    assert expected == D.STAND_DOWN_SERVICES


def test_every_expected_start_mode_is_one_windows_accepts() -> None:
    """Set-Service -StartupType rejects anything else, on the unit, at order 20."""
    assert set(_expectations().values()) <= {"Automatic", "Manual", "Disabled"}


def test_mast_unit_is_never_left_startable() -> None:
    """The point of the change: the one service that commands hardware is Disabled."""
    assert _expectations()["mast-unit"] == "Disabled"
    assert "mast-unit" in D.STAND_DOWN_SERVICES
