"""The bootstrap-reassert provider's ordering and always-run contract.

Like the execution-policy provider next door, these properties are load-bearing
and invisible from the provider's own scripts, so they are asserted here rather
than left to review.

The provider exists so a unit converges on the current bootstrap during an
ordinary provisioning run, instead of somebody carrying a USB stick to it
(MAST_provisioning#143).
"""

from __future__ import annotations

import json
from pathlib import Path

PROVIDERS = Path(__file__).resolve().parents[2] / "providers"
MODULE = "bootstrap-reassert"
REPO_ROOT = Path(__file__).resolve().parents[3]


def _module(name: str) -> dict:
    return json.loads((PROVIDERS / name / "module.json").read_text(encoding="utf-8-sig"))


def test_runs_after_execution_policy_but_before_the_working_providers():
    """It must not displace execution-policy, which is asserted to sort first.

    Nothing here needs the policy set -- both invocations pass
    -ExecutionPolicy Bypass -- but that provider's contract is absolute, and an
    order that squeezed in front of it would fail its test rather than this one,
    which is a confusing place to learn about it.
    """
    mods = {p.parent.name: _module(p.parent.name) for p in PROVIDERS.glob("*/module.json")}
    mine = mods[MODULE]["order"]
    assert mine > mods["execution-policy"]["order"], (
        f"{MODULE} (order={mine}) must sort after execution-policy "
        f"(order={mods['execution-policy']['order']}), which is asserted to run first."
    )
    later = {n: o for n, o in ((n, m["order"]) for n, m in mods.items()) if o > mine}
    assert later, f"{MODULE} should precede the providers that do the installing; nothing sorts after it"


def test_is_an_always_module():
    """Re-assert runs every cycle, not only when a unit looks behind.

    Drift is payload-hash-based, so a bootstrap element changed out of band
    produces no drift and nothing would look again. Worse, the targeted
    alternative -- run only when the stamped bootstrap_version is below current
    -- does nothing at all for a unit whose version is null because it predates
    stamping, which is precisely mast02, the named target of #143.
    """
    assert _module(MODULE).get("always") is True


def test_carries_bootstrap_and_its_util_as_repofiles():
    """bootstrap.ps1 dot-sources mast-client-util.ps1 before it does anything.

    Shipping one without the other reaches the unit and throws
    "term not recognized" a thousand lines in.
    """
    repofiles = set(_module(MODULE).get("repofiles", []))
    assert {"client/bootstrap.ps1", "client/mast-client-util.ps1"} <= repofiles, repofiles
    for entry in repofiles:
        assert (REPO_ROOT / entry).is_file(), f"repofiles entry does not exist: {entry}"


def test_invokes_reassert_only_and_never_a_bare_bootstrap():
    """A bare bootstrap.ps1 on a provisioned unit would do first-touch work.

    The hardware preflight alone would throw (it asserts a FREE D:, which a
    provisioned unit has legitimately filled with the index volume), and that is
    the benign end of what a first-touch run would attempt.
    """
    provide = (PROVIDERS / MODULE / "provide-bootstrap-reassert.ps1").read_text(encoding="utf-8-sig")
    assert "-ReassertOnly" in provide
    assert "-Elements" not in provide, (
        "the provider must take the default routine set; naming elements here would "
        "let an on-demand transport element into a routine run"
    )
