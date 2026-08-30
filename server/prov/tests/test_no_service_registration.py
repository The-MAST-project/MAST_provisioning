"""No provider may register a MAST Windows service.

Provisioning delivers the environment and registers nothing that can be started:
nothing on a unit raises the MAST processes but an operator, and a registered service
is a competing path into the same processes (issue #159). That is a property of the
whole provider tree rather than of any one script, so it is asserted mechanically
here instead of being left to review.

nssm is used in this repo for MAST services only -- the provisioning server's own
MAST-Provision service is set up by hand, per docs/provisioning-server-setup.md -- so
any `nssm install` under the provider tree is a MAST service by construction.
"""

from __future__ import annotations

import re
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[3]
_SCANNED = sorted((_ROOT / "server" / "providers").rglob("*.ps1")) + sorted((_ROOT / "tools").glob("*.ps1"))

_FORBIDDEN = {
    # `install\b` so the word "installed" in a log line is not a registration.
    "nssm-install": re.compile(r"nssm(\.exe)?[\"'}\s]+install\b", re.IGNORECASE),
    "start-mode": re.compile(r"SERVICE_(AUTO_START|DISABLED|INTERACTIVE_PROCESS)"),
    "start-a-mast-service": re.compile(r"(Start|Restart)-Service.*mast-", re.IGNORECASE),
}


def _offences() -> list[str]:
    found = []
    for path in _SCANNED:
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.lstrip().startswith("#"):
                continue  # prose explaining why these are gone is not a registration
            for label, pattern in _FORBIDDEN.items():
                if pattern.search(line):
                    found.append(f"{path.relative_to(_ROOT)}:{lineno} [{label}] {line.strip()}")
    return found


def test_the_provider_tree_scans_something() -> None:
    """A path typo would make every assertion below vacuously true."""
    assert len(_SCANNED) > 50, f"only found {len(_SCANNED)} scripts under the provider tree"


def test_no_provider_registers_or_starts_a_mast_service() -> None:
    offences = _offences()
    assert not offences, "provisioning must register no MAST service:\n" + "\n".join(offences)
