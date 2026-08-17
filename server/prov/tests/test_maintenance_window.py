"""Tests for prov.maintenance_window (port of Test-InMaintenanceWindow).

These take a window and a timezone rather than a registry entry: the function does
not need to know what a unit is, and neither do its tests. The half-specified
window that used to be tested here is now rejected at the registry read -- see
test_registry's "half a window" case.
"""

from datetime import UTC, datetime

from prov.maintenance_window import in_maintenance_window
from prov.registry import MaintenanceWindow


def _utc(y, mo, d, h, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=UTC)


def test_no_window_configured_is_always_allowed():
    r = in_maintenance_window(window=None, now_utc=_utc(2026, 7, 12, 3))
    assert r.allowed and r.reason == "no_window_configured"


# Window-logic tests pin timezone=UTC so the local-hour math is deterministic
# regardless of the CI machine's local timezone (no tz -> server-local, by design).
def test_inside_simple_window_utc():
    window = MaintenanceWindow(start_hour=2, end_hour=6)
    r = in_maintenance_window(window=window, timezone="UTC", now_utc=_utc(2026, 7, 12, 3))
    assert r.allowed and r.reason == "in_window"
    assert r.window == "02:00-06:00"


def test_outside_simple_window_utc():
    window = MaintenanceWindow(start_hour=2, end_hour=6)
    r = in_maintenance_window(window=window, timezone="UTC", now_utc=_utc(2026, 7, 12, 8))
    assert not r.allowed and r.reason == "outside_window"


def test_wrap_window_inside_before_midnight():
    window = MaintenanceWindow(start_hour=22, end_hour=6)
    assert in_maintenance_window(window=window, timezone="UTC", now_utc=_utc(2026, 7, 12, 23)).allowed
    assert in_maintenance_window(window=window, timezone="UTC", now_utc=_utc(2026, 7, 12, 4)).allowed
    assert not in_maintenance_window(window=window, timezone="UTC", now_utc=_utc(2026, 7, 12, 12)).allowed


def test_override_supersedes_unit_window():
    window = MaintenanceWindow(start_hour=0, end_hour=1)
    r = in_maintenance_window(window=window, timezone="UTC", override_start=2, override_end=6, now_utc=_utc(2026, 7, 12, 3))
    assert r.allowed and r.window == "02:00-06:00"


def test_override_applies_with_no_unit_window():
    # The override is fleet-wide, so it must not depend on the unit having one.
    r = in_maintenance_window(window=None, timezone="UTC", override_start=2, override_end=6, now_utc=_utc(2026, 7, 12, 3))
    assert r.allowed and r.window == "02:00-06:00"


def test_iana_timezone_resolves_natively():
    # Asia/Jerusalem is UTC+3 in July (IDT). 00:30 UTC -> 03:30 local, inside 2-6.
    window = MaintenanceWindow(start_hour=2, end_hour=6)
    r = in_maintenance_window(window=window, timezone="Asia/Jerusalem", now_utc=_utc(2026, 7, 12, 0, 30))
    assert r.tz == "Asia/Jerusalem"
    assert r.tz_error is None
    assert r.current == "03:30"
    assert r.allowed


def test_unresolvable_timezone_falls_back_with_error():
    window = MaintenanceWindow(start_hour=0, end_hour=24)
    r = in_maintenance_window(window=window, timezone="Not/AZone", now_utc=_utc(2026, 7, 12, 3))
    assert r.tz_error is not None  # drives MAINT_TZ_WARN
