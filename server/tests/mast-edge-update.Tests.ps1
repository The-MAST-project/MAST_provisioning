# Pester unit tests for the verdict in server/lib/mast-edge-update.ps1 (#230).
#
# Only the judgement is tested: the service and scheduled-task reads, and the
# disabling itself, act on the machine and belong to a unit, not to CI.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-edge-update.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-edge-update.ps1')

Describe 'Test-MastEdgeUpdateOff' {
    It 'is off when both services are disabled and no task is enabled' {
        Test-MastEdgeUpdateOff -ServiceModes @{ edgeupdate = 'Disabled'; edgeupdatem = 'Disabled' } -EnabledTaskCount 0 | Should Be $true
    }
    It 'is on while the Auto service is still Auto (the fleet as found on 2026-09-30)' {
        Test-MastEdgeUpdateOff -ServiceModes @{ edgeupdate = 'Auto'; edgeupdatem = 'Manual' } -EnabledTaskCount 2 | Should Be $false
    }
    It 'is on when one service is left Manual' {
        Test-MastEdgeUpdateOff -ServiceModes @{ edgeupdate = 'Disabled'; edgeupdatem = 'Manual' } -EnabledTaskCount 0 | Should Be $false
    }
    It 'is on when a task was re-enabled behind disabled services' {
        Test-MastEdgeUpdateOff -ServiceModes @{ edgeupdate = 'Disabled'; edgeupdatem = 'Disabled' } -EnabledTaskCount 1 | Should Be $false
    }
    It 'treats an absent service as off, since it cannot update anything' {
        Test-MastEdgeUpdateOff -ServiceModes @{ edgeupdate = $null; edgeupdatem = $null } -EnabledTaskCount 0 | Should Be $true
    }
}
