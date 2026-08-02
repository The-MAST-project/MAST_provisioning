#!/usr/bin/env python3
"""Fleet drift report (MVP): a quick cross-unit read of "what version is on each unit".

Gathers each unit's C:\\MAST\\installed-manifest.json (provisioning payload version) and
C:\\MAST\\bootstrap-manifest.json (which bootstrap the operator ran) over SSH and prints a
cross-unit comparison: a per-unit summary, a module-version matrix flagging where units
diverge, and a bootstrap section flagging units on an older/unstamped bootstrap (with the
bootstrap elements they may be missing). Read-only -- it never changes anything on a unit.

Why SSH (not WinRM): SSH reaches units from any egress, whereas the units' WinRM listener
is LocalSubnet-scoped, so a cross-subnet host (e.g. labcomp) cannot WinRM to them. A --winrm
mode can be added later for a same-subnet prov server.

This is the MVP of the "Version / Drift Detection" feature in
autonomous-provisioning-requirements.md. It trusts the static manifests (acceptable audit
artifacts today) and treats a missing manifest as a first-class signal. Growth path:
computed/live manifests, tiered self-validation, Prometheus -- all behind this report shape.

Usage (from the prov server / labcomp, at the repo root):
    python tools/fleet-drift-report.py                      # all hosts in unit-registry.json
    python tools/fleet-drift-report.py --hosts mast02,mast03
    python tools/fleet-drift-report.py --build-manifest staging/mast03/01-provisioning/build-manifest.json
    python tools/fleet-drift-report.py --json report.json --csv report.csv
    python tools/fleet-drift-report.py --from-json report.json   # re-render a saved gather (no SSH)

Only the live SSH gather needs vm_lib (pywinrm/paramiko); --from-json / --build-manifest
work with no extra dependencies.

Exit codes: 0 = every unit in sync AND bootstrap current; 2 = drift/missing/outdated found;
1 = tool error.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT / "vm"))  # so a lazy 'import vm_lib' resolves in the gather path
sys.path.insert(0, str(_REPO_ROOT / "server"))  # prov.* -- shared with the driver

from prov.drift import ModuleState, classify  # noqa: E402
from prov.unit_paths import UNIT_INSTALLED, UNIT_VALIDATION  # noqa: E402

# The unit-side paths come from prov.unit_paths so this tool and the driver
# cannot disagree about where a unit keeps its state.
MANIFEST_PATH = UNIT_INSTALLED
VALIDATION_PATH = UNIT_VALIDATION
BOOTSTRAP_PATH = r"C:\MAST\bootstrap-manifest.json"
NO_MANIFEST_SENTINEL = "__MAST_NO_MANIFEST__"
NO_BOOTSTRAP_SENTINEL = "__MAST_NO_BOOTSTRAP__"
SPLIT = "====MAST-DRIFT-SPLIT===="


@dataclass
class UnitRecord:
    host: str
    status: str = "unknown"          # ok | no-manifest | unreachable | parse-error | error
    payload_hash: str | None = None
    git_sha: str | None = None
    built_at: str | None = None
    installed_at: str | None = None
    module_versions: dict[str, str] = field(default_factory=dict)
    # Per-module entries from the cumulative manifest (#22 stage 2). Empty on a
    # unit still carrying a pre-stage-2 manifest -- see _manifest_from_obj.
    modules: dict[str, dict] = field(default_factory=dict)
    fully_provisioned: bool | None = None
    bootstrap_version: int | None = None
    bootstrapped_at: str | None = None
    #: Tier-2 verify outcomes {module: pass|fail} from the unit's last
    #: run-verify-only pass; empty when tier 2 has not run.
    validation: dict[str, str] = field(default_factory=dict)
    validated_at: str | None = None
    error: str | None = None


def _load_json(path: Path):
    # utf-8-sig tolerates the BOM that PowerShell's Out-File -Encoding UTF8 writes.
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def _short(value: str | None, n: int = 12) -> str:
    if not value:
        return "-"
    return value if len(value) <= n else value[:n]


def read_registry_hosts(registry_path: Path) -> list[str]:
    data = _load_json(registry_path)
    hosts = [str(e["hostname"]).strip() for e in data if isinstance(e, dict) and e.get("hostname")]
    if not hosts:
        raise ValueError(f"No hostnames found in {registry_path}")
    return hosts


def _manifest_from_obj(host: str, obj: dict) -> UnitRecord:
    # Two manifest shapes coexist during the rollout: the cumulative per-module
    # 'modules' map (#22 stage 2) and the legacy whole-document copy carrying
    # 'module_versions'. Read both so a not-yet-reprovisioned unit still renders
    # rather than showing up empty.
    modules = obj.get("modules") or {}
    if not isinstance(modules, dict):
        modules = {}
    mv = {str(k): str(v.get("version", "")) for k, v in modules.items() if isinstance(v, dict)}
    if not mv:
        mv = {str(k): str(v) for k, v in (obj.get("module_versions") or {}).items()}
    return UnitRecord(
        host=host,
        status="ok",
        payload_hash=obj.get("payload_hash"),
        git_sha=obj.get("git_sha"),
        built_at=obj.get("built_at"),
        installed_at=obj.get("installed_at"),
        module_versions=mv,
        modules=modules,
        fully_provisioned=obj.get("fully_provisioned"),
    )


def _parse_validation(part: str) -> tuple[dict[str, str], str | None]:
    """Tier-2 report, if the unit has one. Absent/garbled means "tier 2 unknown",
    never "tier 2 failed" -- an unreadable report must not manufacture drift."""
    part = (part or "").strip()
    if not part:
        return {}, None
    try:
        obj = json.loads(part)
    except json.JSONDecodeError:
        return {}, None
    mods = obj.get("modules") or {}
    if not isinstance(mods, dict):
        return {}, None
    return {str(k): str(v) for k, v in mods.items()}, obj.get("checked_at")


def _parse_bootstrap(part: str) -> tuple[int | None, str | None]:
    part = part.strip()
    if not part or NO_BOOTSTRAP_SENTINEL in part:
        return None, None
    try:
        obj = json.loads(part)
        bv = obj.get("bootstrap_version")
        return (int(bv) if bv is not None else None), obj.get("bootstrapped_at")
    except (json.JSONDecodeError, ValueError, TypeError):
        return None, None


def gather_unit(host: str, cred: dict[str, str], connect_timeout_s: int) -> UnitRecord:
    """Read installed-manifest.json + bootstrap-manifest.json from one unit over SSH (read-only)."""
    import vm_lib  # lazy: only the live gather needs pywinrm/paramiko

    try:
        session = vm_lib.SshSession(host, cred, connect_timeout_s=connect_timeout_s)
    except Exception as exc:  # noqa: BLE001 - report, do not abort the whole fleet
        return UnitRecord(host=host, status="unreachable", error=str(exc))

    try:
        script = (
            f"if (Test-Path -LiteralPath '{MANIFEST_PATH}') "
            f"{{ Get-Content -LiteralPath '{MANIFEST_PATH}' -Raw }} else {{ '{NO_MANIFEST_SENTINEL}' }}; "
            f"'{SPLIT}'; "
            f"if (Test-Path -LiteralPath '{BOOTSTRAP_PATH}') "
            f"{{ Get-Content -LiteralPath '{BOOTSTRAP_PATH}' -Raw }} else {{ '{NO_BOOTSTRAP_SENTINEL}' }}; "
            f"'{SPLIT}'; "
            f"if (Test-Path -LiteralPath '{VALIDATION_PATH}') "
            f"{{ Get-Content -LiteralPath '{VALIDATION_PATH}' -Raw }}"
        )
        resp = session.run_ps(script)
        out = resp.std_out.decode("utf-8-sig", errors="replace")
        installed_part, _, rest = out.partition(SPLIT)
        bootstrap_part, _, validation_part = rest.partition(SPLIT)
        bootstrap_version, bootstrapped_at = _parse_bootstrap(bootstrap_part)
        validation, validated_at = _parse_validation(validation_part)

        installed_part = installed_part.strip()
        if not installed_part or NO_MANIFEST_SENTINEL in installed_part:
            rec = UnitRecord(host=host, status="no-manifest")
        else:
            try:
                rec = _manifest_from_obj(host, json.loads(installed_part))
            except json.JSONDecodeError as exc:
                rec = UnitRecord(host=host, status="parse-error", error=str(exc))
        rec.bootstrap_version = bootstrap_version
        rec.bootstrapped_at = bootstrapped_at
        rec.validation = validation
        rec.validated_at = validated_at
        return rec
    except Exception as exc:  # noqa: BLE001
        return UnitRecord(host=host, status="error", error=str(exc))
    finally:
        session.close()


def load_bootstrap_elements(repo_root: Path) -> dict:
    """Element history + current bootstrap version (client/bootstrap-elements.json)."""
    path = repo_root / "client" / "bootstrap-elements.json"
    if not path.exists():
        return {}
    return _load_json(path)


def repo_bootstrap_version(repo_root: Path) -> int | None:
    """Parse $script:BootstrapVersion from client/bootstrap-winrm.ps1 (consistency check)."""
    path = repo_root / "client" / "bootstrap-winrm.ps1"
    if not path.exists():
        return None
    m = re.search(r"\$script:BootstrapVersion\s*=\s*(\d+)", path.read_text(encoding="utf-8", errors="replace"))
    return int(m.group(1)) if m else None


def _baseline(values: list[str | None], reference: str | None) -> str | None:
    """Reference wins if given; otherwise the majority (ties -> first seen)."""
    if reference is not None:
        return reference
    present = [v for v in values if v is not None]
    if not present:
        return None
    counts: dict[str, int] = {}
    for v in present:
        counts[v] = counts.get(v, 0) + 1
    return max(present, key=lambda v: (counts[v], -present.index(v)))


#: Compact status glyphs for the per-module matrix.
_STATE_CELL = {
    ModuleState.UP_TO_DATE: "ok",
    ModuleState.NEEDS_UPDATE: "STALE",
    ModuleState.MISSING: "MISSING",
    ModuleState.EXTRA: "extra",
    ModuleState.NEEDS_REPAIR: "REPAIR",
}


def compare_to_build(units: list[UnitRecord], build: dict) -> dict:
    """Per-unit x per-module STATUS against the build -- the authoritative view.

    Keyed on the content hash, exactly as the driver decides what to run
    (prov.drift.classify is literally the same function), so the report can never
    disagree with what the next cycle will do. Versions are still carried for
    readability, but they do not decide anything.
    """
    ok_units = [u for u in units if u.status == "ok"]
    reports = {u.host: classify({"modules": u.modules} if u.modules else None, build,
                                {"modules": u.validation} if u.validation else None)
               for u in ok_units}

    modules = [str(m) for m in (build.get("modules") or [])]
    extras = sorted({m.name for r in reports.values() for m in r.modules
                     if m.state is ModuleState.EXTRA})
    all_modules = modules + [m for m in extras if m not in modules]

    matrix = []
    for mod in all_modules:
        cells, differs = {}, {}
        for u in ok_units:
            entry = next((m for m in reports[u.host].modules if m.name == mod), None)
            state = entry.state if entry else None
            cells[u.host] = _STATE_CELL.get(state, "-") if state else "-"
            differs[u.host] = bool(entry and entry.state is not ModuleState.UP_TO_DATE)
        matrix.append({"module": mod, "baseline": "ok", "cells": cells, "differs": differs})

    drift_by_host = {h: r.targets for h, r in reports.items()}
    verdicts = {}
    for u in units:
        if u.status != "ok":
            verdicts[u.host] = u.status.upper()
        else:
            verdicts[u.host] = "IN SYNC" if reports[u.host].current else "DRIFT"

    return {
        "baseline_hash": build.get("payload_hash"),
        "modules": all_modules,
        "matrix": matrix,
        "drift_modules_by_host": drift_by_host,
        "verdicts": verdicts,
        "summaries": {h: r.summary() for h, r in reports.items()},
    }


def compare(units: list[UnitRecord], reference: UnitRecord | None) -> dict:
    """Cross-unit comparison against a modal baseline.

    The fallback for when no build manifest is supplied: units are compared to
    each other on version strings, which answers "are the units consistent?" but
    not "are they current?". Prefer --build-manifest, which routes to
    compare_to_build and keys on the content hash.
    """
    ok_units = [u for u in units if u.status == "ok"]
    ref_mv = reference.module_versions if reference else {}
    all_modules = sorted({m for u in ok_units for m in u.module_versions} | set(ref_mv))

    baseline_hash = _baseline([u.payload_hash for u in ok_units], reference.payload_hash if reference else None)

    matrix: list[dict] = []
    drift_modules_by_host: dict[str, list[str]] = {u.host: [] for u in ok_units}
    for mod in all_modules:
        cells = {u.host: u.module_versions.get(mod) for u in ok_units}
        base = _baseline(list(cells.values()), ref_mv.get(mod) if reference else None)
        differs = {h: (v != base) for h, v in cells.items()}
        for h, d in differs.items():
            if d:
                drift_modules_by_host[h].append(mod)
        matrix.append({"module": mod, "baseline": base, "cells": cells, "differs": differs})

    verdicts: dict[str, str] = {}
    for u in units:
        if u.status != "ok":
            verdicts[u.host] = u.status.upper()
            continue
        hash_ok = (u.payload_hash == baseline_hash)
        mod_drift = bool(drift_modules_by_host.get(u.host))
        verdicts[u.host] = "IN SYNC" if (hash_ok and not mod_drift) else "DRIFT"

    return {
        "baseline_hash": baseline_hash,
        "modules": all_modules,
        "matrix": matrix,
        "drift_modules_by_host": drift_modules_by_host,
        "verdicts": verdicts,
    }


def bootstrap_gaps(units: list[UnitRecord], elements_doc: dict) -> dict:
    """Per-unit bootstrap state vs the current bootstrap version + missing elements."""
    current = elements_doc.get("current_version")
    elements = elements_doc.get("elements", []) if elements_doc else []
    result: dict[str, dict] = {}
    for u in units:
        v = u.bootstrap_version
        if v is None:
            result[u.host] = {"state": "unstamped", "version": None, "missing": []}
        elif current is not None and v < current:
            missing = [e["id"] for e in elements if int(e.get("since", 0)) > v]
            result[u.host] = {"state": "outdated", "version": v, "missing": missing}
        else:
            result[u.host] = {"state": "current", "version": v, "missing": []}
    return {"current": current, "by_host": result}


def _boot_cell(gap: dict) -> str:
    st = gap["state"]
    if st == "unstamped":
        return "none"
    if st == "outdated":
        return f"v{gap['version']}!"
    return f"v{gap['version']}"


def render(units: list[UnitRecord], reference: UnitRecord | None, cmp: dict, boot: dict, repo_boot_v: int | None) -> str:
    lines: list[str] = []
    cols = ([reference] if reference else []) + units
    host_w = max([len(u.host) for u in cols] + [9])

    lines.append("=== Fleet summary ===")
    hdr = (f"{'unit'.ljust(host_w)}  {'status'.ljust(11)}  {'payload'.ljust(12)}  "
           f"{'git'.ljust(12)}  {'boot'.ljust(6)}  installed_at")
    lines.append(hdr)
    lines.append("-" * len(hdr))
    for u in cols:
        if u is reference:
            verdict, boot_cell = "REFERENCE", "-"
        else:
            verdict = cmp["verdicts"].get(u.host, "?")
            boot_cell = _boot_cell(boot["by_host"].get(u.host, {"state": "unstamped", "version": None}))
        detail = f"  {u.error}" if u.error else ""
        lines.append(
            f"{u.host.ljust(host_w)}  {verdict.ljust(11)}  {_short(u.payload_hash).ljust(12)}  "
            f"{_short(u.git_sha).ljust(12)}  {boot_cell.ljust(6)}  {u.installed_at or '-'}{detail}"
        )

    ok_cols = [u for u in cols if u.status == "ok"]
    if cmp["modules"] and ok_cols:
        lines.append("")
        # 'summaries' is only present in the hash-keyed mode, where each cell is
        # a status against the build rather than a version compared to the fleet.
        if "summaries" in cmp:
            lines.append("=== Module status vs build (ok / STALE / MISSING / extra) ===")
        else:
            lines.append("=== Module versions ('*' = differs from baseline) ===")
        mod_w = max([len(m) for m in cmp["modules"]] + [len("module")])
        cell_w = 22
        header = "module".ljust(mod_w) + "  " + "".join(u.host[:cell_w].ljust(cell_w + 1) for u in ok_cols)
        lines.append(header)
        lines.append("-" * len(header))
        by_mod = {row["module"]: row for row in cmp["matrix"]}
        for mod in cmp["modules"]:
            row = by_mod[mod]
            cells_txt = ""
            for u in ok_cols:
                v = row["cells"].get(u.host)
                mark = "*" if row["differs"].get(u.host) else " "
                cells_txt += (f"{(v or '(absent)')[:cell_w]}{mark}").ljust(cell_w + 1)
            lines.append(mod.ljust(mod_w) + "  " + cells_txt)

    if "summaries" in cmp and ok_cols:
        lines.append("")
        lines.append("=== Tier-2 verify (computed live state) ===")
        for u in ok_cols:
            if u.validated_at:
                fails = sorted(m for m, v in u.validation.items() if str(v).lower() == "fail")
                detail = ("fail: " + ", ".join(fails)) if fails else "all pass"
                lines.append(f"  {u.host}: checked {u.validated_at} -- {detail}")
            else:
                # Not a failure: run-verify-only.ps1 is operator-run, so "never"
                # is the normal state on a unit nobody has validated yet.
                lines.append(f"  {u.host}: never run (run-verify-only.ps1 has not written a report)")

    drifted = {h: mods for h, mods in cmp["drift_modules_by_host"].items() if mods}
    if drifted:
        lines.append("")
        lines.append("=== Module drift detail ===")
        for h, mods in drifted.items():
            lines.append(f"  {h}: {', '.join(mods)}")

    # --- Bootstrap ---
    lines.append("")
    cur = boot["current"]
    lines.append(f"=== Bootstrap (current version: {cur if cur is not None else 'unknown'}) ===")
    if repo_boot_v is not None and cur is not None and repo_boot_v != cur:
        lines.append(f"  [WARN] client/bootstrap-winrm.ps1 $script:BootstrapVersion={repo_boot_v} "
                     f"!= bootstrap-elements.json current_version={cur} -- bump them together.")
    for u in units:
        g = boot["by_host"].get(u.host, {"state": "unstamped", "version": None, "missing": []})
        if g["state"] == "unstamped":
            lines.append(f"  {u.host}: UNSTAMPED -- no bootstrap-manifest.json "
                         f"(pre-versioning, or bootstrap not re-run since stamping was added)")
        elif g["state"] == "outdated":
            miss = ", ".join(g["missing"]) if g["missing"] else "(none listed)"
            lines.append(f"  {u.host}: v{g['version']} OUTDATED (current {cur}) -- may need: {miss}")
        else:
            lines.append(f"  {u.host}: v{g['version']} (current)")

    # --- Overall ---
    lines.append("")
    module_problems = [u.host for u in units if cmp["verdicts"].get(u.host) != "IN SYNC"]
    boot_problems = [u.host for u in units if boot["by_host"].get(u.host, {}).get("state") != "current"]
    if module_problems or boot_problems:
        if module_problems:
            lines.append(f"RESULT: payload drift/gaps on {len(module_problems)} unit(s): {', '.join(module_problems)}")
        if boot_problems:
            lines.append(f"RESULT: bootstrap outdated/unstamped on {len(boot_problems)} unit(s): {', '.join(boot_problems)}")
    else:
        lines.append("RESULT: all units in sync and bootstrap current")
    return "\n".join(lines)


def write_csv(path: Path, units: list[UnitRecord], cmp: dict, boot: dict) -> None:
    # Emit the SAME cells the rendered matrix shows. Reading them off
    # module_versions instead was wrong in hash-keyed mode: a module can drift
    # with an unchanged version string (the desktop-shortcuts verify gaining
    # -FastApiUrl is exactly that), so the text report said STALE while the CSV
    # showed a uniform version and no drift at all.
    modules = cmp["modules"]
    cells_by_module = {row["module"]: row["cells"] for row in cmp["matrix"]}
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["host", "status", "verdict", "payload_hash", "git_sha", "installed_at",
                    "bootstrap_version", "bootstrap_state", "bootstrap_missing"] + modules)
        for u in units:
            g = boot["by_host"].get(u.host, {})
            w.writerow(
                [u.host, u.status, cmp["verdicts"].get(u.host, "?"), u.payload_hash or "", u.git_sha or "",
                 u.installed_at or "", u.bootstrap_version if u.bootstrap_version is not None else "",
                 g.get("state", ""), " ".join(g.get("missing", []))]
                + [str(cells_by_module.get(m, {}).get(u.host, "")) for m in modules]
            )


def main() -> int:
    ap = argparse.ArgumentParser(description="Cross-unit MAST version/drift report (read-only).")
    ap.add_argument("--hosts", help="Comma-separated hostnames (default: all in unit-registry.json).")
    ap.add_argument("--registry", default=None, help="Path to unit-registry.json (default: server/unit-registry.json).")
    ap.add_argument("--build-manifest", default=None, help="Compare units against this build-manifest.json (desired state).")
    ap.add_argument("--connect-timeout", type=int, default=15, help="SSH connect timeout seconds (default 15).")
    ap.add_argument("--json", dest="json_out", default=None, help="Write gathered unit records to this JSON file.")
    ap.add_argument("--csv", dest="csv_out", default=None, help="Write the comparison matrix to this CSV file.")
    ap.add_argument("--from-json", default=None, help="Load previously-gathered records from JSON instead of SSH (no network).")
    args = ap.parse_args()

    reference: UnitRecord | None = None
    build_doc: dict | None = None
    if args.build_manifest:
        try:
            build_doc = _load_json(Path(args.build_manifest))
            reference = _manifest_from_obj("BUILD (reference)", build_doc)
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR: could not load --build-manifest: {exc}", file=sys.stderr)
            return 1

    if args.from_json:
        try:
            raw = _load_json(Path(args.from_json))
            units = [UnitRecord(**r) for r in raw]
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR: could not load --from-json: {exc}", file=sys.stderr)
            return 1
    else:
        if args.hosts:
            hosts = [h.strip() for h in args.hosts.split(",") if h.strip()]
        else:
            registry = Path(args.registry) if args.registry else (_REPO_ROOT / "server" / "unit-registry.json")
            try:
                hosts = read_registry_hosts(registry)
            except Exception as exc:  # noqa: BLE001
                print(f"ERROR: could not read hosts: {exc}", file=sys.stderr)
                return 1
        try:
            import vm_lib  # lazy: pywinrm/paramiko only needed for the live gather
            cred = vm_lib.load_creds()["unit"]
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR: could not load unit credentials / vm_lib: {exc}", file=sys.stderr)
            return 1
        print(f"Gathering manifests from {len(hosts)} unit(s) over SSH...", file=sys.stderr)
        units = []
        for h in hosts:
            rec = gather_unit(h, cred, args.connect_timeout)
            print(f"  {h}: {rec.status} (bootstrap v{rec.bootstrap_version})", file=sys.stderr)
            units.append(rec)

    if args.json_out:
        Path(args.json_out).write_text(json.dumps([asdict(u) for u in units], indent=2), encoding="utf-8")

    # A build manifest carrying module_state lets every cell be a hash-keyed
    # STATUS rather than a version string compared to the fleet's modal value --
    # "is this unit current?" instead of "do the units agree?". Without one (or
    # against a pre-module_state build) fall back to the cross-unit comparison.
    if build_doc and build_doc.get("module_state"):
        cmp = compare_to_build(units, build_doc)
    else:
        cmp = compare(units, reference)
    elements_doc = load_bootstrap_elements(_REPO_ROOT)
    boot = bootstrap_gaps(units, elements_doc)

    if args.csv_out:
        write_csv(Path(args.csv_out), units, cmp, boot)

    print(render(units, reference, cmp, boot, repo_bootstrap_version(_REPO_ROOT)))

    if not units:
        return 1
    in_sync = all(cmp["verdicts"].get(u.host) == "IN SYNC" for u in units)
    boot_ok = all(boot["by_host"].get(u.host, {}).get("state") == "current" for u in units)
    return 0 if (in_sync and boot_ok) else 2


if __name__ == "__main__":
    sys.exit(main())
