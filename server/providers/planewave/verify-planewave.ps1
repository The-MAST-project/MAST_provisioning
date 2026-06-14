#requires -Version 5.1
# PS3 CLI path must match provide-planewave.ps1. PWI4 path varies by vendor layout.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'planewave'
${ps3cliPath} = 'C:\Users\mast\Documents\PlaneWave\ps3cli'
${pwiCandidates} = @(
    'C:\Program Files (x86)\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe',
    'C:\Program Files\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe',
    'C:\Program Files\PlaneWave Instruments\PWI4\pwi4.exe',
    'C:\Program Files (x86)\PlaneWave Instruments\PWI4\pwi4.exe'
)
${pwi} = $null
foreach (${c} in ${pwiCandidates}) {
    if (Test-Path -LiteralPath ${c}) {
        ${pwi} = ${c}
        break
    }
}
${issues} = New-Object 'System.Collections.Generic.List[string]'
if (-not ${pwi}) {
    [void]${issues}.Add('PWI4.exe not found under expected PlaneWave paths.')
}
${pwi4Svc} = Get-Service -Name 'PWI4' -ErrorAction SilentlyContinue
if ($null -eq ${pwi4Svc}) {
    [void]${issues}.Add('PWI4 service not registered')
} elseif (${pwi4Svc}.Status -ne 'Running') {
    [void]${issues}.Add(("PWI4 service registered but not running (status={0})" -f ${pwi4Svc}.Status))
}
if (-not (Test-Path -LiteralPath ${ps3cliPath})) {
    [void]${issues}.Add("PS3 CLI directory missing: ${ps3cliPath}")
}
else {
    # The exe lands inside a dated build folder (e.g. ps3cli-2024-09-10), so search
    # recursively. Resolution must match _locate_ps3cli_dir() in MAST_unit/src/app.py.
    # Pick the largest ps3cli.exe: the special --server build (~4 MB) wins over any
    # stale older on-demand build (~10 KB) that a locked service may have left behind.
    ${exe} = Get-ChildItem -LiteralPath ${ps3cliPath} -Recurse -Filter 'ps3cli.exe' -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
    if (-not ${exe}) {
        [void]${issues}.Add("ps3cli.exe not found under ${ps3cliPath}")
    }
    elseif (${exe}.Length -lt 1MB) {
        # The older on-demand build is ~10 KB; the special --server build is ~4 MB.
        [void]${issues}.Add(("ps3cli.exe is the older on-demand build ({0} bytes) at {1}; expected the special --server build (>1MB)" -f ${exe}.Length, ${exe}.FullName))
    }
}
# Mock PlateSolve3 catalog: 'ps3cli --server' validates these at boot (see provide-planewave.ps1).
# Must match the file set provisioned there: UC4\Index.UC4 + three non-empty Orca\*.orc.
${ps3CatalogPath} = 'C:\Users\mast\Documents\Kepler'
${ps3RequiredFiles} = @(
    @{ Path = (Join-Path ${ps3CatalogPath} 'UC4\Index.UC4');        MustHaveBytes = $false },
    @{ Path = (Join-Path ${ps3CatalogPath} 'Orca\Orca0025.orc');     MustHaveBytes = $true  },
    @{ Path = (Join-Path ${ps3CatalogPath} 'Orca\StarOrca0025.orc'); MustHaveBytes = $true  },
    @{ Path = (Join-Path ${ps3CatalogPath} 'Orca\DistOrca0025.orc'); MustHaveBytes = $true  }
)
foreach (${rf} in ${ps3RequiredFiles}) {
    ${fi} = Get-Item -LiteralPath ${rf}.Path -ErrorAction SilentlyContinue
    if ($null -eq ${fi}) {
        [void]${issues}.Add(("PS3 mock catalog file missing: {0}" -f ${rf}.Path))
    } elseif (${rf}.MustHaveBytes -and ${fi}.Length -lt 1) {
        [void]${issues}.Add(("PS3 mock catalog file is empty (ps3cli reads it at boot): {0}" -f ${rf}.Path))
    }
}
# The mast-unit service runs as LocalSystem, so these Machine env overrides are what make
# ps3cli.exe and the catalog discoverable; without them app.py's home-based lookup fails.
${ps3DirEnv} = [Environment]::GetEnvironmentVariable('PS3CLI_DIR', 'Machine')
${ps3CatEnv} = [Environment]::GetEnvironmentVariable('PS3CLI_CATALOG', 'Machine')
if (-not ${ps3DirEnv}) { [void]${issues}.Add('PS3CLI_DIR machine env var not set') }
if (-not ${ps3CatEnv}) { [void]${issues}.Add('PS3CLI_CATALOG machine env var not set') }
if (${issues}.Count -gt 0) {
    (${issues} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
("PlaneWave OK: PWI4={0}" -f ${pwi}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'planewave' | Out-Null
exit 0
