"""The pwi4-site provider's ordering and run-trigger contract (#209).

Neither property is visible from the provider's own scripts:

* It must sort after config-bootstrap, which writes the C:\\WIS\\config.toml it reads,
  and after instrument-profiles, which stages the PWI4.cfg template.
* It must NOT be ``always: true``. It refuses while PWI4 is open, and with no way to
  defer a module (#190) an always-run module would fail every run made while PWI4 is up.
  It re-runs on a site change instead, because every site profile is one of its
  repofiles and so part of its content hash.
"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PROVIDERS = REPO_ROOT / "server" / "providers"
MODULE = "pwi4-site"
SITES = PROVIDERS / "config-bootstrap" / "sites"


def _module(name: str) -> dict:
    return json.loads((PROVIDERS / name / "module.json").read_text(encoding="utf-8-sig"))


def test_runs_after_the_providers_it_reads_from():
    mine = _module(MODULE)["order"]
    for earlier in ("config-bootstrap", "instrument-profiles"):
        assert _module(earlier)["order"] < mine, f"{MODULE} (order={mine}) must sort after {earlier}"


def test_is_not_an_always_module():
    assert not _module(MODULE).get("always"), (
        f"{MODULE} refuses while PWI4 runs; as an always module it would fail every run made "
        "while PWI4 is open, since a module cannot be deferred (#190)."
    )


def test_every_site_profile_is_in_its_hash():
    profiles = {p.relative_to(REPO_ROOT).as_posix() for p in SITES.glob("*.toml")}
    assert profiles, "no site profiles found"
    missing = profiles - set(_module(MODULE)["repofiles"])
    assert not missing, (
        f"site profiles {sorted(missing)} are not {MODULE} repofiles, so a change to them "
        "would not re-run it and the live PWI4.cfg would keep the old site."
    )


def test_ships_its_scripts_and_the_site_lib():
    m = _module(MODULE)
    assert {"provide-pwi4-site.ps1", "verify-pwi4-site.ps1"} <= set(m["commandfiles"])
    for rel in m["commandfiles"]:
        assert (PROVIDERS / MODULE / rel).is_file(), f"declared commandfile missing: {rel}"
    assert "server/lib/mast-pwi4-site.ps1" in m["repofiles"]
    for rel in m["repofiles"]:
        assert (REPO_ROOT / rel).is_file(), f"declared repofile missing: {rel}"
