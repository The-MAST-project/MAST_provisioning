#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${InstallRoot}        = 'C:\cygwin64\usr\local\astrometry',
    [string]${SmokeFitsPath}      = 'C:\MAST\full-frame.fits',
    [string[]]${IndexSearchPaths} = @('D:\mast-indexes', 'C:\cygwin64\usr\local\astrometry\data'),
    [int]   ${SolveTimeoutSeconds} = 300
)

${ErrorActionPreference} = 'Stop'
${logRoot}   = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\astrometry-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\astrometry-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

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

# Put C:\cygwin64\bin and the astrometry bin on PATH up front. solve-field.exe
# links against cygwin1.dll + the package DLLs that astrometry-dependencies
# installed under C:\cygwin64\bin, and the banner check below invokes the
# binary directly. Without this prefix, even the banner exits with
# STATUS_DLL_NOT_FOUND (0xC0000135 / -1073741515) because the loader can't
# find cygwin1.dll. The same PATH also covers the forked /bin/sh children
# launched during the real plate solve below.
${env:PATH} = 'C:\cygwin64\bin;' + (Join-Path ${InstallRoot} 'bin') + ';' + ${env:PATH}

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
# on D:\mast-indexes (mounted at boot by the 'imdisk' provider at order
# 2300). If neither D: nor /usr/local/astrometry/data has any index files
# at the time this verify runs (which happens on a freshly-provisioned unit
# before the first reboot), we skip the solve, log a clear note, and mark
# the smoke as banner-only. That is intentional: smoke is a fast-path check
# of provider integrity, not a substitute for an end-to-end ops test.
# ---------------------------------------------------------------------------
Write-VLog "Smoke 2/2: real plate solve attempt"

if (-not (Test-Path ${SmokeFitsPath})) {
    Write-VLog ("SKIP: smoke FITS not present at {0}; provider smoke is banner-only." -f ${SmokeFitsPath})
    Set-Content -LiteralPath ${smokeFile} -Encoding ASCII `
        -Value ("astrometry_ok revision={0} solve=skipped reason=no_fits" -f ${revision})
    exit 0
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
    Write-VLog "SKIP: no astrometry index files reachable. Solve cannot run; provider smoke is banner-only."
    Write-VLog "      (After 'imdisk' provider runs and the unit reboots, D:\mast-indexes will be mounted and this smoke will exercise the full solve.)"
    Set-Content -LiteralPath ${smokeFile} -Encoding ASCII `
        -Value ("astrometry_ok revision={0} solve=skipped reason=no_indexes" -f ${revision})
    exit 0
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
Set-Content -LiteralPath ${cfgPath} -Encoding ASCII -Value @(
    'cpulimit 300',
    "add_path ${cygIndex}",
    'autoindex'
)
Write-VLog ("astrometry.cfg: cpulimit 300; add_path {0}; autoindex" -f ${cygIndex})

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
try { ${p2}.Refresh() } catch {}
${rc} = ${p2}.ExitCode
if ($null -eq ${rc}) {
    Write-VLog "FAIL: solve-field exit code was null"
    exit 1
}
if (${rc} -ne 0) {
    Write-VLog ("FAIL: solve-field exit={0}" -f ${rc})
    Write-VLog "--- stdout tail ---"
    Get-Content -LiteralPath ${solveOut} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
    Write-VLog "--- stderr tail ---"
    Get-Content -LiteralPath ${solveErr} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
    exit 1
}

# Success criterion: a .solved marker AND a non-trivial .wcs file with the
# same basename as the input FITS, written to $work (the -D directory).
${baseName}     = [IO.Path]::GetFileNameWithoutExtension(${SmokeFitsPath})
${solvedMarker} = Join-Path ${work} ("{0}.solved" -f ${baseName})
${wcsFile}      = Join-Path ${work} ("{0}.wcs" -f ${baseName})

if (-not (Test-Path ${solvedMarker})) {
    Write-VLog ("FAIL: {0} marker not produced (solver did not converge)" -f ${solvedMarker})
    Write-VLog "--- stdout tail ---"
    Get-Content -LiteralPath ${solveOut} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
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
