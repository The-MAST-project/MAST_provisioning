"""No provider may register a MAST Windows service, and only finalize starts mast-service.

Provisioning registers nothing itself. The one service it runs, the supervisor's
``mast-service``, is registered by MAST_supervision's own installer
(``install/install-mast-service.ps1``), which lives in the supervision checkout and
is outside this scan; the ``mast-service`` provider runs it on supervised units only.
Provisioning starts that service in exactly one place, ``mast-services-finalize``,
at the end of a run. The four legacy services are never started anywhere. That is a
property of the whole provider tree rather than of any one script, so it is asserted
mechanically here instead of being left to review.

nssm is used in this repo for MAST services only -- the provisioning server's own
MAST-Provision service is set up by hand, per docs/provisioning-server-setup.md -- so
any `nssm install` under the provider tree is a MAST service by construction.
"""

from __future__ import annotations

import re
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[3]
_SCANNED = sorted((_ROOT / "server" / "providers").rglob("*.ps1")) + sorted((_ROOT / "tools").glob("*.ps1"))
_FINALIZE = _ROOT / "server" / "providers" / "mast-services-finalize" / "provide-mast-services-finalize.ps1"

_FORBIDDEN = {
    # `install\b` so the word "installed" in a log line is not a registration.
    "nssm-install": re.compile(r"nssm(\.exe)?[\"'}\s]+install\b", re.IGNORECASE),
    "start-mode": re.compile(r"SERVICE_(AUTO_START|DISABLED|INTERACTIVE_PROCESS)"),
    "start-a-mast-service": re.compile(r"(Start|Restart)-Service.*mast-", re.IGNORECASE),
}

#: mast-service is named only through its accessor, so a start of it reads like this.
_START_SUPERVISOR_SERVICE = re.compile(r"(Start|Restart)-Service.*Get-MastSupervisorServiceName", re.IGNORECASE)


def _offences(paths: list[Path]) -> list[str]:
    found = []
    for path in paths:
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.lstrip().startswith("#"):
                continue  # prose explaining why these are gone is not a registration
            labels = [label for label, pattern in _FORBIDDEN.items() if pattern.search(line)]
            if path != _FINALIZE and _START_SUPERVISOR_SERVICE.search(line):
                labels.append("start-mast-service-outside-finalize")
            found.extend(f"{path.name}:{lineno} [{label}] {line.strip()}" for label in labels)
    return found


def test_the_provider_tree_scans_something() -> None:
    """A path typo would make every assertion below vacuously true."""
    assert len(_SCANNED) > 50, f"only found {len(_SCANNED)} scripts under the provider tree"
    assert _FINALIZE in _SCANNED


def test_no_provider_registers_a_mast_service_or_starts_one_outside_finalize() -> None:
    offences = _offences(_SCANNED)
    assert not offences, "provisioning must register no MAST service:\n" + "\n".join(offences)


def test_finalize_is_where_mast_service_is_started() -> None:
    """The allowance above is for a line that exists; a stale one would hide a move."""
    lines = _FINALIZE.read_text(encoding="utf-8").splitlines()
    assert any(_START_SUPERVISOR_SERVICE.search(line) for line in lines if not line.lstrip().startswith("#"))


def test_a_start_of_mast_service_elsewhere_is_an_offence(tmp_path: Path) -> None:
    stray = tmp_path / "provide-elsewhere.ps1"
    stray.write_text("Start-Service -Name (Get-MastSupervisorServiceName)\n", encoding="utf-8")
    assert _offences([stray]) == [
        "provide-elsewhere.ps1:1 [start-mast-service-outside-finalize] Start-Service -Name (Get-MastSupervisorServiceName)"
    ]


def test_a_start_of_a_legacy_service_is_an_offence_even_in_finalize(tmp_path: Path) -> None:
    stray = tmp_path / _FINALIZE.name
    stray.write_text("Start-Service -Name 'mast-unit'\n", encoding="utf-8")
    assert _offences([stray]) == [f"{_FINALIZE.name}:1 [start-a-mast-service] Start-Service -Name 'mast-unit'"]
