"""Does the working tree hold the bytes its commit says it does?

`git status` cannot answer this. Its stat cache skips the content comparison when
a file's size and mtime match the index entry, so a tree can diverge from its own
commit and keep reporting clean. Two trees at ``dd4d16f`` did exactly that and
built payloads differing in 113 files, because two git installations on the build
host disagreed about ``core.autocrlf`` (#216).

The build records ``git_sha`` alongside ``payload_hash``, which is a claim that
the payload derives from that commit. This module is what makes the claim true.

**Only invisible divergence counts.** A file ``git status`` already reports is
somebody's work in progress -- normal, visible, and not this bug. Failing on it
would make the check unusable. The dangerous set is precisely what status does
*not* report.

**Two populations, two questions.** For an ordinary file, the on-disk bytes must
hash to the blob the commit records -- read raw, bypassing the clean filter, since
the filter is what lets a CRLF file "match" an LF blob. For a git-LFS file the
commit records only a ~132-byte pointer, so comparing raw bytes would flag every
correctly-smudged asset; instead the pointer verifies itself, carrying the real
object's ``oid sha256`` and ``size``. That is also the #101 failure -- a pointer
that checked out as text while ``git lfs pull`` exited 0 and nothing noticed.
"""

from __future__ import annotations

import hashlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

#: A file still holding its pointer has never been smudged.
LFS_POINTER_PREFIX = b"version https://git-lfs"
_OID = re.compile(rb"^oid sha256:([0-9a-f]{64})$", re.MULTILINE)
_SIZE = re.compile(rb"^size (\d+)$", re.MULTILINE)
#: Reading a large asset to hash it, without holding it all in memory.
_CHUNK = 1024 * 1024


@dataclass(frozen=True)
class Divergence:
    """One file whose content is not what the commit says, and how it differs."""

    path: str
    reason: str
    detail: str


def _git(repo: Path, *args: str, stdin: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], cwd=repo, input=stdin, capture_output=True, check=True).stdout


def _visible(repo: Path) -> set[str]:
    """Paths git already reports as changed -- excluded, by design."""
    out = _git(repo, "status", "--porcelain", "-z").decode("utf-8", "surrogateescape")
    seen: set[str] = set()
    for entry in out.split("\0"):
        if len(entry) > 3:
            seen.add(entry[3:])
    return seen


def _head_blobs(repo: Path) -> dict[str, str]:
    out = _git(repo, "ls-tree", "-r", "-z", "HEAD").decode("utf-8", "surrogateescape")
    blobs: dict[str, str] = {}
    for entry in out.split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        _mode, kind, oid = meta.split(" ", 2)
        if kind == "blob":
            blobs[path] = oid
    return blobs


def _lfs_tracked(repo: Path) -> set[str]:
    """Paths git-lfs manages. An absent or unconfigured lfs means none."""
    try:
        out = _git(repo, "lfs", "ls-files", "-n")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return set()
    return {line for line in out.decode("utf-8", "surrogateescape").splitlines() if line}


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(_CHUNK):
            h.update(chunk)
    return h.hexdigest()


def _check_ordinary(repo: Path, paths: list[str], blobs: dict[str, str]) -> list[Divergence]:
    """Raw on-disk bytes must hash to the blob the commit records.

    ``--no-filters`` is the load-bearing flag: without it the clean filter runs and
    a CRLF working file hashes to the same object as its LF blob, which is exactly
    the blindness being removed.
    """
    if not paths:
        return []
    # Bytes on stdin, never text mode: on Windows that translates the separators
    # and git takes the trailing CR as part of the filename (learned in #217).
    out = _git(
        repo,
        "hash-object",
        "--no-filters",
        "--stdin-paths",
        stdin=("\n".join(paths) + "\n").encode("utf-8", "surrogateescape"),
    )
    found = out.decode().split()
    diverged = []
    for path, actual in zip(paths, found, strict=True):
        expected = blobs[path]
        if actual != expected:
            diverged.append(Divergence(path, "content", f"on disk {actual[:12]}, commit records {expected[:12]}"))
    return diverged


def _pointers(repo: Path, paths: list[str]) -> dict[str, bytes]:
    """Every LFS pointer blob in ONE git call.

    One `cat-file blob` per path costs 162 process spawns, which is 3 s on a Mac
    and 220 s on the Windows build host -- far too slow for something that runs
    before every provisioning run. `--batch` reads requests on stdin and streams
    back `<oid> blob <size>\n<content>\n` for each.
    """
    if not paths:
        return {}
    req = "".join(f"HEAD:{p}\n" for p in paths).encode("utf-8", "surrogateescape")
    out = _git(repo, "cat-file", "--batch", stdin=req)
    blobs: dict[str, bytes] = {}
    pos = 0
    for path in paths:
        nl = out.index(b"\n", pos)
        header = out[pos:nl].split()
        if len(header) < 3:  # "missing" and the like: nothing to verify against
            pos = nl + 1
            continue
        size = int(header[2])
        start = nl + 1
        blobs[path] = out[start : start + size]
        pos = start + size + 1  # trailing newline after the payload
    return blobs


def _check_lfs(repo: Path, paths: list[str], *, thorough: bool) -> list[Divergence]:
    diverged = []
    pointers = _pointers(repo, paths)
    for path in paths:
        pointer = pointers.get(path)
        if pointer is None:
            continue
        oid = _OID.search(pointer)
        size = _SIZE.search(pointer)
        if not (oid and size):
            continue  # not a pointer in HEAD; nothing to verify it against
        want_oid = oid.group(1).decode()
        want_size = int(size.group(1))
        full = repo / path
        if not full.is_file():
            continue  # absent is visible to status, and to the build's own guard
        if full.read_bytes()[: len(LFS_POINTER_PREFIX)] == LFS_POINTER_PREFIX:
            diverged.append(Divergence(path, "lfs-pointer", "never smudged; still the pointer on disk"))
            continue
        actual_size = full.stat().st_size
        if actual_size != want_size:
            diverged.append(Divergence(path, "lfs-size", f"{actual_size} bytes on disk, pointer says {want_size}"))
            continue
        if thorough:
            actual = _sha256(full)
            if actual != want_oid:
                diverged.append(Divergence(path, "lfs-content", f"sha256 {actual[:12]}, pointer says {want_oid[:12]}"))
    return diverged


def diverged_files(repo_root: Path, *, thorough: bool = False, lfs_paths: set[str] | None = None) -> list[Divergence]:
    """Files whose content differs from HEAD while git reports the tree clean.

    ``thorough`` additionally hashes LFS content, which means reading every asset;
    without it an LFS file is checked for being a pointer and for its size, which
    catches the failures seen in the field at a fraction of the cost.
    """
    repo_root = Path(repo_root)
    visible = _visible(repo_root)
    blobs = _head_blobs(repo_root)
    lfs = _lfs_tracked(repo_root) if lfs_paths is None else lfs_paths

    ordinary, managed = [], []
    for path in sorted(blobs):
        if path in visible or not (repo_root / path).is_file():
            continue
        (managed if path in lfs else ordinary).append(path)

    return _check_ordinary(repo_root, ordinary, blobs) + _check_lfs(repo_root, managed, thorough=thorough)
