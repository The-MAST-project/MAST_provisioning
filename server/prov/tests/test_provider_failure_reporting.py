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

import json
import re
from pathlib import Path

import pytest

# server/prov/tests/test_*.py -> parents[3] == repo root
REPO_ROOT = Path(__file__).resolve().parents[3]
PROVIDER_SCRIPTS = sorted(
    p for p in (REPO_ROOT / "server" / "providers").glob("*/*.ps1") if p.name.startswith(("provide-", "verify-"))
)

# Both spellings: the providers mix `$LASTEXITCODE` and `${LASTEXITCODE}` freely, and a
# pattern matching only the bare form reads as a check while covering half the code.
_LASTEXITCODE = re.compile(r"\$\{?LASTEXITCODE\}?", re.IGNORECASE)
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


# --- verify-mast establishes currency against the REMOTE, not a local mirror (#177) ---
#
# It used to compare HEAD against '@{u}', the remote-tracking ref -- a purely local
# pointer nothing updates but a fetch. After a failed fetch it still holds the commit
# HEAD is on, so the two matched and a stale clone was reported current. On the #176
# VM run this logged "mast verify ok: 3 clone(s) current" on three clones that had
# fetched nothing, in the same run where the provider had just failed them.
#
# Static, for the same reason as the shapes above: the regression is a one-line revert
# to a form that looks more idiomatic than the correct one.

_VERIFY_MAST = REPO_ROOT / "server" / "providers" / "mast" / "verify-mast.ps1"
_CURRENCY_LIB = REPO_ROOT / "server" / "lib" / "mast-git-currency.ps1"

# '@{u}' is still legitimate for *discovering the branch name*; what must not come
# back is resolving it to a SHA, which is the comparison that cannot work.
_REVPARSE_UPSTREAM_SHA = re.compile(r"rev-parse\s+(?!--abbrev-ref)[^\n]*'@\{u\}'")


def test_verify_mast_does_not_resolve_upstream_to_a_sha() -> None:
    text = _strip_comments(_VERIFY_MAST.read_text(encoding="utf-8"))
    hits = [m.group(0) for m in _REVPARSE_UPSTREAM_SHA.finditer(text)]
    assert not hits, (
        "verify-mast.ps1 resolves '@{u}' to a SHA again. That is the remote-tracking ref, "
        "which a failed fetch leaves pointing at the commit HEAD is already on -- so a stale "
        "clone reports as current (#177). Ask the remote with ls-remote instead.\n" + "\n".join(hits)
    )


def test_verify_mast_asks_the_remote() -> None:
    text = _VERIFY_MAST.read_text(encoding="utf-8")
    assert "ls-remote" in text, "verify-mast.ps1 no longer queries origin, so it cannot establish currency (#177)."
    assert "fetch_ok" in text, (
        "verify-mast.ps1 no longer reads fetch_ok, so an unreachable origin has no fallback evidence "
        "and cannot be distinguished from a never-verified checkout (#177)."
    )


def test_verify_mast_does_not_fetch() -> None:
    """ls-remote, not fetch: a verify must not update local refs, or one pass changes
    what the next pass would compare against."""
    text = _strip_comments(_VERIFY_MAST.read_text(encoding="utf-8"))
    assert not re.search(r"\bgit\b[^\n]*\bfetch\b", text, re.IGNORECASE), (
        "verify-mast.ps1 runs a git fetch. Use ls-remote so the check stays read-only (#177)."
    )


def test_the_three_verify_states_are_all_reachable() -> None:
    """0 / 1 / 2 must all be live exits. A 2 nothing can produce is a state that
    exists only in the report format."""
    text = _VERIFY_MAST.read_text(encoding="utf-8")
    assert "Get-MastVerifyExitCode" in text
    assert _CURRENCY_LIB.exists(), "the pure verdict lib is gone; the decision table is untested"
    lib = _CURRENCY_LIB.read_text(encoding="utf-8")
    for state in ("current", "stale", "unverifiable", "unverified"):
        assert f"'{state}'" in lib, f"verdict state {state!r} no longer defined"


# --- the python provider checks its pip calls and verifies with a script (#131) ---
#
# provide-python.ps1 ran `pip install virtualenv` with `*>$null` and never read
# $LASTEXITCODE, and its module.json verify ran `python -m virtualenv --version`
# and wrote the smoke marker regardless of the answer. mast06 reported the module
# green in two consecutive runs with virtualenv absent; the absence surfaced two
# modules later as a jupyter failure. virtualenv is now dropped for the stdlib
# venv module, so there is no PyPI fetch left here to check -- what is guarded is
# that it does not come back, and that the verify stayed a script.
#
# Scoped to this provider deliberately: the same audit across all ~22 providers is
# #62 axis 2 and deserves its own pass.

