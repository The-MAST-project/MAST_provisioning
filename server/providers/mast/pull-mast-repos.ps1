param([string]$CloneRoot = 'C:\MAST\repos')

$gitExe = $null
foreach ($c in @(
    'C:\Program Files\Git\cmd\git.exe',
    'C:\Program Files\Git\bin\git.exe',
    'C:\Program Files (x86)\Git\cmd\git.exe'
)) { if (Test-Path $c) { $gitExe = $c; break } }
if (-not $gitExe) {
    $gc = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gc) { $gitExe = $gc.Source }
}
if (-not $gitExe) { throw 'git.exe not found' }
if (-not (Test-Path -LiteralPath $CloneRoot)) { throw "CloneRoot not found: $CloneRoot" }

$prevPrompt = $env:GIT_TERMINAL_PROMPT
$prevGcm    = $env:GCM_INTERACTIVE
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE     = 'false'
$failed = @()
try {
    foreach ($repo in @(Get-ChildItem -LiteralPath $CloneRoot -Directory -ErrorAction SilentlyContinue)) {
        $d = $repo.FullName
        if (-not (Test-Path -LiteralPath (Join-Path $d '.git'))) { continue }
        Write-Host "[pull-repos] $($repo.Name): pulling ..."
        $p = Start-Process -FilePath $gitExe -ArgumentList @('-C', $d, 'pull') -PassThru -Wait -WindowStyle Hidden
        try { $p.Refresh() } catch {}
        if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) {
            Write-Warning "FAIL $($repo.Name) pull rc=$($p.ExitCode)"
            $failed += $repo.Name; continue
        }
        if (Test-Path -LiteralPath (Join-Path $d '.gitmodules')) {
            $q = Start-Process -FilePath $gitExe -ArgumentList @('-C', $d, 'submodule', 'update', '--init', '--recursive') -PassThru -Wait -WindowStyle Hidden
            try { $q.Refresh() } catch {}
            if ($null -ne $q.ExitCode -and $q.ExitCode -ne 0) {
                Write-Warning "FAIL $($repo.Name) submodule rc=$($q.ExitCode)"
                $failed += $repo.Name; continue
            }
        }
        Write-Host "[pull-repos] $($repo.Name): OK"
    }
} finally {
    if ($null -ne $prevPrompt) { $env:GIT_TERMINAL_PROMPT = $prevPrompt } else { Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
    if ($null -ne $prevGcm)    { $env:GCM_INTERACTIVE = $prevGcm }        else { Remove-Item Env:\GCM_INTERACTIVE     -ErrorAction SilentlyContinue }
}
if ($failed.Count -gt 0) { throw "pull-repos failed: $($failed -join ', ')" }
Write-Host '[pull-repos] All repos pulled.'
exit 0
