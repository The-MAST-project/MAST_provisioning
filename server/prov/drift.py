"""Per-module drift classification.

Pure logic, no I/O: given a unit's ``installed-manifest.json`` and the payload's
``build-manifest.json``, decide per module whether it is current, and derive the
set to (re)provision.

This replaces the whole-payload ``payload_hash`` comparison as the *decision*
input. The aggregate hash stays as the fast "anything changed at all?" gate --
when it matches, nothing here needs to run.

See ``docs/per-module-tracking-plan.md`` Stage 3, issue #22.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class ModuleState(StrEnum):
    """Per-module verdict.

    ``NEEDS_REPAIR`` is produced by the tier-2 computed check (Stage 4), not by
    this comparison -- a written record cannot see that a service has stopped.
    It is declared here so both tiers speak one vocabulary.
    """

    UP_TO_DATE = "up-to-date"
    NEEDS_UPDATE = "needs-update"
    MISSING = "missing"
    EXTRA = "extra"
    NEEDS_REPAIR = "needs-repair"


#: Verdicts that mean "run this module". ``EXTRA`` is deliberately absent: a
#: module the build no longer ships cannot be provisioned, only reported.
ACTIONABLE = frozenset({ModuleState.NEEDS_UPDATE, ModuleState.MISSING, ModuleState.NEEDS_REPAIR})

#: Marker for a module whose installed entry carries no usable hash -- a legacy
#: pre-``modules`` manifest, or an entry written before hashing existed.
_UNKNOWN = ""


@dataclass(frozen=True)
class ModuleDrift:
    name: str
    state: ModuleState
    installed_version: str | None
    built_version: str | None
    installed_hash: str | None
    built_hash: str | None
    #: provide/verify outcomes recorded by the last run that touched the module.
    provide: str | None = None
    verify: str | None = None

    @property
    def actionable(self) -> bool:
        return self.state in ACTIONABLE


@dataclass(frozen=True)
class DriftReport:
    modules: tuple[ModuleDrift, ...]

    @property
    def targets(self) -> list[str]:
        """Modules to pass to execute as ``-Modules``, in build order."""
        return [m.name for m in self.modules if m.actionable]

    @property
    def current(self) -> bool:
        return not self.targets

    def by_state(self, state: ModuleState) -> list[str]:
        return [m.name for m in self.modules if m.state is state]

    def summary(self) -> str:
        """One-line log-friendly census, e.g. ``up-to-date=18 needs-update=2``."""
        counts: dict[str, int] = {}
        for m in self.modules:
            counts[str(m.state)] = counts.get(str(m.state), 0) + 1
        return " ".join(f"{k}={counts[k]}" for k in sorted(counts))


def _entry_field(entry: object, field: str) -> str | None:
    if not isinstance(entry, dict):
        return None
    value = entry.get(field)
    return None if value is None else str(value)


def classify(installed: dict | None, build: dict, validation: dict | None = None) -> DriftReport:
    """Compare a unit's installed manifest against the payload's build manifest.

    ``installed`` may be ``None`` (never provisioned) or a legacy whole-document
    manifest with no ``modules`` map -- both mean "state unknown", and every
    module the build declares comes back ``MISSING`` so the unit reprovisions.
    That is the documented one-time migration for mast01-04.

    ``validation`` is the optional tier-2 computed state: the report written by
    ``client/run-verify-only.ps1`` from re-running each provider's
    ``verify-*.ps1`` on the unit (``{"modules": {name: "pass"|"fail"}}``). Where
    the written record says a module is current but its live verify fails, the
    module classifies ``NEEDS_REPAIR`` -- the runtime drift a content hash
    cannot see (a stopped service, a deleted file). Absent validation simply
    means tier 2 did not run; the tier-1 verdict stands.
    """
    live = {}
    if validation:
        live = validation.get("modules") or {}
        if not isinstance(live, dict):
            live = {}
    build_state = build.get("module_state") or {}
    build_modules = [str(m) for m in (build.get("modules") or [])]
    # A build manifest with module_state but no modules list should still be
    # usable; fall back to the hashed set rather than classifying nothing.
    if not build_modules:
        build_modules = sorted(build_state)

    installed_modules = {}
    if installed:
        installed_modules = installed.get("modules") or {}
        if not isinstance(installed_modules, dict):
            installed_modules = {}

    out: list[ModuleDrift] = []

    for name in build_modules:
        built = build_state.get(name) or {}
        built_hash = _entry_field(built, "hash")
        built_version = _entry_field(built, "version")

        entry = installed_modules.get(name)
        if entry is None:
            out.append(ModuleDrift(name, ModuleState.MISSING, None, built_version, None, built_hash))
            continue

        inst_hash = _entry_field(entry, "hash")
        inst_version = _entry_field(entry, "version")
        provide = _entry_field(entry, "provide")
        verify = _entry_field(entry, "verify")

        # A recorded failure means the module is not installed, whatever the
        # hash says -- the hash records what the payload WOULD have installed,
        # not that installing it worked.
        failed = provide == "fail" or verify == "fail"

        # Hash is the source of truth for "needs update"; the version string is
        # for humans (locked decision 2). An unknown installed hash cannot be
        # asserted equal to anything, so it needs an update rather than a
        # silent pass.
        if failed or not inst_hash or inst_hash == _UNKNOWN or inst_hash != built_hash:
            state = ModuleState.NEEDS_UPDATE
        elif str(live.get(name, "")).lower() == "fail":
            # Hash matches and the install was recorded clean, but the module is
            # not working right now. Reprovisioning is still the action, so this
            # is actionable; the distinct label is what tells an operator the
            # payload did not change -- the unit did.
            state = ModuleState.NEEDS_REPAIR
        else:
            state = ModuleState.UP_TO_DATE

        out.append(ModuleDrift(name, state, inst_version, built_version,
                               inst_hash, built_hash, provide, verify))

    # Modules the unit records but the build no longer ships. Reported, never
    # actioned: provisioning has nothing to run for them, and removing software
    # is out of scope for a drift pass.
    for name in sorted(set(installed_modules) - set(build_modules)):
        entry = installed_modules.get(name)
        out.append(ModuleDrift(name, ModuleState.EXTRA,
                               _entry_field(entry, "version"), None,
                               _entry_field(entry, "hash"), None,
                               _entry_field(entry, "provide"),
                               _entry_field(entry, "verify")))

    return DriftReport(tuple(out))
