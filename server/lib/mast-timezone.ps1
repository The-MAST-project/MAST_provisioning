# Timezone id resolution for the provisioning driver.
#
# unit-registry.json stores IANA timezone ids (e.g. "Asia/Jerusalem") so the
# registry stays portable: .NET 6+ (PowerShell 7, or a future Linux prov
# server) resolves IANA ids natively via TimeZoneInfo.FindSystemTimeZoneById.
# But the driver runs under Windows PowerShell 5.1 (.NET Framework 4.x), whose
# TimeZoneInfo only knows Windows ids and has no TryConvertIanaIdToWindowsId.
# Without a mapping the lookup throws and check-and-provision.ps1 silently
# falls back to server-local time -- defeating maintenance-window enforcement
# (observed in production on mast01/mast03 2026-07-06:
# MAINT_TZ_WARN err=... 'Asia/Jerusalem' was not found). Map the IANA ids the
# fleet uses to Windows ids before resolving.
#
# The map is intentionally small (the zones the fleet actually uses). A raw
# Windows id in the registry still resolves via the direct path below, so both
# id styles are accepted.

$script:IanaToWindowsTimeZone = @{
    'Asia/Jerusalem'      = 'Israel Standard Time'
    'UTC'                 = 'UTC'
    'Etc/UTC'             = 'UTC'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'America/New_York'    = 'Eastern Standard Time'
    'Europe/London'       = 'GMT Standard Time'
}

function Resolve-TimeZoneInfo {
    # Resolve a timezone id to a [System.TimeZoneInfo], accepting either a
    # Windows id or an IANA id. Tries the id directly first (a valid Windows id,
    # or an IANA id under .NET 6+/Linux), then falls back to the IANA->Windows
    # map for .NET Framework 4.x (PowerShell 5.1). Throws if the id resolves
    # under neither path, so the caller can flag it rather than mis-timing a
    # maintenance window.
    param([Parameter(Mandatory)][string]$Id)

    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($Id)
    } catch {
        # Not resolvable directly (the .NET Framework / IANA case) -- fall
        # through to the IANA->Windows mapping below.
    }

    if ($script:IanaToWindowsTimeZone.ContainsKey($Id)) {
        $winId = $script:IanaToWindowsTimeZone[$Id]
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($winId)
    }

    throw "Unresolvable timezone id '$Id': not a valid Windows id and no IANA->Windows mapping is known."
}
