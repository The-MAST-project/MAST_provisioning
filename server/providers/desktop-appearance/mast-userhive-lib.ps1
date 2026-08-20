# Reach a local user's registry hive from code running as somebody else.
#
# Provisioning connects over WinRM as an administrator (or runs as SYSTEM), and
# some of what it must write is per-user: the theme and the wallpaper live under
# HKCU of the account that sees the desktop, which is the autologin 'mast' user
# and never the account doing the provisioning.
#
# Consumed by provide-desktop-appearance.ps1 (writes the values) and
# verify-desktop-appearance.ps1 (reads them back), so provisioning and its check
# resolve the hive exactly the same way.
#
# Two states are worth handling, and their order matters:
#
#   mounted  The user is signed in, so the hive is already at HKU\<sid> and
#            CANNOT be loaded again -- reg.exe load fails on a hive in use. On a
#            MAST unit this is the NORMAL state, not the exception: bootstrap
#            enables Winlogon auto-logon for 'mast' (2026-06-29 decision), so
#            from the first boot after bootstrap mast is signed in.
#   loaded   Nobody is signed in; the profile exists on disk, so its NTUSER.DAT
#            is loaded under a private mount key and unloaded again afterwards.
#
# There is deliberately no fallback to HKCU:. HKCU is the hive of whoever is
# RUNNING the script, so writing there reports success while configuring the
# wrong account -- the defect this file exists not to repeat. A caller that cannot
# reach the target hive is told so, loudly or by $null, and decides.
#
# That defect was client\bootstrap-winrm.ps1's Set-MastHkcu, and #106 removed it by
# moving those writes into this provider: bootstrap ran before the mast account had a
# profile at all, so no hive existed for it to reach and every write landed on the
# operator instead.
#
# This file defines functions and one mount-key constant -- dot-sourcing it reads
# nothing and changes nothing on the machine.

${script:MastHiveMountKey} = 'HKU\MAST_PROVISIONING_HIVE'

function Get-MastUserProfile {
    # SID + on-disk profile path for a local account, or $null when the account
    # does not exist or has never had a profile created (no ProfileList entry).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]${UserName})

    ${account} = Get-LocalUser -Name ${UserName} -ErrorAction SilentlyContinue
    if (-not ${account}) { return $null }

    ${sid} = ${account}.SID.Value
    ${profileKey} = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + ${sid}
    if (-not (Test-Path -LiteralPath ${profileKey})) { return $null }

    ${imagePath} = (Get-ItemProperty -LiteralPath ${profileKey}).ProfileImagePath
    if (-not ${imagePath}) { return $null }

    return [pscustomobject]@{ Sid = ${sid}; ProfilePath = ${imagePath} }
}

function Resolve-MastUserHive {
    # Returns an object carrying the registry Root to write under, or $null when
    # the account has no profile yet (a legitimate "nothing to do here": the
    # first-logon task is what covers that machine).
    #
    # Throws when the profile exists but the hive can be neither found mounted
    # nor loaded -- that is a real failure and must not be papered over, since
    # the only alternative is writing to the wrong user.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]${UserName})

    ${userProfile} = Get-MastUserProfile -UserName ${UserName}
    if (-not ${userProfile}) { return $null }

    ${mountedRoot} = 'Registry::HKEY_USERS\' + ${userProfile}.Sid
    if (Test-Path -LiteralPath ${mountedRoot}) {
        return [pscustomobject]@{
            Root     = ${mountedRoot}
            Sid      = ${userProfile}.Sid
            Source   = 'mounted'
            MountKey = ''
        }
    }

    ${dat} = Join-Path ${userProfile}.ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath ${dat})) {
        throw ("Resolve-MastUserHive: '{0}' has a ProfileList entry ({1}) but no NTUSER.DAT at {2}" -f ${UserName}, ${userProfile}.ProfilePath, ${dat})
    }

    ${output} = & reg.exe load ${script:MastHiveMountKey} ${dat} 2>&1
    if (${LASTEXITCODE} -ne 0) {
        throw ("Resolve-MastUserHive: reg.exe load of {0} failed (exit {1}): {2}" -f ${dat}, ${LASTEXITCODE}, (${output} -join ' '))
    }

    return [pscustomobject]@{
        Root     = 'Registry::' + (${script:MastHiveMountKey} -replace '^HKU\\', 'HKEY_USERS\')
        Sid      = ${userProfile}.Sid
        Source   = 'loaded'
        MountKey = ${script:MastHiveMountKey}
    }
}

function Close-MastUserHive {
    # Unload a hive this module loaded. A 'mounted' hive belongs to a signed-in
    # session and is left alone.
    [CmdletBinding()]
    param([Parameter(Mandatory)]${Hive})

    if (${Hive}.Source -ne 'loaded') { return }

    # PowerShell holds handles open on every key it has read or written, and
    # reg.exe unload fails while any remain -- so the hive would stay mounted
    # until the process exits. Collecting first is the documented way out.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    & reg.exe unload ${Hive}.MountKey 2>&1 | Out-Null
}

function Set-MastUserHiveValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]${Hive},
        [Parameter(Mandatory)][string]${SubKey},
        [Parameter(Mandatory)][string]${Name},
        [Parameter(Mandatory)]${Value},
        [Parameter(Mandatory)][ValidateSet('String', 'DWord')][string]${Type}
    )

    ${path} = Join-Path ${Hive}.Root ${SubKey}
    if (-not (Test-Path -LiteralPath ${path})) { New-Item -Path ${path} -Force | Out-Null }
    Set-ItemProperty -LiteralPath ${path} -Name ${Name} -Value ${Value} -Type ${Type} -Force
}

function Get-MastUserHiveValue {
    # The value, or $null when the key or the value is absent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]${Hive},
        [Parameter(Mandatory)][string]${SubKey},
        [Parameter(Mandatory)][string]${Name}
    )

    ${path} = Join-Path ${Hive}.Root ${SubKey}
    if (-not (Test-Path -LiteralPath ${path})) { return $null }
    ${item} = Get-ItemProperty -LiteralPath ${path} -Name ${Name} -ErrorAction SilentlyContinue
    if (-not ${item}) { return $null }
    return ${item}.${Name}
}
