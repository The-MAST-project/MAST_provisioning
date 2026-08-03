"""Decide whether a unit may be migrated off the pre-mast-clone layout.

Pure logic, no I/O: the caller probes the unit and passes the observations in.
Separated from ``tools/migrate-unit-to-mast-clone.py`` so the preconditions --
the part that must not be wrong on a production unit -- are unit-testable
without a unit.

The migration retires ``C:\\MAST\\repos`` (per-repo clones, a venv inside each,
``common`` via the vestigial submodule) after ``provide-mast.ps1`` has laid down
``C:\\MAST\\src`` via mast-clone. It is a SUPERVISED ONE-SHOT, deliberately not
part of the autonomous loop: it stops a service and removes a tree, one-time
destructive work that should not live in the routine cycle
(docs/mast-clone-adoption-plan.md stage 6).

See issue #31.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum

#: Folders mast-clone creates for the 'unit' role (tools/mast-repos.tsv).
UNIT_ROLE_DIRS = ("common", "unit", "claude")

LEGACY_ROOT = r"C:\MAST\repos"
DEFAULT_TOP = r"C:\MAST\src"


class MigrationState(StrEnum):
    ALREADY_MIGRATED = "already-migrated"
    READY = "ready"
    BLOCKED = "blocked"


@dataclass(frozen=True)
class UnitProbe:
    """What the caller observed on the unit. Every field is a plain fact."""

    host: str
    legacy_present: bool
    #: DIRECTORIES directly under the legacy root. Recorded because it is NOT
    #: always the two standard clones -- mast02 also carries mast-claude-config
    #: and a PlaneWave_PlateSolve3_Catalog directory, and a migration that
    #: assumed the standard pair would delete them without saying so.
    legacy_dirs: tuple[str, ...] = ()
    #: Count of loose files beside them -- the provisioning sidecar logs
    #: (<repo>.git-trace.log and friends). Counted, not listed: there are ~26 on
    #: a provisioned unit and naming them all buries the warning that matters.
    legacy_file_count: int = 0
    venv_python: bool = False
    mast_pth: bool = False
    common_init: bool = False
    present_dirs: tuple[str, ...] = ()
    service_registered: bool = False
    #: NSSM Application path, i.e. the interpreter the service actually runs.
    service_app: str = ""
    service_status: str = ""
    #: Expected interpreter for the new layout.
    expected_app: str = ""


@dataclass(frozen=True)
class MigrationPlan:
    state: MigrationState
    blockers: tuple[str, ...] = ()
    notes: tuple[str, ...] = field(default=())

    @property
    def may_proceed(self) -> bool:
        return self.state is MigrationState.READY


def plan_migration(probe: UnitProbe) -> MigrationPlan:
    """Decide, refusing unless the NEW layout is demonstrably good.

    The order matters: never remove the old tree on the strength of "the new one
    looks present". Every consumer of the new layout is checked first -- the
    venv, the ``sys.path`` wiring, the clones, ``common`` as an importable
    package, and the service actually pointing at the new interpreter. A unit
    that fails any of these still has a working old tree, and taking it away
    would leave it with neither.
    """
    if not probe.legacy_present:
        return MigrationPlan(
            MigrationState.ALREADY_MIGRATED,
            notes=(f"{LEGACY_ROOT} is absent; nothing to retire",),
        )

    blockers: list[str] = []
    notes: list[str] = []

    if not probe.venv_python:
        blockers.append("new layout has no venv interpreter -- mast-clone has not run")
    if not probe.mast_pth:
        blockers.append("mast.pth missing -- <Top> would not be on sys.path for the services")
    if not probe.common_init:
        blockers.append("common/__init__.py missing -- 'common' is not an importable package")

    missing = [d for d in UNIT_ROLE_DIRS if d not in probe.present_dirs]
    if missing:
        blockers.append(f"clones missing from the new layout: {', '.join(missing)}")

    if not probe.service_registered:
        # Not fatal: a unit can be migrated before the service exists, and
        # provisioning registers it. Worth stating rather than passing silently.
        notes.append("mast-unit is not registered; nothing to re-point")
    elif probe.expected_app and probe.service_app:
        if probe.service_app.lower() != probe.expected_app.lower():
            blockers.append(
                f"mast-unit still runs {probe.service_app}, expected {probe.expected_app} "
                "-- re-point it (re-run the mast module) before retiring the old tree"
            )
    elif probe.service_registered and not probe.service_app:
        notes.append("could not read the service's interpreter (nssm absent?); not asserting it")

    if probe.legacy_dirs or probe.legacy_file_count:
        notes.append(
            "legacy tree: "
            + (", ".join(sorted(probe.legacy_dirs)) or "no subdirectories")
            + f" (+{probe.legacy_file_count} loose file(s), the provisioning sidecar logs)"
        )
        # Directories only. The sidecar logs are always there and always go; a
        # non-standard DIRECTORY is content somebody may care about, and the
        # operator should see it before it is retired, not after.
        extras = [
            d
            for d in probe.legacy_dirs
            if not d.lower().startswith("mast_unit") and d.lower() != "mast_common"
        ]
        if extras:
            notes.append("NON-STANDARD directories will also be retired: " + ", ".join(sorted(extras)))

    if blockers:
        return MigrationPlan(MigrationState.BLOCKED, tuple(blockers), tuple(notes))
    return MigrationPlan(MigrationState.READY, (), tuple(notes))
