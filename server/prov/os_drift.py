"""A unit's OS patch level against its build's baseline (MAST_provisioning#15, stage 2).

Pure logic, no I/O beyond reading the repo's own declarations: given what
``server/lib/mast-os-patch-probe.ps1`` found on a unit, the declared builds and the
committed baselines, decide whether the unit is current and what stands in the
way of patching it.

The **reference baseline** is the newest committed baseline for the unit's build.
Committing a baseline is what makes it available (see prov.os_updates); a declared
default and per-unit pins arrive with the apply stages, and replace this rule.

The verdict and the blockers are separate on purpose: a unit can be behind AND
unable to take the update yet (a reboot already pending, a damaged component
store), and the operator needs both facts.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path

from pydantic import BaseModel, ConfigDict

from prov import transport
from prov.os_updates import BASELINES_DIR, Baseline, OsBuilds, UpdateRole

#: Space an LCU install needs on C: before it is attempted. The MSU is ~1 GB, and
#: servicing expands it several-fold while staging; the margin is deliberate.
MIN_FREE_C_BYTES = 20 * 1024**3
#: .NET 4.8.1 reports Release >= this. Its files are 4.8.9xxx, so comparing them to a
#: 4.8 baseline's 4.8.4xxx would read as "ahead" -- it is a different line, not newer.
DOTNET_481_MIN_RELEASE = 533320
DOTNET_48_PREFIX = "4.8."
#: The only value of the AU policy that means "never check".
NO_AUTO_UPDATE_ON = 1
#: Pending-reboot reasons that hold servicing back. A queued file rename
#: (PendingFileRenameOperations) does not: DISM installs over it, and the fleet
#: carries one on every unit, so blocking on it would block everything.
SERVICING_REBOOT_REASONS = frozenset({"CBS RebootPending", "WindowsUpdate RebootRequired"})


class OsPatchState(StrEnum):
    UP_TO_DATE = "up-to-date"
    BEHIND = "behind"
    AHEAD = "ahead"
    NO_BASELINE = "no-baseline"
    UNKNOWN_BUILD = "unknown-build"


class DotnetState(StrEnum):
    UP_TO_DATE = "up-to-date"
    BEHIND = "behind"
    AHEAD = "ahead"
    OTHER_LINE = "other-line"
    UNKNOWN = "unknown"


class Blocker(StrEnum):
    PENDING_REBOOT = "pending-reboot"
    COMPONENT_STORE = "component-store"
    LOW_DISK = "low-disk"


class Finding(StrEnum):
    """Worth saying, but not a reason to hold an update back."""

    LOCKDOWN_OFF = "lockdown-off"
    EDGE_UPDATE_ON = "edge-update-on"
    WINRE_DISABLED = "winre-disabled"


_CLOSED = ConfigDict(extra="forbid")


class ProbeHotfix(BaseModel):
    model_config = _CLOSED
    id: str
    description: str
    installed_on: str | None


class ProbeDotnet(BaseModel):
    model_config = _CLOSED
    release: int | None
    mscorlib_version: str | None


class ProbeEdgeUpdate(BaseModel):
    """Get-MastEdgeUpdateState (server/lib/mast-edge-update.ps1); ``off`` is its verdict."""

    model_config = _CLOSED
    edgeupdate: str | None
    edgeupdatem: str | None
    tasks_enabled: int
    off: bool


class ProbeLockdown(BaseModel):
    model_config = _CLOSED
    no_auto_update: int | None
    task_state: str | None
    wuauserv: str | None
    usosvc: str | None
    waasmedicsvc: str | None
    edge_update: ProbeEdgeUpdate


class OsProbe(BaseModel):
    """What mast-os-patch-probe.ps1 prints. Closed: the two sides must change together."""

    model_config = _CLOSED
    probe_version: int
    computer: str
    product_name: str
    edition_id: str
    current_build: int
    ubr: int
    rollup_package: str | None
    rollup_installed: str | None
    hotfixes: list[ProbeHotfix]
    dotnet: ProbeDotnet
    pending_reboot: list[str]
    free_c_bytes: int
    component_store: str
    winre: str | None
    secure_boot: bool | None
    lockdown: ProbeLockdown


@dataclass(frozen=True)
class OsPatchAssessment:
    state: OsPatchState
    build: int
    ubr: int
    baseline_id: str | None = None
    target_ubr: int | None = None
    lcu_installed: str | None = None
    dotnet: DotnetState = DotnetState.UNKNOWN
    dotnet_version: str | None = None
    dotnet_target: str | None = None
    blockers: tuple[Blocker, ...] = ()
    findings: tuple[Finding, ...] = ()
    pending_reboot: tuple[str, ...] = field(default_factory=tuple)
    secure_boot: bool | None = None


def load_baselines(repo: Path) -> dict[int, list[Baseline]]:
    """Every committed baseline, per build, oldest first."""
    out: dict[int, list[Baseline]] = {}
    for path in sorted((repo / BASELINES_DIR).glob("*/*.json")):
        b = Baseline.model_validate(transport.load_json_object(path))
        out.setdefault(b.build, []).append(b)
    for items in out.values():
        items.sort(key=lambda b: b.msrc_release_date)
    return out


def _version(text: str) -> tuple[int, ...]:
    return tuple(int(p) for p in text.split("."))


def _dotnet_target(baseline: Baseline) -> str | None:
    for f in baseline.files:
        if f.role is UpdateRole.DOTNET:
            # MSRC states one FixedBuild per runtime the CU services, joined by ' & '.
            for part in f.fixed_build.split("&"):
                if part.strip().startswith(DOTNET_48_PREFIX):
                    return part.strip()
    return None


def _dotnet_state(probe: OsProbe, target: str | None) -> DotnetState:
    have = probe.dotnet.mscorlib_version
    if not have or not target or probe.dotnet.release is None:
        return DotnetState.UNKNOWN
    if probe.dotnet.release >= DOTNET_481_MIN_RELEASE or not have.startswith(DOTNET_48_PREFIX):
        return DotnetState.OTHER_LINE
    h, t = _version(have), _version(target)
    if h == t:
        return DotnetState.UP_TO_DATE
    return DotnetState.BEHIND if h < t else DotnetState.AHEAD


def _blockers(probe: OsProbe) -> tuple[Blocker, ...]:
    out = []
    if SERVICING_REBOOT_REASONS & set(probe.pending_reboot):
        out.append(Blocker.PENDING_REBOOT)
    if probe.component_store != "healthy":
        out.append(Blocker.COMPONENT_STORE)
    if probe.free_c_bytes < MIN_FREE_C_BYTES:
        out.append(Blocker.LOW_DISK)
    return tuple(out)


def _findings(probe: OsProbe) -> tuple[Finding, ...]:
    out = []
    if probe.lockdown.no_auto_update != NO_AUTO_UPDATE_ON or probe.lockdown.task_state is None:
        out.append(Finding.LOCKDOWN_OFF)
    if not probe.lockdown.edge_update.off:
        out.append(Finding.EDGE_UPDATE_ON)
    if probe.winre is not None and probe.winre != "Enabled":
        out.append(Finding.WINRE_DISABLED)
    return tuple(out)


def assess(probe: OsProbe, builds: OsBuilds, baselines: dict[int, list[Baseline]]) -> OsPatchAssessment:
    common = {
        "build": probe.current_build,
        "ubr": probe.ubr,
        "blockers": _blockers(probe),
        "findings": _findings(probe),
        "pending_reboot": tuple(probe.pending_reboot),
        "secure_boot": probe.secure_boot,
        "lcu_installed": probe.rollup_installed,
    }
    if not any(b.build == probe.current_build for b in builds.builds):
        return OsPatchAssessment(state=OsPatchState.UNKNOWN_BUILD, **common)
    known = baselines.get(probe.current_build) or []
    if not known:
        return OsPatchAssessment(state=OsPatchState.NO_BASELINE, **common)

    ref = known[-1]
    if probe.ubr == ref.target_ubr:
        state = OsPatchState.UP_TO_DATE
    else:
        state = OsPatchState.BEHIND if probe.ubr < ref.target_ubr else OsPatchState.AHEAD
    target = _dotnet_target(ref)
    return OsPatchAssessment(
        state=state,
        baseline_id=ref.baseline_id,
        target_ubr=ref.target_ubr,
        dotnet=_dotnet_state(probe, target),
        dotnet_version=probe.dotnet.mscorlib_version,
        dotnet_target=target,
        **common,
    )