_PYTHON_DIR = REPO_ROOT / "server" / "providers" / "python"
_PROVIDE_PYTHON = _PYTHON_DIR / "provide-python.ps1"
_VERIFY_PYTHON = _PYTHON_DIR / "verify-python.ps1"

# `& <exe> ... *>$null` -- every stream discarded. Legitimate for a probe whose
# exit code is then read, which is why the assertion below pairs each one with a
# $LASTEXITCODE read rather than banning the redirect.
_ALL_STREAMS_DISCARDED = re.compile(r"\*>\s*\$null")


def test_provide_python_reads_every_discarded_native_call() -> None:
    """A `*>$null` call must be followed by a $LASTEXITCODE read before the next one.

    That is the difference between a silenced probe and a swallowed result: the
    install that started #131 discarded all three streams AND the exit code.
    """
    text = _strip_comments(_PROVIDE_PYTHON.read_text(encoding="utf-8"))
    silenced = [m.end() for m in _ALL_STREAMS_DISCARDED.finditer(text)]
    reads = [m.start() for m in _LASTEXITCODE.finditer(text)]
    for pos in silenced:
        line = text[:pos].count("\n") + 1
        following = [r for r in reads if r > pos]
        assert following, (
            f"provide-python.ps1:{line} discards every stream of a native call and "
            f"nothing reads $LASTEXITCODE afterwards -- the shape that let a failed "
            f"install report success (#131)."
        )
        # Nothing else silenced in between, or the pair is ambiguous.
        next_silenced = [s for s in silenced if s > pos]
        if next_silenced:
            assert following[0] < next_silenced[0], (
                f"provide-python.ps1:{line} discards every stream and the next thing "
                f"in the script is another silenced call, not a $LASTEXITCODE read (#131)."
            )


def test_provide_python_does_not_install_virtualenv() -> None:
    text = _strip_comments(_PROVIDE_PYTHON.read_text(encoding="utf-8"))
    assert not re.search(r"pip\s+install[^\n]*\bvirtualenv\b", text, re.IGNORECASE), (
        "provide-python.ps1 installs virtualenv again. It was dropped for the stdlib venv "
        "module because it was the last PyPI fetch in a provisioning run, and a bench unit "
        "with no route to an index cannot satisfy it (#131)."
    )
    assert re.search(r"pip\s+uninstall[^\n]*\bvirtualenv\b", text, re.IGNORECASE), (
        "provide-python.ps1 no longer removes virtualenv. Every unit provisioned before #131 "
        "has it, and the idempotency guard is what decides whether the cleanup is reached."
    )


def test_provide_python_guard_does_not_skip_the_virtualenv_cleanup() -> None:
    """The early exit must test virtualenv's ABSENCE, not just python + venv.

    A guard weaker than what the module produces (#129) would exit 0 on exactly the
    units that still carry virtualenv, so the package would survive forever on the
    machines the cleanup exists for.
    """
    text = _strip_comments(_PROVIDE_PYTHON.read_text(encoding="utf-8"))
    guard_end = text.find("exit 0")
    assert guard_end > 0, "provide-python.ps1 has no early exit; this guard's premise is gone"
    guard = text[:guard_end]
    assert re.search(r"pip\s+show[^\n]*\bvirtualenv\b", guard, re.IGNORECASE), (
        "provide-python.ps1's idempotency guard does not check whether virtualenv is still "
        "installed, so it exits 0 before reaching the removal on every unit that has it (#131)."
    )


def test_python_verify_is_a_script_that_can_fail() -> None:
    assert _VERIFY_PYTHON.is_file(), (
        "verify-python.ps1 is gone. The python module's verify was an inline module.json "
        "one-liner that wrote 'python_ok' whatever its checks returned (#131)."
    )
    module_json = json.loads((_PYTHON_DIR / "module.json").read_text(encoding="utf-8-sig"))
    assert "verify-python.ps1" in module_json["verify"], "python/module.json's verify no longer runs verify-python.ps1."
    assert "-Command" not in module_json["verify"], (
        "python/module.json's verify is an inline -Command one-liner again (#131)."
    )
    assert "verify-python.ps1" in module_json.get("commandfiles", []), (
        "verify-python.ps1 is not in commandfiles, so build-mast will not stage it and the "
        "verify will fail on the unit with a 'not found' error."
    )

    text = _VERIFY_PYTHON.read_text(encoding="utf-8")
    assert "-m', 'venv'" in text or "-m venv " in text, (
        "verify-python.ps1 no longer exercises `python -m venv`. Asserting the outcome means "
        "creating a venv -- the capability provide-jupyter consumes -- not importing a module (#131)."
    )
    assert "pip show virtualenv" in text, (
        "verify-python.ps1 no longer asserts virtualenv is absent, so a unit that reinstalled it passes (#131)."
    )
