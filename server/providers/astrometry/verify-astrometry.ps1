#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${InstallRoot}        = 'C:\cygwin64\usr\local\astrometry',
    [string]${SmokeFitsPath}      = 'C:\MAST\full-frame.fits',
    [string[]]${IndexSearchPaths} = @('D:\mast-indexes', 'C:\cygwin64\usr\local\astrometry\data'),
    [int]   ${SolveTimeoutSeconds} = 300,
    # Dev-VM-only escape: when the guest CPU lacks AVX/AVX2/FMA, the prebuilt
    # astrometry-engine binary crashes with signal 4 (SIGILL) the moment real
    # solving starts. With -AllowMissingAvx, that specific failure (detected by
    # "killed by signal 4" / "SIGILL" in stderr) is treated as a SKIP with a
    # loud WARNING instead of a hard FAIL. build-mast.ps1 injects this only
    # when -TestMode is set; production runs MUST NOT pass it. Corrupt index
    # files are ALWAYS a hard FAIL -- this switch does not relax that.
    [switch]${AllowMissingAvx}
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'astrometry'
${smokeFile} = Get-MastSmokeMarker -Module 'astrometry'

function Write-VLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

# Fresh log
Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 `
    -Value ("[{0}] verify-astrometry.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${solveField} = Join-Path ${InstallRoot} 'bin\solve-field.exe'
if (-not (Test-Path ${solveField})) {
    Write-VLog ("FAIL: solve-field not found at {0}" -f ${solveField})
    exit 1
}

# Put C:\cygwin64\bin, the cygwin lapack lib dir, and the astrometry bin on
# PATH up front. solve-field.exe links against cygwin1.dll + the package DLLs
# that astrometry-dependencies installed under C:\cygwin64\bin, and the banner
# check below invokes the binary directly. Without C:\cygwin64\bin prefixed,
# even the banner exits with STATUS_DLL_NOT_FOUND (0xC0000135 / -1073741515)
# because the loader can't find cygwin1.dll.
#
# C:\cygwin64\lib\lapack must ALSO be prepended for solve-field's child
# removelines/uniformize processes. Those fork into python3 -> numpy ->
# numpy.linalg._umath_linalg, which dlopens cyglapack-0.dll. provide-
# astrometry-dependencies.ps1 adds this dir to *system* PATH at install time,
# but this verify runs in the same WinRM-spawned PS session that started
# BEFORE the system-PATH update, so the in-process $env:PATH wasn't
# refreshed. Without this prepend, the solve gets to "simplexy: found N
# sources" and then dies at removelines with
# "ImportError: No such file or directory" inside numpy._umath_linalg
# load -- looks like a SIGILL but isn't. Bit 2026-05-28 weizmann run #8.
# See [[project_astrometry_lapack_path]].
${env:PATH} = 'C:\cygwin64\bin;C:\cygwin64\lib\lapack;' + (Join-Path ${InstallRoot} 'bin') + ';' + ${env:PATH}

# ---------------------------------------------------------------------------
# Smoke 1: banner. solve-field with no args must exit 0 and print the
# version banner. Proves the binary loads, all DLL deps resolve, and the
# argument parser comes up.
# ---------------------------------------------------------------------------
Write-VLog "Smoke 1/2: solve-field banner check"
${bannerOut} = Join-Path ${env:TEMP} 'astro-banner-out.txt'
${bannerErr} = Join-Path ${env:TEMP} 'astro-banner-err.txt'
${p1} = Start-Process -FilePath ${solveField} `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput ${bannerOut} -RedirectStandardError ${bannerErr}
try { ${p1}.Refresh() } catch {}
if ($null -eq ${p1}.ExitCode) {
    Write-VLog "FAIL: solve-field banner exit code was null"
    exit 1
}
if (${p1}.ExitCode -ne 0) {
    Write-VLog ("FAIL: solve-field banner exit={0}" -f ${p1}.ExitCode)
    Write-VLog ("stderr: " + (Get-Content -LiteralPath ${bannerErr} -Raw -ErrorAction SilentlyContinue))
    exit 1
}
${banner} = Get-Content -LiteralPath ${bannerOut} -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty(${banner}) -or (${banner} -notmatch 'Revision\s+\S+')) {
    Write-VLog "FAIL: solve-field output did not contain 'Revision <n>'"
    Write-VLog ("first 200 chars: " + (${banner}.Substring(0, [Math]::Min(200, ${banner}.Length))))
    exit 1
}
${revision} = ([regex]'Revision\s+(\S+)').Match(${banner}).Groups[1].Value
Write-VLog ("PASS: banner OK, astrometry.net Revision {0}" -f ${revision})

