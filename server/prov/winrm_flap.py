"""WinRM/PSRP link-flap warning classification (port of mast-winrm-warn.ps1).

During a long remote command over a flaky link, PowerShell's robust-connection
layer emits "connection ... interrupted" / "... restored" WARNING lines -- on a
bad link, hundreds of them. Rather than suppress, the driver captures them for
a phase and logs ONE deduplicated WINRM_LINK_FLAP summary. This is the pure
classifier that turns a bag of warning strings into counts.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class WinRmFlap:
    interrupted: int
    restored: int
    other: int
    other_sample: str
    total: int


def measure_winrm_flap(messages: list[str]) -> WinRmFlap:
    """Classify captured PSRP warning strings by substring (interrupt/restore);
    the first unrecognized message is kept as ``other_sample``."""
    interrupted = 0
    restored = 0
    other = 0
    other_sample = ""
    for m in messages or []:
        if not m or not m.strip():
            continue
        low = m.lower()
        if "interrupt" in low:
            interrupted += 1
        elif "restore" in low:
            restored += 1
        else:
            other += 1
            if not other_sample:
                other_sample = m.strip()
    return WinRmFlap(
        interrupted=interrupted,
        restored=restored,
        other=other,
        other_sample=other_sample,
        total=interrupted + restored + other,
    )
