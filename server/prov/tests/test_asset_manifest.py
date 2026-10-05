"""The one index of every asset a payload needs (MAST_provisioning#48).

Every row is *declared* in vendor-inputs.json. The LFS-held ones were derived
from the pointers until #48 froze them there, and doing the freeze before the
untracking rather than with it is the point: a digest derived from a pointer
stops being derivable the moment the pointer goes, so one step would have emptied
162 rows out of the index with nothing to notice.

While the frozen digests and the pointers both exist, the last tests here check
each against the other. They are transitional by construction and retire with the
pointers -- but until then they are the proof that the freeze was faithful.

They used to be two indexes, two caches and two fetch paths. Merging them is what
lets the build read one manifest and resolve every asset the same way.
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


DECLARED = {
    "inputs": [
        {
            "name": "big-catalog",
            "cached": True,
            "kind": "directory",
            "prefix": "server/providers/planewave/assets/catalog/",
            "used_by": ["planewave"],
            "why_not_in_repo": "2 GB vendor download.",
            "origin": "planewave.com",
            "reacquire": "Download it again.",
            "files": [
                {"path": "server/providers/planewave/assets/catalog/a.bin", "sha256": "a" * 64, "size": 7},
            ],
        },
        {
            "name": "frozen",
            "cached": True,
            # No prefix: the frozen set spans every module and the client media.
            "provenance": False,
            "used_by": [],
            "why_not_in_repo": "Carried by git-LFS until it was retired.",
            "origin": "This repository's history.",
            "reacquire": "The content store.",
            "files": [
                {"path": "server/providers/chrome/assets/chrome.msi", "sha256": "c" * 64, "size": 4096},
                {"path": "client/assets/npcap.exe", "sha256": "d" * 64, "size": 99},
            ],
        },
        {
            "name": "secrets",
            "cached": False,
            "kind": "directory",
            "path": "vault\\secrets",
            "used_by": ["nomachine"],
            "why_not_in_repo": "Issued certificates.",
            "origin": "The vendor.",
            "reacquire": "Buy another seat.",
        },
    ],
    "not_vendor_inputs": [],
}


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A repo with pointer-shaped blobs, so no git-lfs install is required."""
    r = tmp_path / "repo"
    (r / "server/providers/chrome/assets").mkdir(parents=True)
    (r / "client/assets").mkdir(parents=True)
    (r / "server/data").mkdir(parents=True)
    (r / "server/data/vendor-inputs.json").write_text(json.dumps(DECLARED), encoding="utf-8")
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


def test_every_declared_file_becomes_a_row(repo):
    m = build_manifest(repo)
    assert {f["path"] for f in m["files"]} == {
        "server/providers/planewave/assets/catalog/a.bin",
        "server/providers/chrome/assets/chrome.msi",
        "client/assets/npcap.exe",
    }


def test_each_row_carries_what_a_fetch_needs(repo):
    """sha256 and size -- what fetch-assets.sh hashes against. Not recomputed here."""
    m = build_manifest(repo)
    row = next(f for f in m["files"] if f["path"].endswith("chrome.msi"))
    assert row["sha256"] == "c" * 64
    assert row["size"] == 4096
    assert row["source"] == "frozen"


def test_a_file_that_is_declared_nowhere_is_not_in_the_manifest(repo):
    m = build_manifest(repo)
    assert not any(f["path"] == "README.md" for f in m["files"])


def test_rows_name_the_module_that_owns_them(repo):
    # The fetch is per-asset, but a human reading a drift report wants to know
    # which provider just lost its installer.
    m = build_manifest(repo)
    by_path = {f["path"]: f["module"] for f in m["files"]}
    assert by_path["server/providers/chrome/assets/chrome.msi"] == "chrome"
    assert by_path["client/assets/npcap.exe"] == "client"


def test_an_uncached_input_contributes_no_row(repo):
    # It is recorded as a source so the set is still described in one place, but
    # it must never reach the cache the fetch populates.
    m = build_manifest(repo)
    assert "secrets" in {s["name"] for s in m["sources"]}
    assert not any(f["source"] == "secrets" for f in m["files"])


def test_every_source_is_named(repo):
    m = build_manifest(repo)
    assert {s["name"] for s in m["sources"]} == {"big-catalog", "frozen", "secrets"}


