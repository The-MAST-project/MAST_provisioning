#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}  = ${PSScriptRoot},
    [string]${ZipName}     = 'gh_2.92.0_windows_amd64.zip',
    [string]${InstallRoot} = 'C:\Program Files\GitHub CLI'
)

<#
Install GitHub CLI from the official portable ZIP distribution.

Why not the MSI? The gh MSI invariably fails when run under a WinRM
network logon -- the MSI engine attempts to open
HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer
as part of its initial transaction setup, the network-logon token cannot
read that hive, and msiexec aborts with error 1402 / MainEngineThread
returning 2. Passing ALLUSERS=1 / MSIINSTALLPERUSER="" does not help:
the HKCU probe happens before the MSI properties are evaluated. We
verified this twice on 2026-05-25. The ZIP distribution side-steps
msiexec entirely; the result is byte-identical gh.exe.
#>

# --- Import shared helpers (PS 5.1 safe) ---
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        throw "provisioning.psm1 not found next to script or in ${provGlobal}"
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

function Get-InstalledGhExe {
    foreach (${p} in @(
        (Join-Path ${InstallRoot} 'bin\gh.exe'),
        (Join-Path ${env:ProgramFiles} 'GitHub CLI\bin\gh.exe'),
        (Join-Path ${env:ProgramFiles} 'GitHub CLI\gh.exe'),
        'C:\Program Files\GitHub CLI\bin\gh.exe',
        'C:\Program Files\GitHub CLI\gh.exe',
        'C:\Program Files (x86)\GitHub CLI\bin\gh.exe'
    )) {
        if (Test-Path -LiteralPath ${p}) { return ${p} }
    }
    return $null
}

${log} = Start-ProvisionLog -Component 'provide-gh'
try {
    ${existing} = Get-InstalledGhExe
    if (${existing}) {
        Write-Host ("GitHub CLI already present at {0}; ensuring PATH." -f ${existing})
        Add-ToSystemPath -Dir (Split-Path -Parent ${existing})
        exit 0
    }

    ${zipPath} = Join-Path ${AssetsRoot} ${ZipName}
    if (-not (Test-Path ${zipPath})) {
        throw "GitHub CLI ZIP not found: ${zipPath}"
    }

    # Extract straight to the canonical Program Files location. The ZIP
    # contains a top-level `bin\gh.exe` plus `share\` docs; Expand-Archive
    # preserves that structure, which matches what the MSI would have
    # produced.
    Confirm-Dir ${InstallRoot}
    Write-Host ("Extracting {0} -> {1} ..." -f ${zipPath}, ${InstallRoot})
    # Expand-Archive merges with existing dir; -Force overwrites collisions.
    Expand-Archive -Path ${zipPath} -DestinationPath ${InstallRoot} -Force

    ${ghExe} = Get-InstalledGhExe
    if (-not ${ghExe}) {
        # Show what landed for debugging.
        Get-ChildItem ${InstallRoot} -Recurse -ErrorAction SilentlyContinue |
            Select-Object FullName | Format-Table -AutoSize | Out-String | Write-Host
        throw "gh.exe not found under ${InstallRoot} after extraction."
    }

    Add-ToSystemPath -Dir (Split-Path -Parent ${ghExe})
    Write-Host ("GitHub CLI installed at {0}" -f ${ghExe})
}
finally {
    Stop-ProvisionLog
}
exit 0
