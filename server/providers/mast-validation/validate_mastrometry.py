"""
End-to-end MAST_unit plate-solving validation.

Drives the same MastrometryDotNet class that runs in production (under the
mast-unit service) against C:\\MAST\\full-frame.fits, using the MAST_unit
venv. The goal is to validate the full chain through the unit's *own* code:
the per-repo venv, MAST_common imports, Filer/RAM disk wiring, astrometry
binary discovery, and the on-RAM-disk index files.

Preconditions are HARD requirements (exit 1), not skips: a provisioning run
that cannot exercise a real end-to-end solve is not a valid run. The index
image and smoke FITS must be staged and mounted (imdisk provider) before this
runs. We therefore FAIL when:
  - the smoke FITS is not present
  - the ImDisk-mounted index drive / index files are not available
  - import errors, missing solve-field, or the solver not converging
"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from pathlib import Path


def _write_smoke(smoke_path: Path, body: str) -> None:
    smoke_path.parent.mkdir(parents=True, exist_ok=True)
    smoke_path.write_text(body + "\n", encoding="ascii")


def _has_ramdisk_indexes() -> tuple[bool, str]:
    """Return (ok, reason). ok=True means we can attempt the solve."""
    # Mastrometry expects indexes at <ram.drive>/mast-indexes (see
    # MAST_unit/src/solvers/mastrometry.py). Filer chooses D:/ when D: is
    # a mapped drive, else C:/. On a real unit that is the ImDisk RAM disk
    # mount; in the dev VM D: comes from imdisk's boot-time task.
    try:
        import win32api  # type: ignore
        drives = win32api.GetLogicalDriveStrings().split("\000")[:-1]
        d_mapped = "D:\\" in drives
    except Exception as e:  # pragma: no cover -- pywin32 missing
        return False, f"no_pywin32 ({e})"

    candidate = Path("D:/mast-indexes") if d_mapped else Path("C:/mast-indexes")
    if not candidate.exists():
        return False, f"no_index_dir ({candidate})"
    # Need at least one index-*.fits to attempt a solve.
    has_any = any(candidate.glob("index-*.fits"))
    if not has_any:
        return False, f"no_index_files ({candidate})"
    return True, f"using {candidate}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--unit-src", required=True,
                    help="Path to MAST_unit/src (added to sys.path)")
    ap.add_argument("--fits", required=True,
                    help="Path to the full-frame FITS to solve")
    ap.add_argument("--smoke-file", required=True,
                    help="Path of smoke marker to write")
    ap.add_argument("--allow-missing-avx", action="store_true",
                    help="Dev-VM-only escape: if the solver crashes with SIGILL "
                         "(signal 4) because the guest CPU lacks AVX/AVX2/FMA, "
                         "treat that specific failure as SKIPPED with a warning "
                         "instead of FAIL. Corrupt index files are still a hard "
                         "FAIL. Set by build-mast's -TestMode; MUST NOT be passed "
                         "in production.")
    args = ap.parse_args()

    smoke_path = Path(args.smoke_file)
    fits_path = Path(args.fits)
    unit_src = Path(args.unit_src)

    # Make MAST_unit's src importable (common, imagers, solvers, ...).
    if str(unit_src) not in sys.path:
        sys.path.insert(0, str(unit_src))

    os.environ.setdefault("MAST_PROJECT", "unit")

    # Preconditions -- HARD FAIL if not met (a run without a real solve is invalid).
    if not fits_path.exists():
        print(f"FAIL: full-frame FITS not present at {fits_path}. "
              "The smoke FITS must be staged to the unit; a run without a real solve is not valid.")
        return 1

    ok, reason = _has_ramdisk_indexes()
    if not ok:
        print(f"FAIL: astrometry indexes not available ({reason}). "
              "The index image must be staged and mounted (imdisk provider) before validation.")
        return 1

    # Real work: import the production solver and drive it.
    try:
        from common.interfaces.imager import ImagerRoi  # type: ignore
        from imagers import ImagerSettings              # type: ignore
        from solvers.mastrometry import MastrometryDotNet  # type: ignore
    except Exception:
        print("FAIL: import error -- MAST_unit modules not loadable from venv")
        traceback.print_exc()
        return 1

    try:
        solver = MastrometryDotNet()
    except Exception:
        # __init__ asserts RAM disk is mounted and index dir exists; if it
        # blows up despite our preflight, treat that as breakage (not skip).
        print("FAIL: MastrometryDotNet() construction failed")
        traceback.print_exc()
        return 1

    # Match the in-tree test_solver_with_roi() shape -- a generous ROI that
    # both phases tolerate, so we do not need a real Unit/Config wired up.
    try:
        result = solver.solve(
            unit=None,
            phase="spec",
            full_frame_input_image_path=str(fits_path),
            settings=ImagerSettings(
                seconds=5,
                binning=1,
                roi=ImagerRoi(x=0, y=0, width=2500, height=5500),
                image_path=str(fits_path),
            ),
        )
    except Exception:
        print("FAIL: solver.solve() raised")
        traceback.print_exc()
        return 1

    if result is None or not getattr(result, "succeeded", False):
        errors = getattr(result, "errors", None) if result is not None else None
        err_text = " ".join(str(e) for e in (errors or []))

        # Highest-priority check: corrupt/unloadable index file in the staged
        # image. Promoted to a hard FAIL regardless of mode (per DECISIONS.md
        # 2026-05-28); --allow-missing-avx does NOT relax this.
        import re as _re
        corrupt = sorted(set(
            _re.findall(r'Failed to add index\s+"([^"]+)"', err_text)
            + _re.findall(r'Failed to load index from path\s+(\S+)', err_text)
        ))
        if corrupt:
            print("FAIL: corrupt/unloadable astrometry index file(s) detected during the solve:")
            for p in corrupt:
                print(f"  {p}")
            print("These files are corrupt (e.g. missing kdtree header) and must be rebuilt or "
                  "replaced in the index image before re-running.")
            return 1

        # Dev-VM escape: astrometry-engine SIGILL when the guest CPU lacks
        # AVX/AVX2/FMA. With --allow-missing-avx, treat as SKIPPED.
        if args.allow_missing_avx and (
            "killed by signal 4" in err_text or "SIGILL" in err_text
        ):
            body = "mastrometry_ok solve=skipped reason=avx_missing"
            _write_smoke(smoke_path, body)
            print("WARN: solver crashed with signal 4 / SIGILL -- guest CPU lacks AVX/AVX2/FMA.")
            print("WARN: --allow-missing-avx set (dev VM mode); treating mast-validation as SKIPPED.")
            print("WARN: production runs on real MAST hardware MUST NOT pass --allow-missing-avx.")
            print(body)
            return 0

        print(f"FAIL: solve did not converge. errors={errors}")
        return 1

    sol = getattr(result, "solution", None)
    ra_hours = getattr(sol, "ra_hours", None) if sol is not None else None
    dec_degs = getattr(sol, "dec_degs", None) if sol is not None else None
    matched = getattr(sol, "matched_stars", None) if sol is not None else None

    body = (
        "mastrometry_ok solve=ok "
        f"ra_hours={ra_hours} dec_degs={dec_degs} matched={matched}"
    )
    _write_smoke(smoke_path, body)
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
