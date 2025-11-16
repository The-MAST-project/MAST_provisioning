[CmdletBinding()]
param(
    [string]${Top} = "..",
    [string]${HostName} = "mast-test-vm"
)

${ErrorActionPreference} = "Stop"

# Resolve paths
${Top} = (Resolve-Path ${Top}).Path
${stagingRoot} = Join-Path ${Top} "staging"
${clientRoot} = Join-Path ${Top} "client"

# Create staging subdirectory for this host
${stagingPath} = Join-Path ${stagingRoot} ${HostName}
New-Item -ItemType Directory -Path ${stagingPath} -Force | Out-Null

Write-Host "Staging provisioning files for ${HostName}..."

# Copy client provisioning scripts
${executeScript} = Join-Path ${clientRoot} "execute-mast-provisioning.ps1"
if (Test-Path ${executeScript}) {
    Copy-Item ${executeScript} -Destination ${stagingPath} -Force
    Write-Host "Copied execute-mast-provisioning.ps1"
} else {
    Write-Warning "execute-mast-provisioning.ps1 not found at ${executeScript}"
}

# Create a launcher script for manual execution
${launcherPath} = Join-Path ${stagingPath} "Start-Provisioning.ps1"
@"
# Run MAST provisioning
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
& '.\\execute-mast-provisioning.ps1' -StagingPath '.'
"@ | Set-Content -Path ${launcherPath}
Write-Host "Created Start-Provisioning.ps1 launcher"

Write-Host ""
Write-Host "=========================================="
Write-Host "Provisioning staged for: ${HostName}"
Write-Host "Location: ${stagingPath}"
Write-Host "=========================================="
Write-Host ""
Write-Host "To provision on client, run:"
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File Z:\${HostName}\Start-Provisioning.ps1"
Write-Host ""
