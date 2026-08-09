"""Maintenance-window gate (port of Test-InMaintenanceWindow).

The disruptive steps (mark-unavailable, SMB pull, execute, reboot) only run
inside a unit's maintenance window. Timezones are IANA ids in the registry
(e.g. "Asia/Jerusalem"); Python's zoneinfo resolves them natively, so the
IANA->Windows mapping shim the PowerShell driver needed (mast-timezone.ps1)
disappears.

NOTE (Windows deployment): zoneinfo has no bundled tz database on Windows -- it
needs the `tzdata` pip package there, else ZoneInfo() raises and this falls back
to server-local time with ``tz_error`` set (the driver then emits MAINT_TZ_WARN,
matching the PowerShell behavior). Installing tzdata on the Windows prov host is
what lets IANA ids resolve, preserving item 1's fix.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


@dataclass(frozen=True)
class WindowResult:
    allowed: bool
    reason: str = ""
    current: str = ""          # local time "HH:mm" (empty when allowed with no window)
    window: str = ""           # "HH:00-HH:00" (empty when no window configured)
    tz: str | None = None
    tz_error: str | None = None  # set when an IANA id could not be resolved


def _resolve_local(now_utc: datetime, tz: str | None) -> tuple[datetime, str | None]:
    """Convert ``now_utc`` to local time in ``tz`` (IANA). On an unresolvable id,
    fall back to server-local time and return the error string (drives MAINT_TZ_WARN)."""
    if not tz:
        return now_utc.astimezone(), None
    try:
        return now_utc.astimezone(ZoneInfo(tz)), None
    except (ZoneInfoNotFoundError, ValueError, OSError) as e:
        return now_utc.astimezone(), f"{type(e).__name__}: {e}"


def in_maintenance_window(
    unit: Mapping[str, Any],
    *,
    override_start: int = -1,
    override_end: int = -1,
    now_utc: datetime | None = None,
) -> WindowResult:
    """Decide whether ``unit`` is inside its maintenance window right now.

    ``override_start``/``override_end`` (>=0) force a fleet-wide window. Otherwise
    the unit's ``maintenance_window.{start_hour,end_hour}`` is used; a unit with
    no window (or missing fields) is allowed at any time.
    """
    tz = unit.get("timezone") or None

    if override_start >= 0 and override_end >= 0:
        start_h, end_h = override_start, override_end
    else:
        mw = unit.get("maintenance_window")
        if not mw:
            return WindowResult(allowed=True, reason="no_window_configured", tz=tz)
        if "start_hour" not in mw or "end_hour" not in mw:
            return WindowResult(allowed=True, reason="window_fields_missing", tz=tz)
        start_h, end_h = int(mw["start_hour"]), int(mw["end_hour"])

    now_utc = now_utc or datetime.now(timezone.utc)
    local, tz_error = _resolve_local(now_utc, tz)
    h = local.hour
    if start_h <= end_h:
        in_win = start_h <= h < end_h
    else:  # wrap, e.g. 22-06
        in_win = h >= start_h or h < end_h

    return WindowResult(
        allowed=in_win,
        reason="in_window" if in_win else "outside_window",
        current=local.strftime("%H:%M"),
        window=f"{start_h:02d}:00-{end_h:02d}:00",
        tz=tz,
        tz_error=tz_error,
    )
