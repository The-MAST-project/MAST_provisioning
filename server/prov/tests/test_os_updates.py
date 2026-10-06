"""OS patch baseline resolution against saved Microsoft responses (MAST_provisioning#15).

The fixtures are real responses from 2026-09-29, trimmed to what the code parses: the
September 2026 CVRF (four products) and the Update Catalog search and download pages
for its two 19044 KBs, each page cut to its verbatim result rows or file fields with a
provenance header. KB5039211 -- the June 2024 LCU the fleet runs -- is the Catalog's
actual answer for a superseded update.
"""

from __future__ import annotations

import base64
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from prov import os_updates
from prov.os_updates import (
    Baseline,
    CatalogFile,
    CatalogRow,
    MsrcFix,
    MsrcRelease,
    NotInCatalogError,
    OsUpdatesError,
    Resolved,
    UpdateRole,
)

DATA = Path(__file__).parent / "data" / "os_updates"
REPO = Path(__file__).resolve().parents[3]
LCU_ID = "b8966278-25af-4e52-806f-fda166e18fb3"
DOTNET_ID = "0fa60993-a59c-414e-b201-304f63748cc6"
SEP = MsrcRelease("2026-Sep", "2026-09-08T07:00:00Z", "https://api.msrc.microsoft.com/cvrf/v3.0/cvrf/2026-Sep")


def fixture(name: str) -> str:
    return (DATA / name).read_text(encoding="utf-8")


def cvrf() -> dict:
    return json.loads(fixture("cvrf-2026-Sep-trimmed.json"))


def declared_19044() -> os_updates.DeclaredBuild:
    return os_updates.load_os_builds(REPO / os_updates.OS_BUILDS).get(19044)


class FakeHttp:
    """Serves the fixtures; every download returns ``payload`` so its hashes are known."""

    def __init__(self, payload: bytes = b"msu-bytes") -> None:
        self.payload = payload
        self.downloads: list[str] = []

    def get_text(self, url: str, headers: dict[str, str] | None = None) -> str:
        if url == SEP.cvrf_url:
            return fixture("cvrf-2026-Sep-trimmed.json")
        kb = url.rsplit("q=KB", 1)[1]
        return fixture(f"search-KB{kb}.html")

    def post_form(self, url: str, form: dict[str, str]) -> str:
        update_id = json.loads(form["updateIDs"])[0]["updateID"]
        return fixture(f"dialog-{update_id}.html")

    def download(self, url: str, dest: Path) -> None:
        self.downloads.append(url)
        dest.write_bytes(self.payload)


class MatchingDigestHttp(FakeHttp):
    """The real dialogs, with each digest rewritten to the fake payload's SHA1 so a fetch verifies."""

    def post_form(self, url: str, form: dict[str, str]) -> str:
        real = os_updates.parse_download_dialog(super().post_form(url, form))
        digest = base64.b64encode(hashlib.sha1(self.payload).digest()).decode("ascii")
        real_digest = base64.b64encode(bytes.fromhex(real.sha1)).decode("ascii")
        return super().post_form(url, form).replace(real_digest, digest)


def test_declared_config_validates():
    b = declared_19044()
    assert [u.role for u in b.updates] == [UpdateRole.LCU, UpdateRole.DOTNET]


def test_undeclared_build_is_an_error():
    with pytest.raises(OsUpdatesError, match="26100 is not declared"):
        os_updates.load_os_builds(REPO / os_updates.OS_BUILDS).get(26100)


def test_latest_release_is_by_initial_release_date():
    doc = {
        "value": [
            {"ID": "2026-Sep", "InitialReleaseDate": "2026-09-08T07:00:00Z", "CvrfUrl": "sep"},
            {"ID": "2026-Aug", "InitialReleaseDate": "2026-08-11T07:00:00Z", "CvrfUrl": "aug"},
        ]
    }
    assert os_updates.latest_release(doc).release_id == "2026-Sep"
    assert os_updates.release_by_id(doc, "2026-Aug").cvrf_url == "aug"


