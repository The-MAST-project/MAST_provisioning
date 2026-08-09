"""Staging-payload size accounting (port of server/lib/mast-staging-size.ps1).

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
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class StagingSize:
    bytes: int
    files: int


def staging_payload_size(path: str | Path) -> StagingSize:
    """Total (bytes, files) under ``path`` as robocopy would copy it, descending
    through directory junctions/symlinks. Missing/unreadable entries are skipped
    (best-effort, matching the PowerShell -ErrorAction SilentlyContinue)."""
    total_bytes = 0
    total_files = 0
    visited: set[str] = set()

    def walk(d: Path) -> None:
        nonlocal total_bytes, total_files
        try:
            real = os.path.realpath(d)
        except OSError:
            return
        if real in visited:  # cycle guard (a junction pointing at an ancestor)
            return
        visited.add(real)
        try:
            entries = list(os.scandir(d))
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

    walk(Path(path))
    return StagingSize(bytes=total_bytes, files=total_files)
