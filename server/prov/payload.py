"""What a targeted run does NOT have to carry to the unit (MAST_provisioning#186).

The build stays the full module set and declares it -- ``fully_provisioned`` is
judged against ``build-manifest.json``'s ``modules``, so a subset build makes
that flag read true over a partial set (#63, and
docs/decisions/2026-08-11-modules-filters-execution-and-never-the-build.md).
What is reduced here is only what crosses the wire.

**The manifest is complete.** Every staged root entry is recorded exactly once:
under ``module_payload`` against the module(s) that caused it to be staged, or
under ``payload_always`` for what every run needs whatever it targets -- the
client scripts, each provider's ``provide-``/``verify-`` scripts, the repofiles,
``commands.json`` and ``build-manifest.json`` itself. ``build-mast.ps1`` refuses
to write a manifest that leaves anything unrecorded, so there is no catch-all
here and an unrecorded name is a bug rather than a default.

That completeness is what makes the two ways of saying "send everything" agree:
``--force`` sends the whole payload by the empty-target rule, and targeting every
module sends it by attribution alone. ``test_force_and_targeting_every_module_
transfer_the_same_set`` is the assertion; an entry reaching the unit only because
no rule named it would break it.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any


class IncompletePayloadManifestError(Exception):
    """A build-manifest that cannot say what the payload is made of.

    Fail rather than guess in either direction: assuming "send everything" hides
    a driver/build mismatch behind a silently expensive run, and assuming "send
    nothing" ships a payload with holes.
    """


@dataclass(frozen=True)
class Exclusions:
    """Staging-root names to keep out of the transfer, in build order."""

    files: tuple[str, ...] = ()
    dirs: tuple[str, ...] = ()

    def __bool__(self) -> bool:
        return bool(self.files or self.dirs)

    def summary(self) -> str:
        return ",".join((*self.dirs, *self.files)) or "none"


def _names(entry: Any, key: str, where: str) -> list[str]:
    if not isinstance(entry, dict):
        raise IncompletePayloadManifestError(f"{where}: expected an object, got {type(entry).__name__}")
    value = entry.get(key, [])
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise IncompletePayloadManifestError(f"{where}.{key}: expected a list of names, got {value!r}")
    return [v for v in value if v]


def exclusions(build: dict[str, Any], targets: Sequence[str]) -> Exclusions:
    """Recorded assets no module in ``targets`` claims.

    ``targets`` is the driver's post-classification, post-``--modules`` target
    set, which already folds in the always-run modules, so their assets are kept
    by the same rule as anything else. An empty ``targets`` means "run
    everything" -- ``--force``, a first provisioning, the
    aggregate-differs-but-no-module-drifted fallback -- and excludes nothing.
    """
    payload = build.get("module_payload")
    always = build.get("payload_always")
    if not isinstance(payload, dict) or not isinstance(always, dict):
        raise IncompletePayloadManifestError(
            "build-manifest.json has no module_payload/payload_always; the driver and "
            "build/build-mast.ps1 disagree about the payload format"
        )
    # Validated even when nothing will be excluded, so a bad manifest surfaces on
    # the run that produced it rather than on the next targeted one.
    never = {n for key in ("files", "dirs") for n in _names(always, key, "payload_always")}
    claimants: dict[tuple[str, str], set[str]] = {}
    order: list[tuple[str, str]] = []
    for module, entry in payload.items():
        for key in ("files", "dirs"):
            for name in _names(entry, key, f"module_payload.{module}"):
                slot = (key, name)
                if slot not in claimants:
                    claimants[slot] = set()
                    order.append(slot)
                claimants[slot].add(str(module))

    wanted = set(targets)
    if not wanted:
        return Exclusions()

    dropped = [s for s in order if s[1] not in never and not (claimants[s] & wanted)]
    return Exclusions(
        files=tuple(n for k, n in dropped if k == "files"),
        dirs=tuple(n for k, n in dropped if k == "dirs"),
    )