def test_msrc_fix_for_the_lcu_and_dotnet_lines():
    assert os_updates.fix_for_product(cvrf(), "Windows 10 Version 21H2 for x64-based Systems") == MsrcFix(
        "5122878", "10.0.19044.7725"
    )
    dotnet = os_updates.fix_for_product(
        cvrf(), "Microsoft .NET Framework 3.5 AND 4.8 on Windows 10 Version 21H2 for x64-based Systems"
    )
    assert dotnet.kb == "5126046"


def test_msrc_unknown_product_is_an_error():
    with pytest.raises(OsUpdatesError, match="is not in MSRC release 2026-Sep"):
        os_updates.fix_for_product(cvrf(), "Windows 10 Version 1507 for x64-based Systems")


def test_msrc_two_fixes_for_one_product_is_an_error():
    doc = cvrf()
    rem = next(r for v in doc["Vulnerability"] for r in v["Remediations"] if r["Type"] == 2 and r["ProductID"] == ["11931"])
    doc["Vulnerability"].append({"CVE": "CVE-X", "Remediations": [{**rem, "Description": {"Value": "5999999"}}]})
    with pytest.raises(OsUpdatesError, match="expected one fix"):
        os_updates.fix_for_product(doc, "Windows 10 Version 21H2 for x64-based Systems")


def test_target_ubr_comes_from_fixed_build():
    assert os_updates.target_ubr(MsrcFix("5122878", "10.0.19044.7725"), 19044) == 7725
    with pytest.raises(OsUpdatesError, match="not a 10.0.19044.UBR build"):
        os_updates.target_ubr(MsrcFix("5124008", "10.0.26100.9445"), 19044)


def test_catalog_search_picks_the_one_declared_row():
    b = declared_19044()
    rows = os_updates.parse_catalog_search(fixture("search-KB5122878.html"), "5122878")
    assert len(rows) == 9
    assert os_updates.select_row(rows, "5122878", b.updates[0].catalog_title).update_id == LCU_ID
    rows = os_updates.parse_catalog_search(fixture("search-KB5126046.html"), "5126046")
    assert os_updates.select_row(rows, "5126046", b.updates[1].catalog_title).update_id == DOTNET_ID


def test_catalog_title_match_is_exact():
    rows = [
        CatalogRow("a", "2026-09 Dynamic Cumulative Update for Windows 10 Version 21H2 for x64-based Systems (KB5122878)"),
        CatalogRow("b", "2026-09 Cumulative Update for Windows 10 Version 22H2 for x64-based Systems (KB5122878)"),
    ]
    with pytest.raises(OsUpdatesError, match="found 0 of 2"):
        os_updates.select_row(rows, "5122878", "Cumulative Update for Windows 10 Version 21H2 for x64-based Systems")


def test_superseded_kb_is_not_in_catalog():
    with pytest.raises(NotInCatalogError, match="KB5039211"):
        os_updates.parse_catalog_search(fixture("search-KB5039211.html"), "5039211")


def test_download_dialog_yields_url_and_sha1():
    f = os_updates.parse_download_dialog(fixture(f"dialog-{LCU_ID}.html"))
    assert f.filename == "windows10.0-kb5122878-x64_191c536a44656eb754daa7cb7e9b517b05d690f7.msu"
    assert f.url.endswith("/" + f.filename)
    # The Catalog embeds the SHA1 in the filename too; the two must agree.
    assert f.sha1 == "191c536a44656eb754daa7cb7e9b517b05d690f7"


def test_resolve_against_fixtures():
    got = os_updates.resolve(FakeHttp(), declared_19044(), SEP)
    assert [(r.role, r.fix.kb, r.row.update_id) for r in got] == [
        (UpdateRole.LCU, "5122878", LCU_ID),
        (UpdateRole.DOTNET, "5126046", DOTNET_ID),
    ]


def _resolved(payload: bytes) -> Resolved:
    return Resolved(
        UpdateRole.LCU,
        MsrcFix("5122878", "10.0.19044.7725"),
        CatalogRow(LCU_ID, "t"),
        CatalogFile("https://x/f.msu", "f.msu", hashlib.sha1(payload).hexdigest()),
    )


