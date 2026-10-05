"""Resolve, fetch and propose an OS patch baseline (MAST_provisioning#15, stage 1).

A baseline is a named patch level for one Windows build: the exact update files
that define it and the UBR its cumulative update produces. This module builds one
from Microsoft's own sources and touches no unit:

- **What is current** comes from the MSRC CVRF feed, which lists each month's
  remediation KB per product and the build it fixes to (``FixedBuild``), so the
  target UBR is read off the feed rather than out of the MSU.
- **Where the bytes are** comes from the Update Catalog, which has no API: the
  search page is matched against the declared row title, and the download dialog
  yields the file URL and its SHA1.

The Catalog drops superseded updates (the fleet's June 2024 LCU, KB5039211, no
longer resolves), so a baseline cannot be re-downloaded later. Fetching therefore
lands each file in the machine-wide asset cache under the path it will be keyed
by, and the baseline records the sha256 that path must hash to.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Protocol

from pydantic import BaseModel, ConfigDict, Field

from prov import relay, transport

MSRC_API = "https://api.msrc.microsoft.com/cvrf/v3.0"
CATALOG = "https://www.catalog.update.microsoft.com"
OS_BUILDS = Path("server/data/os-builds.json")
BASELINES_DIR = Path("server/data/os-baselines")
#: Repo-relative key prefix of a fetched update, per #48's one asset rule.
ASSET_PREFIX = "server/providers/windows-updates/assets"

HTTP_TIMEOUT_S = 60
READ_CHUNK = 1024 * 1024
#: CVRF remediation type 2 is "Vendor Fix"; the others are workarounds, mitigations and release notes.
VENDOR_FIX = 2

_NO_RESULTS = re.compile(r'id="ctl00_catalogBody_noResultText"')
_ROW = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_link'[^>]*>\s*([^<]*?)\s*</a>")
_DIALOG_FIELD = re.compile(r"\.(url|digest|fileName) = '([^']+)'")
_FIXED_BUILD = re.compile(r"^10\.0\.(\d+)\.(\d+)$")


class OsUpdatesError(Exception):
    """A baseline cannot be resolved or fetched as declared."""


class NotInCatalogError(OsUpdatesError):
    """The Catalog no longer serves this KB; its bytes can only come from our own store."""


class UpdateRole(StrEnum):
    LCU = "lcu"
    DOTNET = "dotnet"


_CLOSED = ConfigDict(extra="forbid")


class DeclaredUpdate(BaseModel):
    model_config = _CLOSED
    role: UpdateRole
    msrc_product: str
    catalog_title: str


class DeclaredBuild(BaseModel):
    model_config = _CLOSED
    build: int
    edition: str
    updates: list[DeclaredUpdate]


class OsBuilds(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    comment: list[str] = Field(default_factory=list, alias="_comment")
    builds: list[DeclaredBuild]

    def get(self, build: int) -> DeclaredBuild:
        for b in self.builds:
            if b.build == build:
                return b
        raise OsUpdatesError(f"build {build} is not declared in {OS_BUILDS}")


class BaselineFile(BaseModel):
    model_config = _CLOSED
    role: UpdateRole
    kb: str
    fixed_build: str
    catalog_update_id: str
    url: str
    filename: str
    path: str
    sha1: str
    sha256: str
    size: int


class Baseline(BaseModel):
    model_config = _CLOSED
    baseline_id: str
    build: int
    target_ubr: int
    msrc_release: str
    msrc_release_date: str
    proposed_utc: str
    files: list[BaselineFile]


def load_os_builds(path: Path) -> OsBuilds:
    return OsBuilds.model_validate(transport.load_json_object(path))


class Http(Protocol):
    def get_text(self, url: str, headers: dict[str, str] | None = None) -> str: ...

    def post_form(self, url: str, form: dict[str, str]) -> str: ...

    def download(self, url: str, dest: Path) -> None: ...


class UrllibHttp:
    """Stdlib HTTP; urllib honors HTTPS_PROXY / the system proxy, which is how labcomp2 reaches out."""

    def _open(self, req: urllib.request.Request):
        return urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S)

    def get_text(self, url: str, headers: dict[str, str] | None = None) -> str:
        with self._open(urllib.request.Request(url, headers=headers or {})) as r:
            return r.read().decode("utf-8")

    def post_form(self, url: str, form: dict[str, str]) -> str:
        body = urllib.parse.urlencode(form).encode("ascii")
        with self._open(urllib.request.Request(url, data=body)) as r:
            return r.read().decode("utf-8")

    def download(self, url: str, dest: Path) -> None:
        with self._open(urllib.request.Request(url)) as r, dest.open("wb") as fh:
            for chunk in iter(lambda: r.read(READ_CHUNK), b""):
                fh.write(chunk)


@dataclass(frozen=True)
class MsrcRelease:
    release_id: str
    initial_release_date: str
    cvrf_url: str


@dataclass(frozen=True)
class MsrcFix:
    kb: str
    fixed_build: str


@dataclass(frozen=True)
class CatalogRow:
    update_id: str
    title: str


@dataclass(frozen=True)
class CatalogFile:
    url: str
    filename: str
    sha1: str


def latest_release(updates_doc: dict) -> MsrcRelease:
    releases = updates_doc.get("value") or []
    if not releases:
        raise OsUpdatesError("MSRC lists no releases")
    r = max(releases, key=lambda x: x["InitialReleaseDate"])
    return MsrcRelease(r["ID"], r["InitialReleaseDate"], r["CvrfUrl"])


def release_by_id(updates_doc: dict, release_id: str) -> MsrcRelease:
    for r in updates_doc.get("value") or []:
        if r["ID"] == release_id:
            return MsrcRelease(r["ID"], r["InitialReleaseDate"], r["CvrfUrl"])
    raise OsUpdatesError(f"MSRC has no release {release_id!r}")


def fix_for_product(cvrf: dict, product: str) -> MsrcFix:
    """The one vendor-fix KB this release carries for ``product``; anything else is an error."""
    ids = {p["ProductID"] for p in cvrf["ProductTree"]["FullProductName"] if p["Value"] == product}
    if not ids:
        raise OsUpdatesError(
            f"product {product!r} is not in MSRC release {cvrf['DocumentTracking']['Identification']['ID']['Value']}"
        )
    fixes: set[MsrcFix] = set()
    for vuln in cvrf.get("Vulnerability") or []:
        for rem in vuln.get("Remediations") or []:
            if rem.get("Type") != VENDOR_FIX or not ids & set(rem.get("ProductID") or []):
                continue
            kb = (rem.get("Description") or {}).get("Value", "")
            if kb.isdigit():
                fixes.add(MsrcFix(kb, rem.get("FixedBuild") or ""))
    if len(fixes) != 1:
        raise OsUpdatesError(f"expected one fix for {product!r}, found {sorted(f.kb for f in fixes) or 'none'}")
    return fixes.pop()


def target_ubr(fix: MsrcFix, build: int) -> int:
    m = _FIXED_BUILD.match(fix.fixed_build)
    if not m or int(m.group(1)) != build:
        raise OsUpdatesError(f"KB{fix.kb} fixes to {fix.fixed_build!r}, not a 10.0.{build}.UBR build")
    return int(m.group(2))


def parse_catalog_search(html: str, kb: str) -> list[CatalogRow]:
    if _NO_RESULTS.search(html):
        raise NotInCatalogError(f"the Update Catalog no longer serves KB{kb}")
    return [CatalogRow(m.group(1), m.group(2)) for m in _ROW.finditer(html)]


def select_row(rows: list[CatalogRow], kb: str, catalog_title: str) -> CatalogRow:
    wanted = re.compile(rf"^\d{{4}}-\d{{2}} {re.escape(catalog_title)} \(KB{kb}\)$")
    hits = [r for r in rows if wanted.match(r.title)]
    if len(hits) != 1:
        raise OsUpdatesError(f"expected one Catalog row '{catalog_title} (KB{kb})', found {len(hits)} of {len(rows)}")
    return hits[0]


def parse_download_dialog(html: str) -> CatalogFile:
    fields: dict[str, list[str]] = {}
    for m in _DIALOG_FIELD.finditer(html):
        fields.setdefault(m.group(1), []).append(m.group(2))
    if any(len(fields.get(k, [])) != 1 for k in ("url", "digest", "fileName")):
        raise OsUpdatesError(f"expected one file in the download dialog, found {fields}")
    sha1 = base64.b64decode(fields["digest"][0]).hex()
    return CatalogFile(fields["url"][0], fields["fileName"][0], sha1)


def _download_dialog_form(update_id: str) -> dict[str, str]:
    return {"updateIDs": json.dumps([{"size": 0, "languages": "", "uidInfo": update_id, "updateID": update_id}])}


@dataclass(frozen=True)
class Resolved:
    role: UpdateRole
    fix: MsrcFix
    row: CatalogRow
    file: CatalogFile


def resolve(http: Http, declared: DeclaredBuild, release: MsrcRelease) -> list[Resolved]:
    cvrf = json.loads(http.get_text(release.cvrf_url, {"Accept": "application/json"}))
    out = []
    for upd in declared.updates:
        fix = fix_for_product(cvrf, upd.msrc_product)
        search = http.get_text(f"{CATALOG}/Search.aspx?q=KB{fix.kb}")
        row = select_row(parse_catalog_search(search, fix.kb), fix.kb, upd.catalog_title)
        dialog = http.post_form(f"{CATALOG}/DownloadDialog.aspx", _download_dialog_form(row.update_id))
        out.append(Resolved(upd.role, fix, row, parse_download_dialog(dialog)))
    return out


def _hash(path: Path) -> tuple[str, str]:
    sha1, sha256 = hashlib.sha1(), hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(READ_CHUNK), b""):
            sha1.update(chunk)
            sha256.update(chunk)
    return sha1.hexdigest(), sha256.hexdigest()


def fetch(http: Http, r: Resolved, build: int, cache: Path) -> BaselineFile:
    """Land one file in the cache, verified against the Catalog's SHA1. Idempotent."""
    key = f"{ASSET_PREFIX}/{build}/{r.file.filename}"
    dest = cache / key
    if not (dest.is_file() and _hash(dest)[0] == r.file.sha1):
        dest.parent.mkdir(parents=True, exist_ok=True)
        part = dest.with_name(dest.name + ".part")
        http.download(r.file.url, part)
        got_sha1, _ = _hash(part)
        if got_sha1 != r.file.sha1:
            part.unlink()
            raise OsUpdatesError(f"{r.file.filename}: SHA1 {got_sha1} does not match the Catalog's {r.file.sha1}")
        os.replace(part, dest)
    _, sha256 = _hash(dest)
    return BaselineFile(
        role=r.role,
        kb=r.fix.kb,
        fixed_build=r.fix.fixed_build,
        catalog_update_id=r.row.update_id,
        url=r.file.url,
        filename=r.file.filename,
        path=key,
        sha1=r.file.sha1,
        sha256=sha256,
        size=dest.stat().st_size,
    )


