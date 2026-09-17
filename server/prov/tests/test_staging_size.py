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


def test_a_healthy_trimmed_pull_is_not_slow():
    """The regression #195 introduced: the floor was calibrated on the full payload.

    Per-module trimming took the normal pull from 14.9 GB to one or two orders of
    magnitude less, at which point the transfer is dominated by session setup and
    per-file overhead rather than by bandwidth. Judged on rate alone every healthy
    run trips the alarm -- it fired on all six units on 2026-09-15 -- and an alarm
    that always fires reports nothing.
    """
    from prov.driver import transfer_is_slow

    # mast03 and mast07, 2026-09-15: desktop-appearance only.
    assert transfer_is_slow(1_028_708, 1.8) is False
    # mast03, 2026-09-15: five modules.
    assert transfer_is_slow(20_007_014, 2.9) is False


def test_a_healthy_full_payload_is_not_slow():
    from prov.driver import transfer_is_slow

    # mast07, 2026-09-15: the whole payload at line rate.
    assert transfer_is_slow(14_877_440_807, 139.2) is False


def test_the_routed_path_collapse_is_still_caught():
    """What the signal exists for, and must keep catching.

    2026-09-02: labcomp2 on VLAN 2 with the units on VLAN 1 put every payload byte
    through the gateway. Four of six units fell to 0.14-0.25 MB/s and burned the
    full 3600 s watchdog. There is no error for this -- the transfer simply crawls.
    """
    from prov.driver import transfer_is_slow

    assert transfer_is_slow(14_877_440_807, 3600.0) is True
    # And the merely-degraded case: the full payload at a fifth of line rate.
    assert transfer_is_slow(14_877_440_807, 744.0) is True


def test_a_short_transfer_is_never_slow_however_low_the_rate():
    """Duration is the symptom, not rate.

    The failure being detected is a transfer that runs long enough to threaten the
    watchdog. A pull that finished in two seconds did not, whatever its MB/s reads.
    """
    from prov.driver import transfer_is_slow

    assert transfer_is_slow(1_000, 0.5) is False
    assert transfer_is_slow(0, 0.0) is False


def test_excludes_a_root_file_and_a_root_dir(tmp_path):
    (tmp_path / "keep.bin").write_bytes(b"k" * 10)
    (tmp_path / "drop.bin").write_bytes(b"d" * 5000)
    big = tmp_path / "wheels"
    big.mkdir()
    (big / "w1.whl").write_bytes(b"w" * 3000)
    r = staging_payload_size(tmp_path, exclude_files=("drop.bin",), exclude_dirs=("wheels",))
    assert r.files == 1
    assert r.bytes == 10


def test_exclusion_matches_only_at_the_staging_root(tmp_path):
    # The names become robocopy exclusions built from the staging root, which
    # match there and nowhere else. A same-named file deeper in the tree belongs
    # to a module that IS targeted and must still be counted.
    (tmp_path / "requirements.txt").write_bytes(b"r" * 100)
    sub = tmp_path / "cygwin-pkg-cache"
    sub.mkdir()
    (sub / "requirements.txt").write_bytes(b"r" * 40)
    r = staging_payload_size(tmp_path, exclude_files=("requirements.txt",))
    assert r.files == 1
    assert r.bytes == 40


def test_excluding_a_linked_dir_drops_what_it_points_at(tmp_path):
    # The mast-indexes case: the staged entry is a junction, and the bytes that
    # would not be transferred are the target's, not the link's.
    payload = tmp_path / "payload"
    payload.mkdir()
    (payload / "root.bin").write_bytes(b"a" * 10)
    ext = tmp_path / "external_indexes"
    ext.mkdir()
    (ext / "index.bin").write_bytes(b"b" * 990)
    (payload / "mast-indexes").symlink_to(ext, target_is_directory=True)
    assert staging_payload_size(payload).bytes == 1000
    r = staging_payload_size(payload, exclude_dirs=("mast-indexes",))
    assert r.files == 1
    assert r.bytes == 10


def test_no_exclusions_is_the_previous_behavior(tmp_path):
    (tmp_path / "a.bin").write_bytes(b"x" * 7)
    assert staging_payload_size(tmp_path) == staging_payload_size(tmp_path, exclude_files=(), exclude_dirs=())
