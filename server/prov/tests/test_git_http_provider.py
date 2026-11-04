"""git through bcproxy: HTTP/1.1, a stall limit, and retries (#220).

At git's default HTTP/2 a fetch through the site proxy hangs forever once the
tunnel is up. A hang is invisible to fetch_ok -- the call never returns -- so a
unit silently stops updating. The fix is carried in three places that must agree:
mast-clone's two halves set it for their own process, and the git-http provider
writes it machine-wide for everything else.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
_PROVIDER = _REPO_ROOT / "server" / "providers" / "git-http"
_LIB = _PROVIDER / "mast-git-http-lib.ps1"
_CLONE_PS1 = _REPO_ROOT / "tools" / "mast-clone.ps1"
_CLONE_SH = _REPO_ROOT / "tools" / "mast-clone.sh"

EXPECTED = {
    "http.version": "HTTP/1.1",
    "http.lowSpeedLimit": "1000",
    "http.lowSpeedTime": "60",
}

_PS1_ENTRY = re.compile(r"^\s*'(http\.\w+)'\s*=\s*'([^']*)'\s*$", re.MULTILINE)
_SH_ENTRY = re.compile(r'^\s*"(http\.\w+)=([^"]*)"\s*$', re.MULTILINE)


def _module() -> dict:
    return json.loads((_PROVIDER / "module.json").read_text(encoding="utf-8-sig"))


def test_the_three_copies_carry_the_same_settings() -> None:
    assert dict(_PS1_ENTRY.findall(_LIB.read_text(encoding="utf-8"))) == EXPECTED
    assert dict(_PS1_ENTRY.findall(_CLONE_PS1.read_text(encoding="utf-8"))) == EXPECTED
    assert dict(_SH_ENTRY.findall(_CLONE_SH.read_text(encoding="utf-8"))) == EXPECTED


def test_git_http_is_an_always_module_after_git() -> None:
    """A value changed out of band produces no payload-hash drift, so only an
    always-run module would look at it again; and git.exe must exist first."""
    module = _module()
    assert module.get("always") is True
    git = json.loads((_REPO_ROOT / "server" / "providers" / "git" / "module.json").read_text(encoding="utf-8-sig"))
    assert module["order"] > git["order"]


def test_git_http_verify_is_its_live_check_script() -> None:
    verify = _module()["verify"]
    assert "verify-git-http.ps1" in verify, verify
    assert "-Command" not in verify, verify


def test_both_halves_export_the_settings_through_git_config_count() -> None:
    """Per process, appended after the caller's own entries, never `git config`."""
    ps1 = _CLONE_PS1.read_text(encoding="utf-8")
    sh = _CLONE_SH.read_text(encoding="utf-8")
    assert "$env:GIT_CONFIG_COUNT" in ps1 and "env:GIT_CONFIG_KEY_" in ps1
    assert 'export GIT_CONFIG_COUNT="$_gc_index"' in sh and '_gc_index="${GIT_CONFIG_COUNT:-0}"' in sh


def test_every_clone_and_fetch_in_the_ps1_is_retried() -> None:
    plain = [
        f"{i}: {line.strip()}"
        for i, line in enumerate(_CLONE_PS1.read_text(encoding="utf-8").splitlines(), start=1)
        if re.search(r"Invoke-Git\s+@\(.*'(fetch|clone)'", line)
    ]
    assert not plain, "mast-clone.ps1 reaches the remote without Invoke-GitNetwork:\n" + "\n".join(plain)


def test_every_clone_and_fetch_in_the_sh_is_retried() -> None:
    plain = [
        f"{i}: {line.strip()}"
        for i, line in enumerate(_CLONE_SH.read_text(encoding="utf-8").splitlines(), start=1)
        if re.search(r"\bgit\b.*\b(fetch|clone)\b\s", line)
        and not re.search(r'run_net (--creates "[^"]*" )?git', line)
        and not line.lstrip().startswith("#")
        and "warn" not in line
        and "info" not in line
    ]
    assert not plain, "mast-clone.sh reaches the remote without run_net:\n" + "\n".join(plain)


# --- the retry behavior, by running the real script ----------------------------
#
# The assertions above pin the source text; these run tools/mast-clone.sh against a
# fake git on PATH, so a regression in the append or the retry budget fails here
# rather than on a unit. The .ps1 half has no runner off Windows; it was checked the
# same way on labcomp2 (see the decision record).

_FAKE_GIT = """#!/usr/bin/env bash
echo "$* | GIT_CONFIG_COUNT=${GIT_CONFIG_COUNT:-} \
${GIT_CONFIG_KEY_0:-}=${GIT_CONFIG_VALUE_0:-} ${GIT_CONFIG_KEY_1:-}=${GIT_CONFIG_VALUE_1:-} \
${GIT_CONFIG_KEY_2:-}=${GIT_CONFIG_VALUE_2:-} ${GIT_CONFIG_KEY_3:-}=${GIT_CONFIG_VALUE_3:-}" >> "$FAKE_GIT_LOG"
case "$*" in
  *"remote get-url origin"*) echo "MAST_common MAST_unit.2024-12-12 mast-claude-config MAST_supervision";;
  *" fetch "*) exit 1;;
  "clone "*) mkdir -p "${@: -1}"; exit 1;;
  *"rev-parse"*) echo 0123456789abcdef;;
esac
exit 0
"""

needs_bash = pytest.mark.skipif(os.name == "nt" or shutil.which("bash") is None, reason="runs mast-clone.sh")


def _unit_dirs() -> list[str]:
    rows = [line.split("\t") for line in (_REPO_ROOT / "tools" / "mast-repos.tsv").read_text(encoding="utf-8").splitlines()]
    return [r[0] for r in rows if len(r) >= 4 and not r[0].startswith("#") and "unit" in r[2].split(",")]


def _run_clone(tmp_path: Path, top: Path) -> tuple[list[str], str]:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    fake = bindir / "git"
    fake.write_text(_FAKE_GIT, encoding="utf-8")
    fake.chmod(0o755)
    log = tmp_path / "git.log"
    env = {
        **os.environ,
        "PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}",
        "FAKE_GIT_LOG": str(log),
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.caller",
        "GIT_CONFIG_VALUE_0": "kept",
    }
    out = subprocess.run(
        ["bash", str(_CLONE_SH), "--top", str(top), "--role", "unit", "--direct-http"],
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    return log.read_text(encoding="utf-8").splitlines(), out.stdout + out.stderr


@needs_bash
def test_a_dead_remote_costs_three_attempts_once_then_one_each(tmp_path: Path) -> None:
    top = tmp_path / "top"
    dirs = _unit_dirs()
    for d in dirs:
        (top / d / ".git").mkdir(parents=True)
    calls, _ = _run_clone(tmp_path, top)
    fetches = [c for c in calls if " fetch --prune " in c]
    assert len(fetches) == 3 + (len(dirs) - 1), fetches
    expected = "GIT_CONFIG_COUNT=4 core.caller=kept http.version=HTTP/1.1 http.lowSpeedLimit=1000 http.lowSpeedTime=60"
    assert all(c.endswith(expected) for c in fetches), fetches[0]
    manifest = json.loads((top / "clone-manifest.json").read_text(encoding="utf-8"))
    assert [r["fetch_ok"] for r in manifest["repos"]] == [False] * len(dirs)


@needs_bash
def test_a_clone_that_leaves_its_folder_is_not_retried(tmp_path: Path) -> None:
    calls, output = _run_clone(tmp_path, tmp_path / "top")
    assert len([c for c in calls if c.startswith("clone ")]) == 1, calls
    assert "not the network; not retrying" in output
