"""The driver's removal sets must match the unit-side authority.

``tools/mast-service-names.ps1`` is the single source of truth for which services
provisioning removes: both unit-side providers read it. The driver cannot -- it
stands the unit down before any payload has been transferred, so it carries its own
copy of the lists. This pins the two together, so adding a service to the PowerShell
table without teaching the driver fails here rather than leaving a service the run
never removes.
"""

from __future__ import annotations

import re
from pathlib import Path

from prov import driver as D

_TABLE = Path(__file__).resolve().parents[3] / "tools" / "mast-service-names.ps1"

#: function Get-MastServiceNames {
#:     @('mast-unit', 'mast-pwi4', ...)
#: }
_LIST = r"function {0} \{{\s*@\((?P<items>[^)]*)\)"


def _names(function: str) -> tuple[str, ...]:
    match = re.search(_LIST.format(function), _TABLE.read_text(encoding="utf-8"))
    assert match, f"{function} not found in {_TABLE}"
    return tuple(re.findall(r"'([^']+)'", match.group("items")))


def test_removal_set_matches_the_powershell_table() -> None:
    assert _names("Get-MastServiceNames") == D.STAND_DOWN_SERVICES


def test_legacy_set_matches_the_powershell_table() -> None:
    assert _names("Get-MastLegacyServiceNames") == D.STAND_DOWN_LEGACY_SERVICES


def test_the_two_sets_are_disjoint() -> None:
    """A name in both would be removed twice, once ungated -- defeating the gate."""
    assert not set(D.STAND_DOWN_SERVICES) & set(D.STAND_DOWN_LEGACY_SERVICES)


def test_mast_unit_is_removed() -> None:
    """The point of the change: the one service that commands hardware is gone."""
    assert "mast-unit" in D.STAND_DOWN_SERVICES
