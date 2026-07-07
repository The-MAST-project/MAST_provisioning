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

MANIFEST_PATH = r"C:\MAST\installed-manifest.json"
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
    bootstrap_version: int | None = None
    bootstrapped_at: str | None = None
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
    mv = obj.get("module_versions") or {}
    return UnitRecord(
        host=host,
        status="ok",
        payload_hash=obj.get("payload_hash"),
        git_sha=obj.get("git_sha"),
        built_at=obj.get("built_at"),
        installed_at=obj.get("installed_at"),
        module_versions={str(k): str(v) for k, v in mv.items()},
    )


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
            f"{{ Get-Content -LiteralPath '{BOOTSTRAP_PATH}' -Raw }} else {{ '{NO_BOOTSTRAP_SENTINEL}' }}"
        )
        resp = session.run_ps(script)
        out = resp.std_out.decode("utf-8-sig", errors="replace")
        installed_part, _, bootstrap_part = out.partition(SPLIT)
        bootstrap_version, bootstrapped_at = _parse_bootstrap(bootstrap_part)

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
        return rec
    except Exception as exc:  # noqa: BLE001
        return UnitRecord(host=host, status="error", error=str(exc))
    finally:
        session.close()


def load_reference(path: Path) -> UnitRecord:
    return _manifest_from_obj("BUILD (reference)", _load_json(path))


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


def compare(units: list[UnitRecord], reference: UnitRecord | None) -> dict:
    """Build the matrix + per-unit drift verdict against a baseline."""
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
    modules = cmp["modules"]
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
                + [u.module_versions.get(m, "") for m in modules]
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
    if args.build_manifest:
        try:
            reference = load_reference(Path(args.build_manifest))
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
