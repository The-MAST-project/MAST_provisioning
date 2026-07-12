"""Per-run provisioning-log retention (port of server/lib/mast-log-archive.ps1).

The driver writes each run's logs under C:\\MAST\\logs\\prov\\sessions\\<run-id>\\.
On a host up for weeks-to-years that grows without bound, so at end of run the
driver keeps the newest N run dirs and prunes the rest. The delete DECISION is
the pure ``select_prunable_runs`` (unit-tested); ``run_retention`` is the thin
filesystem runner over it.
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Callable

# A run id is "run-yyyyMMdd-HHmmss" (check_and_provision mints it). The embedded
# stamp sorts lexically == chronologically. A dir whose name does not conform is
# of unknown provenance and is never pruned.
_RUN_ID_RE = re.compile(r"^run-(\d{8}-\d{6})$")


def run_id_timestamp(run_id: str) -> str | None:
    """Return the sortable "yyyyMMdd-HHmmss" of a conforming run id, else None."""
    m = _RUN_ID_RE.match(run_id)
    return m.group(1) if m else None


def select_prunable_runs(run_ids: list[str], retain: int) -> list[str]:
    """Keep-newest-N retention: return the run ids to prune.

    The newest ``retain`` conforming names are always kept (the hard ceiling
    that bounds growth); everything ranked beyond them is returned for pruning.
    Non-conforming names are never returned.
    """
    if retain < 1:
        raise ValueError(f"retain must be >= 1 (got {retain})")
    conforming = [r for r in run_ids if run_id_timestamp(r) is not None]
    if len(conforming) <= retain:
        return []
    ordered = sorted(conforming, key=run_id_timestamp, reverse=True)  # type: ignore[arg-type]
    return ordered[retain:]


def run_retention(
    sessions_root: Path,
    retain: int,
    logger: Callable[[str], None] | None = None,
) -> list[str]:
    """List the run dirs under ``sessions_root``, prune those beyond the newest
    ``retain``, and return the run ids removed. ``logger`` (message) receives
    per-dir prune warnings."""
    sessions_root = Path(sessions_root)
    if not sessions_root.is_dir():
        return []
    names = [p.name for p in sessions_root.iterdir() if p.is_dir()]
    prune = select_prunable_runs(names, retain)
    removed: list[str] = []
    for name in prune:
        try:
            shutil.rmtree(sessions_root / name)
            removed.append(name)
        except OSError as e:
            if logger:
                logger(f"prune failed dir={name} err={e}")
    return removed
