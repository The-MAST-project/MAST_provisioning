"""Tests for prov.winrm_flap. Mirrors server/tests/mast-winrm-warn.Tests.ps1."""

from prov.winrm_flap import measure_winrm_flap


def test_counts_interrupted_and_restored():
    msgs = [
        "The network connection to the remote machine has been interrupted. Attempting to reconnect...",
        "The network connection to the remote machine has been restored.",
        "The network connection to the remote machine has been interrupted. Attempting to reconnect...",
        "The network connection to the remote machine has been restored.",
    ]
    f = measure_winrm_flap(msgs)
    assert (f.interrupted, f.restored, f.other, f.total) == (2, 2, 0, 4)


def test_unrecognized_warning_is_other_with_sample():
    f = measure_winrm_flap(["Some other odd warning"])
    assert f.other == 1
    assert f.other_sample == "Some other odd warning"


def test_ignores_blank_and_none_entries():
    f = measure_winrm_flap(["", "   ", None])  # type: ignore[list-item]
    assert f.total == 0


def test_empty_set_is_all_zero():
    assert measure_winrm_flap([]).total == 0
