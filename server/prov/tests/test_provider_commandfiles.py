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
