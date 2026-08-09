# Pester unit tests for the pure classifier in server/lib/mast-winrm-warn.ps1.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-winrm-warn.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-winrm-warn.ps1')

Describe 'Measure-WinRmFlap' {
    It 'counts interrupted and restored PSRP messages' {
        $msgs = @(
            'The network connection to the remote machine has been interrupted. Attempting to reconnect...',
            'The network connection to the remote machine has been restored.',
            'The network connection to the remote machine has been interrupted. Attempting to reconnect...',
            'The network connection to the remote machine has been restored.'
        )
        $f = Measure-WinRmFlap -Messages $msgs
        $f.Interrupted | Should Be 2
        $f.Restored    | Should Be 2
        $f.Other       | Should Be 0
        $f.Total       | Should Be 4
    }
    It 'buckets an unrecognized warning as Other and keeps a sample' {
        $f = Measure-WinRmFlap -Messages @('Some other odd warning')
        $f.Other       | Should Be 1
        $f.OtherSample | Should Be 'Some other odd warning'
    }
    It 'ignores null / whitespace entries' {
        $f = Measure-WinRmFlap -Messages @('', '   ', $null)
        $f.Total | Should Be 0
    }
    It 'returns all-zero for an empty set' {
        (Measure-WinRmFlap -Messages @()).Total | Should Be 0
    }
}
