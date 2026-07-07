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
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # must NOT spawn PowerShell (lazy all_modules)
    return mod


rpt = _load_run_prov_test()


def _args(**kw) -> argparse.Namespace:
    base = dict(
        phases=None, build_only=False, execute_only=False,
        build_transfer_verify=False, pull_repos=False, rebuild_repos=False,
    )
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
