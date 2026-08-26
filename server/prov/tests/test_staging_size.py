"""Tests for prov.staging_size. The Windows-junction path is verified on the
Windows host; here we cover plain files, nested dirs, symlink-follow, and the
cycle guard (a symlinked dir pointing back into the tree must not double-count
or loop) -- the cross-platform stand-ins for the junction behavior."""

from prov.staging_size import staging_payload_size


def test_counts_flat_and_nested_files(tmp_path):
    (tmp_path / "a.bin").write_bytes(b"x" * 100)
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "b.bin").write_bytes(b"y" * 250)
    (sub / "c.bin").write_bytes(b"z" * 50)
    r = staging_payload_size(tmp_path)
    assert r.files == 3
    assert r.bytes == 400


def test_follows_symlinked_dir_like_a_junction(tmp_path):
    payload = tmp_path / "payload"
    payload.mkdir()
    (payload / "root.bin").write_bytes(b"a" * 10)
    # An out-of-tree dir with content, linked in like the mast-indexes junction.
    ext = tmp_path / "external_indexes"
    ext.mkdir()
    (ext / "index.bin").write_bytes(b"b" * 990)
    (payload / "indexes").symlink_to(ext, target_is_directory=True)
    r = staging_payload_size(payload)
    assert r.files == 2
    assert r.bytes == 1000


def test_cycle_guard_prevents_double_count_and_loop(tmp_path):
    payload = tmp_path / "payload"
    payload.mkdir()
    (payload / "root.bin").write_bytes(b"a" * 42)
    # A self-referential link back to the tree must be visited at most once.
    (payload / "loop").symlink_to(payload, target_is_directory=True)
    r = staging_payload_size(payload)
    assert r.files == 1
    assert r.bytes == 42


def test_missing_path_is_zero(tmp_path):
    r = staging_payload_size(tmp_path / "does-not-exist")
    assert r.files == 0 and r.bytes == 0


def test_transfer_rate_is_mib_per_second():
    from prov.driver import transfer_rate_mbps

    assert transfer_rate_mbps(1_048_576 * 100, 1.0) == 100.0
    assert transfer_rate_mbps(13_855 * 1_048_576, 132.0) == 105.0


def test_transfer_rate_is_zero_when_elapsed_is_unusable():
    from prov.driver import transfer_rate_mbps

    assert transfer_rate_mbps(1_048_576, 0.0) == 0.0
    assert transfer_rate_mbps(1_048_576, -1.0) == 0.0
