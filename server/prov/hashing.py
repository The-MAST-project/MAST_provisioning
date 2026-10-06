"""File hashing shared by the prov package."""

from __future__ import annotations

import hashlib
from pathlib import Path

READ_CHUNK = 1024 * 1024


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(READ_CHUNK):
            h.update(chunk)
    return h.hexdigest()
