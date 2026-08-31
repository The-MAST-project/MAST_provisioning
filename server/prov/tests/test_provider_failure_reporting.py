"""Guard: a provider must not be able to exit 0 without achieving its outcome.

Measured on the fleet's actual PowerShell -- 5.1.19041.6807 on a unit (Windows 10
IoT Enterprise LTSC) and 5.1.26100.8875 on the prov host -- ``powershell.exe -File``
exits **1** for an unhandled terminating error, whether it is thrown at top level or
inside ``try``/``finally`` with no ``catch``. So a provider that fails by ``throw`` is
NOT invisible to the orchestrator, which is what #38 assumed.

Exactly one shape was found that turns a failure into ``exit 0``:

    try { throw "boom" } finally { exit 0 }

``exit`` inside ``finally`` runs while the terminating error is still pending and
overrides it, so the process reports success. That is what this module guards, plus
the dead-guard idiom from #38 behaviour 1 -- ``$LASTEXITCODE`` is a native-process
concept and is not set by invoking a ``.ps1``, so any "did the child script succeed?"
test built on it is dead code that silently never fires.

Neither shape is present as of 2026-08-10; both are cheap to reintroduce and neither
is visible in a run's output, which is why they are asserted rather than reviewed.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

# server/prov/tests/test_*.py -> parents[3] == repo root
REPO_ROOT = Path(__file__).resolve().parents[3]
PROVIDER_SCRIPTS = sorted(
    p for p in (REPO_ROOT / "server" / "providers").glob("*/*.ps1") if p.name.startswith(("provide-", "verify-"))
)

_LASTEXITCODE = re.compile(r"\$LASTEXITCODE", re.IGNORECASE)
_FINALLY = re.compile(r"\bfinally\s*\{", re.IGNORECASE)
_EXIT_ZERO = re.compile(r"\bexit\s+0\b", re.IGNORECASE)

# Any call operator invocation -- `& <thing>` or `. <thing>`. What matters for the
# dead-guard check is whether the NEAREST one before a $LASTEXITCODE read was a .ps1
# (which does not set it) or anything else (a native exe, often reached through a
# variable holding its path, which does).
_INVOCATION = re.compile(r"[&.]\s+(?P<target>[^\s;|&]+)")

_LINE_COMMENT = re.compile(r"#[^\n]*")
_BLOCK_COMMENT = re.compile(r"<#.*?#>", re.DOTALL)


def _strip_comments(text: str) -> str:
    """Blank out comments, preserving offsets so reported line numbers stay right.

    Without this the checks fire on prose: provide-mast.ps1's header comment explains
    the $LASTEXITCODE hazard in words, and matching that would flag the one provider
    that documents it.
    """

    def _blank(m: re.Match[str]) -> str:
        return "".join("\n" if c == "\n" else " " for c in m.group(0))

    return _LINE_COMMENT.sub(_blank, _BLOCK_COMMENT.sub(_blank, text))


def _block_after(text: str, open_brace_index: int) -> str:
    """Return the brace-balanced block starting at ``open_brace_index``."""
    depth = 0
    for i in range(open_brace_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace_index : i + 1]
    return text[open_brace_index:]


def test_there_are_provider_scripts_to_check() -> None:
    # A glob that silently matches nothing would make every test below vacuous.
    assert len(PROVIDER_SCRIPTS) > 20, f"only found {len(PROVIDER_SCRIPTS)} provider scripts"


@pytest.mark.parametrize("script", PROVIDER_SCRIPTS, ids=lambda p: p.parent.name + "/" + p.name)
def test_no_exit_zero_inside_finally(script: Path) -> None:
    text = _strip_comments(script.read_text(encoding="utf-8", errors="replace"))
    for match in _FINALLY.finditer(text):
        block = _block_after(text, match.end() - 1)
        hit = _EXIT_ZERO.search(block)
        if hit:
            line = text[: match.start()].count("\n") + 1
            pytest.fail(
                f"{script.parent.name}/{script.name}: 'exit 0' inside the finally block "
                f"at line {line}. finally runs while a terminating error is still "
                f"pending, and exit overrides it -- the provider reports SUCCESS for a "
                f"run that failed (#38). Let the error propagate: powershell.exe -File "
                f"already exits 1 for an unhandled throw on the fleet's 5.1."
            )


@pytest.mark.parametrize("script", PROVIDER_SCRIPTS, ids=lambda p: p.parent.name + "/" + p.name)
def test_no_lastexitcode_test_on_a_ps1_call(script: Path) -> None:
    text = _strip_comments(script.read_text(encoding="utf-8", errors="replace"))
    invocations = [(m.end(), m.group("target")) for m in _INVOCATION.finditer(text)]
    if not invocations:
        return
    for check in (m.start() for m in _LASTEXITCODE.finditer(text)):
        preceding = [(pos, tgt) for pos, tgt in invocations if pos < check]
        if not preceding:
            continue
        _, nearest_target = max(preceding, key=lambda pair: pair[0])
        if not nearest_target.strip("\"'").lower().endswith(".ps1"):
            continue  # nearest call was not a .ps1, so $LASTEXITCODE may well be set
        line = text[:check].count("\n") + 1
        pytest.fail(
            f"{script.parent.name}/{script.name}: $LASTEXITCODE read at line {line}, "
            f"where the nearest preceding call operator invoked a .ps1. "
            f"$LASTEXITCODE is not set by invoking a .ps1, so this test is dead code "
            f"that never fires (#38 behaviour 1). Assert the outcome instead -- does "
            f"the artifact the step was supposed to produce actually exist?"
        )


# --- the mast provider asserts the clone was verified, not merely present (#175) ---
#
# provide-mast.ps1 delegates the whole source layout to tools/mast-clone.ps1, which
# reports a failed fetch and carries on -- it is also the casual dev clone tool, where
# refreshing an existing tree off-network is legitimate. The fleet has no such case, so
# the assertion is the caller's. Before it existed, a unit with no route to GitHub kept
# its previous checkout while the two post-conditions here (venv interpreter present,
# unit checkout present) both held, and the module reported SUCCESS.
#
# This is the third instance of the same shape in this module: presence is not outcome.

_PROVIDE_MAST = REPO_ROOT / "server" / "providers" / "mast" / "provide-mast.ps1"


def test_provide_mast_asserts_fetch_ok() -> None:
    text = _PROVIDE_MAST.read_text(encoding="utf-8")
    assert "clone-manifest.json" in text, (
        "provide-mast.ps1 no longer reads mast-clone's sidecar, so nothing checks that the "
        "checkouts were verified against origin (#175)."
    )
    assert "fetch_ok" in text, (
        "provide-mast.ps1 no longer asserts fetch_ok. mast-clone reports a failed fetch and "
        "carries on by design; without this assertion an unreachable remote leaves the unit "
        "on old code and the module reports SUCCESS (#175)."
    )
    # Fail-closed on a missing key, not just a false one: mast-clone.ps1 ships in this
    # module's payload as a 'repofiles' entry, so a sidecar without the key is itself wrong.
    assert "Properties.Match('fetch_ok')" in text, (
        "provide-mast.ps1 must treat a MISSING fetch_ok as unverified, not as a pass (#175)."
    )
