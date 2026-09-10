"""The vendor set is declared, not folklore (MAST_provisioning#186 stage 0).

`C:\\MAST\\` on the provisioning server holds three unrelated things: build inputs
that are hard to re-acquire, regenerable artifacts, and scratch. Only the first
group has to survive the machine, and until this file existed the list of which
paths those were lived in nobody's head.

These tests keep the declaration and the build in step, the same way
`test_pull_staging_args_match_the_script` keeps the pull script and its caller in
step: a new build-host path that nobody declares fails here rather than being
discovered when the laptop dies.
"""

from __future__ import annotations

import json
import re

from prov import transport as T

VENDOR_INPUTS = T.REPO_ROOT / "server" / "data" / "vendor-inputs.json"
BUILD_SCRIPTS = sorted((T.REPO_ROOT / "build").glob("*.ps1"))
#: Any 'C:\MAST\...' string literal in the build scripts.
MAST_LITERAL = re.compile(r"'(C:\\MAST\\[^']*)'")

REQUIRED = {"name", "path", "kind", "why_not_in_repo", "origin", "used_by"}


def load() -> dict:
    return json.loads(VENDOR_INPUTS.read_text(encoding="utf-8-sig"))


def test_every_entry_is_fully_described():
    # A path with no origin is not a declaration, it is a note. Re-acquiring is
    # the whole point of writing this down.
    for entry in load()["inputs"]:
        missing = REQUIRED - set(entry)
        assert not missing, f"{entry.get('name', entry)} is missing {sorted(missing)}"
        assert entry["kind"] in ("directory", "file")


def test_declared_paths_are_the_ones_the_build_actually_reads():
    declared = {e["path"] for e in load()["inputs"]}
    for entry in load()["inputs"]:
        ref = entry.get("build_reference")
        if not ref:
            continue
        script = T.REPO_ROOT / ref
        assert script.is_file(), f"{entry['name']}: build_reference {ref} does not exist"
        assert entry["path"] in script.read_text(encoding="utf-8"), (
            f"{entry['name']}: {entry['path']} is not referenced by {ref}"
        )
    assert declared, "no vendor inputs declared"


def test_no_undeclared_build_host_path():
    # The guard that matters. A sixth vendored input added to build-mast.ps1
    # without a declaration would otherwise be load-bearing and invisible --
    # exactly how the PlateSolve3 catalog stayed unattributed in the payload.
    data = load()
    known = {e["path"] for e in data["inputs"]} | {e["path"] for e in data["not_vendor_inputs"]}
    found: dict[str, str] = {}
    for script in BUILD_SCRIPTS:
        for literal in MAST_LITERAL.findall(script.read_text(encoding="utf-8")):
            found.setdefault(literal, script.name)
    undeclared = {p: s for p, s in found.items() if p not in known}
    assert not undeclared, (
        f"build-host paths used but not declared in {VENDOR_INPUTS.name}: {undeclared}. "
        "Add it to 'inputs' (it must survive the machine) or 'not_vendor_inputs' (it must not)."
    )


def test_things_deliberately_excluded_say_why():
    for entry in load()["not_vendor_inputs"]:
        assert entry.get("reason"), f"{entry.get('path')} is excluded with no reason given"
