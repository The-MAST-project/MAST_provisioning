"""The provenance beside the bytes is generated, never written by hand.

#194 asks for a PROVENANCE.md per entry under /Storage/mast-vendor/, so somebody
rebuilding from the mirror finds the origin where the bytes are rather than in a
repo they may not have. Hand-writing it would make a second copy of prose that
already lives in server/data/vendor-inputs.json, and the two would drift -- which
is the failure this whole issue is about, one step removed.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
GENERATOR = REPO / "tools" / "write-vendor-provenance.py"
INPUTS = REPO / "server" / "data" / "vendor-inputs.json"


def generate(out: Path) -> None:
    subprocess.run(
        [sys.executable, str(GENERATOR), "--inputs", str(INPUTS), "--out", str(out)],
        check=True,
        capture_output=True,
    )


def provenance_for(out, entry) -> Path:
    """Where the provenance for one entry lands, which depends on its kind."""
    if entry["kind"] == "file":
        return out / (entry["name"] + ".PROVENANCE.md")
    return out / entry["name"] / "PROVENANCE.md"


def test_one_provenance_file_per_declared_input(tmp_path):
    generate(tmp_path)
    for entry in json.loads(INPUTS.read_text())["inputs"]:
        assert provenance_for(tmp_path, entry).is_file(), entry["name"]


def test_a_file_entry_never_becomes_a_directory(tmp_path):
    """The tree is rsynced INTO the vendor store, over the bytes it describes.

    Emitting `full-frame.fits/PROVENANCE.md` for an entry whose kind is `file`
    makes rsync replace the 90 MB file on the store with a directory, and every
    later attempt to sync the real file then fails because a directory is in the
    way. Done on 2026-09-17; recovered from the content store, which still held
    the blob.
    """
    generate(tmp_path)
    for entry in json.loads(INPUTS.read_text())["inputs"]:
        if entry["kind"] == "file":
            assert not (tmp_path / entry["name"]).is_dir(), entry["name"]
            assert (tmp_path / (entry["name"] + ".PROVENANCE.md")).is_file()


def test_each_file_carries_what_recovery_needs(tmp_path):
    # Hashes prove a file is intact and say nothing about how to get it again.
    # These two fields are the entire reason the store exists.
    generate(tmp_path)
    for entry in json.loads(INPUTS.read_text())["inputs"]:
        text = provenance_for(tmp_path, entry).read_text()
        assert entry["origin"] in text
        assert entry["reacquire"] in text


def test_the_index_lists_every_entry(tmp_path):
    generate(tmp_path)
    index = (tmp_path / "PROVENANCE.md").read_text()
    for entry in json.loads(INPUTS.read_text())["inputs"]:
        assert entry["name"] in index


def test_regenerating_changes_nothing(tmp_path):
    # It runs on every mirror. If it were not byte-stable, every run would rewrite
    # five files and rsync would ship them, which teaches the reader that a
    # changed PROVENANCE.md means nothing.
    generate(tmp_path)
    first = {p: p.read_bytes() for p in sorted(tmp_path.rglob("PROVENANCE.md"))}
    generate(tmp_path)
    assert {p: p.read_bytes() for p in sorted(tmp_path.rglob("PROVENANCE.md"))} == first


def test_it_does_not_invent_a_hash(tmp_path):
    # The content store already holds every one of these files content-addressed,
    # so a checksum written here would be a second, staler answer to a question
    # already answered. See #202 and the verify script.
    generate(tmp_path)
    for p in tmp_path.rglob("PROVENANCE.md"):
        assert "sha256" not in p.read_text().lower()
