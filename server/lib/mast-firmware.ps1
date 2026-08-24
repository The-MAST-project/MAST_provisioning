# Firmware (BIOS/UEFI) setup reader and policy evaluator.
#
# WHY THIS FILE EXISTS: a MAST unit must power itself back on when mains
# returns -- the DLI switch cuts and restores AC, and a unit whose BIOS is set
# to stay off is simply absent from the fleet until someone drives to the site.
# That setting lives in BIOS setup, which provisioning cannot write, so the only
# thing software can do is READ it and say so loudly.
#
# There is exactly one reader, and it is this file. Two callers use it:
#   - client/bootstrap.ps1, at the console, where an operator can walk into BIOS
#     setup and fix it in ninety seconds;
#   - server/providers/power-management/verify-power-management.ps1, during an
#     unattended provisioning run, where it warns and never fails the run.
# Both reach it the same way, and both compare against the same baseline file.
#
# HOW THE VALUE IS READ: the ASUS WMI provider (root\WMI:ASUSManagement) does
# enumerate the setup questions -- GetSetupItemList returns all 127 of them,
# including 'APM Configuration/Restore AC Power Loss' with its '0 = S5 State /
# 1 = S0 State' value map -- but its per-item accessors are stubs on the BIOS
# the fleet runs: GetOptionData and GetBootOrder both return ErrorCode 15 for
# every input. So the catalog is available and the values are not.
#
# The values ARE available in the AMI setup varstore, exposed to Windows as the
# UEFI variable 'Setup' under the AMI GUID. It is an opaque struct -- one byte
# per question, no names -- so a field is located by toggling it in BIOS setup
# and diffing the blob. That is how every offset in firmware-baseline.json was
# obtained (measured on mast08, 2026-08-24); they are NOT derivable by counting
# the catalog, whose order is preserved but whose spacing is not.
#
# Requires elevation (SeSystemEnvironmentPrivilege). Every failure path returns
# an 'unavailable' result rather than throwing: a firmware read that does not
# work must never be what stops a unit being built.

$script:MastFirmwareSetupVariable = 'Setup'
$script:MastFirmwareSetupGuid = '{EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9}'

function Initialize-MastFirmwareInterop {
    if ('MastFirmwareNative' -as [type]) { return }
    $src = @'
using System;
using System.Runtime.InteropServices;

public class MastFirmwareNative {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint GetFirmwareEnvironmentVariableExW(
        string lpName, string lpGuid, byte[] pBuffer, uint nSize, out uint pdwAttributes);

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES { public uint Count; public LUID Luid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValueW(string system, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint length, IntPtr prev, IntPtr returnLength);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    private const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
    private const uint TOKEN_QUERY = 0x8;
    private const uint SE_PRIVILEGE_ENABLED = 0x2;

    public static bool EnableSystemEnvironmentPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) return false;
        LUID luid;
        if (!LookupPrivilegeValueW(null, "SeSystemEnvironmentPrivilege", out luid)) return false;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.Count = 1; tp.Luid = luid; tp.Attributes = SE_PRIVILEGE_ENABLED;
        if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
        return Marshal.GetLastWin32Error() == 0;
    }

    // Returns null and sets error when the variable cannot be read; the caller
    // turns that into an 'unavailable' result rather than an exception.
    public static byte[] Read(string name, string guid, out int error) {
        byte[] buffer = new byte[65536];
        uint attributes;
        uint size = GetFirmwareEnvironmentVariableExW(name, guid, buffer, (uint)buffer.Length, out attributes);
        if (size == 0) { error = Marshal.GetLastWin32Error(); return null; }
        error = 0;
        byte[] data = new byte[size];
        Array.Copy(buffer, data, (int)size);
        return data;
    }
}
'@
    Add-Type -TypeDefinition $src -Language CSharp
}

function Get-MastFirmwareSetup {
    <#
    .SYNOPSIS
      Read the AMI setup varstore plus the board/BIOS identity that scopes it.
    .OUTPUTS
      An object with Available, Reason, Bytes, Sha256, Length, BaseboardProduct,
      BiosVersion. Available is $false -- never an exception -- on a machine
      with no such variable (the dev VM, a legacy-BIOS box, a non-ASUS board) or
      when the process cannot take SeSystemEnvironmentPrivilege.
    #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        Available        = $false
        Reason           = ''
        Bytes            = $null
        Sha256           = ''
        Length           = 0
        BaseboardProduct = ''
        BiosVersion      = ''
    }

    try {
        $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
        if ($board.Product) { $result.BaseboardProduct = [string]$board.Product }
    } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        if ($bios.SMBIOSBIOSVersion) { $result.BiosVersion = [string]$bios.SMBIOSBIOSVersion }
    } catch { Write-Verbose "ignored: $($_.Exception.Message)" }

    try {
        Initialize-MastFirmwareInterop
    } catch {
        $result.Reason = ("firmware interop unavailable: {0}" -f $_.Exception.Message)
        return [pscustomobject]$result
    }

    if (-not [MastFirmwareNative]::EnableSystemEnvironmentPrivilege()) {
        $result.Reason = 'could not enable SeSystemEnvironmentPrivilege (not elevated?)'
        return [pscustomobject]$result
    }

    $err = 0
    $bytes = [MastFirmwareNative]::Read($script:MastFirmwareSetupVariable, $script:MastFirmwareSetupGuid, [ref]$err)
    if ($null -eq $bytes) {
        # 203 = ERROR_ENVVAR_NOT_FOUND: no such UEFI variable. Expected on the
        # dev VM and on any board that is not AMI/ASUS -- not a defect here.
        $result.Reason = ("UEFI variable '{0}' not readable (win32 error {1})" -f $script:MastFirmwareSetupVariable, $err)
        return [pscustomobject]$result
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }

    $result.Available = $true
    $result.Bytes = $bytes
    $result.Length = $bytes.Length
    $result.Sha256 = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    return [pscustomobject]$result
}

