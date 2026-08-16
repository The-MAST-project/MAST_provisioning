"""Dev-drift alarm on tools/mast-clone.ps1 and tools/mast-repos.tsv (#31).

Provisioning delegates the unit's whole source layout to mast-clone, a tool whose
primary consumer is the dev workflow. These assertions pin the part units depend
on, so a change made for development reasons fails here before it reaches a unit.

A failure is not necessarily a defect: update the snapshot in the same commit that
reviews the change. That update is the acknowledgement that the change is
fleet-affecting.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
_MANIFEST = _REPO_ROOT / "tools" / "mast-repos.tsv"
_CLONE_PS1 = _REPO_ROOT / "tools" / "mast-clone.ps1"

#: The rows role `unit` resolves to, as (dir, repo, branch, rev). Adding a repo to
#: the role, retargeting one at a feature branch, or pinning a rev changes what
#: every unit receives.
EXPECTED_UNIT_ROWS = {
    ("common", "MAST_common", "master", ""),
    ("unit", "MAST_unit.2024-12-12", "main", ""),
    ("claude", "mast-claude-config", "main", ""),
}

#: `#!uv-version` directive: the resolver every unit's venv is built with.
EXPECTED_UV_VERSION = "0.11.33"

#: SHA-256 of tools/mast-clone.ps1 -- the coarse backstop that surfaces any edit,
#: including ones no assertion below covers.
EXPECTED_CLONE_PS1_SHA256 = "13ef758a2b025a56651ded258263a79355dedba98c619271296e27056536de19"

#: Parameters provide-mast.ps1 passes, or relies on existing.
REQUIRED_PARAMETERS = ("Top", "Role", "Transport", "Update", "DryRun")

_ROLE = "unit"


@dataclass(frozen=True)
class ManifestRow:
    dir: str
    repo: str
    roles: tuple[str, ...]
    branch: str
    rev: str


def _read_manifest(path: Path) -> tuple[list[ManifestRow], str | None]:
    """Rows and the `#!uv-version` value, parsed as both clone scripts parse them."""
    rows: list[ManifestRow] = []
    uv_version: str | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#!uv-version"):
            parts = stripped.split()
            if len(parts) >= 2:
                uv_version = parts[1]
            continue
        if not stripped or stripped.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 4:
            continue
        rows.append(
            ManifestRow(
                dir=fields[0].strip(),
                repo=fields[1].strip(),
                roles=tuple(r.strip() for r in fields[2].split(",")),
                branch=fields[3].strip(),
                rev=fields[4].strip() if len(fields) >= 5 else "",
            )
        )
    return rows, uv_version


@pytest.fixture(scope="module")
def manifest() -> tuple[list[ManifestRow], str | None]:
    return _read_manifest(_MANIFEST)


def _unit_rows(rows: list[ManifestRow]) -> set[tuple[str, str, str, str]]:
    return {(r.dir, r.repo, r.branch, r.rev) for r in rows if _ROLE in r.roles or "all" in r.roles}


def test_unit_role_resolves_to_the_expected_rows(manifest) -> None:
    rows, _ = manifest
    assert _unit_rows(rows) == EXPECTED_UNIT_ROWS


def test_uv_version_is_the_pinned_one(manifest) -> None:
    _, uv_version = manifest
    assert uv_version == EXPECTED_UV_VERSION


def test_unit_layout_is_common_unit_claude(manifest) -> None:
    """<Top>\\{common,unit,claude} -- the three NSSM coordinates are built on it."""
    rows, _ = manifest
    assert {d for d, _, _, _ in _unit_rows(rows)} == {"common", "unit", "claude"}


def test_common_is_named_common(manifest) -> None:
    """MAST_common's repo root IS the `common` package; any other folder name
    breaks every `from common.X import ...` in the fleet."""
    rows, _ = manifest
    assert [r.dir for r in rows if r.repo == "MAST_common"] == ["common"]


def test_every_unit_row_pins_a_branch(manifest) -> None:
    rows, _ = manifest
    assert all(branch for _, _, branch, _ in _unit_rows(rows))


def test_invocation_surface_still_exists() -> None:
    script = _CLONE_PS1.read_text(encoding="utf-8")
    missing = [p for p in REQUIRED_PARAMETERS if f"${p}" not in script]
    assert not missing, f"mast-clone.ps1 no longer declares: {missing}"


def test_https_transport_is_accepted() -> None:
    """provide-mast.ps1 invokes with -Transport https; units have no deploy key."""
    script = _CLONE_PS1.read_text(encoding="utf-8")
    assert "ValidateSet('ssh', 'https')" in script


def test_prefers_a_staged_uv_over_bootstrapping() -> None:
    """Stage 4 vendors uv.exe into the payload so provisioning needs no CDN."""
    script = _CLONE_PS1.read_text(encoding="utf-8")
    assert ".tools\\uv.exe" in script


def test_writes_mast_pth() -> None:
    """NSSM services inherit no shell env, so <Top> reaches sys.path via mast.pth."""
    script = _CLONE_PS1.read_text(encoding="utf-8")
    assert "mast.pth" in script


def test_mast_clone_ps1_is_unchanged() -> None:
    digest = hashlib.sha256(_CLONE_PS1.read_bytes()).hexdigest()
    assert digest == EXPECTED_CLONE_PS1_SHA256, (
        "tools/mast-clone.ps1 changed. Review the diff for fleet impact, then update "
        "EXPECTED_CLONE_PS1_SHA256 in the same commit."
    )
