"""prov.hashing: the one file hasher the prov package uses."""

from __future__ import annotations

import hashlib

from prov import hashing


def test_sha256_of_matches_hashlib_across_chunk_boundaries(tmp_path):
    body = b"a" * (hashing.READ_CHUNK + 7)
    f = tmp_path / "f.bin"
    f.write_bytes(body)
    assert hashing.sha256_of(f) == hashlib.sha256(body).hexdigest()
