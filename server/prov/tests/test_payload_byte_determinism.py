"""A payload's bytes must depend on the commit, not on who checked it out.

Two git installations sit on the provisioning server's PATH with opposite
`core.autocrlf` settings, and with no `text` attribute the one that performed the
checkout decided the working tree's line endings. Two trees at the same commit
therefore built payloads differing in 113 files, and `git status` called both
clean -- the stat cache skips the content comparison when size and mtime match,
so a tree can diverge from its own commit and keep saying it has not (#216).

`.gitattributes` is what arbitrates. These tests hold it to that.
"""

from __future__ import annotations

import subprocess

from prov import transport as T

#: Vendor artifacts consumed byte for byte -- driver INFs and catalogs are read by
#: Windows setup, certificates are signed blobs. A filter must never rewrite them.
BYTE_EXACT_SUFFIXES = (".inf", ".sys", ".cat", ".cer")


def ls_files_eol() -> list[tuple[str, str, str]]:
    """(index-eol, attrs, path) for every tracked file."""
    out = subprocess.run(["git", "ls-files", "--eol"], cwd=T.REPO_ROOT, capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        fields, path = line.split("\t", 1)
        parts = fields.split()
        rows.append((parts[0], " ".join(parts[2:]), path.strip()))
    return rows


def test_no_tracked_file_carries_crlf_into_the_index():
    """The repository stores LF, so a checkout can be made to reproduce it.

    A CRLF blob is one committed from a CRLF working tree, and it is how the two
    exceptions arrived: a decision record and jupyter's requirements.txt, both
    renormalized here.
    """
    crlf = [path for eol, _attrs, path in ls_files_eol() if "crlf" in eol]
    assert crlf == []


def test_text_files_are_pinned_to_lf_rather_than_left_to_the_tool():
    # `attr/` reports what .gitattributes decided. An unspecified text attribute
    # is the bug: it hands the decision to whichever git does the checkout.
    undecided = [
        path
        for eol, attrs, path in ls_files_eol()
        if eol.startswith("i/lf") and "text" not in attrs and not path.endswith(BYTE_EXACT_SUFFIXES)
    ]
    assert undecided == [], f"no line-ending rule covers: {undecided[:10]}"


def test_byte_exact_vendor_artifacts_are_never_filtered():
    """-text, not eol=lf: these must not be rewritten at all.

    A `.inf` git guesses is text would otherwise be normalised on checkout, and
    what reaches the unit would no longer be what the vendor shipped.
    """
    paths = [p for _eol, _attrs, p in ls_files_eol() if p.endswith(BYTE_EXACT_SUFFIXES)]
    assert paths, "no byte-exact vendor artifacts found; the suffix list has gone stale"
    # One --stdin call, not one process per file: this runs in CI on every push.
    out = subprocess.run(
        ["git", "check-attr", "--stdin", "text"],
        cwd=T.REPO_ROOT,
        input="\n".join(paths),
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    filtered = [line for line in out.splitlines() if "text: unset" not in line]
    assert filtered == [], f"these would be rewritten by a filter: {filtered[:5]}"