# ---------------------------------------------------------------------------
# Smoke 2: real plate solve of C:\MAST\full-frame.fits.
#
# Requires (a) the FITS to be present, and (b) at least one astrometry index
# file reachable. The operational layout puts index-5202-* / index-5203-*
# on D:\mast-indexes, supplied as the imdisk file-backed image and mounted by
# the 'imdisk' provider (order 250, before this one) immediately in-session.
#
# These are HARD requirements, not skip conditions: a provisioning run that
# cannot run a real plate solve is not a valid run (the index image + smoke
# FITS must be staged and mounted). If the FITS or indexes are absent we FAIL
# so the gap is surfaced loudly rather than passing a banner-only green.
# ---------------------------------------------------------------------------
Write-VLog "Smoke 2/2: real plate solve (required)"

if (-not (Test-Path ${SmokeFitsPath})) {
    Write-VLog ("FAIL: smoke FITS not present at {0}. The full-frame FITS must be staged to the unit; a run without a real solve is not valid." -f ${SmokeFitsPath})
    exit 1
}

# Locate index files
${indexDir} = $null
foreach (${p} in ${IndexSearchPaths}) {
    if (Test-Path ${p}) {
        ${idxCount} = @(Get-ChildItem ${p} -Filter 'index-*.fits' -ErrorAction SilentlyContinue).Count
        Write-VLog ("  candidate index path {0}: {1} index files" -f ${p}, ${idxCount})
        if (${idxCount} -gt 0) {
            ${indexDir} = ${p}
            break
        }
    } else {
        Write-VLog ("  candidate index path {0}: missing" -f ${p})
    }
}
if ($null -eq ${indexDir}) {
    Write-VLog "FAIL: no astrometry index files reachable (checked: $(${IndexSearchPaths} -join ', '))."
    Write-VLog "      The index image must be staged and mounted (imdisk provider, order 250) BEFORE this verify runs."
    Write-VLog "      A provisioning run that cannot exercise a real plate solve is not a valid run."
    exit 1
}
Write-VLog ("Using index path: {0}" -f ${indexDir})

# Stage workdir
${work} = Join-Path ${env:TEMP} 'astro-smoke-solve'
if (Test-Path ${work}) { Remove-Item -LiteralPath ${work} -Recurse -Force }
${null} = New-Item -ItemType Directory -Path ${work} -Force

# Cygwin paths for the cfg
${cygWorkDrive}  = (${work}.Substring(0,1)).ToLower()
${cygWork}       = '/cygdrive/' + ${cygWorkDrive} + ((${work}.Substring(2)) -replace '\\','/')
${cygIndexDrive} = (${indexDir}.Substring(0,1)).ToLower()
${cygIndex}      = '/cygdrive/' + ${cygIndexDrive} + ((${indexDir}.Substring(2)) -replace '\\','/')

${cfgPath} = Join-Path ${work} 'astrometry.cfg'
# Write LF-only. This cfg is read by the cygwin solve-field/astrometry-engine;
# Set-Content (CRLF) leaves a trailing \r on "add_path <dir>\r" so opendir()
# fails silently and the solver reports "You must list at least one index in
# the config file" despite indexes being present. Use WriteAllText with \n.
${cfgText} = (@('cpulimit 300', "add_path ${cygIndex}", 'autoindex') -join "`n") + "`n"
[System.IO.File]::WriteAllText(${cfgPath}, ${cfgText}, (New-Object System.Text.ASCIIEncoding))
Write-VLog ("astrometry.cfg (LF): cpulimit 300; add_path {0}; autoindex" -f ${cygIndex})

# PATH was already pre-set near the top of this script (before the banner
# check); leaving the line above for back-compat with that earlier setup.

${solveOut} = Join-Path ${env:TEMP} 'astro-solve-out.txt'
${solveErr} = Join-Path ${env:TEMP} 'astro-solve-err.txt'

# Args picked for the mast00 full-frame:
#   8288 x 5644 pixels at ~0.09 arcsec/pix => ~12 arcmin (0.2 deg) field width.
#   --downsample 4 cuts work image to 2072 x 1411 for speed.
#   --scale-units arcsecperpix with a wide-but-bounded window covers the
#   mast00 plate scale and tolerates minor focus/temperature drift without
#   making the solver wander into impossible-scale space.
${solveArgs} = @(
    '--config', ${cfgPath},
    '--no-plots',
    '--no-verify',
    '--overwrite',
    '--downsample', '4',
    '--scale-units', 'arcsecperpix',
    '--scale-low',  '0.05',
    '--scale-high', '0.30',
    '-D', ${work},
    '-N', 'none',
    '--new-fits', 'none',
    ${SmokeFitsPath}
)

