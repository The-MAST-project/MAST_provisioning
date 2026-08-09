"""Proxy-posture classification (port of server/lib/mast-proxy-assert.ps1).

Proxy state on a unit is owned solely by the `proxy` provider. This is the
READ-ONLY decision half of the driver's end-of-run guard: given the proxy
surfaces read off a unit, classify which still point at a proxy.

Critical vs. advisory: git and env-honoring tools read the machine
http_proxy/https_proxy ENV vars, so a dirty env surface on a `direct` run is a
hard failure. WinINet (IE/UI apps) and WinHTTP (Windows Update / BITS) are real
proxy surfaces but do not break git; a dirty one is advisory, not fatal.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# 'netsh winhttp show proxy' prints "Proxy Server(s) :  <server>" when set.
_WINHTTP_SET_RE = re.compile(r"Proxy Server\(s\)\s*:\s*\S")


@dataclass(frozen=True)
class ProxyPosture:
    """The proxy surfaces read off a unit (machine env + WinINet + WinHTTP)."""

    http_proxy: str | None = None
    https_proxy: str | None = None
    wininet_enable: int = 0
    wininet_server: str | None = None
    winhttp: str | None = None


@dataclass(frozen=True)
class ProxyDirtySurfaces:
    """Surfaces still pointing at a proxy, split by severity. Each entry is a
    "surface=value" string, matching the PowerShell event fields."""

    critical: list[str] = field(default_factory=list)
    advisory: list[str] = field(default_factory=list)


def get_proxy_dirty_surfaces(posture: ProxyPosture) -> ProxyDirtySurfaces:
    """Classify a unit's proxy posture into critical (env; git-breaking) and
    advisory (WinINet/WinHTTP) dirty surfaces."""
    critical: list[str] = []
    advisory: list[str] = []

    if posture.http_proxy:
        critical.append(f"http_proxy={posture.http_proxy}")
    if posture.https_proxy:
        critical.append(f"https_proxy={posture.https_proxy}")

    if int(posture.wininet_enable or 0) == 1 and posture.wininet_server:
        advisory.append(f"wininet={posture.wininet_server}")
    if posture.winhttp and _WINHTTP_SET_RE.search(posture.winhttp):
        advisory.append("winhttp=set")

    return ProxyDirtySurfaces(critical=critical, advisory=advisory)
