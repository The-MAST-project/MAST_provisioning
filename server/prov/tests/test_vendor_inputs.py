"""The vendor set is declared, not folklore (MAST_provisioning#186 stage 0).

`C:\\MAST\\` on the provisioning server holds three unrelated things: build inputs
that are hard to re-acquire, regenerable artifacts, and scratch. Only the first
group has to survive the machine, and until this file existed the list of which
paths those were lived in nobody's head.

Since #48 those inputs are not a second set beside the LFS-held assets: they are
rows in the same `server/data/assets.json`, keyed by the path each file would
have if it were tracked, and read through the same cache. So these tests guard
two joints -- the declaration against the generated manifest, and the declaration
against the build scripts, the same way `test_pull_staging_args_match_the_script`
keeps the pull script and its caller in step.
"""

from __future__ import annotations

import json
import re

from prov import transport as T

VENDOR_INPUTS = T.REPO_ROOT / "server" / "data" / "vendor-inputs.json"
ASSETS = T.REPO_ROOT / "server" / "data" / "assets.json"
BUILD_SCRIPTS = sorted((T.REPO_ROOT / "build").glob("*.ps1"))
MIRROR = T.REPO_ROOT / "tools" / "vendor-mirror.sh"
#: The delimited source list the mirror carries.
SOURCES_BLOCK = re.compile(r"# MIRROR_SOURCES_BEGIN(.*?)# MIRROR_SOURCES_END", re.DOTALL)
SOURCE_NAME = re.compile(r'^\s*"([^":]+):', re.MULTILINE)
#: The machine-wide cache every asset is read from.
ASSET_CACHE_ROOT = "C:\\MAST\\provider-assets"
#: Any 'C:\MAST\...' string literal in the build scripts.
MAST_LITERAL = re.compile(r"'(C:\\MAST\\[^']*)'")

REQUIRED = {"name", "cached", "why_not_in_repo", "origin", "reacquire", "used_by"}


def load() -> dict:
    return json.loads(VENDOR_INPUTS.read_text(encoding="utf-8-sig"))


def assets() -> dict:
    return json.loads(ASSETS.read_text(encoding="utf-8-sig"))


def test_every_entry_is_fully_described():
    # A path with no origin is not a declaration, it is a note. Re-acquiring is
    # the whole point of writing this down.
    for entry in load()["inputs"]:
        missing = REQUIRED - set(entry)
        assert not missing, f"{entry.get('name', entry)} is missing {sorted(missing)}"


def test_a_cached_input_is_keyed_in_the_one_asset_namespace():
    # The cache mirrors the repo tree, so a cached input needs the path its files
    # would have if they were tracked -- otherwise nothing can resolve it.
    for entry in load()["inputs"]:
        if not entry["cached"]:
            assert entry.get("path"), f"{entry['name']}: an uncached input still needs a path"
            continue
        prefix = entry.get("prefix")
        assert prefix, f"{entry['name']} is cached but declares no prefix"
        assert prefix.startswith("server/providers/"), f"{entry['name']}: {prefix}"
        assert entry.get("files"), f"{entry['name']} is cached but declares no files"
        for f in entry["files"]:
            assert f["path"].startswith(prefix), f"{entry['name']}: {f['path']} is outside {prefix}"
            assert re.fullmatch(r"[0-9a-f]{64}", f["sha256"]), f"{entry['name']}: {f['path']}"
            assert f["size"] > 0


def test_the_generated_manifest_carries_every_declared_file():
    """The declaration and the one index cannot drift apart silently.

    A hand-edited vendor-inputs.json with no regenerate is exactly the drift this
    catches: the build reads assets.json and would not see the new file at all.
    """
    indexed = {f["path"]: f for f in assets()["files"]}
    for entry in load()["inputs"]:
        for f in entry.get("files", []):
            got = indexed.get(f["path"])
            assert got is not None, f"{f['path']} is declared but missing from {ASSETS.name}; regenerate it"
            assert got["sha256"] == f["sha256"] and got["size"] == f["size"], f["path"]
            assert got["source"] == entry["name"]


def test_an_uncached_input_reaches_no_asset_row():
    # The NoMachine seats are issued certificates sourced from the gitignored
    # vault/. A row here would put them in the cache that fetch-assets.sh
    # populates, which is the leak Assert-MastNoNoMachineCertsInAssets exists for.
    uncached = {e["name"] for e in load()["inputs"] if not e["cached"]}
    for row in assets()["files"]:
        assert row["source"] not in uncached, f"{row['path']} comes from an uncached input"


def test_declared_paths_are_the_ones_the_build_actually_reads():
    for entry in load()["inputs"]:
        ref = entry.get("build_reference")
        if not ref:
            continue
        script = T.REPO_ROOT / ref
        assert script.is_file(), f"{entry['name']}: build_reference {ref} does not exist"
        text = script.read_text(encoding="utf-8")
        # A cached input's re-acquisition tool has to write into the slot the
        # build reads from; an uncached one is still named by the script directly.
        slot = ASSET_CACHE_ROOT + "\\" + entry["prefix"].rstrip("/").replace("/", "\\") if entry["cached"] else entry["path"]
        assert slot in text, f"{entry['name']}: {ref} does not reference {slot}"


def test_no_undeclared_build_host_path():
    # The guard that matters. A sixth vendored input added to build-mast.ps1
    # without a declaration would otherwise be load-bearing and invisible --
    # exactly how the PlateSolve3 catalog stayed unattributed in the payload.
    data = load()
    slots = {ASSET_CACHE_ROOT + "\\" + e["prefix"].rstrip("/").replace("/", "\\") for e in data["inputs"] if e.get("prefix")}
    known = slots | {ASSET_CACHE_ROOT} | {e["path"] for e in data["not_vendor_inputs"]}
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


def test_the_mirror_carries_every_declared_input():
    """The drift this catches has already happened once.

    `nomachine-licenses` is declared here and was absent from the mirror script's
    source list, so four of the five inputs were mirrored by the job and the fifth
    reached mast-ns-control by hand. Nothing reported the gap -- the job exited 0
    having done what it was told.
    """
    block = SOURCES_BLOCK.search(MIRROR.read_text(encoding="utf-8"))
    assert block, "no MIRROR_SOURCES block in vendor-mirror.sh"
    assert set(SOURCE_NAME.findall(block.group(1))) == {e["name"] for e in load()["inputs"]}


def test_the_mirror_reads_the_cache_slots_the_declaration_names():
    # The mirror pushes the build host's only copy upstream. Pointed at a stale
    # path it would skip the input and still exit 0, which is the failure above.
    text = MIRROR.read_text(encoding="utf-8")
    for entry in load()["inputs"]:
        prefix = entry.get("prefix")
        if not prefix:
            continue
        assert prefix.rstrip("/") in text, f"{entry['name']}: vendor-mirror.sh does not read {prefix}"


def test_the_mirror_lives_in_the_repo():
    """It ran from C:\\agent-worktrees\\... until 2026-09-17.

    That is an agent task folder, which the workspace contract tears down with
    `rm -rf`; the job was also registered One Time Only, so it had run once and had
    no next run. A scheduled task pointing into disposable scratch is one teardown
    from silently not existing.
    """
    assert MIRROR.is_file()
    assert "agent-worktrees" not in MIRROR.read_text(encoding="utf-8")
