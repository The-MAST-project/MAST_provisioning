#requires -Version 5.1
[CmdletBinding()]
param(
    # The policy the fleet is provisioned to. RemoteSigned is the target: it runs
    # local unsigned scripts (every provider file is local) while still requiring a
    # signature on anything downloaded. Bypass would work too and is strictly
    # weaker, so it is not the default.
    [ValidateSet('RemoteSigned', 'AllSigned', 'Restricted', 'Unrestricted', 'Bypass')]
    [string]${Policy} = 'RemoteSigned'
)

# Set (and record) the machine-wide PowerShell ExecutionPolicy.
#
# This used to be a MANUAL step that bootstrap-winrm.ps1 only PRINTED, and it was
# skipped on mast04 (2026-07-07) and mast03 (2026-07-08) -- both then fixed by hand.
# A printed instruction is not a mechanism; a provider that runs every cycle is.
# See #51.
#
# Why the unit tolerates being wrong here for a long time without anyone noticing:
# every provisioning invocation passes -ExecutionPolicy Bypass, so a Restricted unit
# provisions fine and only breaks for anything running a bare `powershell -File`.
# That masking is the reason this needs its own verify rather than being assumed.
#
# THE TRAP (measured on mast03, PS 5.1.19041.4522):
#   Set-ExecutionPolicy writes the registry, THEN throws
#       System.Security.SecurityException  "Security error."
#       FullyQualifiedErrorId = ExecutionPolicyOverride,...SetExecutionPolicyCommand
#   whenever a MORE PERMISSIVE policy shadows the scope just written. Our own
#   -ExecutionPolicy Bypass puts Process=Bypass in exactly that position, so setting
#   LocalMachine=RemoteSigned throws EVERY time it succeeds. Observed directly:
#       setting LocalMachine -> RemoteSigned (registry now: Bypass)
#         THREW: Security error.   fqid: ExecutionPolicyOverride,...
#         registry after = RemoteSigned          <-- the write landed
#   So the outcome MUST come from reading the policy back, never from the absence of
#   an exception. Reporting the throw as failure would fail a provider that did its
#   job -- the mirror image of #38, where a throw was reported as success.
#
# This also explains why it looked like a step only a human could do: run
# interactively, Process is Undefined, nothing shadows the write, and no exception
# is raised. The automated path is the only one that throws.

${ErrorActionPreference} = 'Stop'

${logRoot}   = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\execution-policy-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\execution-policy-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

function Write-EpLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}
function Write-Smoke { param([string]${Value}) Set-Content -LiteralPath ${smokeFile} -Value ${Value} -Encoding ASCII }

# The full scope table, which is what makes a Group Policy override diagnosable
# instead of mysterious. MachinePolicy/UserPolicy come from GPO and CANNOT be set
# by us; if either is defined it wins over LocalMachine no matter what we write.
function Write-ScopeTable {
    param([string]${Label})
    foreach (${row} in (Get-ExecutionPolicy -List)) {
        Write-EpLog ("  {0}: {1} = {2}" -f ${Label}, ${row}.Scope, ${row}.ExecutionPolicy)
    }
}

Write-EpLog ("provide-execution-policy: target LocalMachine = {0}" -f ${Policy})
Write-ScopeTable -Label 'before'

${before} = (Get-ExecutionPolicy -Scope LocalMachine).ToString()

if (${before} -eq ${Policy}) {
    Write-EpLog ("LocalMachine is already {0}; nothing to do." -f ${Policy})
}
else {
    # Isolated EAP so the ExecutionPolicyOverride throw cannot escape and abort the
    # provider, and so a genuine failure is still caught and reported.
    ${prevEap} = ${ErrorActionPreference}
    try {
        ${ErrorActionPreference} = 'Continue'
        try {
            Set-ExecutionPolicy -ExecutionPolicy ${Policy} -Scope LocalMachine -Force
            Write-EpLog ("Set-ExecutionPolicy {0} returned without error." -f ${Policy})
        }
        catch [System.Security.SecurityException] {
            # Expected on every successful tighten under our Bypass wrapper. Not an
            # error: the write has already happened, the read-back below is the judge.
            if ($_.FullyQualifiedErrorId -like 'ExecutionPolicyOverride*') {
                Write-EpLog ("Set-ExecutionPolicy reported ExecutionPolicyOverride -- expected: " +
                             "a more permissive scope shadows LocalMachine in this process. " +
                             "The registry write is unaffected; confirming by read-back.")
            }
            else {
                Write-EpLog ("Set-ExecutionPolicy raised SecurityException ({0}): {1}" -f `
                             $_.FullyQualifiedErrorId, $_.Exception.Message)
            }
        }
        catch {
            Write-EpLog ("Set-ExecutionPolicy failed ({0}): {1}" -f `
                         $_.Exception.GetType().FullName, $_.Exception.Message)
        }
    }
    finally {
        ${ErrorActionPreference} = ${prevEap}
    }
}

# The only thing that decides the outcome.
${after} = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
Write-ScopeTable -Label 'after'

if (${after} -ne ${Policy}) {
    ${gpo} = @(Get-ExecutionPolicy -List |
        Where-Object { $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -ne 'Undefined' })
    if (${gpo}.Count -gt 0) {
        ${which} = (${gpo} | ForEach-Object { "{0}={1}" -f $_.Scope, $_.ExecutionPolicy }) -join ', '
        Write-EpLog ("FAIL: LocalMachine is {0}, wanted {1}, and Group Policy defines {2}. " -f ${after}, ${Policy}, ${which})
        Write-EpLog ("A GPO scope outranks LocalMachine and cannot be changed from here; " +
                     "this needs a domain-policy change, not a provisioning fix.")
    }
    else {
        Write-EpLog ("FAIL: LocalMachine is {0} after attempting to set {1}, with no Group Policy to explain it." -f ${after}, ${Policy})
    }
    Write-Smoke ("execution-policy_fail localmachine={0} wanted={1}" -f ${after}, ${Policy})
    exit 1
}

# Effective policy is what a bare `powershell -File` will actually honor. Under our
# own Bypass wrapper this reads Bypass, which is correct and not a finding -- it is
# reported so the log shows both the persisted setting and the in-process view.
${effective} = (Get-ExecutionPolicy).ToString()
Write-EpLog ("OK: LocalMachine = {0} (effective in this process = {1})" -f ${after}, ${effective})
Write-Smoke ("execution-policy_ok localmachine={0} effective={1}" -f ${after}, ${effective})
exit 0
