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
#: Windows setup, certificates are signed blobs, and two DLLs are members of a
#: signed driver package. A filter must never rewrite them.
BYTE_EXACT_SUFFIXES = (".inf", ".sys", ".cat", ".cer", ".dll")


def ls_files_eol() -> list[tuple[str, str, str]]:
    """(index-eol, attrs, path) for every tracked file."""
    out = subprocess.run(["git", "ls-files", "--eol"], cwd=T.REPO_ROOT, capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        fields, path = line.split("\t", 1)
        parts = fields.split()
        rows.append((parts[0], " ".join(parts[2:]), path.strip()))
    return rows


def test_no_filtered_file_carries_crlf_into_the_index():
    """The repository stores LF for everything a filter is allowed to touch.

    A CRLF blob is one committed from a CRLF working tree, and it is how the two
    exceptions arrived: a decision record and jupyter's requirements.txt, both
    renormalized here.

    Byte-exact artifacts are exempt, and the exemption is the point rather than a
    loophole. The goal is that a commit decides the bytes instead of whichever git
    checked it out -- `-text` achieves that exactly as `eol=lf` does, by storing
    and restoring the file unchanged on every platform. Demanding LF of them
    instead is not neutral: a `.cat` signs the exact bytes of its package, so
    normalising a `.inf` inside one voids the signature and Windows refuses the
    driver. This assertion used to cover them, and passed only because both
    driver INFs were already in that broken state -- it was holding the damage in
    place rather than catching it (#48).
    """
    crlf = [path for eol, _attrs, path in ls_files_eol() if "crlf" in eol and not path.endswith(BYTE_EXACT_SUFFIXES)]
    assert crlf == []


def test_a_byte_exact_artifact_keeps_the_line_endings_its_signature_covers():
    # The companion to the exemption above: exempt from the LF rule is not the
    # same as unchecked. server/prov/tests/test_driver_catalogs.py enforces this
    # per signed package; here it is the repo-wide statement that a .inf which
    # went in LF-only is a bug, not a style choice.
    flattened = [path for eol, _attrs, path in ls_files_eol() if path.endswith(".inf") and "lf" in eol and "crlf" not in eol]
    assert flattened == [], f"these .inf files lost their CRLF and void their catalogs: {flattened}"


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
    #
    # Bytes, not text=True. On Windows the text mode translates the "\n" separators
    # to "\r\n", git takes the trailing CR as part of each filename, matches no rule
    # and reports `text: auto` for all of them -- a line-endings test defeated by
    # line endings. Seen on tests (windows-latest) for this very commit.
    out = subprocess.run(
        ["git", "check-attr", "--stdin", "text"],
        cwd=T.REPO_ROOT,
        input="\n".join(paths).encode("utf-8"),
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8")
    filtered = [line for line in out.splitlines() if "text: unset" not in line]
    assert filtered == [], f"these would be rewritten by a filter: {filtered[:5]}"
