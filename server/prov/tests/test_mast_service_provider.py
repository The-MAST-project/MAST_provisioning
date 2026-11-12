"""mast-service: provisioning installs the supervisor's service on supervised units only.

The supervisor's own installer (MAST_supervision ``install/install-mast-service.ps1``)
does the ``nssm install``; this repo decides where it runs and owns the service's
life around a run: standdown (20) stops it, the ``mast-service`` provider installs or
removes it, finalize (9500) starts it or asserts it absent. The flag reaches all three
through the build, as ``-Supervised`` on the command lines, so a flip changes the
modules' content hashes.

None of this runs PowerShell here; the scripts are pinned by their text, and Pester
on CI covers the rest.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from prov import driver as D

_ROOT = Path(__file__).resolve().parents[3]
_PROVIDERS = _ROOT / "server" / "providers"
_PROVIDER = _PROVIDERS / "mast-service"
_NAMES = _ROOT / "tools" / "mast-service-names.ps1"
_BUILD = _ROOT / "build" / "build-mast.ps1"
_STANDDOWN = _PROVIDERS / "mast-services-standdown" / "provide-mast-services-standdown.ps1"
_STANDDOWN_VERIFY = _PROVIDERS / "mast-services-standdown" / "verify-mast-services-standdown.ps1"
_FINALIZE = _PROVIDERS / "mast-services-finalize" / "provide-mast-services-finalize.ps1"
_FINALIZE_VERIFY = _PROVIDERS / "mast-services-finalize" / "verify-mast-services-finalize.ps1"

SERVICE = "mast-service"
ACCESSOR = "Get-MastSupervisorServiceName"
SUPERVISED_MODULES = {"mast-service", "mast-services-finalize"}


def _module(name: str) -> dict:
    return json.loads((_PROVIDERS / name / "module.json").read_text(encoding="utf-8-sig"))


def _code(path: Path) -> str:
    """The script without its comment lines, so prose about a call is not the call."""
    lines = path.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("#"))


# --- the name ---------------------------------------------------------------------


def test_the_service_name_has_one_accessor() -> None:
    match = re.search(rf"function {ACCESSOR} \{{\s*'([^']+)'\s*\}}", _NAMES.read_text(encoding="utf-8"))
    assert match, f"{ACCESSOR} not found in {_NAMES}"
    assert match.group(1) == SERVICE


def test_the_service_is_not_on_the_removal_lists() -> None:
    """Get-MastServiceNames feeds the driver's phase 2b, which deletes; a supervised
    unit's service must survive every run."""
    assert SERVICE not in D.STAND_DOWN_SERVICES
    assert SERVICE not in D.STAND_DOWN_LEGACY_SERVICES


#: A line that acts on a service. The module shares the service's name, so a log
#: component or a verify-log name spelled 'mast-service' is not an offence.
_SERVICE_ACTION = re.compile(
    r"(Get|Stop|Start|Restart|Set)-Service|Remove-MastService|Win32_Service|sc(\.exe)?\s", re.IGNORECASE
)


def test_no_script_acts_on_the_service_by_a_spelled_out_name() -> None:
    offenders = [
        f"{path.relative_to(_ROOT)}: {line.strip()}"
        for path in sorted(_PROVIDERS.rglob("*.ps1"))
        for line in _code(path).splitlines()
        if SERVICE in line and _SERVICE_ACTION.search(line)
    ]
    assert not offenders, f"name the service through {ACCESSOR}:\n" + "\n".join(offenders)


# --- the provider -----------------------------------------------------------------


def test_the_provider_runs_after_mast_and_nssm() -> None:
    order = _module("mast-service")["order"]
    assert order > _module("mast")["order"]
    assert order > _module("nssm")["order"]
    assert order < _module("mast-services-finalize")["order"]


def test_the_provider_is_hash_driven_not_always() -> None:
    """The flag and the supervision pin are both in its hash; an always-run install
    would rewrite a running service's registration every run."""
    assert not _module("mast-service").get("always", False)


def test_the_provider_stages_its_scripts_and_the_shared_files() -> None:
    module = _module("mast-service")
    assert set(module["commandfiles"]) == {"provide-mast-service.ps1", "verify-mast-service.ps1"}
    # mast-repos.tsv: the installer lives in the supervision checkout, outside this
    # module's own files, so the supervision pin must be in its hash.
    assert set(module["repofiles"]) == {"tools/mast-service-names.ps1", "tools/mast-repos.tsv"}


