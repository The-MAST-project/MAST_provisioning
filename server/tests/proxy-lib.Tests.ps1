# Pester unit tests for the pure helpers in server/providers/proxy/proxy-lib.ps1.
#
# Only the side-effect-free functions are exercised here (bypass-list conversion,
# host:port parsing, the WinINet blob layout). The registry/env/netsh mutators
# (Set-WinINetProxy, Set-WinHttpProxy, Set-MastProxyState, ...) are verified on a
# real unit, not in these tests.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\proxy-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\providers\proxy\proxy-lib.ps1')

Describe 'Convert-NoProxyToWildcardBypass' {
    It 'expands a /24 CIDR to a three-octet wildcard' {
        Convert-NoProxyToWildcardBypass '10.23.3.0/24' | Should Be '10.23.3.*;<local>'
    }
    It 'expands a /16 CIDR to a two-octet wildcard' {
        Convert-NoProxyToWildcardBypass '10.23.0.0/16' | Should Be '10.23.*;<local>'
    }
    It 'passes non-CIDR entries through and appends <local> once' {
        Convert-NoProxyToWildcardBypass 'localhost,127.0.0.1' | Should Be 'localhost;127.0.0.1;<local>'
    }
    It 'handles multiple CIDR entries' {
        Convert-NoProxyToWildcardBypass '10.23.3.0/24,10.23.4.0/24' | Should Be '10.23.3.*;10.23.4.*;<local>'
    }
    It 'does not duplicate an explicit <local>' {
        Convert-NoProxyToWildcardBypass '<local>,10.23.3.0/24' | Should Be '<local>;10.23.3.*'
    }
}

Describe 'Get-ProxyHostPort' {
    It 'parses host:port out of an http URL' {
        Get-ProxyHostPort -ProxyUrl 'http://bcproxy.weizmann.ac.il:8080' | Should Be 'bcproxy.weizmann.ac.il:8080'
    }
    It 'accepts a bare host:port' {
        Get-ProxyHostPort -ProxyUrl 'bcproxy.weizmann.ac.il:8080' | Should Be 'bcproxy.weizmann.ac.il:8080'
    }
    It 'defaults to port 80 when the URL omits the port' {
        Get-ProxyHostPort -ProxyUrl 'http://bcproxy.weizmann.ac.il' | Should Be 'bcproxy.weizmann.ac.il:80'
    }
    It 'returns $null for an empty string' {
        Get-ProxyHostPort -ProxyUrl '' | Should BeNullOrEmpty
    }
}

Describe 'New-WinINetConnBlob' {
    It 'writes the version marker and the flags byte at offset 8' {
        $b = New-WinINetConnBlob -Flags 0x01 -HostPort '' -Bypass ''
        $b[0] | Should Be 0x46
        $b[8] | Should Be 0x01
    }
    It 'stamps the manual-proxy flag (0x02) when set' {
        (New-WinINetConnBlob -Flags 0x02 -HostPort 'h:8080' -Bypass '<local>')[8] | Should Be 0x02
    }
}
