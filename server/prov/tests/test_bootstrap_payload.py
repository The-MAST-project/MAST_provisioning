"""Tests for prov.bootstrap_payload -- what a bare unit's bootstrap medium carries.

The bootstrap payload used to be defined three times: a README step naming three files, the ISO
builder staging seven, and whatever an operator copied. These pin it to one list.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from prov import bootstrap_payload as B
from prov import transport as T

REPO = T.REPO_ROOT


def make_repo(tmp_path: Path, files: dict[str, bytes], assets: dict[str, bytes] | None = None) -> Path:
    repo = tmp_path / "repo"
    for rel, body in files.items():
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_bytes(body)
    (repo / "client").mkdir(parents=True, exist_ok=True)
    (repo / B.BOOTSTRAP_PAYLOAD).write_text(json.dumps({"files": [*files, *(assets or {})]}), encoding="utf-8")
    rows = [{"path": p, "sha256": hashlib.sha256(b).hexdigest(), "size": len(b)} for p, b in (assets or {}).items()]
    (repo / B.ASSETS).parent.mkdir(parents=True, exist_ok=True)
    (repo / B.ASSETS).write_text(json.dumps({"files": rows}), encoding="utf-8")
    return repo


def test_the_shipped_payload_names_only_files_the_repo_or_the_asset_index_holds():
    assets = {r["path"] for r in json.loads((REPO / B.ASSETS).read_text(encoding="utf-8"))["files"]}
    for rel in B.load_declared(REPO):
        assert (REPO / rel).is_file() or rel in assets, rel


def test_the_iso_builder_stages_every_file_of_the_payload():
    """Until the ISO builder reads the list itself, this is what keeps them equal."""
    iso = (REPO / "vm" / "build-autounattend-iso.ps1").read_text(encoding="utf-8")
    for rel in B.load_declared(REPO):
        assert Path(rel).name in iso or Path(rel).name.startswith("npcap-"), rel


def test_the_payload_is_flat_and_named_by_leaf(tmp_path):
    repo = make_repo(tmp_path, {"client/bootstrap.ps1": b"ps", "server/lib/mast-firmware.ps1": b"fw"})
    files = B.payload_files(repo, tmp_path / "cache")
    assert [f.path for f in files] == ["bootstrap.ps1", "mast-firmware.ps1"]
    assert files[0].sha256 == hashlib.sha256(b"ps").hexdigest()


def test_an_asset_resolves_from_the_cache_when_the_repo_lacks_it(tmp_path):
    repo = make_repo(tmp_path, {"client/bootstrap.ps1": b"ps"}, {"client/assets/npcap-1.88.exe": b"npcap"})
    cache = tmp_path / "cache"
    (cache / "client" / "assets").mkdir(parents=True)
    (cache / "client" / "assets" / "npcap-1.88.exe").write_bytes(b"npcap")
    files = B.payload_files(repo, cache)
    assert files[-1].source == cache / "client" / "assets" / "npcap-1.88.exe"


def test_an_asset_that_is_not_its_indexed_bytes_is_refused(tmp_path):
    repo = make_repo(tmp_path, {}, {"client/assets/npcap-1.88.exe": b"npcap"})
    cache = tmp_path / "cache"
    (cache / "client" / "assets").mkdir(parents=True)
    (cache / "client" / "assets" / "npcap-1.88.exe").write_bytes(b"stale")
    with pytest.raises(B.BootstrapPayloadError, match="npcap-1.88.exe"):
        B.payload_files(repo, cache)


def test_a_missing_file_is_refused(tmp_path):
    repo = make_repo(tmp_path, {}, {"client/assets/npcap-1.88.exe": b"npcap"})
    with pytest.raises(B.BootstrapPayloadError, match="npcap-1.88.exe"):
        B.payload_files(repo, tmp_path / "cache")


def test_two_files_with_one_leaf_name_are_refused(tmp_path):
    repo = make_repo(tmp_path, {"client/x.ps1": b"a", "server/lib/x.ps1": b"b"})
    with pytest.raises(B.BootstrapPayloadError, match="x.ps1"):
        B.payload_files(repo, tmp_path / "cache")


def test_the_payload_hash_follows_content_not_order(tmp_path):
    repo = make_repo(tmp_path, {"client/a.ps1": b"a", "client/b.ps1": b"b"})
    files = B.payload_files(repo, tmp_path / "cache")
    assert B.payload_hash(files) == B.payload_hash(list(reversed(files)))
    (repo / "client" / "b.ps1").write_bytes(b"changed")
    assert B.payload_hash(B.payload_files(repo, tmp_path / "cache")) != B.payload_hash(files)


def test_stage_copies_the_payload_flat(tmp_path):
    repo = make_repo(tmp_path, {"client/bootstrap.ps1": b"ps", "server/lib/mast-firmware.ps1": b"fw"})
    out = tmp_path / "usb"
    B.stage(B.payload_files(repo, tmp_path / "cache"), out)
    assert sorted(p.name for p in out.iterdir()) == ["bootstrap.ps1", "mast-firmware.ps1"]
    assert (out / "mast-firmware.ps1").read_bytes() == b"fw"


def test_snapshot_to_an_undeclared_site_is_an_error_line_not_a_traceback(tmp_path, capsys):
    repo = make_repo(tmp_path, {"client/bootstrap.ps1": b"ps"})
    rc = B.main(["--repo", str(repo), "--cache", str(tmp_path), "snapshot", "--site", "nowhere"])
    assert rc == 1
    assert "BOOTSTRAP_PAYLOAD_ERROR" in capsys.readouterr().err