def baseline_id(build: int, release: MsrcRelease) -> str:
    return f"{build}-{release.initial_release_date[:7]}"


def propose(http: Http, declared: DeclaredBuild, release: MsrcRelease, cache: Path, now: datetime) -> Baseline:
    resolved = resolve(http, declared, release)
    lcu = [r for r in resolved if r.role is UpdateRole.LCU]
    if len(lcu) != 1:
        raise OsUpdatesError(f"build {declared.build} must declare exactly one {UpdateRole.LCU} update")
    return Baseline(
        baseline_id=baseline_id(declared.build, release),
        build=declared.build,
        target_ubr=target_ubr(lcu[0].fix, declared.build),
        msrc_release=release.release_id,
        msrc_release_date=release.initial_release_date,
        proposed_utc=now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        files=[fetch(http, r, declared.build, cache) for r in resolved],
    )


def write_baseline(baseline: Baseline, out_dir: Path) -> Path:
    """Write the proposal; an existing baseline with different files is an error, never overwritten."""
    dest = out_dir / str(baseline.build) / f"{baseline.baseline_id}.json"
    if dest.exists():
        existing = Baseline.model_validate(transport.load_json_object(dest))
        if existing.files == baseline.files:
            return dest
        raise OsUpdatesError(f"{dest} already exists with different files; Microsoft re-released a KB")
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    tmp.write_text(json.dumps(baseline.model_dump(mode="json"), indent=2) + "\n", encoding="utf-8", newline="\n")
    os.replace(tmp, dest)
    return dest


