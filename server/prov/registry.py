"""The unit registry: ``server/unit-registry.json`` and the models that describe it.

The registry is the operator's declaration of the fleet -- which units exist,
which site's bootstrap profile each takes, and when each may be provisioned. It is
hand-edited, and the driver also writes to it (the inventory phase records a MAC),
so the models here own both directions: read with validation, write without losing
anything the file carried.

Pydantic rather than a TypedDict or a plain dict, matching MAST_common's config
layer, which models every config document this way. The registry is config too.

Deliberately its own module rather than part of prov.transport: transport is the
WinRM/SSH layer, and a config schema is not transport. It borrows only the
BOM-tolerant JSON reader from there.
"""

from __future__ import annotations

from pathlib import Path
from typing import Annotated, Any

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, ValidationError

from prov import transport

#: A required identifier: whitespace-stripped and non-empty, so `"  "` is rejected
#: rather than silently becoming an empty hostname or site.
Identifier = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]

_STRICT = ConfigDict(
    # Closed models, no `extra="allow"`. Every field the file may carry is declared
    # below -- including `_comment`, which the template uses -- so a round-trip
    # cannot drop anything, and a misspelled key (`sitte`) is an error at the read
    # instead of a value silently ignored for the life of the fleet.
    extra="forbid",
    # Validate on assignment too: the driver sets `entry.mac` from a remote
    # inventory, and a bad value should fail there rather than at the next read.
    validate_assignment=True,
    populate_by_name=True,
)


class MaintenanceWindow(BaseModel):
    """The hours a unit may be provisioned in, in the unit's own ``timezone``.

    Both bounds are required: an entry carrying only one is rejected at the read,
    which is why nothing downstream handles a half-specified window.
    """

    model_config = _STRICT

    start_hour: int
    end_hour: int


class UnitEntry(BaseModel):
    """One entry in ``server/unit-registry.json``.

    ``hostname`` and ``site`` are required. ``site`` selects the bootstrap config
    profile and is the operator's explicit choice, never derived from the hostname,
    so an entry without one is rejected rather than defaulted -- see the decision
    record. Everything else is optional and defaults to None.
    """

    model_config = _STRICT

    hostname: Identifier
    site: Identifier
    #: The template's documentation field. Modeled so a rewrite preserves it;
    #: aliased because pydantic treats a leading underscore as a private attribute.
    comment: str | None = Field(default=None, alias="_comment")
    timezone: str | None = None
    maintenance_window: MaintenanceWindow | None = None
    ip: str | None = None
    #: Written by the driver's inventory phase, not usually by hand.
    mac: str | None = None
    #: Omitted means "every provider discovered under server/providers"; a list
    #: deliberately restricts this unit to a subset.
    modules: list[str] | None = None


def load_unit_registry(path: Path) -> list[UnitEntry]:
    """Every entry in the registry, validated, or ``TypeError`` naming the file.

    TypeError rather than pydantic's ValidationError so the three readers in this
    repo report a malformed file the same way (see ``transport.load_json_object`` /
    ``load_json_list``); the validation detail is carried through in the message.
    """
    entries = transport.load_json_list(path)
    try:
        return [UnitEntry.model_validate(entry) for entry in entries]
    except ValidationError as e:
        raise TypeError(f"{path}: {e}") from e


def dump_unit_registry(entries: list[UnitEntry]) -> list[dict[str, Any]]:
    """The entries as JSON-ready dicts, for writing the registry back.

    ``by_alias`` so ``comment`` goes back out as ``_comment``, and ``exclude_none``
    so an optional key the file did not carry does not reappear as an explicit
    ``null`` -- this file is hand-edited, and a MAC write should not reformat every
    other entry.
    """
    return [entry.model_dump(by_alias=True, exclude_none=True) for entry in entries]