function Get-MastFirmwareBaselinePath {
    <#
    .SYNOPSIS
      Locate firmware-baseline.json: beside the caller first, then in the repo.
    .DESCRIPTION
      The build stages this file flat into the payload root (a 'repofiles' entry
      of the power-management module) and the ISO builder stages it beside
      bootstrap.ps1, so beside-the-caller is the deployed case and the repo path
      is the developer case. Same two-step the mast-log.ps1 dot-source uses.
    #>
    [CmdletBinding()]
    param([string]$ScriptRoot = $PSScriptRoot)

    $candidates = @(
        (Join-Path $ScriptRoot 'firmware-baseline.json'),                    # staged payload / bootstrap media
        (Join-Path $ScriptRoot '..\data\firmware-baseline.json'),            # repo: server\lib -> server\data
        (Join-Path $ScriptRoot '..\..\server\data\firmware-baseline.json'),  # repo: server\providers\<m> -> server\data
        (Join-Path $ScriptRoot '..\server\data\firmware-baseline.json')      # repo: client -> server\data
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return ''
}

function Get-MastFirmwareBaseline {
    <#
    .SYNOPSIS
      The baseline entry for one board + BIOS version, or $null if none matches.
    .DESCRIPTION
      A miss is the expected outcome on new hardware -- the fleet will take
      boards that do not exist yet -- so it is a first-class result, not an
      error. The caller reports 'cannot verify', which is a different thing from
      'verified wrong'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BaseboardProduct,
        [string]$BiosVersion
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $doc.boards) { return $null }
    foreach ($b in @($doc.boards)) {
        if (([string]$b.baseboard_product -eq $BaseboardProduct) -and ([string]$b.bios_version -eq $BiosVersion)) {
            return $b
        }
    }
    return $null
}

