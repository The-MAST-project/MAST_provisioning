"""Tests for per-module drift classification (issue #22 stage 3)."""

from __future__ import annotations

from prov.drift import ModuleState, classify


def build_manifest(**hashes: str) -> dict:
    return {
        "payload_hash": "aggregate",
        "modules": list(hashes),
        "module_state": {n: {"version": "1.0", "hash": h} for n, h in hashes.items()},
    }


def installed_manifest(**entries: dict) -> dict:
    return {"installed_at": "2026-08-02T10:00:00Z", "modules": dict(entries)}


def entry(hash_: str, provide: str = "pass", verify: str = "pass", version: str = "1.0") -> dict:
    return {"version": version, "hash": hash_, "provide": provide, "verify": verify, "installed_at": "2026-08-02T09:00:00Z"}


def test_matching_hashes_are_up_to_date():
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h1"))
    assert r.current
    assert r.targets == []
    assert r.by_state(ModuleState.UP_TO_DATE) == ["git"]


def test_changed_hash_needs_update():
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h2"))
    assert r.targets == ["git"]


def test_only_the_drifted_module_is_targeted():
    """The point of the epic: one changed module must not trigger a full cycle."""
    r = classify(
        installed_manifest(git=entry("h1"), python=entry("p1"), ascom=entry("a1")),
        build_manifest(git="h1", python="p2", ascom="a1"),
    )
    assert r.targets == ["python"]


def test_targets_follow_build_order_not_alphabetical():
    """execute runs commands.json in order; the target list must not reshuffle it."""
    build = {
        "modules": ["proxy", "python", "ascom"],
        "module_state": {n: {"version": "1", "hash": "new"} for n in ("proxy", "python", "ascom")},
    }
    r = classify(installed_manifest(), build)
    assert r.targets == ["proxy", "python", "ascom"]


def test_module_absent_from_installed_is_missing():
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h1", python="p1"))
    assert r.by_state(ModuleState.MISSING) == ["python"]
    assert r.targets == ["python"]


def test_never_provisioned_unit_targets_everything():
    r = classify(None, build_manifest(git="h1", python="p1"))
    assert r.targets == ["git", "python"]


def test_legacy_manifest_without_modules_map_targets_everything():
    """mast01-04 carry a pre-module_state whole-document copy: state unknown."""
    legacy = {"payload_hash": "old", "git_sha": "abc", "installed_at": "2026-06-01T00:00:00Z"}
    r = classify(legacy, build_manifest(git="h1", python="p1"))
    assert r.targets == ["git", "python"]
    assert all(m.state is ModuleState.MISSING for m in r.modules)


def test_legacy_manifest_with_a_modules_list_targets_everything():
    """The shape mast01-04 actually carry: 'modules' present, but the pre-module_state
    LIST of names rather than a map. Same meaning as the no-key case above -- state
    unknown -- and it must not be walked as if it were a map."""
    legacy = {
        "payload_hash": "old",
        "git_sha": "abc",
        "hostname": "mast01",
        "modules": ["proxy"],
        "module_versions": {"proxy": "1.1"},
        "installed_at": "2026-07-08T09:40:59Z",
    }
    r = classify(legacy, build_manifest(git="h1", python="p1"))
    assert r.targets == ["git", "python"]
    assert all(m.state is ModuleState.MISSING for m in r.modules)


def test_recorded_provide_failure_needs_update_even_when_hash_matches():
    """The hash says what the payload WOULD install, not that installing worked."""
    r = classify(installed_manifest(git=entry("h1", provide="fail")), build_manifest(git="h1"))
    assert r.targets == ["git"]


def test_recorded_verify_failure_needs_update_even_when_hash_matches():
    r = classify(installed_manifest(git=entry("h1", verify="fail")), build_manifest(git="h1"))
    assert r.targets == ["git"]


def test_verify_none_is_not_a_failure():
    """A module with no verify command must not be reprovisioned forever."""
    r = classify(installed_manifest(git=entry("h1", verify="none")), build_manifest(git="h1"))
    assert r.current


def test_skipped_verify_needs_update_even_when_hash_matches():
    """Declared and not run is an unknown, and an unknown is not clean.

    The counterpart of test_verify_none_is_not_a_failure: 'none' means there was
    nothing to run, 'skipped' means it was there and this pass did not run it.
    Reading the second as the first is what lets a module stop being targeted
    for a check nobody performed.
    """
    r = classify(installed_manifest(git=entry("h1", verify="skipped")), build_manifest(git="h1"))
    assert r.targets == ["git"]


def test_skipped_provide_needs_update_even_when_hash_matches():
    r = classify(installed_manifest(git=entry("h1", provide="skipped")), build_manifest(git="h1"))
    assert r.targets == ["git"]


def test_missing_installed_hash_needs_update_rather_than_silently_passing():
    r = classify(installed_manifest(git={"version": "1.0", "provide": "pass"}), build_manifest(git="h1"))
    assert r.targets == ["git"]


def test_module_the_build_no_longer_ships_is_extra_and_not_actionable():
    r = classify(installed_manifest(git=entry("h1"), oldmod=entry("o1")), build_manifest(git="h1"))
    assert r.by_state(ModuleState.EXTRA) == ["oldmod"]
    assert r.targets == []
    assert r.current


def test_summary_counts_every_state():
    r = classify(
        installed_manifest(git=entry("h1"), python=entry("p1"), oldmod=entry("o1")),
        build_manifest(git="h1", python="p2", ascom="a1"),
    )
    s = r.summary()
    assert "up-to-date=1" in s
    assert "needs-update=1" in s
    assert "missing=1" in s
    assert "extra=1" in s


