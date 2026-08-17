"""Tests for prov.registry -- the unit-registry models and their reader.

The registry is hand-edited AND written back by the driver's inventory phase, so
these cover both directions: what a malformed entry does at the read, and that a
rewrite preserves everything the file carried.
"""

import json

import pytest
from pydantic import ValidationError

from prov import registry as R
from prov import transport as T

_FULL_ENTRY = {
    "_comment": "the bench unit; do not point this at a production site",
    "hostname": "mastw",
    "site": "wis",
    "maintenance_window": {"start_hour": 0, "end_hour": 24},
    "timezone": "Asia/Jerusalem",
    "ip": "192.168.56.113",
    "mac": "08-00-27-48-EA-CE",
    "modules": ["python", "mast"],
}


def _field_names_in_the_file() -> set[str]:
    """Every key UnitEntry accepts, spelled as the file spells it."""
    return {f.alias or name for name, f in R.UnitEntry.model_fields.items()}


def test_unit_entry_matches_the_registry_template(tmp_path):
    # The template is what an operator copies, so it and UnitEntry must agree: a key
    # added to one and not the other is how the registry and the code reading it
    # drift apart. `_comment` is one of those keys -- modeled, not tolerated, so a
    # rewrite cannot drop it.
    template = json.loads((T.REPO_ROOT / "server" / "unit-registry.json.template").read_text(encoding="utf-8-sig"))
    assert len(template) == 1
    keys = set(template[0])
    declared = _field_names_in_the_file()
    assert keys <= declared, f"template keys absent from UnitEntry: {sorted(keys - declared)}"

    # Everything the model requires must be in the template, or the copied entry is
    # rejected the first time it is read. Derived from the model, not hard-coded.
    required = {name for name, f in R.UnitEntry.model_fields.items() if f.is_required()}
    assert required == {"hostname", "site"}
    assert required <= keys

    # And the template entry itself must load.
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps(template), encoding="utf-8")
    assert [e.hostname for e in R.load_unit_registry(p)] == [template[0]["hostname"]]


@pytest.mark.parametrize(
    ("entry", "expected"),
    [
        ({"site": "ns"}, "hostname"),
        ({"hostname": "mast01"}, "site"),
        ({"hostname": "mast01", "site": "   "}, "site"),
        ({"hostname": "mast01", "site": 7}, "site"),
        ({"hostname": "mast01", "site": "ns", "maintenance_window": {"start_hour": 0}}, "end_hour"),
        (
            {"hostname": "mast01", "site": "ns", "maintenance_window": {"start_hour": 0, "end_hour": "half six"}},
            "end_hour",
        ),
        ({"hostname": "mast01", "site": "ns", "sitte": "ns"}, "sitte"),
    ],
    ids=[
        "no hostname",
        "no site",
        "blank site",
        "non-string site",
        "half a window",
        "unparseable hour",
        "misspelled key",
    ],
)
def test_load_unit_registry_rejects_a_malformed_entry(tmp_path, entry, expected):
    # Rejected at the read, naming the file: a registry the driver cannot trust must
    # not reach the phase that would provision from it. The misspelled-key case is
    # what the closed model buys -- `sitte: "ns"` would otherwise be carried along
    # silently while `site` went missing.
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps([entry]), encoding="utf-8")
    with pytest.raises(TypeError, match=expected):
        R.load_unit_registry(p)
    # And the file is named, so an operator knows which one to fix.
    with pytest.raises(TypeError, match="unit-registry.json"):
        R.load_unit_registry(p)


def test_load_unit_registry_accepts_the_optional_keys_absent(tmp_path):
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps([{"hostname": "mast01", "site": "ns"}]), encoding="utf-8")
    (entry,) = R.load_unit_registry(p)
    assert entry.hostname == "mast01"
    assert entry.mac is None
    assert entry.maintenance_window is None


def test_round_trip_preserves_everything_the_file_carried(tmp_path):
    # The inventory phase rewrites the WHOLE registry to record one MAC, so a
    # round-trip that dropped a field -- `_comment`, or an entry's `modules` -- would
    # quietly edit the operator's file. This is the guard for that.
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps([_FULL_ENTRY]), encoding="utf-8")
    assert R.dump_unit_registry(R.load_unit_registry(p)) == [_FULL_ENTRY]


def test_round_trip_does_not_add_nulls_for_absent_keys(tmp_path):
    # ...and it must not go the other way either: writing a MAC should not stamp
    # "ip": null, "modules": null onto every other hand-written entry.
    minimal = {"hostname": "mast01", "site": "ns"}
    p = tmp_path / "unit-registry.json"
    p.write_text(json.dumps([minimal]), encoding="utf-8")
    entries = R.load_unit_registry(p)
    entries[0].mac = "10-7C-61-5B-06-25"
    assert R.dump_unit_registry(entries) == [{**minimal, "mac": "10-7C-61-5B-06-25"}]


def test_assignment_is_validated():
    # validate_assignment: the MAC comes from a remote inventory read, so a bad value
    # fails where it is set rather than at the next read of the file.
    entry = R.UnitEntry(hostname="mast01", site="ns")
    with pytest.raises(ValidationError):
        entry.mac = 42  # pyright: ignore[reportAttributeAccessIssue]
