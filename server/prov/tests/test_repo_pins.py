"""The MAST repo manifest pins every repo to an exact revision.

A branch pins a moving target: a unit gets whatever the head was at the moment
ITS clone ran. On 2026-08-11 two upstream merges landed mid-fleet-run and left
three units on two different MAST_common and two different MAST_unit commits,
every run reporting success and nothing in the logs saying they had diverged
(MAST_unit#94, #75). The manifest has carried a `rev` column for that since; this
is what keeps it populated.
"""

from __future__ import annotations

import re

from prov import transport as T

MANIFEST = T.REPO_ROOT / "tools" / "mast-repos.tsv"
SHA = re.compile(r"^[0-9a-f]{40}$")


def rows() -> list[list[str]]:
    out = []
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        out.append(line.split("\t"))
    return out


def test_the_manifest_lists_the_repos_a_unit_needs():
    dirs = {r[0] for r in rows()}
    assert {"common", "unit", "claude"} <= dirs, dirs


def test_every_repo_is_pinned_to_an_exact_revision():
    unpinned = [r[0] for r in rows() if len(r) < 5 or not r[4].strip()]
    assert not unpinned, (
        f"{unpinned} track a branch head. Two units provisioned minutes apart can then "
        "land on different commits, with every run reporting success."
    )


def test_the_pins_are_full_sha1s_not_abbreviations():
    # mast-clone checks out detached at this value; an abbreviation is ambiguous
    # in principle and unreadable as provenance in clone-manifest.json.
    bad = [(r[0], r[4]) for r in rows() if not SHA.match(r[4].strip())]
    assert not bad, bad


def test_branch_is_still_declared_alongside_the_pin():
    # The pin is what is checked out; the branch is what a -Branch override falls
    # back to, and two repos have a default that was an abandoned stub.
    assert all(r[3].strip() for r in rows())
