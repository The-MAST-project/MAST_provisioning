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
import re
from dataclasses import dataclass
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
_MANIFEST = _REPO_ROOT / "tools" / "mast-repos.tsv"
_CLONE_PS1 = _REPO_ROOT / "tools" / "mast-clone.ps1"
_CLONE_SH = _REPO_ROOT / "tools" / "mast-clone.sh"

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
#: including ones no assertion below covers. Taken over LF-normalized text, not
#: raw bytes: the CI matrix checks out on both platforms and a Windows checkout
#: rewrites the line endings, so a byte digest would differ by platform alone.
EXPECTED_CLONE_PS1_SHA256 = "30bb68f497b74ea099ce66e7880f1eea5b3ad7979eef7ec1b41fe4cf5b4fd2fb"

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


def test_consults_the_staged_uv() -> None:
    """Stage 4 vendors uv.exe into <Top>\\.tools so a provisioning run needs no CDN.
    It is consulted after `uv` on PATH, and either candidate is taken only on an
    exact match against the manifest pin."""
    script = _CLONE_PS1.read_text(encoding="utf-8")
    assert ".tools\\uv.exe" in script


def test_writes_mast_pth() -> None:
    """<Top> reaches sys.path via mast.pth, not via a shell-set PYTHONPATH."""
    script = _CLONE_PS1.read_text(encoding="utf-8")
    assert "mast.pth" in script


def test_mast_clone_ps1_is_unchanged() -> None:
    normalized = _CLONE_PS1.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    assert digest == EXPECTED_CLONE_PS1_SHA256, (
        "tools/mast-clone.ps1 changed. Review the diff for fleet impact, then update "
        "EXPECTED_CLONE_PS1_SHA256 in the same commit."
    )


# --- the fetch result is never discarded (#175) --------------------------------
#
# On mast05's 2026-08-30 bench reprov, three fetches failed against an unresolvable
# proxy, the module reported SUCCESS, and clone-manifest.json recorded the stale SHAs
# as the intended result. The cause was one call whose result was thrown away, and
# the reason it produced no signal at all is that `merge --ff-only @{u}` then compared
# HEAD against a remote-tracking ref the failed fetch had not moved, printed
# `Already up to date.` and returned success.
#
# Asserted rather than reviewed for the same reason as the shapes in
# test_provider_failure_reporting.py: it is a one-token regression, invisible in a
# run's output, and the alternative to catching it here is reading a per-module log
# on a unit.

_DISCARDED_INVOKE_GIT = re.compile(r"\$null\s*=\s*Invoke-Git", re.IGNORECASE)


def test_no_git_result_is_discarded_in_the_ps1() -> None:
    """`Invoke-Git` documents itself as returning $true on success; assigning that to
    $null is how #175 happened. There is no legitimate fire-and-forget git call in
    this script -- every other call site already checks, which is what made the one
    exception invisible."""
    offenders = [
        f"{i}: {line.strip()}"
        for i, line in enumerate(_CLONE_PS1.read_text(encoding="utf-8").splitlines(), start=1)
        if _DISCARDED_INVOKE_GIT.search(line)
    ]
    assert not offenders, "mast-clone.ps1 discards an Invoke-Git result; check it instead (#175):\n" + "\n".join(offenders)


def test_every_fetch_is_guarded_in_the_sh() -> None:
    """The shell half used to get this right only by accident: under `set -e` a bare
    failing fetch aborted the whole script, which meant no clone-manifest.json and no
    summary at all. Both halves now guard the fetch explicitly and carry on."""
    unguarded = [
        f"{i}: {line.strip()}"
        for i, line in enumerate(_CLONE_SH.read_text(encoding="utf-8").splitlines(), start=1)
        if re.search(r"\bgit\b.*\bfetch\b", line) and not line.strip().startswith("if !")
    ]
    assert not unguarded, "mast-clone.sh runs a git fetch whose failure is not handled (#175):\n" + "\n".join(unguarded)


def test_both_halves_record_fetch_ok() -> None:
    """The sidecar must distinguish 'this SHA is what origin says' from 'this SHA is
    what was already on disk and could not be checked'. provide-mast.ps1 asserts on
    the key and fleet-drift-report.py renders it, so a half that stopped writing it
    would fail the fleet closed (.ps1) or go quiet (.sh)."""
    # Anchored on how each half actually emits the key, not a substring search:
    # 'fetch_ok' matches inside 'fetch_okay' and would pass a rename.
    assert re.search(r"\bfetch_ok\s*=", _CLONE_PS1.read_text(encoding="utf-8"))
    assert '"fetch_ok": %s' in _CLONE_SH.read_text(encoding="utf-8")
