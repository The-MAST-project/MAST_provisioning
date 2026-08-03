#requires -Version 5.1
[CmdletBinding()]
param(
  [string]${InstallDir} = 'C:\Program Files\NoMachine'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'nomachine'

# A 'Running' nxservice is NOT proof the unit is reachable: when the 9.0.188
# session-history cleaner crashes nxserver.bin three times, nxservice stays
# Running while nxserver/nxnode/nxd are disabled and nothing listens on 4000.
# Verify the serving state, and the config that keeps the crash from recurring.
${NX_PORT} = 4000
${REQUIRED_CFG} = [ordered]@{
  SessionHistory  = '0'
  UpdateFrequency = '0'
}
# nxserver reports e.g. 'Thu Jul 01 15:47:19 CEST 2027'. The leading weekday and
# the timezone abbreviation are both stripped before parsing: 'ddd' would make
# ParseExact reject any date whose weekday disagrees, silently skipping the check.
${EXPIRY_FORMAT} = 'MMM dd HH:mm:ss yyyy'

${report}   = New-Object System.Collections.Generic.List[string]
${failures} = New-Object System.Collections.Generic.List[string]

${svcMatches} = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        ($PSItem.DisplayName -match 'NoMachine') -or ($PSItem.Name -match 'nx')
    })
if (${svcMatches}.Count -lt 1) {
    ${failures}.Add('NoMachine-related Windows service not found (expected nx* or display name containing NoMachine).')
} else {
    ${report}.Add((${svcMatches} | Select-Object Name, Status, DisplayName | Format-Table -AutoSize | Out-String))
}

${nxExe} = Join-Path ${InstallDir} 'bin\nxserver.exe'
if (-not (Test-Path -LiteralPath ${nxExe})) {
    ${failures}.Add("nxserver.exe not found at ${nxExe}.")
} else {
    ${status} = & ${nxExe} --status 2>&1
    ${report}.Add('nxserver --status:')
    ${status} | ForEach-Object { ${report}.Add("  $PSItem") }
    if (-not (${status} | Select-String -Pattern 'Enabled service:\s*nxd' -Quiet)) {
        ${failures}.Add('nxd is not enabled: the unit cannot accept NX connections. Restart the nxservice service to clear the crash-loop latch.')
    }
}

${listening} = @(Get-NetTCPConnection -State Listen -LocalPort ${NX_PORT} -ErrorAction SilentlyContinue)
if (${listening}.Count -lt 1) {
    ${failures}.Add("Nothing is listening on TCP ${NX_PORT} (NX protocol).")
} else {
    ${report}.Add("Listening on ${NX_PORT}: " + ((${listening} | ForEach-Object { $PSItem.LocalAddress }) -join ', '))
}

${cfgPath} = Join-Path ${InstallDir} 'etc\server.cfg'
if (-not (Test-Path -LiteralPath ${cfgPath})) {
    ${failures}.Add("server.cfg not found at ${cfgPath}.")
} else {
    ${cfgLines} = @(Get-Content -LiteralPath ${cfgPath})
    foreach (${key} in ${REQUIRED_CFG}.Keys) {
        ${want} = "${key} $(${REQUIRED_CFG}[${key}])"
        ${have} = @(${cfgLines} | Where-Object { $PSItem -match "^\s*${key}\s+-?\d+\s*$" })
        if (${have}.Count -lt 1) {
            ${failures}.Add("server.cfg: expected '${want}', found '<unset>'.")
        } elseif (${have}[0].Trim() -cne ${want}) {
            ${failures}.Add("server.cfg: expected '${want}', found '$(${have}[0].Trim())'.")
        } else {
            ${report}.Add("server.cfg: ${want}")
        }
    }
}

# Ask the server what it actually loaded rather than reading etc\server.lic: a
# certificate that is expired or rejected still leaves the file sitting on disk.
if (Test-Path -LiteralPath ${nxExe}) {
    ${sub} = & ${nxExe} --subscription 2>&1
    ${expiryMatch} = ${sub} | Select-String -Pattern 'Subscription expiry:\s*(.+?)\.?\s*$' | Select-Object -First 1
    if (-not ${expiryMatch}) {
        ${failures}.Add('nxserver --subscription reports no subscription expiry: no valid license is loaded.')
        ${report}.Add('nxserver --subscription:')
        ${sub} | ForEach-Object { ${report}.Add("  $PSItem") }
    } else {
        ${expiryRaw} = ${expiryMatch}.Matches[0].Groups[1].Value.Trim()
        ${report}.Add("subscription expiry: ${expiryRaw}")
        # Drop the leading weekday and the timezone abbreviation (.NET parses
        # neither usefully here), then compare. An unparseable date is reported
        # verbatim rather than failed, so a formatting quirk cannot fail a unit.
        ${stripped} = [regex]::Replace(${expiryRaw}, '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\s+', '')
        ${stripped} = [regex]::Replace(${stripped}, '\s+[A-Z]{2,5}\s+(\d{4})$', ' $1')
        ${parsedExpiry} = [datetime]::MinValue
        if ([datetime]::TryParseExact(${stripped}, ${EXPIRY_FORMAT},
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]${parsedExpiry})) {
            if (${parsedExpiry} -lt (Get-Date)) {
                ${failures}.Add("NoMachine subscription expired on ${expiryRaw}.")
            }
        } else {
            ${report}.Add('  (expiry not parsed for comparison; reported verbatim)')
        }
    }
}

if (${failures}.Count -gt 0) {
    ((@('FAILURES:') + (${failures} | ForEach-Object { "  - $PSItem" }) + @('', 'DETAIL:') + ${report}) -join [Environment]::NewLine) |
        Out-File -FilePath ${verifyLog} -Encoding UTF8
    ${failures} | ForEach-Object { Write-Warning $PSItem }
    exit 1
}

(${report} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'nomachine' | Out-Null
exit 0
