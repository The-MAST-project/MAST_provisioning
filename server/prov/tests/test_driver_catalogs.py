"""A signed driver package must reach the unit byte for byte.

A `.cat` is a DETACHED signature over the exact bytes of every file in its
package. Rewrite one line ending anywhere in that package and the catalog no
longer matches, so `pnputil /add-driver` refuses the whole thing with "The hash
for the file is not present in the specified catalog file. The file is likely
corrupt or the victim of tampering."

Both driver packages in this repo were in that state, and had been since the
files were first committed: `e2f.inf` and `ASICAMUSB3.inf` were stored LF where
the vendor signed CRLF. Nothing noticed, because `zwo` and `intel-nic-driver`
only execute when they drift, and they almost never do -- mast03's two runs
before 2026-09-27 ran 15 commands each and touched neither. It surfaced only
when a 46-of-46 drift forced every module to run, at which point both failed on
a live unit.

So this is the guard the `.gitattributes` rules needed: those rules say what
must not be normalized, and nothing checked that the bytes on disk agree.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from prov import transport as T


#: A file with no NUL byte is one git's heuristic calls text -- the only kind a
#: line-ending filter would ever rewrite. The binaries in a package (.sys, .dll,
#: the catalog itself) are safe by that heuristic, which is why the two .inf
#: files were the ones damaged.
def _is_text(blob: bytes) -> bool:
    return b"\x00" not in blob


def _packages() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "-z", "*.cat"], cwd=T.REPO_ROOT, capture_output=True, check=True
    ).stdout.decode()
    return sorted({T.REPO_ROOT / Path(p).parent for p in out.split("\0") if p})


def test_there_is_a_package_to_check():
    # A rename that moved the drivers out from under this test would otherwise
    # make it pass by checking nothing.
    assert _packages(), "no .cat found; this guard is checking nothing"


def test_no_package_member_has_been_line_ending_normalized():
    damaged = []
    for pkg in _packages():
        rel = pkg.relative_to(T.REPO_ROOT).as_posix()
        listed = subprocess.run(
            ["git", "ls-files", "-z", rel], cwd=T.REPO_ROOT, capture_output=True, check=True
        ).stdout.decode()
        for name in (p for p in listed.split("\0") if p):
            blob = (T.REPO_ROOT / name).read_bytes()
            if not _is_text(blob):
                continue
            if b"\n" in blob and b"\r\n" not in blob:
                damaged.append(name)
    assert not damaged, (
        "line endings were rewritten inside a signed driver package, which voids "
        f"its catalog and makes pnputil reject the driver: {damaged}. Restore CRLF "
        "from the vendor original; the -text rules in .gitattributes keep it that way."
    )


def test_every_package_member_is_exempt_from_line_ending_filters():
    # The bytes being right today is not enough -- the next person to touch one
    # of these needs git to leave it alone.
    unprotected = []
    for pkg in _packages():
        rel = pkg.relative_to(T.REPO_ROOT).as_posix()
        listed = subprocess.run(
            ["git", "ls-files", "-z", rel], cwd=T.REPO_ROOT, capture_output=True, check=True
        ).stdout.decode()
        names = [p for p in listed.split("\0") if p]
        attrs = subprocess.run(
            ["git", "check-attr", "--stdin", "-z", "text"],
            cwd=T.REPO_ROOT,
            input="\0".join(names).encode(),
            capture_output=True,
            check=True,
        ).stdout.decode()
        # -z emits path\0attr\0value\0 per file, so the split leaves a trailing
        # empty field; strict=True would trip over it rather than truncating.
        fields = [f for f in attrs.split("\0") if f != ""]
        assert len(fields) == 3 * len(names), "unexpected check-attr output"
        for name, _attr, value in zip(fields[0::3], fields[1::3], fields[2::3], strict=True):
            if value != "unset":
                unprotected.append(f"{name} (text={value})")
    assert not unprotected, (
        "these are members of a signed driver package but are not exempt from "
        f"line-ending filters: {unprotected}. Add the extension to the -text block "
        "in .gitattributes."
    )
