"""The working tree must match the commit the build will record as its provenance.

`git status` cannot establish this. Its stat cache skips the content comparison
when a file's size and mtime match the index entry, so a tree can diverge from its
own commit and go on reporting clean -- which is how two trees at `dd4d16f` built
payloads differing in 113 files while both looked clean (#216).

The tests below use `git update-index --assume-unchanged` to reproduce that
blindness deliberately: it is the same end state -- a file git will not look at.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from prov.tree_integrity import diverged_files


def git(repo: Path, *args: str, stdin: bytes | None = None) -> str:
    return subprocess.run(["git", *args], cwd=repo, input=stdin, capture_output=True, check=True).stdout.decode()


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    r = tmp_path / "repo"
    r.mkdir()
    git(r, "init", "-q")
    git(r, "config", "user.email", "t@t")
    git(r, "config", "user.name", "t")
    (r / "script.ps1").write_bytes(b"Write-Host one\nWrite-Host two\n")
    (r / "data.json").write_bytes(b'{"a": 1}\n')
    git(r, "add", "-A")
    git(r, "commit", "-qm", "initial")
    return r


def test_a_faithful_tree_reports_nothing(repo):
    assert diverged_files(repo) == []


def test_an_invisible_divergence_is_caught(repo):
    """The whole point: bytes differ, git status says clean.

    CRLF is the case that actually happened, so it is the case used here.
    """
    (repo / "script.ps1").write_bytes(b"Write-Host one\r\nWrite-Host two\r\n")
    git(repo, "update-index", "--assume-unchanged", "script.ps1")
    assert git(repo, "status", "--porcelain").strip() == "", "precondition: status must be clean"

    found = diverged_files(repo)
    assert [d.path for d in found] == ["script.ps1"]
    assert found[0].reason == "content"


def test_a_visible_edit_is_not_reported(repo):
    """A developer editing a file is not this bug and must not fail a build.

    The dangerous set is exactly the divergences git does NOT already report; one
    it does report is somebody's work in progress.
    """
    (repo / "script.ps1").write_bytes(b"Write-Host three\n")
    assert git(repo, "status", "--porcelain").strip() != ""
    assert diverged_files(repo) == []


def test_a_deleted_file_is_visible_and_so_not_reported(repo):
    (repo / "data.json").unlink()
    assert diverged_files(repo) == []


def test_an_unsmudged_lfs_pointer_is_caught(repo):
    """The #101 failure: a pointer checked out as 132 bytes of text.

    `git lfs pull` exited 0, `git status` was clean, and the build staged the
    pointer as an installer. The pointer carries the real object's sha256 and
    size, so it verifies itself.
    """
    pointer = b"version https://git-lfs.github.com/spec/v1\noid sha256:" + b"a" * 64 + b"\nsize 4096\n"
    (repo / "asset.bin").write_bytes(pointer)
    git(repo, "add", "asset.bin")
    git(repo, "commit", "-qm", "add an lfs-tracked asset")
    # Still a pointer on disk: never smudged.
    found = diverged_files(repo, lfs_paths={"asset.bin"})
    assert [d.path for d in found] == ["asset.bin"]
    assert found[0].reason == "lfs-pointer"


def test_a_smudged_lfs_file_of_the_wrong_size_is_caught(repo):
    pointer = b"version https://git-lfs.github.com/spec/v1\noid sha256:" + b"a" * 64 + b"\nsize 4096\n"
    (repo / "asset.bin").write_bytes(pointer)
    git(repo, "add", "asset.bin")
    git(repo, "commit", "-qm", "add an lfs-tracked asset")
    (repo / "asset.bin").write_bytes(b"x" * 99)  # smudged, but truncated
    git(repo, "update-index", "--assume-unchanged", "asset.bin")
    found = diverged_files(repo, lfs_paths={"asset.bin"})
    assert [d.path for d in found] == ["asset.bin"]
    assert found[0].reason == "lfs-size"


def test_a_correctly_smudged_lfs_file_passes(repo):
    body = b"x" * 4096
    import hashlib

    digest = hashlib.sha256(body).hexdigest()
    pointer = f"version https://git-lfs.github.com/spec/v1\noid sha256:{digest}\nsize 4096\n".encode()
    (repo / "asset.bin").write_bytes(pointer)
    git(repo, "add", "asset.bin")
    git(repo, "commit", "-qm", "add an lfs-tracked asset")
    (repo / "asset.bin").write_bytes(body)
    git(repo, "update-index", "--assume-unchanged", "asset.bin")
    assert diverged_files(repo, lfs_paths={"asset.bin"}) == []
    # And thorough mode agrees, having actually hashed it.
    assert diverged_files(repo, lfs_paths={"asset.bin"}, thorough=True) == []


def test_thorough_catches_a_right_sized_wrong_content_lfs_file(repo):
    """Size alone cannot see bit rot; the pointer's sha256 can."""
    pointer = b"version https://git-lfs.github.com/spec/v1\noid sha256:" + b"a" * 64 + b"\nsize 4096\n"
    (repo / "asset.bin").write_bytes(pointer)
    git(repo, "add", "asset.bin")
    git(repo, "commit", "-qm", "add an lfs-tracked asset")
    (repo / "asset.bin").write_bytes(b"y" * 4096)  # right size, wrong bytes
    git(repo, "update-index", "--assume-unchanged", "asset.bin")
    assert diverged_files(repo, lfs_paths={"asset.bin"}) == []
    found = diverged_files(repo, lfs_paths={"asset.bin"}, thorough=True)
    assert [d.path for d in found] == ["asset.bin"]
    assert found[0].reason == "lfs-content"