def test_build_manifest_without_modules_list_falls_back_to_module_state():
    build = {"module_state": {"git": {"version": "1", "hash": "h1"}}}
    r = classify(installed_manifest(git=entry("h1")), build)
    assert r.current


def test_versions_are_carried_for_reporting():
    """Hash decides; version is what the fleet report shows a human."""
    installed = installed_manifest(git=entry("h1", version="2.44"))
    build = {"modules": ["git"], "module_state": {"git": {"version": "2.52", "hash": "h2"}}}
    r = classify(installed, build)
    m = r.modules[0]
    assert (m.installed_version, m.built_version) == ("2.44", "2.52")
    assert m.state is ModuleState.NEEDS_UPDATE


# --- tier-2 computed validation (stage 4) ------------------------------------


def validation(**modules: str) -> dict:
    return {"checked_at": "2026-08-02T10:00:00Z", "failures": 0, "modules": dict(modules)}


def test_live_verify_failure_on_a_hash_matched_module_is_needs_repair():
    """Runtime drift: the payload did not change, the unit did."""
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h1"), validation(git="fail"))
    assert r.by_state(ModuleState.NEEDS_REPAIR) == ["git"]
    assert r.targets == ["git"]


def test_live_verify_pass_leaves_the_module_up_to_date():
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h1"), validation(git="pass"))
    assert r.current


def test_absent_validation_leaves_the_tier_1_verdict_alone():
    """Tier 2 not having run must not be read as a failure."""
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h1"), None)
    assert r.current


def test_a_module_missing_from_the_validation_report_is_not_penalised():
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h1"), validation(python="fail"))
    assert r.current


def test_needs_update_wins_over_needs_repair():
    """A changed payload is reported as an update, not a repair -- the fix differs."""
    r = classify(installed_manifest(git=entry("h1")), build_manifest(git="h2"), validation(git="fail"))
    assert r.by_state(ModuleState.NEEDS_UPDATE) == ["git"]
    assert r.by_state(ModuleState.NEEDS_REPAIR) == []


# --- always-run (order-terminal) modules --------------------------------------


def build_with_always(*always: str, **hashes: str) -> dict:
    b = build_manifest(**hashes)
    b["always_modules"] = list(always)
    return b


def test_always_modules_join_a_non_empty_target_set():
    b = build_with_always("reboot", git="h1", python="p2", reboot="r1")
    r = classify(installed_manifest(git=entry("h1"), python=entry("p1"), reboot=entry("r1")), b)
    assert r.targets == ["python", "reboot"]
    assert r.drifted == ["python"]


def test_always_modules_do_not_create_a_run_on_their_own():
    """Nothing drifted -> nothing runs. An always-module is a tag-along, not a
    reason to provision, or every cycle would run forever."""
    b = build_with_always("reboot", git="h1", reboot="r1")
    r = classify(installed_manifest(git=entry("h1"), reboot=entry("r1")), b)
    assert r.targets == []
    assert r.current


def test_always_modules_keep_build_order():
    b = {
        "modules": ["proxy", "python", "reboot"],
        "always_modules": ["proxy", "reboot"],
        "module_state": {
            "proxy": {"version": "1", "hash": "x1"},
            "python": {"version": "1", "hash": "NEW"},
            "reboot": {"version": "1", "hash": "r1"},
        },
    }
    installed = installed_manifest(proxy=entry("x1"), python=entry("OLD"), reboot=entry("r1"))
    # proxy runs first and reboot last, as their module.json order dictates.
    assert classify(installed, b).targets == ["proxy", "python", "reboot"]


def test_an_always_module_that_is_itself_drifted_is_not_duplicated():
    b = build_with_always("reboot", git="h1", python="p2", reboot="NEW")
    r = classify(installed_manifest(git=entry("h1"), python=entry("p1"), reboot=entry("r1")), b)
    assert r.targets == ["python", "reboot"]


# --- tier-2 staleness ----------------------------------------------------------


def dated_entry(hash_: str, installed_at: str) -> dict:
    return {"version": "1.0", "hash": hash_, "provide": "pass", "verify": "pass", "installed_at": installed_at}


def test_a_validation_report_older_than_the_install_is_ignored():
    """Nothing clears validation.json, so without this a repaired module would be
    re-targeted by its own pre-repair 'fail' on every later payload change."""
    installed = installed_manifest(git=dated_entry("h1", "2026-08-02T12:00:00Z"))
    stale = {"checked_at": "2026-07-01T00:00:00Z", "modules": {"git": "fail"}}
    assert classify(installed, build_manifest(git="h1"), stale).current


def test_a_validation_report_newer_than_the_install_still_counts():
    installed = installed_manifest(git=dated_entry("h1", "2026-07-01T00:00:00Z"))
    fresh = {"checked_at": "2026-08-02T12:00:00Z", "modules": {"git": "fail"}}
    assert classify(installed, build_manifest(git="h1"), fresh).targets == ["git"]


def test_an_unparseable_timestamp_keeps_the_tier_2_verdict():
    """Cannot tell -> do not silently suppress a reported failure."""
    installed = installed_manifest(git=dated_entry("h1", "not-a-date"))
    report = {"checked_at": "2026-08-02T12:00:00Z", "modules": {"git": "fail"}}
    assert classify(installed, build_manifest(git="h1"), report).targets == ["git"]
