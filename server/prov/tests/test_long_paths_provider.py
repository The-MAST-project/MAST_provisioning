"""The long-paths provider's always-run contract (#248).

Drift is payload-hash-based, so a LongPathsEnabled value changed out of band
produces no drift; only an always-run module would ever look at it again.
"""

from __future__ import annotations

import json
from pathlib import Path

PROVIDERS = Path(__file__).resolve().parents[2] / "providers"
MODULE = "long-paths"


def _module() -> dict:
    return json.loads((PROVIDERS / MODULE / "module.json").read_text(encoding="utf-8-sig"))


def test_long_paths_is_an_always_module():
    assert _module().get("always") is True


def test_long_paths_verify_is_its_live_check_script():
    verify = _module()["verify"]
    assert "verify-long-paths.ps1" in verify, verify
    assert "-Command" not in verify, verify