Write-VLog ("solve-field args: " + (${solveArgs} -join ' '))
${p2} = Start-Process -FilePath ${solveField} -ArgumentList ${solveArgs} `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput ${solveOut} -RedirectStandardError ${solveErr}
${finished} = ${p2}.WaitForExit(${SolveTimeoutSeconds} * 1000)
if (-not ${finished}) {
    try { ${p2}.Kill() } catch {}
    Write-VLog ("FAIL: solve-field timed out after {0}s" -f ${SolveTimeoutSeconds})
    exit 1
}
# The WaitForExit(ms) overload can return $true while ExitCode is momentarily
# unreadable ($null) under PS 5.1. A parameterless WaitForExit() after it flushes
# the redirected streams and guarantees ExitCode is populated, closing the race.
try { ${p2}.WaitForExit() } catch {}
try { ${p2}.Refresh() } catch {}
${rc} = ${p2}.ExitCode
if ($null -eq ${rc}) {
    ${baseNameTmp} = [IO.Path]::GetFileNameWithoutExtension(${SmokeFitsPath})
    if (Test-Path (Join-Path ${work} ("{0}.solved" -f ${baseNameTmp}))) {
        Write-VLog "WARN: solve-field exit code unreadable but .solved marker present; treating as success."
        ${rc} = 0
    } else {
        # Don't FAIL here yet. The SIGILL crash path on a CPU without AVX/AVX2/FMA
        # produces exactly this state (process gone before PS can read ExitCode,
        # no .solved marker written), and bailing now would bypass BOTH the
        # corrupt-index hard-FAIL check (lines ~231+) AND the SIGILL+
        # -AllowMissingAvx skip path (lines ~252+, ~274+) -- losing the dev-VM
        # escape and any chance of surfacing a corrupt index. Use a non-zero
        # sentinel so the downstream rc!=0 branch handles outcome:
        #   - if stderr names failed indexes -> hard FAIL (correct, no skip)
        #   - else if SIGILL + -AllowMissingAvx -> SKIP with avx_missing reason
        #   - else hard FAIL
        # This bit 2026-05-28 weizmann run #7 (vm/run-logs/run-20260528-141902).
        Write-VLog "WARN: solve-field exit code unreadable and no .solved marker; deferring outcome to corrupt-index + SIGILL checks below."
        ${rc} = -1
    }
}
function Get-FailedIndexFiles {
    # Scan solve-field stdout/stderr for any index the loader could not read
    # (corrupt FITS/kdtree). Returns the deduplicated list of offending paths.
    param([string]$StdoutPath, [string]$StderrPath)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($src in @($StdoutPath, $StderrPath)) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        foreach ($ln in (Get-Content -LiteralPath $src -ErrorAction SilentlyContinue)) {
            $m1 = [regex]::Match($ln, 'Failed to add index\s+"([^"]+)"')
            if ($m1.Success) {
                if (-not $hits.Contains($m1.Groups[1].Value)) { $hits.Add($m1.Groups[1].Value) }
                continue
            }
            $m2 = [regex]::Match($ln, 'Failed to load index from path\s+(\S+)')
            if ($m2.Success -and (-not $hits.Contains($m2.Groups[1].Value))) { $hits.Add($m2.Groups[1].Value) }
        }
    }
    return ,$hits
}
function Test-AvxSigill {
    # $true if stderr suggests the solve died from an illegal instruction --
    # the symptom when astrometry-engine hits AVX/AVX2/FMA on an SSE-only guest.
    param([string]$StderrPath)
    if (-not (Test-Path -LiteralPath $StderrPath)) { return $false }
    $t = Get-Content -LiteralPath $StderrPath -Raw -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    return ($t -match 'killed by signal 4\b' -or $t -match 'SIGILL')
}

# ---------------------------------------------------------------------------
# Highest-priority check: any index file the loader could not read is a HARD
# FAIL regardless of mode. The solver silently skips a corrupt index and
# converges via the others, so this is otherwise invisible behind a green
# solve. -AllowMissingAvx does NOT relax this. See DECISIONS.md 2026-05-28.
# ---------------------------------------------------------------------------
${failedIndexes} = Get-FailedIndexFiles -StdoutPath ${solveOut} -StderrPath ${solveErr}
if (${failedIndexes}.Count -gt 0) {
    Write-VLog "***************************************************************"
    Write-VLog ("[FAIL] {0} astrometry index file(s) FAILED TO LOAD during the solve:" -f ${failedIndexes}.Count)
    foreach (${fi} in ${failedIndexes}) { Write-VLog ("[FAIL]   {0}" -f ${fi}) }
    Write-VLog "[FAIL] The file(s) above are corrupt/unreadable (e.g. missing kdtree header)."
    Write-VLog "[FAIL] Rebuild or replace them in the index image before re-running."
    Write-VLog "--- offending solver lines ---"
    Get-Content -LiteralPath ${solveErr} -ErrorAction SilentlyContinue |
        Where-Object { ${_} -match 'kdtree|index_reload|engine_add_index|Failed to (add|load|read)' } |
        Select-Object -First 20 | ForEach-Object { Write-VLog ("  {0}" -f ${_}) }
    Write-VLog "***************************************************************"
    exit 1
}

if (${rc} -ne 0) {
    Write-VLog ("solve-field exited {0}; inspecting output." -f ${rc})
    Write-VLog "--- stdout tail ---"
    Get-Content -LiteralPath ${solveOut} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
    Write-VLog "--- stderr tail ---"
    Get-Content -LiteralPath ${solveErr} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
    if (${AllowMissingAvx} -and (Test-AvxSigill -StderrPath ${solveErr})) {
        Write-VLog "WARN: stderr contains 'signal 4' / SIGILL -- guest CPU lacks AVX/AVX2/FMA."
        Write-VLog "WARN: -AllowMissingAvx set (dev VM mode); treating astrometry solve as SKIPPED."
        Write-VLog "WARN: production runs on real MAST hardware MUST NOT pass -AllowMissingAvx."
        Set-Content -LiteralPath ${smokeFile} -Encoding ASCII `
            -Value ("astrometry_ok revision={0} solve=skipped reason=avx_missing" -f ${revision})
        exit 0
    }
    Write-VLog "FAIL: solve-field exited non-zero."
    exit 1
}

