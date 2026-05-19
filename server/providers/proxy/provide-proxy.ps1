param(
    [string]${HttpProxy}  = "http://bcproxy.weizmann.ac.il:8080",
    [string]${HttpsProxy} = "http://bcproxy.weizmann.ac.il:8080",
    [string]${NoProxy}    = "10.23.3.0/24,10.23.4.0/24"
)

${ErrorActionPreference} = "Stop"

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "proxy-install.log"

function Write-ProxyLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-proxy.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# Match mastw: proxy env vars at machine scope so every subsequent provisioning
# step (git clone, pip install, choco, etc.) honors the Weizmann web proxy.
# These match the values observed on mastw (compare-mastw/GAPS.md, 2026-05-18).
try {
    ${pairs} = @(
        @{ Name = 'http_proxy';  Value = ${HttpProxy}  },
        @{ Name = 'https_proxy'; Value = ${HttpsProxy} },
        @{ Name = 'no_proxy';    Value = ${NoProxy}    }
    )

    foreach (${p} in ${pairs}) {
        ${name}  = ${p}.Name
        ${value} = ${p}.Value
        ${prev}  = [Environment]::GetEnvironmentVariable(${name}, 'Machine')
        if (${prev} -eq ${value}) {
            Write-ProxyLog ("{0} already set to expected value; skipping" -f ${name})
            continue
        }
        Write-ProxyLog ("Setting machine env: {0} = {1} (previous: {2})" -f ${name}, ${value}, ${prev})
        [Environment]::SetEnvironmentVariable(${name}, ${value}, 'Machine')
    }

    # Verification readback.
    foreach (${p} in ${pairs}) {
        ${current} = [Environment]::GetEnvironmentVariable(${p}.Name, 'Machine')
        if (${current} -ne ${p}.Value) {
            throw ("Machine env {0} did not stick: got '{1}', expected '{2}'" -f ${p}.Name, ${current}, ${p}.Value)
        }
    }

    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'proxy-smoke.txt') -Encoding UTF8 -Value 'proxy_ok'

    Write-ProxyLog "Proxy environment installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("Proxy provisioning failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
