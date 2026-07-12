"""Tests for prov.proxy_assert -- the READ-ONLY proxy-posture classifier.

Mirrors server/tests/mast-proxy-assert.Tests.ps1.
"""

from prov.proxy_assert import ProxyPosture, get_proxy_dirty_surfaces


def test_clean_posture_has_no_dirty_surfaces():
    d = get_proxy_dirty_surfaces(ProxyPosture())
    assert d.critical == []
    assert d.advisory == []


def test_machine_env_is_critical():
    d = get_proxy_dirty_surfaces(
        ProxyPosture(http_proxy="http://bcproxy.weizmann.ac.il:8080",
                     https_proxy="http://bcproxy.weizmann.ac.il:8080")
    )
    assert d.critical == [
        "http_proxy=http://bcproxy.weizmann.ac.il:8080",
        "https_proxy=http://bcproxy.weizmann.ac.il:8080",
    ]
    assert d.advisory == []


def test_wininet_enabled_with_server_is_advisory():
    d = get_proxy_dirty_surfaces(
        ProxyPosture(wininet_enable=1, wininet_server="bcproxy:8080")
    )
    assert d.advisory == ["wininet=bcproxy:8080"]
    assert d.critical == []


def test_wininet_disabled_is_clean():
    d = get_proxy_dirty_surfaces(
        ProxyPosture(wininet_enable=0, wininet_server="bcproxy:8080")
    )
    assert d.advisory == []


def test_winhttp_set_is_advisory():
    text = "Current WinHTTP proxy settings:\n    Proxy Server(s) :  bcproxy:8080\n"
    d = get_proxy_dirty_surfaces(ProxyPosture(winhttp=text))
    assert d.advisory == ["winhttp=set"]


def test_winhttp_direct_is_clean():
    text = "Current WinHTTP proxy settings:\n    Direct access (no proxy server).\n"
    d = get_proxy_dirty_surfaces(ProxyPosture(winhttp=text))
    assert d.advisory == []
