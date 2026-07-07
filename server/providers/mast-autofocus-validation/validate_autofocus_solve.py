r"""
End-to-end autofocus solve validation.

Drives the same production code path the live unit uses --
focus_analysis.analyze_focus_files (lifted out of Autofocuser.do_start_autofocus
in MAST_unit) -- against bundled FITS focus sweeps, confirming end-to-end that:

  * ps3cli.exe + its star catalog are installed and --server is reachable,
  * the build can fit a focus v-curve and return a solution,
  * the returned best-focus position lands near the expected value.

Like validate_mastrometry.py, this lives in the provisioning provider and imports
MAST_unit's src via --unit-src, so the unit repo carries only production code while
the validation fixtures (the FITS, shipped as the provider's autofocus-fits.zip)
and runner live with provisioning.

Each subdirectory of --fits-dir is one focus run (odd number of FOCUS*.fits, the
focuser position encoded in the file name; ps3cli reads it from there, so no
focuser hardware is involved). --expected maps a series name to
{"best_focus_position": <int>, "max_tolerance": <float>, "position_slop": <int>}
or {"expect_solution": false} for a negative control.

Exit code is 0 only if every series matches its expected outcome.
"""

import argparse
import glob
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8998


def find_focus_files(directory: Path) -> list[str]:
    """Return the FOCUS*.fits images in ``directory`` (matches .fit/.fits/.fts)."""
    return sorted(glob.glob(str(directory / "FOCUS*.f*t*")))


def discover_series(fits_root: Path) -> dict[str, list[str]]:
    """
    Map each immediate subdirectory of ``fits_root`` that holds FOCUS*.fits files
    to its file list. If ``fits_root`` itself holds FOCUS*.fits, treat it as a
    single series named after the directory.
    """
    series: dict[str, list[str]] = {}
    own = find_focus_files(fits_root)
    if own:
        series[fits_root.name] = own
        return series
    for child in sorted(p for p in fits_root.iterdir() if p.is_dir()):
        files = find_focus_files(child)
        if files:
            series[child.name] = files
    return series


