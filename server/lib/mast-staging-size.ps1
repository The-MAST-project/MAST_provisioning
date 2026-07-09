# Staging-payload size accounting for the provisioning driver.
#
# The driver logs TRANSFER_START bytes and computes TRANSFER_PROGRESS pct/ETA
# against a pre-scan of the server-side staging tree. Get-ChildItem -Recurse
# does NOT descend directory junctions / reparse points, but robocopy on the
# unit copies THROUGH them -- e.g. the `mast-indexes` junction
# (-> C:\MAST\mast-indexes, the ~9.85 GB astrometry index seed). Counting the
# parent tree alone undercounted bytes_total (~3.6 GB) while the unit-side
# readback saw the full ~13.45 GB of real copied files, so TRANSFER_PROGRESS
# ran past 100% with negative ETAs (mast03/mast04, 2026-07). This helper adds
# each junction's contents by enumerating the junction path directly, so the
# denominator matches what robocopy actually moves.

function Get-StagingPayloadSize {
    # Returns @{ Bytes = <long>; Files = <int> } for $Path as robocopy would
    # copy it (descending through directory junctions). One level of junction
    # is resolved (the staging tree has leaf junctions only).
    param([Parameter(Mandatory)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue)
    $bytes = [long](($files | Measure-Object -Sum -Property Length).Sum)
    $count = $files.Count

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $junctions = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band $reparse) -eq $reparse })
    foreach ($j in $junctions) {
        $jf = @(Get-ChildItem -LiteralPath $j.FullName -File -Recurse -Force -ErrorAction SilentlyContinue)
        $bytes += [long](($jf | Measure-Object -Sum -Property Length).Sum)
        $count += $jf.Count
    }

    return @{ Bytes = $bytes; Files = $count }
}
