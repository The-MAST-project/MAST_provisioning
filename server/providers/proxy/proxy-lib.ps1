# Shared proxy-state logic for MAST units.
#
# Single source of truth for reading and flipping the three proxy surfaces a
# MAST unit exposes. Consumed by:
#   - provide-proxy.ps1  (the provisioning-time provider)
#   - set-proxy.ps1      (the operator "MAST Proxy" desktop tool)
# so there is ONE implementation, not a drifting second copy.
#
# The three surfaces (managed in lockstep):
#   A. Machine-scope env vars: http_proxy, https_proxy, no_proxy
#      (curl, wget, pip, npm, git, requests, urllib3, ...)
#   B. HKCU IE / WinINet proxy (ProxyEnable/ProxyServer/ProxyOverride + the
#      DefaultConnectionSettings/SavedLegacySettings flags blob; cygwin
#      setup-x86_64.exe, Edge/IE, .NET HttpClient default, MSI downloads)
#   C. Machine WinHTTP (netsh winhttp; Windows Update agent, BITS, COM services)
#
# This file DEFINES FUNCTIONS ONLY -- dot-sourcing it has no side effects. The
# caller drives the mutation (Set-MastProxyState) and readback (Get-MastProxyPosture).

# ---------------------------------------------------------------------------
# Pluggable logger. Callers may route lib output into their own log via
# Set-ProxyLibLogger; the default writes to the host.
# ---------------------------------------------------------------------------
$script:ProxyLibLogger = $null
function Set-ProxyLibLogger {
    param([scriptblock]$Logger)
    $script:ProxyLibLogger = $Logger
}
function Write-ProxyLibLog {
    param([string]$Line)
    if ($null -ne $script:ProxyLibLogger) { & $script:ProxyLibLogger $Line }
    else { Write-Host $Line }
}

# ---------------------------------------------------------------------------
# Surface helpers (extracted verbatim from provide-proxy.ps1; behavior is
# unchanged -- only Write-ProxyLog calls became Write-ProxyLibLog).
# ---------------------------------------------------------------------------
function Convert-NoProxyToWildcardBypass([string]$List) {
    # WinINet/WinHTTP bypass lists do NOT understand CIDR -- the WSMan client
    # even faults 87 "The parameter is incorrect" on every local operation
    # while a CIDR entry is present (broke bootstrap re-runs on mast01). The
    # NO_PROXY env var keeps CIDR for tools that support it; these two
    # surfaces get wildcard prefixes plus <local>.
    $parts = @()
    foreach ($e in ($List -split ',')) {
        $t = $e.Trim()
        if (-not $t) { continue }
        if ($t -match '^(\d+)\.(\d+)\.(\d+)\.\d+/24$') { $parts += ('{0}.{1}.{2}.*' -f $Matches[1], $Matches[2], $Matches[3]) }
        elseif ($t -match '^(\d+)\.(\d+)\.\d+\.\d+/16$') { $parts += ('{0}.{1}.*' -f $Matches[1], $Matches[2]) }
        else { $parts += $t }
    }
    if ($parts -notcontains '<local>') { $parts += '<local>' }
    return ($parts -join ';')
}

function Get-ProxyHostPort {
    # Parse 'host:port' out of 'http://host:port[/...]' or 'host:port'.
    # Returns "host:port" or $null on parse failure.
    param([string]$ProxyUrl)
    if ([string]::IsNullOrEmpty($ProxyUrl)) { return $null }
    if ($ProxyUrl -match '^https?://') {
        try {
            $uri = [System.Uri]$ProxyUrl
            $h = $uri.Host
            $p = $uri.Port
            if ($p -le 0) { $p = 80 }
            if (-not $h) { return $null }
            return ("{0}:{1}" -f $h, $p)
        } catch { return $null }
    }
    if ($ProxyUrl -match '^[^:/]+:\d+$') { return $ProxyUrl }
    return $null
}

function Set-WinINetProxy {
    # HKCU IE / WinINet proxy. cygwin setup-x86_64.exe and many other Windows
    # tools read these. Provisioning and the operator tool both run as the
    # 'mast' user, so HKCU of that user is what matters.
    param(
        [Parameter(Mandatory)][bool]$Enable,
        [string]$HostPort,
        [string]$NoProxyList
    )
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    if ($Enable) {
        Set-ItemProperty -Path $k -Name 'ProxyEnable' -Type DWord  -Value 1
        Set-ItemProperty -Path $k -Name 'ProxyServer' -Type String -Value $HostPort
        if ($NoProxyList) {
            $bypass = Convert-NoProxyToWildcardBypass $NoProxyList
            Set-ItemProperty -Path $k -Name 'ProxyOverride' -Type String -Value $bypass
        } else {
            Remove-ItemProperty -Path $k -Name 'ProxyOverride' -ErrorAction SilentlyContinue
        }
    } else {
        Set-ItemProperty -Path $k -Name 'ProxyEnable' -Type DWord -Value 0
        Set-ItemProperty -Path $k -Name 'ProxyServer' -Type String -Value ''
        Remove-ItemProperty -Path $k -Name 'ProxyOverride' -ErrorAction SilentlyContinue
    }
}

