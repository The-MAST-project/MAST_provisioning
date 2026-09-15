"""The provisioning run repaints the operator desktop itself; no AtLogon task does.

The background states when the unit was last provisioned and reads that from
installed-manifest.json, which execute writes only after every module has run. So
the refresh cannot live in a module -- one inside the command loop paints the
previous run's date, permanently one run behind (#200).

It used to be split: execute re-rendered, then started an AtLogon task to repaint
the live session, because only something inside the logon session can call
SystemParametersInfo. That task ran non-elevated against a machine-wide image and
could never re-render (#206). It is retired: the detached execute task already runs
as mast with LogonType Interactive, so execute is itself inside the session and
elevated, and does both halves.
"""

from __future__ import annotations

import re

from prov import transport as T

EXECUTE = T.REPO_ROOT / "client" / "execute-mast-provisioning.ps1"
APPEARANCE = T.REPO_ROOT / "server" / "providers" / "desktop-appearance"
PROVIDE = APPEARANCE / "provide-desktop-appearance.ps1"
LIB = APPEARANCE / "mast-appearance-lib.ps1"
RETIRED_TASK = "MAST-DesktopAppearance-Apply"


def test_the_refresh_runs_after_the_installed_manifest_is_written():
    # The ordering IS the fix. If the refresh moves above the merge it silently
    # starts painting the previous run's date, which is the bug it exists to fix.
    text = EXECUTE.read_text(encoding="utf-8")
    merge = text.index("Merge-MastInstalledManifest -Previous")
    refresh = text.index("Update-MastStaleBackground")
    assert merge < refresh, "the background refresh must run after installed_at is written"


def test_execute_repaints_the_live_session_after_re_rendering():
    # Re-rendering changes the file; only SystemParametersInfo makes the running
    # desktop show it. Both belong to execute now, in that order.
    text = EXECUTE.read_text(encoding="utf-8")
    assert text.index("Update-MastStaleBackground") < text.index("Set-MastLiveDesktop")


def test_the_live_apply_is_best_effort():
    # A desktop that did not repaint is cosmetic and verify reports it; it must not
    # fail a run whose modules all succeeded.
    text = EXECUTE.read_text(encoding="utf-8")
    block = text[text.index("Refresh the desktop background") : text.index("DESKTOP_APPLY_ERROR")]
    assert "try {" in block


def test_the_live_apply_only_touches_the_mast_users_own_hive():
    # It writes HKCU of the calling process. Execute runs as mast under the
    # detached task, but the WinRM fallback path does not, and writing the theme
    # into an administrator's hive would be silent and wrong.
    text = LIB.read_text(encoding="utf-8")
    body = text[text.index("function Set-MastLiveDesktop") :]
    assert "USERNAME" in body, "Set-MastLiveDesktop must check whose hive HKCU is"


def test_nothing_registers_the_retired_atlogon_task():
    for path in sorted(APPEARANCE.glob("*.ps1")) + [EXECUTE]:
        text = path.read_text(encoding="utf-8")
        assert "New-ScheduledTaskTrigger -AtLogOn" not in text, f"{path.name} still registers an AtLogon task"
        assert "Start-ScheduledTask" not in text, f"{path.name} still starts the retired apply task"


def test_the_provider_removes_the_task_from_units_that_still_carry_it():
    # Not creating it is not enough: six units in the field have it registered.
    text = PROVIDE.read_text(encoding="utf-8")
    assert re.search(rf"Unregister-ScheduledTask[^\n]*\$\{{RetiredTaskName\}}|{RETIRED_TASK}", text)
    assert "Unregister-ScheduledTask" in text


def test_the_apply_script_is_gone():
    assert not (APPEARANCE / "apply-desktop-appearance.ps1").exists()
