#requires -Version 5.1
# The one definition of how git speaks HTTP on a MAST machine, shared by the
# provide and verify scripts so the values they write and the values they check
# cannot differ. tools/mast-clone.ps1 and tools/mast-clone.sh set the same values
# for their own processes; server/prov/tests/test_git_http_provider.py pins the
# three copies together.
#
# Through bcproxy, git's default HTTP/2 hangs a fetch forever once the tunnel is
# up (#220). HTTP/1.1 works; the low-speed pair turns any remaining stall into an
# error instead of a hang -- for a person in VS Code as much as for a script, and
# for verify-mast.ps1's own 'git ls-remote', which runs outside mast-clone.

${script:MastGitHttpConfig} = [ordered]@{
    'http.version'       = 'HTTP/1.1'
    'http.lowSpeedLimit' = '1000'
    'http.lowSpeedTime'  = '60'
}

function Get-MastGitExe {
    foreach (${p} in @((Join-Path ${env:ProgramFiles} 'Git\cmd\git.exe'), (Join-Path ${env:ProgramFiles} 'Git\bin\git.exe'))) {
        if (Test-Path -LiteralPath ${p}) { return ${p} }
    }
    throw 'git.exe not found under Program Files\Git; the git provider (order 700) installs it'
}

function Get-MastGitSystemValue {
    # The --system value, or $null when the key is unset. 'git config --get' exits 1
    # for an unset key, which is an answer here, not a fault -- so the preference is
    # forced for the call (see Get-ProbeExitCode in provide-python.ps1 for why).
    param([Parameter(Mandatory)][string]${GitExe}, [Parameter(Mandatory)][string]${Key})
    ${prev} = ${ErrorActionPreference}
    ${ErrorActionPreference} = 'SilentlyContinue'
    try {
        ${out} = & ${GitExe} config --system --get ${Key} 2>$null
        if (${LASTEXITCODE} -ne 0) { return $null }
        return ([string]${out}).Trim()
    }
    finally { ${ErrorActionPreference} = ${prev} }
}

function Get-MastGitHttpMismatches {
    # One line per key whose live --system value differs from the declared one;
    # empty when the machine matches.
    param([Parameter(Mandatory)][string]${GitExe})
    ${bad} = @()
    foreach (${key} in ${script:MastGitHttpConfig}.Keys) {
        ${want} = ${script:MastGitHttpConfig}[${key}]
        ${have} = Get-MastGitSystemValue -GitExe ${GitExe} -Key ${key}
        # Case-sensitive: git matches http.version with strcmp, so 'http/1.1' is an
        # unknown value it ignores, falling back to HTTP/2 and the hang.
        if (${have} -cne ${want}) {
            ${bad} += ("{0} = {1}, expected {2}" -f ${key}, $(if ($null -eq ${have}) { '(unset)' } else { ${have} }), ${want})
        }
    }
    return ,${bad}
}

function Set-MastGitHttpConfig {
    param([Parameter(Mandatory)][string]${GitExe})
    foreach (${key} in ${script:MastGitHttpConfig}.Keys) {
        & ${GitExe} config --system ${key} ${script:MastGitHttpConfig}[${key}]
        if (${LASTEXITCODE} -ne 0) { throw ("git config --system {0} failed with exit code {1}" -f ${key}, ${LASTEXITCODE}) }
    }
}
