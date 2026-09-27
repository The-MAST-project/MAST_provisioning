"""The manifest that lets vendored binaries leave git-LFS.

Every LFS pointer already carries the `oid sha256` and `size` of the object it
stands for, so the manifest is *derived* from what git already holds rather than
typed by anyone. That is the whole reason retiring LFS is mechanical: the data
needed to replace it is the data LFS itself stores (MAST_provisioning#48).

Deriving it also means it cannot disagree with the pointers while both exist,
which is what makes the migration reversible until the untracking step.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

import pytest

from prov.asset_manifest import build_manifest, module_of


def git(repo: Path, *args: str, stdin: bytes | None = None) -> str:
    return subprocess.run(["git", *args], cwd=repo, input=stdin, capture_output=True, check=True).stdout.decode()


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A repo with pointer-shaped blobs, so no git-lfs install is required."""
    r = tmp_path / "repo"
    (r / "server/providers/chrome/assets").mkdir(parents=True)
    (r / "client/assets").mkdir(parents=True)
    git(r, "init", "-q")
    git(r, "config", "user.email", "t@t")
    git(r, "config", "user.name", "t")

    def pointer(body: bytes) -> bytes:
        d = hashlib.sha256(body).hexdigest()
        return f"version https://git-lfs.github.com/spec/v1\noid sha256:{d}\nsize {len(body)}\n".encode()

    (r / "server/providers/chrome/assets/chrome.msi").write_bytes(pointer(b"x" * 4096))
    (r / "client/assets/npcap.exe").write_bytes(pointer(b"y" * 99))
    (r / "README.md").write_bytes(b"not an asset\n")
    git(r, "add", "-A")
    git(r, "commit", "-qm", "assets")
    return r


LFS = {"server/providers/chrome/assets/chrome.msi", "client/assets/npcap.exe"}


def test_every_lfs_path_becomes_a_row(repo):
    m = build_manifest(repo, lfs_paths=LFS)
    assert {f["path"] for f in m["files"]} == LFS


def test_each_row_carries_what_a_fetch_needs(repo):
    """sha256 and size, taken from the pointer -- not recomputed, not guessed."""
    m = build_manifest(repo, lfs_paths=LFS)
    row = next(f for f in m["files"] if f["path"].endswith("chrome.msi"))
    assert row["sha256"] == hashlib.sha256(b"x" * 4096).hexdigest()
    assert row["size"] == 4096


def test_a_file_that_is_not_lfs_is_not_in_the_manifest(repo):
    m = build_manifest(repo, lfs_paths=LFS)
    assert not any(f["path"] == "README.md" for f in m["files"])


def test_rows_name_the_module_that_owns_them(repo):
    # The fetch is per-asset, but a human reading a drift report wants to know
    # which provider just lost its installer.
    m = build_manifest(repo, lfs_paths=LFS)
    by_path = {f["path"]: f["module"] for f in m["files"]}
    assert by_path["server/providers/chrome/assets/chrome.msi"] == "chrome"
    assert by_path["client/assets/npcap.exe"] == "client"


def test_module_of_handles_both_layouts():
    assert module_of("server/providers/zwo/assets/driver/x64/a.sys") == "zwo"
    assert module_of("client/assets/npcap.exe") == "client"
    assert module_of("tools/something.ps1") is None


def test_the_manifest_is_byte_stable(repo):
    """It is regenerated and committed; churn on every run would make the diff
    meaningless and train the reader to skip it."""
    a = json.dumps(build_manifest(repo, lfs_paths=LFS), indent=2, sort_keys=True)
    b = json.dumps(build_manifest(repo, lfs_paths=LFS), indent=2, sort_keys=True)
    assert a == b


def test_rows_are_ordered_so_the_diff_reads(repo):
    m = build_manifest(repo, lfs_paths=LFS)
    assert [f["path"] for f in m["files"]] == sorted(f["path"] for f in m["files"])


# --- the committed manifest, against the repository it indexes ----------------
#
# Deliberately not via `git lfs ls-files`: that needs git-lfs installed, and CI
# checks out without LFS. A pointer is recognisable from its blob alone, so this
# asks git directly and works anywhere.

import subprocess as _sp  # noqa: E402

from prov import transport as _T  # noqa: E402
from prov.asset_manifest import _pointers  # noqa: E402

COMMITTED = _T.REPO_ROOT / "server" / "data" / "provider-assets.json"
POINTER = b"version https://git-lfs"


def tracked_pointer_paths() -> set[str]:
    """Every tracked file whose committed blob is an LFS pointer."""
    out = _sp.run(["git", "ls-files", "-z"], cwd=_T.REPO_ROOT, capture_output=True, check=True).stdout.decode(
        "utf-8", "surrogateescape"
    )
    paths = [p for p in out.split("\0") if p]
    blobs = _pointers(_T.REPO_ROOT, paths)
    return {p for p, b in blobs.items() if b.startswith(POINTER)}


def test_the_committed_manifest_indexes_every_lfs_asset():
    """An asset added to LFS and not to the manifest is one the store may lack.

    That is not hypothetical: when this manifest was first generated the store was
    missing two of 162 -- an installer no module declares and the bootstrap
    npcap -- because the store only ever saw what a payload carried.
    """
    committed = {f["path"] for f in json.loads(COMMITTED.read_text())["files"]}
    assert committed == tracked_pointer_paths()


def test_each_committed_row_matches_the_pointer_it_came_from():
    rows = {f["path"]: f for f in json.loads(COMMITTED.read_text())["files"]}
    blobs = _pointers(_T.REPO_ROOT, sorted(rows))
    for path, row in rows.items():
        blob = blobs[path]
        assert f"oid sha256:{row['sha256']}".encode() in blob, path
        assert f"size {row['size']}".encode() in blob, path
