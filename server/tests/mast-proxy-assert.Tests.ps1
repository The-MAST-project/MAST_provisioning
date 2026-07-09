# Pester unit tests for the pure classifier in server/lib/mast-proxy-assert.ps1.
#
# Mirrors the other server/tests: dot-source the lib and assert the DECISION
# (which surfaces count as dirty, and critical vs. advisory) without any WinRM /
# unit I/O.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-proxy-assert.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-proxy-assert.ps1')

$clean = @{
    http_proxy = $null; https_proxy = $null
    wininet_enable = 0; wininet_server = ''
    winhttp = 'Current WinHTTP proxy settings:`n    Direct access (no proxy server).'
}

Describe 'Get-ProxyDirtySurfaces' {
    It 'reports nothing dirty for a fully clean posture' {
        $d = Get-ProxyDirtySurfaces -Posture $clean
        $d.Critical.Count | Should Be 0
        $d.Advisory.Count | Should Be 0
    }
    It 'flags machine http_proxy/https_proxy as CRITICAL (git-breaking)' {
        $p = $clean.Clone()
        $p.http_proxy  = 'bcproxy.weizmann.ac.il:8080'
        $p.https_proxy = 'bcproxy.weizmann.ac.il:8080'
        $d = Get-ProxyDirtySurfaces -Posture $p
        $d.Critical.Count | Should Be 2
        ($d.Critical -join ';') | Should Match 'bcproxy'
        $d.Advisory.Count | Should Be 0
    }
    It 'flags an enabled WinINet proxy as ADVISORY, not critical' {
        $p = $clean.Clone()
        $p.wininet_enable = 1; $p.wininet_server = 'bcproxy.weizmann.ac.il:8080'
        $d = Get-ProxyDirtySurfaces -Posture $p
        $d.Critical.Count | Should Be 0
        $d.Advisory.Count | Should Be 1
    }
    It 'ignores WinINet when ProxyEnable is 0 even if a server string lingers' {
        $p = $clean.Clone()
        $p.wininet_enable = 0; $p.wininet_server = 'bcproxy.weizmann.ac.il:8080'
        (Get-ProxyDirtySurfaces -Posture $p).Advisory.Count | Should Be 0
    }
    It 'flags a set WinHTTP proxy as ADVISORY' {
        $p = $clean.Clone()
        $p.winhttp = 'Current WinHTTP proxy settings:`n    Proxy Server(s) :  bcproxy.weizmann.ac.il:8080'
        (Get-ProxyDirtySurfaces -Posture $p).Advisory.Count | Should Be 1
    }
    It 'separates critical env from advisory surfaces when both are dirty' {
        $p = $clean.Clone()
        $p.http_proxy = 'bcproxy.weizmann.ac.il:8080'
        $p.wininet_enable = 1; $p.wininet_server = 'bcproxy.weizmann.ac.il:8080'
        $d = Get-ProxyDirtySurfaces -Posture $p
        $d.Critical.Count | Should Be 1
        $d.Advisory.Count | Should Be 1
    }
}