# Success criterion: a .solved marker AND a non-trivial .wcs file with the
# same basename as the input FITS, written to $work (the -D directory).
${baseName}     = [IO.Path]::GetFileNameWithoutExtension(${SmokeFitsPath})
${solvedMarker} = Join-Path ${work} ("{0}.solved" -f ${baseName})
${wcsFile}      = Join-Path ${work} ("{0}.wcs" -f ${baseName})

if (-not (Test-Path ${solvedMarker})) {
    Write-VLog ("solve-field returned 0 but {0} marker was not produced." -f ${solvedMarker})
    Write-VLog "--- stdout tail ---"
    Get-Content -LiteralPath ${solveOut} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
    if (${AllowMissingAvx} -and (Test-AvxSigill -StderrPath ${solveErr})) {
        Write-VLog "WARN: stderr SIGILL detected; -AllowMissingAvx -> skipping astrometry solve."
        Set-Content -LiteralPath ${smokeFile} -Encoding ASCII `
            -Value ("astrometry_ok revision={0} solve=skipped reason=avx_missing" -f ${revision})
        exit 0
    }
    Write-VLog "FAIL: solver did not converge."
    exit 1
}
if (-not (Test-Path ${wcsFile})) {
    Write-VLog ("FAIL: {0} not produced" -f ${wcsFile})
    exit 1
}
${wcsSize} = (Get-Item ${wcsFile}).Length
if (${wcsSize} -lt 1000) {
    Write-VLog ("FAIL: {0} too small ({1} bytes; expected a full FITS header)" -f ${wcsFile}, ${wcsSize})
    exit 1
}

# Pull a couple of WCS keywords for the smoke marker. listhead.exe ships
# with astrometry; if it is missing the .wcs presence/size check above
# still gates pass/fail.
${wcsSummary} = '(no listhead)'
${listhead} = Join-Path ${InstallRoot} 'bin\listhead.exe'
if (Test-Path ${listhead}) {
    ${cygWcs} = '/cygdrive/' + (${wcsFile}.Substring(0,1)).ToLower() + ((${wcsFile}.Substring(2)) -replace '\\','/')
    ${hdrOut} = & ${listhead} ${cygWcs} 2>&1
    ${ra}   = (${hdrOut} | Select-String -Pattern '^CRVAL1\s*=\s*([\-\d.E+]+)').Matches.Groups[1].Value
    ${dec}  = (${hdrOut} | Select-String -Pattern '^CRVAL2\s*=\s*([\-\d.E+]+)').Matches.Groups[1].Value
    if (${ra} -and ${dec}) { ${wcsSummary} = ("ra={0} dec={1}" -f ${ra}, ${dec}) }
}
Write-VLog ("PASS: solve converged. {0} = {1} bytes, {2}" -f (Split-Path -Leaf ${wcsFile}), ${wcsSize}, ${wcsSummary})

Set-Content -LiteralPath ${smokeFile} -Encoding ASCII `
    -Value ("astrometry_ok revision={0} solve=ok wcs_bytes={1} {2}" -f ${revision}, ${wcsSize}, ${wcsSummary})
Write-VLog "astrometry smoke OK"
exit 0
