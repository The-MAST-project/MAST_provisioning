"""The execution-policy provider's ordering and always-run contract.

Both properties are load-bearing and neither is visible from the provider's own
scripts, so they are asserted here rather than left to review:

* It must sort FIRST. It is the precondition every bare ``powershell -File``
  invocation depends on, so a provider that ran before it could fail for a
  reason this one exists to remove.
* It must be ``always: true``. Drift is payload-hash-based, so a policy changed
  out of band produces no drift and nothing would ever look again -- which is
  exactly the state the provider is for (#51).
"""

from __future__ import annotations

import json
from pathlib import Path

PROVIDERS = Path(__file__).resolve().parents[2] / "providers"
MODULE = "execution-policy"


def _module(name: str) -> dict:
    # utf-8-sig: several module.json files carry a BOM.
    return json.loads((PROVIDERS / name / "module.json").read_text(encoding="utf-8-sig"))


def _all_modules() -> dict[str, dict]:
    return {p.parent.name: _module(p.parent.name) for p in PROVIDERS.glob("*/module.json")}


def test_execution_policy_runs_before_every_other_provider():
    mods = _all_modules()
    assert MODULE in mods, f"{MODULE} provider is missing"
    mine = mods[MODULE]["order"]
    others = {n: m["order"] for n, m in mods.items() if n != MODULE}
    earlier = {n: o for n, o in others.items() if o <= mine}
    assert not earlier, (
        f"{MODULE} must run first (order={mine}) but these order at or before it: {earlier}. "
        "It is the precondition for running any .ps1 without an -ExecutionPolicy override."
    )


def test_execution_policy_is_an_always_module():
    assert _module(MODULE).get("always") is True, (
        "execution-policy must be always:true -- a policy changed out of band produces no "
        "payload-hash drift, so a drift-targeted run would never re-check it."
    )


def test_execution_policy_declares_both_of_its_scripts():
    m = _module(MODULE)
    files = set(m["commandfiles"])
    assert {"provide-execution-policy.ps1", "verify-execution-policy.ps1"} <= files, files
    for rel in files:
        assert (PROVIDERS / MODULE / rel).is_file(), f"declared commandfile missing: {rel}"


def test_execution_policy_verify_is_a_script_not_an_inline_command():
    # The verify re-reads live policy and inspects every scope; that does not fit in
    # a one-line -Command, and squeezing it back in would be how the GPO check gets
    # dropped.
    verify = _module(MODULE)["verify"]
    assert "verify-execution-policy.ps1" in verify, verify
    assert "-Command" not in verify, verify