function New-WinINetConnBlob {
    # Build a minimal-but-valid DefaultConnectionSettings binary blob.
    # Layout: [u32 version=0x46][u32 counter][u32 flags]
    #         [u32 len + proxyserver][u32 len + bypass][u32 len + pac-url=0]
    #         [32 trailing zero bytes].
    param([int]$Flags, [string]$HostPort, [string]$Bypass)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]0x46)
    $bw.Write([uint32]1)
    $bw.Write([uint32]$Flags)
    $srv = if (($Flags -band 0x02) -and $HostPort) { $HostPort } else { '' }
    $byp = if ($Flags -band 0x02) { $Bypass } else { '' }
    $sb = [System.Text.Encoding]::ASCII.GetBytes($srv); $bw.Write([uint32]$sb.Length); if ($sb.Length) { $bw.Write($sb) }
    $bb = [System.Text.Encoding]::ASCII.GetBytes($byp); $bw.Write([uint32]$bb.Length); if ($bb.Length) { $bw.Write($bb) }
    $bw.Write([uint32]0)
    $bw.Write((New-Object byte[] 32))
    $bw.Flush()
    return $ms.ToArray()
}

function Set-WinINetConnectionFlags {
    # WinINet reads the flags byte (offset 8) of the binary
    # DefaultConnectionSettings / SavedLegacySettings blobs. A stray WPAD
    # auto-detect bit (0x08) makes the OS probe for a proxy even with an
    # explicit one set -- on a multi-homed host that probe makes CryptoAPI's
    # revocation fetch fail and hard-fails TLS-revocation-enforcing installers.
    # Force an EXPLICIT config: manual-proxy-only (0x02) in 'use' mode,
    # direct-only (0x01) in 'direct' mode -- never 0x08 (WPAD) or 0x04 (PAC).
    param(
        [Parameter(Mandatory)][bool]$Enable,
        [string]$HostPort,
        [string]$NoProxyList
    )
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    $flags = if ($Enable) { 0x02 } else { 0x01 }
    $bypass = if ($NoProxyList) { Convert-NoProxyToWildcardBypass $NoProxyList } else { '' }
    foreach ($name in @('DefaultConnectionSettings', 'SavedLegacySettings')) {
        $existing = $null
        try { $existing = (Get-ItemProperty -Path $k -Name $name -ErrorAction Stop).$name } catch {}
        if ($existing -and $existing.Length -ge 12) {
            # In-place: just clear/flip the flags byte and bump the change counter
            # (offset 4) so WinINet reloads, leaving the rest of the blob intact.
            $b = [byte[]]$existing.Clone()
            $b[8] = [byte]$flags
            $ctr = [System.BitConverter]::ToUInt32($b, 4) + 1
            [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$ctr), 0, $b, 4, 4)
        } else {
            $b = New-WinINetConnBlob -Flags $flags -HostPort $HostPort -Bypass $bypass
        }
        Set-ItemProperty -Path $k -Name $name -Value $b -Type Binary
    }
}

function Get-WinINetAutoDetect {
    # Returns $true if the WPAD auto-detect bit (0x08) is set in
    # DefaultConnectionSettings, else $false.
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
    try {
        $v = (Get-ItemProperty -Path $k -Name 'DefaultConnectionSettings' -ErrorAction Stop).DefaultConnectionSettings
        if ($v -and $v.Length -ge 9) { return [bool]($v[8] -band 0x08) }
    } catch {}
    return $false
}

function Get-WinINetProxyState {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $h = @{ Enable = 0; Server = ''; Override = '' }
    if (-not (Test-Path $k)) { return $h }
    try {
        $p = Get-ItemProperty -Path $k -ErrorAction Stop
        if ($null -ne $p.ProxyEnable)   { $h.Enable   = [int]$p.ProxyEnable }
        if ($null -ne $p.ProxyServer)   { $h.Server   = [string]$p.ProxyServer }
        if ($null -ne $p.ProxyOverride) { $h.Override = [string]$p.ProxyOverride }
    } catch {}
    return $h
}

