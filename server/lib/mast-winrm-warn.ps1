# WinRM/PSRP transport-warning rate-limiting for the provisioning driver.
#
# During a long Invoke-Command over a flaky bench link, PowerShell's robust-
# connection layer emits "The network connection ... has been interrupted ..."
# / "... has been restored." WARNING lines -- untimestamped and, on a bad link,
# hundreds of them, drowning the meaningful events in the controller log
# (mast04 2026-07-07). Rather than suppress them, the driver captures the
# warning messages for a phase and logs ONE deduplicated, timestamped
# WINRM_LINK_FLAP summary. This file is the pure classifier that turns a bag of
# warning strings into counts.

function Measure-WinRmFlap {
    # $Messages: warning strings captured for one phase (from -WarningVariable
    # on a foreground Invoke-Command, or a background job's Warning stream).
    # Returns @{ Interrupted; Restored; Other; OtherSample; Total }.
    param([string[]]$Messages)

    $interrupted = 0
    $restored    = 0
    $other       = 0
    $otherSample = ''
    foreach ($m in @($Messages)) {
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        if ($m -match 'interrupt') {
            $interrupted++
        } elseif ($m -match 'restore') {
            $restored++
        } else {
            $other++
            if (-not $otherSample) { $otherSample = $m.Trim() }
        }
    }
    return @{
        Interrupted = $interrupted
        Restored    = $restored
        Other       = $other
        OtherSample = $otherSample
        Total       = ($interrupted + $restored + $other)
    }
}
