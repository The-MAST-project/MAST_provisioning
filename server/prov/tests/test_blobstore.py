"""Tests for tools/blobstore.py -- the blobstore on the staging relay (#202).

The properties that matter are the two the design was chosen for: a version is a
self-describing whole, and no version is defined by reference to another. Both
are asserted here rather than argued.
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import sys

import pytest

from prov import transport as T

_spec = importlib.util.spec_from_file_location("blobstore", T.REPO_ROOT / "tools" / "blobstore.py")
assert _spec and _spec.loader
rs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rs)


def manifest_for(files: dict[str, bytes], payload_hash: str | None = None) -> dict:
    # Derived from the content by default, as the build derives it -- including the
    # build's one exclusion: build-manifest.json carries the hash, so it is not in it.
    hashed = sorted((p, b) for p, b in files.items() if p != rs.BUILD_MANIFEST)
    digest = hashlib.sha256(json.dumps(hashed, default=bytes.hex).encode()).hexdigest()
    return {
        "payload_hash": payload_hash or digest,
        "hostname": "unit1",
        "files": [{"path": p, "size": len(b), "sha256": hashlib.sha256(b).hexdigest()} for p, b in sorted(files.items())],
    }


def run(root, argv: list[str], stdin: dict | None = None) -> str:
    out, sys.stdout = sys.stdout, io.StringIO()
    old_in = sys.stdin
    if stdin is not None:
        sys.stdin = io.StringIO(json.dumps(stdin))
    try:
        rc = rs.main(["--root", str(root), *argv])
        assert rc == 0
        return sys.stdout.getvalue()
    finally:
        sys.stdout, sys.stdin = out, old_in


def run_store(root, *argv: str) -> int:
    """Like `run`, but returns the exit code: fsck reports corruption with rc=1."""
    out, sys.stdout = sys.stdout, io.StringIO()
    try:
        return rs.main(["--root", str(root), *argv])
    finally:
        sys.stdout = out


_seeded = 0


def seed_blobs(root, files: dict[str, bytes]):
    # A fresh directory per call, because seed hardlinks these into the store:
    # reusing a path and calling write_bytes would TRUNCATE the shared inode and
    # rewrite the blob under its old name. That is the standing hazard of a
    # hardlinked store and the reason seeded trees are read-only.
    global _seeded
    _seeded += 1
    src = root / f"_src{_seeded}"
    src.mkdir()
    for name, body in files.items():
        (src / name.replace("/", "_")).write_bytes(body)
    run(root, ["seed", str(src)])
    return src


FILES = {"commands.json": b"cmds", "installer.exe": b"x" * 4096, "wheels/a.whl": b"wheel-a"}


def test_want_lists_only_what_the_store_lacks(tmp_path):
    m = manifest_for(FILES)
    assert len(run(tmp_path, ["want"], m).split()) == 3
    seed_blobs(tmp_path, FILES)
    assert run(tmp_path, ["want"], m).strip() == "", "a fully-present payload costs no transfer"


def test_assemble_hardlinks_rather_than_copies(tmp_path):
    seed_blobs(tmp_path, FILES)
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for(FILES))
    built = tmp_path / "hosts" / "mast07" / "01-provisioning"
    assert (built / "commands.json").read_bytes() == b"cmds"
    assert (built / "wheels" / "a.whl").read_bytes() == b"wheel-a"
    blob = rs.blob_path(tmp_path, hashlib.sha256(b"x" * 4096).hexdigest())
    assert (built / "installer.exe").stat().st_ino == blob.stat().st_ino


def test_two_versions_share_bytes_with_no_notion_of_previous(tmp_path):
    """The requirement. Two payloads that differ in one file share the rest, in
    either order, with neither defined by reference to the other."""
    v1 = dict(FILES)
    v2 = {**FILES, "commands.json": b"cmds-changed"}
    seed_blobs(tmp_path, v1)
    seed_blobs(tmp_path, {"commands.json": b"cmds-changed"})
    run(tmp_path, ["assemble", "--host", "unitA"], manifest_for(v1, "hash-A"))
    run(tmp_path, ["assemble", "--host", "unitB"], manifest_for(v2, "hash-B"))

    a = tmp_path / "hosts" / "unitA" / "01-provisioning"
    b = tmp_path / "hosts" / "unitB" / "01-provisioning"
    assert (a / "installer.exe").stat().st_ino == (b / "installer.exe").stat().st_ino, "shared byte shared"
    assert (a / "commands.json").read_bytes() != (b / "commands.json").read_bytes()
    # One copy on disk, named by the store and by both payloads. Counted as
    # "at least", not exactly: the seed source holds a name too, and in
    # production so does whatever tree was adopted.
    blob = rs.blob_path(tmp_path, hashlib.sha256(b"x" * 4096).hexdigest())
    assert (a / "installer.exe").stat().st_ino == blob.stat().st_ino
    assert blob.stat().st_nlink >= 3


def test_a_version_is_self_describing(tmp_path):
    seed_blobs(tmp_path, FILES)
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for(FILES, "hash-A"))
    recorded = json.loads((tmp_path / "hosts" / "mast07" / "payload-manifest.json").read_text())
    assert recorded["payload_hash"] == "hash-A"
    assert {e["path"] for e in recorded["files"]} == set(FILES)


def test_assemble_prunes_what_the_new_manifest_does_not_name(tmp_path):
    # A leftover from an older payload would sit in the tree the unit pulls, so
    # its trim figures and its disk guard would describe something else.
    seed_blobs(tmp_path, FILES)
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for(FILES))
    built = tmp_path / "hosts" / "mast07" / "01-provisioning"
    assert (built / "wheels" / "a.whl").exists()

    smaller = {"commands.json": b"cmds"}
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for(smaller))
    assert not (built / "installer.exe").exists()
    assert not (built / "wheels").exists(), "an emptied directory goes too"


def test_assemble_replaces_a_path_whose_content_changed(tmp_path):
    seed_blobs(tmp_path, {"commands.json": b"old"})
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for({"commands.json": b"old"}))
    seed_blobs(tmp_path, {"commands.json": b"new"})
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for({"commands.json": b"new"}))
    assert (tmp_path / "hosts" / "mast07" / "01-provisioning" / "commands.json").read_bytes() == b"new"


def test_assemble_refuses_rather_than_serving_a_hole(tmp_path):
    # Reaching assembly without the blob means the want/upload step failed
    # silently. Serving a payload with a file missing is the worse outcome.
    with pytest.raises(SystemExit, match="missing"):
        run(tmp_path, ["assemble", "--host", "mast07"], manifest_for(FILES))


def test_gc_is_a_refcount_not_a_policy(tmp_path):
    import shutil

    src = seed_blobs(tmp_path, FILES)
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for(FILES))
    # Drop the seed source so payload trees are the only references left, which
    # is the steady state once a payload has been assembled from the store.
    shutil.rmtree(src)
    # Nothing is unreferenced while a payload names it.
    assert "freed=0" in run(tmp_path, ["gc"])

    smaller = {"commands.json": b"cmds"}
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for(smaller))
    # The host tree moved on, but the first payload's snapshot still names them.
    assert "freed=0" in run(tmp_path, ["gc"])

    shutil.rmtree(snapshot_dir(tmp_path, "provisioning-payload", manifest_for(FILES)["payload_hash"]))
    out = run(tmp_path, ["gc"])
    assert "freed=2" in out, out
    assert "bytes_freed=4103" in out, out


def test_deleting_one_version_leaves_another_intact(tmp_path):
    seed_blobs(tmp_path, FILES)
    run(tmp_path, ["assemble", "--host", "unitA"], manifest_for(FILES))
    run(tmp_path, ["assemble", "--host", "unitB"], manifest_for(FILES))
    import shutil

    shutil.rmtree(tmp_path / "hosts" / "unitA")
    assert "freed=0" in run(tmp_path, ["gc"]), "blobs unitB still names must survive"
    assert (tmp_path / "hosts" / "unitB" / "01-provisioning" / "installer.exe").read_bytes() == b"x" * 4096


def snapshot_dir(root, kind: str, snapshot_id: str):
    return root / kind / snapshot_id


def test_assembling_a_host_also_snapshots_its_payload(tmp_path):
    seed_blobs(tmp_path, FILES)
    m = manifest_for(FILES)
    run(tmp_path, ["assemble", "--host", "mast07"], m)
    snap = snapshot_dir(tmp_path, "provisioning-payload", m["payload_hash"])
    host = tmp_path / "hosts" / "mast07" / "01-provisioning"
    assert (snap / "installer.exe").stat().st_ino == (host / "installer.exe").stat().st_ino
    assert (snap / "wheels" / "a.whl").read_bytes() == b"wheel-a"
    recorded = json.loads((tmp_path / "provisioning-payload" / f"{m['payload_hash']}.json").read_text())
    assert {e["path"] for e in recorded["files"]} == set(FILES)


def test_a_payload_snapshot_outlives_the_host_tree_moving_on(tmp_path):
    seed_blobs(tmp_path, FILES)
    v1 = manifest_for(FILES)
    run(tmp_path, ["assemble", "--host", "mast07"], v1)
    run(tmp_path, ["assemble", "--host", "mast07"], manifest_for({"commands.json": b"cmds"}))
    snap = snapshot_dir(tmp_path, "provisioning-payload", v1["payload_hash"])
    assert (snap / "installer.exe").read_bytes() == b"x" * 4096
    assert not (tmp_path / "hosts" / "mast07" / "01-provisioning" / "installer.exe").exists()


def test_two_units_on_one_payload_share_one_snapshot(tmp_path):
    seed_blobs(tmp_path, FILES)
    m = manifest_for(FILES)
    run(tmp_path, ["assemble", "--host", "unitA"], m)
    run(tmp_path, ["assemble", "--host", "unitB"], m)
    assert [d.name for d in (tmp_path / "provisioning-payload").iterdir() if d.is_dir()] == [m["payload_hash"]]


def test_two_builds_of_one_payload_differ_only_in_build_manifest_and_share_a_snapshot(tmp_path):
    """build-manifest.json records when and for whom a payload was built, so two
    builds of one payload_hash always differ in it. The snapshot is the payload,
    which payload_hash names, so it leaves that file out rather than refusing the
    second build as a changed snapshot."""
    first = {**FILES, "build-manifest.json": b'{"hostname": "mast05"}'}
    second = {**FILES, "build-manifest.json": b'{"hostname": "mast06"}'}
    seed_blobs(tmp_path, first)
    seed_blobs(tmp_path, {"build-manifest.json": second["build-manifest.json"]})
    m1, m2 = manifest_for(first), manifest_for(second)
    assert m1["payload_hash"] == m2["payload_hash"]
    run(tmp_path, ["assemble", "--host", "mast05"], m1)
    run(tmp_path, ["assemble", "--host", "mast06"], m2)

    snap = snapshot_dir(tmp_path, "provisioning-payload", m1["payload_hash"])
    assert not (snap / "build-manifest.json").exists()
    assert (snap / "installer.exe").is_file()
    recorded = json.loads((tmp_path / "provisioning-payload" / f"{m1['payload_hash']}.json").read_text())
    assert "build-manifest.json" not in {e["path"] for e in recorded["files"]}
    host = tmp_path / "hosts" / "mast06" / "01-provisioning" / "build-manifest.json"
    assert host.read_bytes() == second["build-manifest.json"], "the host tree still carries its own"


def test_snapshot_builds_a_named_tree_of_any_kind(tmp_path):
    seed_blobs(tmp_path, FILES)
    run(tmp_path, ["snapshot", "--kind", "windows-os-baseline", "--id", "19044-2026-09"], manifest_for(FILES))
    snap = snapshot_dir(tmp_path, "windows-os-baseline", "19044-2026-09")
    blob = rs.blob_path(tmp_path, hashlib.sha256(b"x" * 4096).hexdigest())
    assert (snap / "installer.exe").stat().st_ino == blob.stat().st_ino
    assert (tmp_path / "windows-os-baseline" / "19044-2026-09.json").is_file()


def test_a_snapshot_keeps_its_blobs_through_gc(tmp_path):
    import shutil

    src = seed_blobs(tmp_path, FILES)
    run(tmp_path, ["snapshot", "--kind", "bootstrap-payload", "--id", "b1"], manifest_for(FILES))
    shutil.rmtree(src)
    assert "freed=0" in run(tmp_path, ["gc"]), "nothing but the snapshot names these, and that is enough"


def test_an_unknown_snapshot_kind_is_refused(tmp_path):
    seed_blobs(tmp_path, FILES)
    with pytest.raises(SystemExit):
        run(tmp_path, ["snapshot", "--kind", "bogus", "--id", "x"], manifest_for(FILES))


def test_resnapshotting_the_same_content_is_a_no_op(tmp_path):
    seed_blobs(tmp_path, FILES)
    m = manifest_for(FILES)
    run(tmp_path, ["snapshot", "--kind", "bootstrap-payload", "--id", "b1"], m)
    out = run(tmp_path, ["snapshot", "--kind", "bootstrap-payload", "--id", "b1"], m)
    assert "existing" in out, out


def test_a_snapshot_is_never_rewritten_under_its_id(tmp_path):
    # An id names one set of bytes for good. A different set under the same id
    # means the source changed after it was published, which is worth stopping on.
    seed_blobs(tmp_path, FILES)
    seed_blobs(tmp_path, {"commands.json": b"cmds-changed"})
    run(tmp_path, ["snapshot", "--kind", "windows-os-baseline", "--id", "b1"], manifest_for(FILES))
    with pytest.raises(SystemExit, match="differs"):
        run(
            tmp_path,
            ["snapshot", "--kind", "windows-os-baseline", "--id", "b1"],
            manifest_for({**FILES, "commands.json": b"cmds-changed"}),
        )


def test_snapshot_refuses_rather_than_recording_a_hole(tmp_path):
    with pytest.raises(SystemExit, match="missing"):
        run(tmp_path, ["snapshot", "--kind", "bootstrap-payload", "--id", "b1"], manifest_for(FILES))
    assert not snapshot_dir(tmp_path, "bootstrap-payload", "b1").exists(), "no half-built snapshot left behind"


def test_seed_is_idempotent(tmp_path):
    src = seed_blobs(tmp_path, FILES)
    out = run(tmp_path, ["seed", str(src)])
    assert "added=0" in out, out


def test_seeding_the_same_bytes_from_two_places_stores_one_copy(tmp_path):
    seed_blobs(tmp_path, {"a.bin": b"same"})
    seed_blobs(tmp_path, {"b.bin": b"same"})
    blobs = [b for shard in (tmp_path / rs.BLOBSTORE_DIR).iterdir() for b in shard.iterdir()]
    assert len(blobs) == 1, blobs


def test_seed_adopts_without_transferring(tmp_path):
    # The relay already holds every blob of every payload it has served, so the
    # first store-backed sync should move nothing.
    seed_blobs(tmp_path, FILES)
    assert run(tmp_path, ["want"], manifest_for(FILES)).strip() == ""


def test_the_store_is_sharded_so_one_directory_does_not_hold_everything(tmp_path):
    seed_blobs(tmp_path, FILES)
    shards = [d.name for d in (tmp_path / rs.BLOBSTORE_DIR).iterdir() if d.is_dir()]
    assert all(len(s) == 2 for s in shards), shards
    for entry in manifest_for(FILES)["files"]:
        assert rs.blob_path(tmp_path, entry["sha256"]).exists()


def test_a_manifest_without_files_is_refused(tmp_path):
    with pytest.raises(SystemExit, match="files"):
        run(tmp_path, ["want"], {"payload_hash": "h"})


@pytest.mark.skipif(os.name == "nt", reason="POSIX relay")
def test_blob_name_is_its_own_checksum(tmp_path):
    # Which is what makes the store self-verifying and #194's separate
    # MANIFEST.sha256 unnecessary.
    seed_blobs(tmp_path, FILES)
    for shard in (tmp_path / rs.BLOBSTORE_DIR).iterdir():
        for blob in shard.iterdir():
            assert rs.sha256_of(blob) == blob.name


def test_fsck_passes_a_sound_store(tmp_path):
    """The store's filename is its checksum, which makes the claim checkable.

    Nothing checked it until now, so "content-addressed" was an assumption rather
    than a property -- and every other guard in this system compares something
    against this store (#194, #189). If a blob rots they all agree with the rot.
    """
    root = tmp_path / "relay"
    (root / rs.BLOBSTORE_DIR).mkdir(parents=True)
    body = b"an installer, notionally"
    digest = hashlib.sha256(body).hexdigest()
    shard = root / rs.BLOBSTORE_DIR / digest[:2]
    shard.mkdir()
    (shard / digest).write_bytes(body)

    rc = run_store(root, "fsck")
    assert rc == 0


def test_fsck_catches_a_rotted_blob(tmp_path):
    root = tmp_path / "relay"
    (root / rs.BLOBSTORE_DIR).mkdir(parents=True)
    body = b"an installer, notionally"
    digest = hashlib.sha256(body).hexdigest()
    shard = root / rs.BLOBSTORE_DIR / digest[:2]
    shard.mkdir()
    blob = shard / digest
    blob.write_bytes(body)
    # One byte flips; the name still claims the original content.
    blob.write_bytes(b"an installer, notionallY")

    rc = run_store(root, "fsck")
    assert rc == 1


def test_fsck_leaves_the_corrupt_blob_in_place(tmp_path):
    """Deleting it would take out every hardlink into it, across every host tree.

    A bad byte is more recoverable than a missing file, so this reports and does
    not repair.
    """
    root = tmp_path / "relay"
    (root / rs.BLOBSTORE_DIR).mkdir(parents=True)
    digest = hashlib.sha256(b"original").hexdigest()
    shard = root / rs.BLOBSTORE_DIR / digest[:2]
    shard.mkdir()
    blob = shard / digest
    blob.write_bytes(b"corrupted")

    run_store(root, "fsck")
    assert blob.is_file()


def test_seed_reports_failure_when_it_cannot_adopt(tmp_path, monkeypatch):
    """It returned 0 having adopted nothing, until 2026-09-27.

    Seeding from /tmp into a store on /Storage fails every link -- hardlinks
    cannot cross filesystems, which is a documented constraint of this store --
    and `seed` printed the errors, summarised `added=0`, and exited 0. A caller
    that seeds before dropping its own copy would have dropped the last one.
    """
    root = tmp_path / "relay"
    (root / rs.BLOBSTORE_DIR).mkdir(parents=True)
    src = tmp_path / "incoming"
    src.mkdir()
    (src / "asset.bin").write_bytes(b"bytes that cannot be linked")

    def refuse(*_a, **_k):
        raise OSError(18, "Invalid cross-device link")

    monkeypatch.setattr(rs.os, "link", refuse)
    assert run_store(root, "seed", str(src)) == 1


def test_seed_succeeds_when_it_adopts(tmp_path):
    root = tmp_path / "relay"
    (root / rs.BLOBSTORE_DIR).mkdir(parents=True)
    src = tmp_path / "incoming"
    src.mkdir()
    (src / "asset.bin").write_bytes(b"adoptable bytes")
    assert run_store(root, "seed", str(src)) == 0