function Set-WinHttpProxy {
    param(
        [Parameter(Mandatory)][bool]$Enable,
        [string]$HostPort,
        [string]$NoProxyList
    )
    if ($Enable) {
        $bypass = if ($NoProxyList) { Convert-NoProxyToWildcardBypass $NoProxyList } else { '<local>' }
        $cmd = "netsh winhttp set proxy `"$HostPort`" `"$bypass`""
    } else {
        $cmd = "netsh winhttp reset proxy"
    }
    Write-ProxyLibLog ("  WinHTTP: {0}" -f $cmd)
    $out = & cmd /c $cmd 2>&1
    foreach ($line in $out) { Write-ProxyLibLog ("    {0}" -f $line) }
}

# ---------------------------------------------------------------------------
# Orchestration: flip all three surfaces to match a mode, and read them back.
# This is the exact A -> B -> C sequence provide-proxy.ps1 used inline.
# ---------------------------------------------------------------------------
function Set-MastProxyState {
    param(
        [Parameter(Mandatory)][ValidateSet('use','direct')][string]$Mode,
        [string]$HttpProxy  = 'http://bcproxy.weizmann.ac.il:8080',
        [string]$HttpsProxy = 'http://bcproxy.weizmann.ac.il:8080',
        [string]$NoProxy    = '10.23.3.0/24,10.23.4.0/24'
    )

    $pairs = @(
        @{ Name = 'http_proxy';  Value = $HttpProxy  },
        @{ Name = 'https_proxy'; Value = $HttpsProxy },
        @{ Name = 'no_proxy';    Value = $NoProxy    }
    )

    # ----- (A) Machine env vars -----
    if ($Mode -eq 'use') {
        foreach ($p in $pairs) {
            $prev = [Environment]::GetEnvironmentVariable($p.Name, 'Machine')
            if ($prev -eq $p.Value) {
                Write-ProxyLibLog ("{0} already set to expected value; skipping" -f $p.Name)
                continue
            }
            Write-ProxyLibLog ("Setting machine env: {0} = {1} (previous: {2})" -f $p.Name, $p.Value, $prev)
            [Environment]::SetEnvironmentVariable($p.Name, $p.Value, 'Machine')
        }
    } else {
        foreach ($p in $pairs) {
            $prev = [Environment]::GetEnvironmentVariable($p.Name, 'Machine')
            if ([string]::IsNullOrEmpty($prev)) {
                Write-ProxyLibLog ("{0} already empty; skipping" -f $p.Name)
                continue
            }
            Write-ProxyLibLog ("Clearing machine env: {0} (was: {1})" -f $p.Name, $prev)
            [Environment]::SetEnvironmentVariable($p.Name, $null, 'Machine')
        }
    }

    # ----- (B) WinINet / IE proxy -----
    $hostPort = Get-ProxyHostPort -ProxyUrl $HttpsProxy
    if ($Mode -eq 'use') {
        if (-not $hostPort) {
            throw ("Cannot parse host:port out of HttpsProxy='{0}'." -f $HttpsProxy)
        }
        Write-ProxyLibLog ("Setting WinINet proxy: ProxyEnable=1 ProxyServer={0} ProxyOverride={1}" -f $hostPort, $NoProxy)
        Set-WinINetProxy -Enable $true -HostPort $hostPort -NoProxyList $NoProxy
        Write-ProxyLibLog "Forcing WinINet connection flags to manual-only (clearing WPAD auto-detect 0x08 / PAC 0x04)."
        Set-WinINetConnectionFlags -Enable $true -HostPort $hostPort -NoProxyList $NoProxy
    } else {
        Write-ProxyLibLog "Clearing WinINet proxy: ProxyEnable=0"
        Set-WinINetProxy -Enable $false
        Write-ProxyLibLog "Forcing WinINet connection flags to direct-only (clearing WPAD auto-detect 0x08 / PAC 0x04)."
        Set-WinINetConnectionFlags -Enable $false
    }

    # ----- (C) Machine WinHTTP -----
    if ($Mode -eq 'use') {
        Set-WinHttpProxy -Enable $true -HostPort $hostPort -NoProxyList $NoProxy
    } else {
        Set-WinHttpProxy -Enable $false
    }
}

function Get-MastProxyPosture {
    # Read all three surfaces into one structure for display / assertion.
    $env = @{
        http_proxy  = [Environment]::GetEnvironmentVariable('http_proxy', 'Machine')
        https_proxy = [Environment]::GetEnvironmentVariable('https_proxy', 'Machine')
        no_proxy    = [Environment]::GetEnvironmentVariable('no_proxy', 'Machine')
    }
    $winhttp = ''
    try { $winhttp = (& cmd /c 'netsh winhttp show proxy' 2>&1 | Out-String) } catch {}
    return @{
        Env            = $env
        WinINet        = (Get-WinINetProxyState)
        WpadAutoDetect = (Get-WinINetAutoDetect)
        WinHttp        = $winhttp
    }
}
