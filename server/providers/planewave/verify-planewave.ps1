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
${pwi4Svc} = Get-Service -Name 'mast-pwi4' -ErrorAction SilentlyContinue
if ($null -eq ${pwi4Svc}) {
    [void]${issues}.Add('mast-pwi4 service not registered')
} elseif (${pwi4Svc}.Status -ne 'Running') {
    [void]${issues}.Add(("mast-pwi4 service registered but not running (status={0})" -f ${pwi4Svc}.Status))
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
# PWTools (portable utility bundle) extracted beside ps3cli; find PWTools.exe under it.
${pwToolsPath} = 'C:\Users\mast\Documents\PlaneWave\PWTools'
${pwToolsExe}  = Get-ChildItem -LiteralPath ${pwToolsPath} -Recurse -Filter 'PWTools.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not ${pwToolsExe}) {
    [void]${issues}.Add("PWTools.exe not found under ${pwToolsPath}")
}

# Real PlateSolve3 catalog: 'ps3cli --server' validates it at boot (see provide-planewave.ps1).
# Must match the file set the vendor installer lays down: UC4\Index.UC4 (non-empty) +
# 180 Z###.UC4 zone files + 39 Orca\*.orc (Orca / StarOrca / DistOrca).
${ps3CatalogPath}  = 'C:\Users\mast\Documents\Kepler'
${ps3MinUc4Zones}  = 180
${ps3MinOrcaFiles} = 39
${ps3IndexFile}    = Join-Path ${ps3CatalogPath} 'UC4\Index.UC4'
${ps3Index}        = Get-Item -LiteralPath ${ps3IndexFile} -ErrorAction SilentlyContinue
if ($null -eq ${ps3Index}) {
    [void]${issues}.Add(("PS3 catalog index missing: {0}" -f ${ps3IndexFile}))
} elseif (${ps3Index}.Length -lt 1) {
    [void]${issues}.Add(("PS3 catalog index is empty (ps3cli reads it at boot): {0}" -f ${ps3IndexFile}))
}
${ps3ZoneCount} = @(Get-ChildItem -LiteralPath (Join-Path ${ps3CatalogPath} 'UC4')  -Filter 'Z*.UC4' -File -ErrorAction SilentlyContinue).Count
${ps3OrcaCount} = @(Get-ChildItem -LiteralPath (Join-Path ${ps3CatalogPath} 'Orca') -Filter '*.orc'  -File -ErrorAction SilentlyContinue).Count
if (${ps3ZoneCount} -lt ${ps3MinUc4Zones}) {
    [void]${issues}.Add(("PS3 catalog UC4 zone files incomplete: {0} found, expected >= {1}" -f ${ps3ZoneCount}, ${ps3MinUc4Zones}))
}
if (${ps3OrcaCount} -lt ${ps3MinOrcaFiles}) {
    [void]${issues}.Add(("PS3 catalog Orca files incomplete: {0} found, expected >= {1}" -f ${ps3OrcaCount}, ${ps3MinOrcaFiles}))
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