def load_baseline(repo: Path, build: int, baseline_id: str) -> Baseline:
    return Baseline.model_validate(transport.load_json_object(repo / BASELINES_DIR / str(build) / f"{baseline_id}.json"))


def snapshot_files(baseline: Baseline, cache: Path) -> list[relay.SnapshotFile]:
    """The baseline's files, each named by its own filename in the snapshot."""
    files = []
    for f in baseline.files:
        source = cache / f.path
        if not source.is_file():
            raise OsUpdatesError(f"{f.filename} is not in the asset cache at {source}; propose fetches it")
        files.append(relay.SnapshotFile(f.filename, f.sha256, f.size, source))
    return files


def _release(http: Http, release_id: str | None) -> MsrcRelease:
    updates = json.loads(http.get_text(f"{MSRC_API}/updates", {"Accept": "application/json"}))
    return release_by_id(updates, release_id) if release_id else latest_release(updates)


def _cache_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--cache", type=Path, required=True, help="the machine-wide asset cache, e.g. C:\\MAST\\provider-assets"
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Resolve and propose an OS patch baseline (MAST_provisioning#15).")
    p.add_argument("--repo", type=Path, default=Path("."))
    p.add_argument("--build", type=int, required=True)
    p.add_argument("--release", help="MSRC release id, e.g. 2026-Sep; default the latest")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("resolve", help="print what the baseline would contain; downloads nothing")
    prop = sub.add_parser("propose", help="fetch into the asset cache and write the baseline manifest")
    _cache_arg(prop)
    snap = sub.add_parser("snapshot", help="keep a committed baseline's files on the relay")
    snap.add_argument("--baseline-id", required=True, help="e.g. 19044-2026-09")
    _cache_arg(snap)
    snap.add_argument("--site", default="ns", help="the staging host to keep it on (server/data/staging-hosts.json)")
    args = p.parse_args(argv)

    if args.cmd == "snapshot":
        return _snapshot(args)

    http = UrllibHttp()
    try:
        declared = load_os_builds(args.repo / OS_BUILDS).get(args.build)
        release = _release(http, args.release)
        if args.cmd == "resolve":
            for r in resolve(http, declared, release):
                print(f"{r.role:<7} KB{r.fix.kb} fixed_build={r.fix.fixed_build} {r.row.title}\n        {r.file.url}")
            return 0
        baseline = propose(http, declared, release, args.cache, datetime.now(UTC))
        dest = write_baseline(baseline, args.repo / BASELINES_DIR)
    except OsUpdatesError as exc:
        print(f"OS_BASELINE_ERROR {exc}", file=sys.stderr)
        return 1
    print(
        f"OS_BASELINE_PROPOSED id={baseline.baseline_id} target_ubr={baseline.target_ubr}"
        f" files={len(baseline.files)} -> {dest}"
    )
    return 0


def _snapshot(args: argparse.Namespace) -> int:
    try:
        site = relay.staging_host(args.repo / relay.STAGING_HOSTS, args.site)
        baseline = load_baseline(args.repo, args.build, args.baseline_id)
        files = snapshot_files(baseline, args.cache)
    except (OsUpdatesError, relay.UnknownSiteError) as exc:
        print(f"OS_BASELINE_ERROR {exc}", file=sys.stderr)
        return 1
    result = relay.sync_snapshot(
        kind=relay.SnapshotKind.WINDOWS_OS_BASELINE, snapshot_id=baseline.baseline_id, files=files, relay=site
    )
    if not result.ok:
        failure = f"OS_BASELINE_SNAPSHOT_FAILED id={baseline.baseline_id} rc={result.returncode} {result.detail}"
        print(failure, file=sys.stderr)
        return 1
    print(f"OS_BASELINE_SNAPSHOT_OK id={baseline.baseline_id} {result.detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
