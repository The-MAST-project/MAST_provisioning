"""Unit tests for pure logic in run-prov-test.py (no VM, no WinRM).

run-prov-test.py is loaded via importlib (its filename has hyphens) -- this only
works because module discovery is now LAZY (all_modules()), so importing the
script no longer spawns PowerShell. That laziness is what makes phase-selection
logic unit-testable; resolve_phases() is pure (args -> phase set), so we test it
directly with synthetic argparse namespaces.

Run with pytest:   python -m pytest vm/tests/
Or standalone:     python vm/tests/test_run_prov_test.py
"""

import argparse
import importlib.util
import sys
from pathlib import Path

VM_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(VM_DIR))


def _load_run_prov_test():
    path = VM_DIR / "run-prov-test.py"
    spec = importlib.util.spec_from_file_location("run_prov_test", path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # must NOT spawn PowerShell (lazy all_modules)
    return mod


rpt = _load_run_prov_test()


def _args(**kw) -> argparse.Namespace:
    base = {
        "phases": None,
        "build_only": False,
        "execute_only": False,
        "build_transfer_verify": False,
        "pull_repos": False,
        "rebuild_repos": False,
    }
    base.update(kw)
    return argparse.Namespace(**base)


def test_default_is_full_cycle():
    assert rpt.resolve_phases(_args()) == rpt.DEFAULT_PHASES


def test_explicit_phases_parsed():
    assert rpt.resolve_phases(_args(phases="build,transfer")) == frozenset({"build", "transfer"})
    # whitespace / empty segments tolerated
    assert rpt.resolve_phases(_args(phases=" build , verify ,")) == frozenset({"build", "verify"})


def test_legacy_flags_map_to_phase_sets():
    assert rpt.resolve_phases(_args(build_only=True)) == frozenset({"build"})
    assert rpt.resolve_phases(_args(execute_only=True)) == frozenset({"execute", "verify"})
    assert rpt.resolve_phases(_args(pull_repos=True)) is None
    assert rpt.resolve_phases(_args(rebuild_repos=True)) is None


def test_unknown_phase_exits():
    try:
        rpt.resolve_phases(_args(phases="build,bogus"))
    except SystemExit:
        return
    raise AssertionError("unknown phase should SystemExit")


def test_conflicting_legacy_flags_exit():
    try:
        rpt.resolve_phases(_args(build_only=True, execute_only=True))
    except SystemExit:
        return
    raise AssertionError("conflicting legacy flags should SystemExit")


def test_phases_with_legacy_flag_exits():
    try:
        rpt.resolve_phases(_args(phases="build", build_only=True))
    except SystemExit:
        return
    raise AssertionError("--phases combined with a legacy flag should SystemExit")


def _run_all() -> int:
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(_run_all())


def test_dev_vm_address_recognises_the_host_only_network():
    assert rpt.is_dev_vm_address("192.168.56.101")
    assert rpt.is_dev_vm_address("192.168.56.1")


def test_dev_vm_address_rejects_real_units():
    # The bench link-local pair a physical unit uses (2026-08-25, mast08).
    assert not rpt.is_dev_vm_address("169.254.27.222")
    # A routable institute address, which is what a bare unit name resolves to.
    assert not rpt.is_dev_vm_address("132.76.237.21")
    # An unresolved name must not read as the VM.
    assert not rpt.is_dev_vm_address("")
    assert not rpt.is_dev_vm_address("mast08")