def test_one_path_cannot_come_from_two_sources(repo):
    """One path is one file, and nothing decides which byte wins."""
    from prov.asset_manifest import ManifestError

    clash = json.loads((repo / "server/data/vendor-inputs.json").read_text())
    clash["inputs"][0]["files"][0]["path"] = "server/providers/chrome/assets/chrome.msi"
    (repo / "server/data/vendor-inputs.json").write_text(json.dumps(clash), encoding="utf-8")
    with pytest.raises(ManifestError, match="claimed by both"):
        build_manifest(repo)


def test_a_missing_declaration_is_an_error_not_an_empty_index(repo):
    # Silently emitting nothing would produce a manifest that looks complete and
    # drops 13.87 GiB of assets.
    from prov.asset_manifest import ManifestError

    (repo / "server/data/vendor-inputs.json").unlink()
    with pytest.raises(ManifestError):
        build_manifest(repo)


def test_module_of_handles_both_layouts():
    assert module_of("server/providers/zwo/assets/driver/x64/a.sys") == "zwo"
    assert module_of("client/assets/npcap.exe") == "client"
    assert module_of("tools/something.ps1") is None


def test_the_manifest_is_byte_stable(repo):
    """It is regenerated and committed; churn on every run would make the diff
    meaningless and train the reader to skip it."""
    a = json.dumps(build_manifest(repo), indent=2, sort_keys=True)
    b = json.dumps(build_manifest(repo), indent=2, sort_keys=True)
    assert a == b


def test_rows_are_ordered_so_the_diff_reads(repo):
    m = build_manifest(repo)
    assert [f["path"] for f in m["files"]] == sorted(f["path"] for f in m["files"])


# --- freeze fidelity: the frozen digests against the pointers they came from ---
#
# TRANSITIONAL. These retire with the pointers, at the untracking. Until then they
# are the only thing that can catch a frozen digest that does not match the file
# git still holds -- a hand-edit, a bad merge, or a regeneration against the wrong
# tree. Once the pointers are gone there is nothing left to compare against, which
# is exactly why the freeze had to happen first and be checked while it could be.
#
# Deliberately not via `git lfs ls-files`: that needs git-lfs installed, and CI
# checks out without LFS. A pointer is recognisable from its blob alone, so this
# asks git directly and works anywhere.

import subprocess as _sp  # noqa: E402

from prov import transport as _T  # noqa: E402
from prov.asset_manifest import _pointers  # noqa: E402

COMMITTED = _T.REPO_ROOT / "server" / "data" / "assets.json"
POINTER = b"version https://git-lfs"


def tracked_pointer_paths() -> set[str]:
    """Every tracked file whose committed blob is an LFS pointer."""
    out = _sp.run(["git", "ls-files", "-z"], cwd=_T.REPO_ROOT, capture_output=True, check=True).stdout.decode(
        "utf-8", "surrogateescape"
    )
    paths = [p for p in out.split("\0") if p]
    blobs = _pointers(_T.REPO_ROOT, paths)
    return {p for p, b in blobs.items() if b.startswith(POINTER)}


def committed_lfs_rows() -> dict[str, dict]:
    """The frozen ex-LFS rows. The build-host rows have no pointer to check
    against -- their digests came from the blobstore, by inode."""
    return {f["path"]: f for f in json.loads(COMMITTED.read_text())["files"] if f["source"] == "git-lfs"}


def test_every_pointer_still_in_the_tree_has_a_frozen_row():
    """An asset in LFS and not in the manifest is one the store may lack.

    That is not hypothetical: when this manifest was first generated the store was
    missing two of 162 -- an installer no module declares and the bootstrap
    npcap -- because the store only ever saw what a payload carried. Now that the
    rows are frozen rather than derived, this is also what catches an asset added
    to LFS after the freeze, which nothing would otherwise pick up.
    """
    assert committed_lfs_rows().keys() == tracked_pointer_paths()


def test_each_frozen_row_matches_the_pointer_it_was_taken_from():
    rows = committed_lfs_rows()
    blobs = _pointers(_T.REPO_ROOT, sorted(rows))
    for path, row in rows.items():
        blob = blobs[path]
        assert f"oid sha256:{row['sha256']}".encode() in blob, path
        assert f"size {row['size']}".encode() in blob, path
