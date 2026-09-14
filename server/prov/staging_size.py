"""Staging-payload size accounting (ported from the retired server/lib/mast-staging-size.ps1).

The driver logs TRANSFER_START bytes and computes TRANSFER_PROGRESS pct/ETA
against a pre-scan of the server-side staging tree. robocopy on the unit copies
THROUGH directory junctions (e.g. the `mast-indexes` junction -> the ~9.85 GB
astrometry index seed), so the pre-scan must descend them too, or bytes_total
undercounts and progress runs past 100%.

Unlike the PowerShell version -- which had to re-add junction contents because
Get-ChildItem -Recurse skips reparse points -- this walks manually and follows
junctions/symlinks exactly once (guarded against cycles by resolved real path),
so the count matches what robocopy moves directly.
"""

from __future__ import annotations

import os
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class StagingSize:
    bytes: int
    files: int


def staging_payload_size(
    path: str | Path,
    *,
    exclude_files: Iterable[str] = (),
    exclude_dirs: Iterable[str] = (),
) -> StagingSize:
    """Total (bytes, files) under ``path`` as robocopy would copy it, descending
    through directory junctions/symlinks. Missing/unreadable entries are skipped
    (best-effort, matching the PowerShell -ErrorAction SilentlyContinue).

    ``exclude_files`` / ``exclude_dirs`` are staging-root leaf names the transfer
    will skip (prov.payload). They are honored at the ROOT ONLY, because the pull
    script builds robocopy's /XF and /XD arguments as full paths under the source
    UNC -- so a deeper file of the same name is still copied and must still be
    counted. Keeping the two in step is not cosmetic: this figure is the unit's
    disk guard (``-PayloadBytes``), and a full-payload number against a trimmed
    copy re-creates the #7 item 6 mismatch in the opposite direction."""
    # One set for both: a directory and a file cannot share a name inside one
    # directory, so nothing is lost by merging them, and the root's entries can
    # be filtered once instead of per-entry.
    skip = frozenset(n for n in (*exclude_files, *exclude_dirs) if n)
    total_bytes = 0
    total_files = 0
    visited: set[str] = set()

    def walk(d: Path, skip_here: frozenset[str] = frozenset()) -> None:
        nonlocal total_bytes, total_files
        try:
            real = os.path.realpath(d)
        except OSError:
            return
        if real in visited:  # cycle guard (a junction pointing at an ancestor)
            return
        visited.add(real)
        try:
            entries = [e for e in os.scandir(d) if e.name not in skip_here]
        except OSError:
            return
        for e in entries:
            try:
                if e.is_dir():  # follows junctions/symlinks (default follow_symlinks=True)
                    walk(Path(e.path))
                elif e.is_file():
                    total_bytes += e.stat().st_size
                    total_files += 1
            except OSError:
                continue

    walk(Path(path), skip)
    return StagingSize(bytes=total_bytes, files=total_files)