def test_the_provider_and_mast_agree_on_the_top() -> None:
    top = re.search(r'-Top "([^"]+)"', _module("mast")["command"])
    assert top
    for key in ("command", "verify"):
        assert f'-Top "{top.group(1)}"' in _module("mast-service")[key]


def test_supervised_runs_the_supervision_installer_and_fails_without_one() -> None:
    code = _code(_PROVIDER / "provide-mast-service.ps1")
    assert re.search(r"\[switch\]\$\{Supervised\}", code)
    assert "'supervision\\install\\install-mast-service.ps1'" in code
    assert re.search(r"if \(-not \(Test-Path -LiteralPath \$\{installer\}\)\)", code)


def test_unsupervised_removes_it_through_provisionings_own_removal() -> None:
    """Not the installer's -Uninstall: removal must work on a checkout that predates it."""
    code = _code(_PROVIDER / "provide-mast-service.ps1")
    assert re.search(rf"Remove-MastService -Name \({ACCESSOR}\)", code)
    assert "-Uninstall" not in code


def test_the_provider_never_starts_the_service() -> None:
    for script in ("provide-mast-service.ps1", "verify-mast-service.ps1"):
        code = _code(_PROVIDER / script)
        assert not re.search(r"(Start|Restart)-Service|sc(\.exe)?\s+start", code, re.IGNORECASE), script


def test_the_provider_verify_checks_the_registration_not_running() -> None:
    code = _code(_PROVIDER / "verify-mast-service.ps1")
    assert re.search(r"\[switch\]\$\{Supervised\}", code)
    for expected in ("LocalSystem", "'Auto'", "supervision.service"):
        assert expected in code, expected
    assert "'Running'" not in code


# --- standdown and finalize ----------------------------------------------------------


def test_standdown_stops_it_and_never_deletes_it() -> None:
    code = _code(_STANDDOWN)
    assert re.search(rf"Stop-Service -Name \({ACCESSOR}\)", code)
    assert not re.search(rf"Remove-MastService -Name \({ACCESSOR}\)", code)


def test_standdown_verify_asserts_it_is_not_running() -> None:
    assert re.search(rf"Get-Service -Name \({ACCESSOR}\)", _code(_STANDDOWN_VERIFY))


def test_finalize_starts_it_when_supervised_and_asserts_it_absent_otherwise() -> None:
    code = _code(_FINALIZE)
    assert re.search(r"\[switch\]\$\{Supervised\}", code)
    assert re.search(rf"Start-Service -Name \({ACCESSOR}\)", code)
    assert "Get-MastRegisteredServiceNames" in code, "the legacy names must still be asserted absent"


def test_finalize_verify_asserts_running_when_supervised() -> None:
    code = _code(_FINALIZE_VERIFY)
    assert re.search(r"\[switch\]\$\{Supervised\}", code)
    assert "'Running'" in code
    assert "Get-MastRegisteredServiceNames" in code


# --- the build ----------------------------------------------------------------------


def test_the_build_names_the_modules_that_take_the_flag() -> None:
    text = _BUILD.read_text(encoding="utf-8")
    match = re.search(r"\$\{SupervisedModules\} = @\(([^)]*)\)", text)
    assert match, "build-mast.ps1 declares no SupervisedModules list"
    assert set(re.findall(r"'([^']+)'", match.group(1))) == SUPERVISED_MODULES


def test_the_build_puts_the_flag_on_both_command_and_verify() -> None:
    """Both lines are in the module's content hash, so a flip re-runs both modules."""
    text = _BUILD.read_text(encoding="utf-8")
    guard = r"if \(\$\{Supervised\} -and \$\{m\} -in \$\{SupervisedModules\}\) "
    for line in ("cmd", "verifyCmd"):
        appended = rf"\{{ \$\{{{line}\}} = \$\{{{line}\}} \+ ' -Supervised' \}}"
        assert re.search(guard + appended, text), line


def test_every_module_that_takes_the_flag_declares_it() -> None:
    for module in SUPERVISED_MODULES:
        for key in ("command", "verify"):
            script = re.search(r'-File "\.\\([^"]+\.ps1)"', _module(module)[key])
            assert script, (module, key)
            code = _code(_PROVIDERS / module / script.group(1))
            assert re.search(r"\[switch\]\$\{Supervised\}", code), (module, key)