function Test-MastFirmwarePolicy {
    <#
    .SYNOPSIS
      Compare a setup varstore against its baseline; classify what it finds.
    .DESCRIPTION
      Status is one of:
        match            -- hash and every named field agree with the baseline.
        field-drift      -- a NAMED field is wrong. NeedsAttention: a unit in
                            this state may not come back after a mains event.
        blob-drift       -- the hash differs but every named field is right.
                            Something in BIOS setup changed; nothing we know to
                            be load-bearing. Reported, never escalated -- if
                            every drift demanded a keystroke, operators would
                            learn to dismiss the keystroke.
        unknown-baseline -- no entry for this board + BIOS version. NeedsAttention:
                            not verified is not the same as verified good, and
                            silence here is exactly how a reset BIOS hides.
        unavailable      -- the variable could not be read at all.
    .OUTPUTS
      Status, NeedsAttention, Messages (operator-facing lines), Fields, and the
      identity/hash values a caller records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Setup,
        $Baseline
    )

    $out = [ordered]@{
        Status           = 'unavailable'
        NeedsAttention   = $false
        Messages         = @()
        Fields           = @()
        BaselineMatched  = $false
        BaseboardProduct = $Setup.BaseboardProduct
        BiosVersion      = $Setup.BiosVersion
        Sha256           = $Setup.Sha256
    }

    if (-not $Setup.Available) {
        $out.Messages = @(("BIOS setup varstore not readable ({0}); power policy not verified." -f $Setup.Reason))
        return [pscustomobject]$out
    }

    if ($null -eq $Baseline) {
        $out.Status = 'unknown-baseline'
        $out.NeedsAttention = $true
        $out.Messages = @(
            ("no firmware baseline for board '{0}' BIOS '{1}' -- this BIOS cannot be verified." -f $Setup.BaseboardProduct, $Setup.BiosVersion),
            'Check BIOS setup by hand: Advanced -> APM Configuration -> "Restore AC Power Loss" must be "S0 State"',
            'so the unit powers itself back on when mains returns. Then re-baseline this board (see README).'
        )
        return [pscustomobject]$out
    }

    # A varstore of a different size is not the struct this baseline describes,
    # so every offset in it points at an unrelated byte. Treat it as unverified
    # rather than comparing: the one outcome this check must never produce is a
    # quiet pass on a machine it could not actually read.
    $expectedLength = 0
    if ($Baseline.PSObject.Properties.Match('setup_length').Count) { $expectedLength = [int]$Baseline.setup_length }
    if ($expectedLength -gt 0 -and $Setup.Length -ne $expectedLength) {
        $out.Status = 'unknown-baseline'
        $out.NeedsAttention = $true
        $out.Messages = @(
            ("BIOS setup is {0} bytes but the baseline for '{1}' BIOS '{2}' describes {3} -- the baseline does not apply to this firmware." -f `
                $Setup.Length, $Setup.BaseboardProduct, $Setup.BiosVersion, $expectedLength),
            'Power policy NOT verified. Check Advanced -> APM Configuration by hand, then re-baseline (see README).'
        )
        return [pscustomobject]$out
    }

    $messages = @()
    $fields = @()
    $fieldDrift = $false

    foreach ($f in @($Baseline.fields)) {
        $offset = [int]$f.offset
        $expect = [int]$f.expect
        if ($offset -lt 0 -or $offset -ge $Setup.Length) {
            # The baseline describes a different-sized varstore than the one in
            # front of us: the entry is not applicable, and pretending otherwise
            # would read an unrelated byte.
            $messages += ("baseline field '{0}' offset {1} is outside this {2}-byte varstore; skipped." -f $f.name, $offset, $Setup.Length)
            continue
        }
        $actual = [int]$Setup.Bytes[$offset]
        $ok = ($actual -eq $expect)
        if (-not $ok) { $fieldDrift = $true }
        $fields += [pscustomobject]@{
            Name   = [string]$f.name
            Offset = $offset
            Expect = $expect
            Actual = $actual
            Ok     = $ok
        }
        if (-not $ok) {
            $messages += ("{0} = {1}, expected {2} ({3})." -f $f.name, $actual, $expect, $f.meaning)
            if ($f.remedy) { $messages += ("  Fix: {0}" -f $f.remedy) }
        }
    }

    $out.Fields = $fields
    $hashMatches = ([string]$Baseline.setup_sha256 -eq $Setup.Sha256)
    $out.BaselineMatched = $hashMatches

    # Fields were declared and none of them could be read: same trap as a
    # length mismatch, so it gets the same answer rather than a clean bill.
    if ((@($Baseline.fields).Count -gt 0) -and ($fields.Count -eq 0)) {
        $out.Status = 'unknown-baseline'
        $out.NeedsAttention = $true
        $out.Messages = @($messages + 'No baseline field could be read from this varstore; power policy NOT verified.')
        return [pscustomobject]$out
    }

    if ($fieldDrift) {
        $out.Status = 'field-drift'
        $out.NeedsAttention = $true
        $out.Messages = $messages
        return [pscustomobject]$out
    }

    if (-not $hashMatches) {
        $out.Status = 'blob-drift'
        $out.NeedsAttention = $false
        $diffCount = -1
        try {
            $ref = [Convert]::FromBase64String([string]$Baseline.setup_base64)
            if ($ref.Length -eq $Setup.Length) {
                $diffCount = 0
                for ($i = 0; $i -lt $ref.Length; $i++) {
                    if ($ref[$i] -ne $Setup.Bytes[$i]) { $diffCount++ }
                }
            }
        } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
        $detail = if ($diffCount -gt 0) { ("{0} byte(s) differ" -f $diffCount) }
                  elseif ($diffCount -eq 0) { 'hash differs but the recorded bytes match -- the baseline entry is internally inconsistent' }
                  else { 'byte count unknown' }
        $out.Messages = @(
            ("BIOS setup differs from the baseline for this board ({0}); every known power-policy field is still correct." -f $detail),
            'Some other BIOS setting was changed. Not blocking, but worth knowing before this unit ships.'
        )
        return [pscustomobject]$out
    }

    $out.Status = 'match'
    $out.Messages = @()
    return [pscustomobject]$out
}

function Get-MastFirmwarePolicyState {
    <#
    .SYNOPSIS
      One call: read the varstore, find its baseline, classify. Both callers use this.
    #>
    [CmdletBinding()]
    param([string]$ScriptRoot = $PSScriptRoot)

    $setup = Get-MastFirmwareSetup
    $path = Get-MastFirmwareBaselinePath -ScriptRoot $ScriptRoot
    $baseline = $null
    if ($setup.Available) {
        $baseline = Get-MastFirmwareBaseline -Path $path -BaseboardProduct $setup.BaseboardProduct -BiosVersion $setup.BiosVersion
    }
    $state = Test-MastFirmwarePolicy -Setup $setup -Baseline $baseline
    Add-Member -InputObject $state -NotePropertyName 'BaselinePath' -NotePropertyValue $path -Force
    return $state
}