def wait_for_port(host: str, port: int, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def start_ps3cli_server(port: int):
    """
    Launch a throwaway ``ps3cli --server``, resolving the exe and catalog via
    MAST_unit's shared locator (PlaneWave.ps3cli_locate) -- the same logic app.py
    uses, honoring PS3CLI_DIR/PS3CLI_CATALOG then default locations. Returns the
    Popen handle; caller must terminate it. Requires --unit-src already on sys.path.
    """
    from PlaneWave.ps3cli_locate import locate_ps3cli_catalog, locate_ps3cli_dir

    ps3dir = locate_ps3cli_dir()
    if ps3dir is None:
        raise RuntimeError(
            "ps3cli.exe not found (set PS3CLI_DIR or install under "
            "~/Documents/PlaneWave/ps3cli)"
        )
    catalog = locate_ps3cli_catalog()
    if catalog is None:
        raise RuntimeError(
            "PlateSolve catalog (a dir containing UC4 and Orca) not found "
            "(set PS3CLI_CATALOG or install under ~/Documents/Kepler)"
        )
    exe = str(Path(ps3dir) / "ps3cli.exe")
    cmd = [exe, "--server", f"--port={port}", f"--root-path={catalog}"]
    print(f"  launching: {' '.join(cmd)}")
    return subprocess.Popen(cmd, cwd=ps3dir)


def validate_series(name: str, files: list[str], expected: dict, host: str, port: int, timeout: float) -> bool:
    from focus_analysis import FocusAnalysisError, analyze_focus_files

    print(f"\n=== series '{name}' ({len(files)} images) ===")
    for f in files:
        print(f"    {f}")

    try:
        status = analyze_focus_files(files, timeout=timeout, host=host, port=port)
    except FocusAnalysisError as ex:
        print(f"  FAIL: analyser error (phase={ex.phase}): {ex}")
        return False
    except Exception as ex:  # connection refused, etc.
        print(f"  FAIL: {type(ex).__name__}: {ex}")
        return False

    result = status.analysis_result
    if result is None:
        print(f"  FAIL: empty analysis_result (last_log_message={status.last_log_message!r})")
        return False

    exp = expected.get(name, {})
    expect_solution = exp.get("expect_solution", True)

    if not expect_solution:
        # negative control: the analyser ran but is expected NOT to find a solution
        if result.has_solution:
            print(f"  FAIL: expected no solution but got best={result.best_focus_position}")
            return False
        print("  PASS (analyser ran and correctly found no solution)")
        return True

    if not result.has_solution:
        print(f"  FAIL: no solution (errors={result.errors})")
        return False

    print(
        f"  solved: best_focus_position={result.best_focus_position}, "
        f"best_focus_star_diameter={result.best_focus_star_diameter}, "
        f"tolerance={result.tolerance}"
    )

    ok = True
    if exp:
        max_tol = exp.get("max_tolerance")
        if max_tol is not None and (result.tolerance is None or result.tolerance > max_tol):
            print(f"  FAIL: tolerance {result.tolerance} exceeds max_tolerance {max_tol}")
            ok = False
        want_pos = exp.get("best_focus_position")
        slop = exp.get("position_slop", 0)
        if want_pos is not None and result.best_focus_position is not None:
            delta = abs(result.best_focus_position - want_pos)
            if delta > slop:
                print(f"  FAIL: best position {result.best_focus_position} off from {want_pos} by {delta} (> {slop})")
                ok = False
            else:
                print(f"  position within {slop} of expected {want_pos} (off by {delta})")
    else:
        print("  (no expected.json entry for this series -- solution-only check)")

    print(f"  {'PASS' if ok else 'FAIL'}")
    return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--unit-src", type=Path, required=True,
                        help="path to MAST_unit/src (added to sys.path for focus_analysis + PlaneWave.ps3cli_locate)")
    parser.add_argument("--fits-dir", type=Path, required=True,
                        help="directory holding focus series (subdirs of FOCUS*.fits)")
    parser.add_argument("--expected", type=Path, default=None,
                        help="JSON of per-series expectations (optional)")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--timeout", type=float, default=60, help="per-series analyser timeout (s)")
    parser.add_argument("--start-server", action="store_true",
                        help="launch a throwaway ps3cli --server (auto-locates exe + catalog, "
                             "honoring PS3CLI_DIR/PS3CLI_CATALOG if set)")
    parser.add_argument("--server-wait", type=float, default=30, help="seconds to wait for the server port")
    args = parser.parse_args()

    # Make MAST_unit's src importable (focus_analysis, PlaneWave.ps3cli_locate).
    if str(args.unit_src) not in sys.path:
        sys.path.insert(0, str(args.unit_src))

    if not args.fits_dir.is_dir():
        print(f"ERROR: fits dir not found: {args.fits_dir}")
        return 2

    series = discover_series(args.fits_dir)
    if not series:
        print(f"ERROR: no FOCUS*.fits series found under {args.fits_dir}")
        return 2

    expected = {}
    if args.expected and args.expected.is_file():
        expected = json.loads(args.expected.read_text())
        print(f"loaded expectations for: {sorted(expected)}")

    server = None
    try:
        if args.start_server:
            print("starting ps3cli --server ...")
            server = start_ps3cli_server(args.port)

        if not wait_for_port(args.host, args.port, args.server_wait):
            print(f"ERROR: ps3cli server not reachable at {args.host}:{args.port} "
                  f"within {args.server_wait}s (is the unit app or --start-server running?)")
            return 2

        results = {name: validate_series(name, files, expected, args.host, args.port, args.timeout)
                   for name, files in series.items()}
    finally:
        if server is not None:
            print("\nterminating throwaway ps3cli --server")
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()

    passed = sum(1 for ok in results.values() if ok)
    print(f"\n==== {passed}/{len(results)} series passed ====")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