def test_fetch_lands_the_file_under_its_asset_key_and_is_idempotent(tmp_path: Path):
    http = FakeHttp(b"abc")
    got = os_updates.fetch(http, _resolved(b"abc"), 19044, tmp_path)
    assert got.path == "server/providers/windows-updates/assets/19044/f.msu"
    assert (tmp_path / got.path).read_bytes() == b"abc"
    assert got.sha256 == hashlib.sha256(b"abc").hexdigest()
    assert got.size == 3
    os_updates.fetch(http, _resolved(b"abc"), 19044, tmp_path)
    assert len(http.downloads) == 1


def test_fetch_rejects_a_sha1_mismatch_and_leaves_nothing(tmp_path: Path):
    with pytest.raises(OsUpdatesError, match="does not match the Catalog"):
        os_updates.fetch(FakeHttp(b"tampered"), _resolved(b"abc"), 19044, tmp_path)
    assert not any(p.is_file() for p in tmp_path.rglob("*"))


def test_propose_writes_a_baseline_and_reproposing_is_a_no_op(tmp_path: Path):
    http = MatchingDigestHttp()
    now = datetime(2026, 9, 29, 12, tzinfo=UTC)
    baseline = os_updates.propose(http, declared_19044(), SEP, tmp_path / "cache", now)
    assert baseline.baseline_id == "19044-2026-09"
    assert baseline.target_ubr == 7725
    assert [f.kb for f in baseline.files] == ["5122878", "5126046"]
    dest = os_updates.write_baseline(baseline, tmp_path / "baselines")
    assert dest == tmp_path / "baselines" / "19044" / "19044-2026-09.json"
    assert Baseline.model_validate_json(dest.read_text(encoding="utf-8")) == baseline
    later = baseline.model_copy(update={"proposed_utc": "2026-09-30T00:00:00Z"})
    assert os_updates.write_baseline(later, tmp_path / "baselines") == dest
    assert Baseline.model_validate_json(dest.read_text(encoding="utf-8")).proposed_utc == baseline.proposed_utc


def test_a_rereleased_kb_does_not_overwrite_the_baseline(tmp_path: Path):
    baseline = os_updates.propose(MatchingDigestHttp(), declared_19044(), SEP, tmp_path / "cache", datetime.now(UTC))
    os_updates.write_baseline(baseline, tmp_path / "baselines")
    changed = [baseline.files[0].model_copy(update={"sha256": "0" * 64}), *baseline.files[1:]]
    with pytest.raises(OsUpdatesError, match="already exists with different files"):
        os_updates.write_baseline(baseline.model_copy(update={"files": changed}), tmp_path / "baselines")


def test_snapshot_files_name_each_update_by_its_filename(tmp_path: Path):
    cache = tmp_path / "cache"
    baseline = os_updates.propose(MatchingDigestHttp(), declared_19044(), SEP, cache, datetime.now(UTC))
    files = os_updates.snapshot_files(baseline, cache)
    assert [f.path for f in files] == [f.filename for f in baseline.files]
    assert [f.sha256 for f in files] == [f.sha256 for f in baseline.files]
    assert all(f.source == cache / b.path for f, b in zip(files, baseline.files, strict=True))


def test_snapshot_files_refuse_an_update_missing_from_the_cache(tmp_path: Path):
    cache = tmp_path / "cache"
    baseline = os_updates.propose(MatchingDigestHttp(), declared_19044(), SEP, cache, datetime.now(UTC))
    (cache / baseline.files[0].path).unlink()
    with pytest.raises(OsUpdatesError, match=baseline.files[0].filename):
        os_updates.snapshot_files(baseline, cache)


def test_snapshot_to_an_undeclared_site_is_an_error_line_not_a_traceback(tmp_path: Path, capsys):
    argv = ["--repo", str(tmp_path), "--build", "19044", "snapshot", "--baseline-id", "x", "--cache", str(tmp_path)]
    assert os_updates.main([*argv, "--site", "nowhere"]) == 1
    assert "OS_BASELINE_ERROR" in capsys.readouterr().err
