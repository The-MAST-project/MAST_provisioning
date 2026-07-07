# Shared network/WinINet posture helpers for MAST providers.
#
# Dot-source with the standard two-path fallback (staging-flattened, then dev):
#   $_netDot = Join-Path $PSScriptRoot 'mast-net.ps1'
#   if (-not (Test-Path $_netDot)) { $_netDot = Join-Path $PSScriptRoot '..\..\lib\mast-net.ps1' }
#   . $_netDot

function Disable-WinINetCertRevocationCheck {
    # Turn OFF WinINet "check for server certificate revocation" for the current
    # user (HKCU). Returns the previous value so the caller can restore it.
    #
    # Why this exists: behind the Weizmann forward proxy (bcproxy), Windows
    # CryptoAPI revocation retrieval (cryptnet) cannot complete the CRL/OCSP
    # fetch through the proxy -- it returns ERROR_INVALID_PARAMETER (0x80070057)
    # / CRYPT_E_REVOCATION_OFFLINE even though ordinary HTTP(S) through the same
    # proxy works (curl, git, .NET all succeed). WinINet-based installers
    # (cygwin setup-x86_64.exe, Chrome's online stub) then HARD-fail the TLS
    # handshake with error 12057. git already does revocation best-effort, which
    # is why repo clones work; these installers do not. We make revocation
    # best-effort for the duration of such an install, scoped to the 'mast'
    # user's WinINet, and RESTORE it afterward via
    # Restore-WinINetCertRevocationCheck. See DECISIONS.md (2026-05-27).
    #
    # Returns: prior CertificateRevocation DWORD, or $null if it was unset.
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    $prev = $null
    try { $prev = (Get-ItemProperty -Path $k -Name 'CertificateRevocation' -ErrorAction Stop).CertificateRevocation } catch {}
    Set-ItemProperty -Path $k -Name 'CertificateRevocation' -Type DWord -Value 0
    return $prev
}

function Restore-WinINetCertRevocationCheck {
    # Restore the CertificateRevocation value captured by
    # Disable-WinINetCertRevocationCheck. $null restores the "unset" state.
    param([Parameter()] $Previous)
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    if ($null -eq $Previous) {
        Remove-ItemProperty -Path $k -Name 'CertificateRevocation' -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $k -Name 'CertificateRevocation' -Type DWord -Value ([int]$Previous)
    }
}
