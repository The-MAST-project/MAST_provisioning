"""execute's end-of-run background refresh names the task the provider registers.

The refresh cannot live in a module: the background states when the unit was last
provisioned and reads that from installed-manifest.json, which execute writes only
after every module has run. A render from mast-services-finalize -- order 9500 and
still inside the command loop -- would paint the previous run's date, permanently
one run behind (#200). So execute starts the AtLogon task directly, and the task's
name is the seam between two files that cannot import from each other.
"""

from __future__ import annotations

import re

from prov import transport as T

EXECUTE = T.REPO_ROOT / "client" / "execute-mast-provisioning.ps1"
PROVIDE = T.REPO_ROOT / "server" / "providers" / "desktop-appearance" / "provide-desktop-appearance.ps1"


def ps_string(path, variable: str) -> str:
    m = re.search(rf"\$\{{{variable}\}}\s*=\s*'([^']+)'", path.read_text(encoding="utf-8"))
    assert m, f"no ${{{variable}}} assignment in {path.name}"
    return m.group(1)


def test_execute_starts_the_task_the_provider_registers():
    assert ps_string(EXECUTE, "applyTask") == ps_string(PROVIDE, "TaskName")


def test_the_refresh_runs_after_the_installed_manifest_is_written():
    # The ordering IS the fix. If the refresh moves above the merge it silently
    # starts painting the previous run's date, which is the bug it exists to fix.
    text = EXECUTE.read_text(encoding="utf-8")
    merge = text.index("Merge-MastInstalledManifest -Previous")
    refresh = text.index("BACKGROUND_REFRESH started")
    assert merge < refresh, "the background refresh must run after installed_at is written"


def test_the_refresh_is_best_effort():
    # A missed refresh is repaired by verify + the drift loop; it must not fail a
    # run that otherwise succeeded.
    text = EXECUTE.read_text(encoding="utf-8")
    block = text[text.index("Refresh the desktop background") : text.index("BACKGROUND_REFRESH_ERROR")]
    assert "try {" in block
