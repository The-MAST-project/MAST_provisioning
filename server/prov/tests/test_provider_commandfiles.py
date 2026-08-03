"""Guard: every provider ``*-lib.ps1`` must be staged.

Regression guard for the proxy-lib.ps1 gap (2026-07-21): provide-proxy.ps1
dot-sources proxy-lib.ps1, but it was missing from proxy/module.json
``commandfiles``, so build-mast never staged it and the unit threw
"proxy-lib.ps1 not found next to provide-proxy.ps1" at order 100.

Invariant: any ``<provider>/<name>-lib.ps1`` present in the tree must be listed
in that provider's module.json ``commandfiles`` (or it will not reach the unit).
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

# server/prov/tests/test_*.py -> parents[3] == repo root
REPO_ROOT = Path(__file__).resolve().parents[3]
PROVIDERS = REPO_ROOT / "server" / "providers"

_LIBS = sorted(PROVIDERS.glob("*/*-lib.ps1"))


@pytest.mark.parametrize("lib", _LIBS, ids=lambda p: p.parent.name + "/" + p.name)
def test_provider_lib_is_in_commandfiles(lib: Path) -> None:
    module_json = lib.parent / "module.json"
    assert module_json.exists(), f"{lib} has no sibling module.json"
    data = json.loads(module_json.read_text(encoding="utf-8-sig"))
    commandfiles = data.get("commandfiles", [])
    assert lib.name in commandfiles, (
        f"{lib.name} exists in {lib.parent.name}/ but is not in its module.json "
        f"commandfiles ({commandfiles}); build-mast will not stage it and the "
        f"provider will fail on the unit with a 'not found' error."
    )


_MODULE_JSONS = sorted(PROVIDERS.glob("*/module.json"))

# Payloads deliberately absent from a dev checkout; build-mast skips them only
# under -TestMode and throws otherwise (build-mast.ps1 staging loop).
_OPTIONAL_COMMANDFILES = {
    ("cygwin", "assets/astrometry.tgz"),
    ("mast", "assets/uv-x86_64-pc-windows-msvc.zip"),
    ("mast", "assets/uv-x86_64-pc-windows-msvc.zip.sha256"),
}


def _entries(module_json: Path, key: str) -> list[str]:
    data = json.loads(module_json.read_text(encoding="utf-8-sig"))
    return [str(e) for e in (data.get(key) or [])]


@pytest.mark.parametrize("module_json", _MODULE_JSONS, ids=lambda p: p.parent.name)
def test_commandfiles_entries_exist(module_json: Path) -> None:
    """A manifest naming a file that is not there fails the build, late.

    The staging loop throws on a missing commandfile, so a stale entry left
    behind by a refactor breaks every build for every unit -- worth catching in
    a suite that runs in a second rather than in a 10-minute payload build.
    """
    provider = module_json.parent.name
    missing = [
        e for e in _entries(module_json, "commandfiles")
        if (provider, e) not in _OPTIONAL_COMMANDFILES
        and not (module_json.parent / e).exists()
    ]
    assert not missing, f"{provider}/module.json lists commandfiles that do not exist: {missing}"


@pytest.mark.parametrize("module_json", _MODULE_JSONS, ids=lambda p: p.parent.name)
def test_repofiles_entries_exist_and_are_contained(module_json: Path) -> None:
    """repofiles are repo-top-relative and must resolve inside the repo.

    Mirrors the containment rule enforced at build time by
    Resolve-MastRepoFile (build/build-staging-lib.ps1); this catches a bad
    entry without needing PowerShell.
    """
    provider = module_json.parent.name
    for entry in _entries(module_json, "repofiles"):
        assert not Path(entry).is_absolute(), f"{provider}: repofiles entry is absolute: {entry}"
        assert ".." not in Path(entry).parts, f"{provider}: repofiles entry escapes the repo: {entry}"
        target = REPO_ROOT / entry
        assert target.is_file(), f"{provider}: repofiles entry does not exist: {entry}"
