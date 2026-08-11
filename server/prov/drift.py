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

from dataclasses import dataclass, field
from datetime import UTC, datetime
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
    #: Order-terminal cross-cutting modules that join any non-empty target set.
    always: frozenset[str] = field(default_factory=frozenset)

    @property
    def targets(self) -> list[str]:
        """Modules to pass to execute as ``-Modules``, in build order.

        Includes the ``always`` modules whenever anything else is being run.
        ``reboot`` (detect pending-reboot, drop the flag the orchestrator acts
        on), ``mast-services-finalize`` and the end-of-run ``proxy`` re-assert
        exist to close out a run; a targeted update that installed anything must
        still close with them, or e.g. an installer's pending reboot goes
        unnoticed. Build order is preserved -- they are ordered last by their
        module.json ``order``, and this walks ``self.modules`` in build order.
        """
        drifted = [m.name for m in self.modules if m.actionable]
        if not drifted:
            return []
        wanted = set(drifted) | {m.name for m in self.modules if m.name in self.always and m.state is not ModuleState.EXTRA}
        return [m.name for m in self.modules if m.name in wanted]

    @property
    def drifted(self) -> list[str]:
        """Modules that actually drifted, excluding the always-run tag-alongs."""
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


_TS_FMT = "%Y-%m-%dT%H:%M:%SZ"


def _parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        # _TS_FMT ends in a literal Z, i.e. these are UTC. strptime returns a
        # NAIVE datetime for that, so attach the zone the format already asserts:
        # both sides of the comparison in _validation_is_stale come through here,
        # so aware-vs-aware stays consistent.
        return datetime.strptime(value, _TS_FMT).replace(tzinfo=UTC)
    except ValueError:
        return None


def _validation_is_stale(checked_at: datetime | None, installed_at: str | None) -> bool:
    """Was the module (re)installed after the verify report was written?

    Nothing clears ``validation.json`` -- ``run-verify-only.ps1`` is its only
    writer and is operator-run. So after the driver repairs a module, the old
    "fail" is still sitting there, and without this check it would re-target the
    repaired module on every subsequent payload change, forever. A report that
    predates the module's own ``installed_at`` describes a build that no longer
    exists on the unit; ignore it and let tier 1 stand until verify runs again.

    An unparseable or absent timestamp on either side means "cannot tell", and
    the tier-2 verdict is kept -- consistent with treating tier 2 as advisory
    rather than manufacturing or suppressing drift on a guess.
    """
    installed = _parse_ts(installed_at)
    if checked_at is None or installed is None:
        return False
    return installed > checked_at


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
    checked_at = None
    if validation:
        live = validation.get("modules") or {}
        checked_at = _parse_ts(validation.get("checked_at"))
    build_state = build.get("module_state") or {}
    build_modules = [str(m) for m in (build.get("modules") or [])]
    always = frozenset(str(m) for m in (build.get("always_modules") or []))

    installed_modules = {}
    if installed:
        # Only a MAP records per-module state. A legacy manifest carries 'modules'
        # as a list of names -- the shape mast01-04 were left with -- and that is
        # the same "state unknown" as the key being absent, not something to walk.
        recorded = installed.get("modules")
        installed_modules = recorded if isinstance(recorded, dict) else {}

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
        if failed or not inst_hash or inst_hash != built_hash:
            state = ModuleState.NEEDS_UPDATE
        elif str(live.get(name, "")).lower() == "fail" and not _validation_is_stale(
            checked_at, _entry_field(entry, "installed_at")
        ):
            # Hash matches and the install was recorded clean, but the module is
            # not working right now. Reprovisioning is still the action, so this
            # is actionable; the distinct label is what tells an operator the
            # payload did not change -- the unit did.
            state = ModuleState.NEEDS_REPAIR
        else:
            state = ModuleState.UP_TO_DATE

        out.append(ModuleDrift(name, state, inst_version, built_version, inst_hash, built_hash, provide, verify))

    # Modules the unit records but the build no longer ships. Reported, never
    # actioned: provisioning has nothing to run for them, and removing software
    # is out of scope for a drift pass.
    for name in sorted(set(installed_modules) - set(build_modules)):
        entry = installed_modules.get(name)
        out.append(
            ModuleDrift(
                name,
                ModuleState.EXTRA,
                _entry_field(entry, "version"),
                None,
                _entry_field(entry, "hash"),
                None,
                _entry_field(entry, "provide"),
                _entry_field(entry, "verify"),
            )
        )

    return DriftReport(tuple(out), always)
