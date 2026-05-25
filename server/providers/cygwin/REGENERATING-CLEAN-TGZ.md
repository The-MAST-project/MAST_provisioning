# Regenerating `cygwin64-clean.tgz`

`assets/cygwin64-clean.tgz` is the prebuilt minimal Cygwin tree that
`provide-cygwin.ps1` extracts to `C:\cygwin64`. It is **not** generated
by any provisioning step; it is built once by a developer and committed.
This document captures the recipe so the next time we need a fresh
baseline (Cygwin minor-version bump, replacement Cygwin signing key,
new mirror policy, etc.) we don't have to reverse-engineer it.

The previous in-tree helper `install-clean-cygwin.ps1` was a one-line
`setup-x86_64.exe --download` invocation -- it populated a package
download cache and was easy to mistake for "the script that builds the
clean tgz." It did not actually install Cygwin and was deleted on
2026-05-25 (see DECISIONS.md). The full recipe always lived in the
developer's head; it lives here now.

## When to regenerate

- Cygwin minor-version bump (e.g. 3.6.x -> 3.7.x). `cygwin1.dll` ABI is
  stable within a minor release; cross-minor mixing produces
  `STATUS_ENTRYPOINT_NOT_FOUND` at load time and is the failure mode
  this asset exists to prevent.
- Upstream Cygwin replaced its package-signing key and the bundled key
  in our copy no longer validates.
- The `astrometry-dependencies` provider has been updated to expect a
  newer baseline (e.g. a newer `cygwin` package version that the bundled
  `setup-x86_64.exe` can no longer install side-by-side).
- The Weizmann mirror (`cygwin.itefix.net`) has changed, or the proxy
  setup has changed, in a way that breaks the fixed `--site` /
  `--proxy` line below.

If none of those apply, do not regenerate. The tgz is large (~55 MB)
and churning it inflates the repo history.

## Inputs you need

- A clean Windows workstation, **not** the host you build MAST on day
  to day. The recipe wipes `C:\cygwin64-clean`; if you are using that
  path for anything else, change `--root` below to something disposable.
- Network access to `https://cygwin.itefix.net` (the Weizmann-blessed
  mirror) through `bcproxy.weizmann.ac.il:8080` -- or override both to
  match wherever you are building.
- A recent `setup-x86_64.exe` from `https://www.cygwin.com/setup-x86_64.exe`.
  The version already shipped under
  `server/providers/astrometry-dependencies/assets/setup-x86_64.exe`
  is fine.

## Step 1 -- Install a fresh minimal Cygwin

Run as administrator (the installer self-elevates anyway; running as
admin from the start avoids the UAC handoff that can lose network
state). The package list below is the minimal set that `provide-cygwin.ps1`
and the existing postinstall flow assume. Add packages here only if
something the provisioning pipeline actually needs at base-Cygwin time
(i.e. before `astrometry-dependencies` runs) is missing.

```powershell
# Adjust paths/proxy to your environment if needed.
$setup  = 'C:\Users\<you>\Downloads\setup-x86_64.exe'
$root   = 'C:\cygwin64-clean'
$site   = 'https://cygwin.itefix.net'
$proxy  = 'bcproxy.weizmann.ac.il:8080'
$cache  = Join-Path $root 'var\cache\setup'

# Baseline packages. setup-x86_64.exe resolves transitive deps automatically.
$packages = @(
    'cygwin',          # cygwin1.dll, core runtime
    'bash',            # /etc/postinstall/*.sh dispatcher
    'coreutils',       # ls, cat, etc. -- expected by provisioning scripts
    'dash',            # /usr/bin/dash, runs the postinstall fragments
    'tar',             # extraction during builds
    'xz',              # .tar.xz support for the manual install path
    'gzip'             # .tar.gz support
) -join ','

& $setup `
    --quiet-mode `
    --no-shortcuts --no-desktop --no-startmenu --no-write-registry `
    --root  $root `
    --site  $site `
    --proxy $proxy `
    --local-package-dir $cache `
    --packages $packages
```

Setup will exit 0 even if it elevated, downloaded nothing, and gave up
quietly. Always inspect `$root\var\log\setup.log.full` afterwards:

```powershell
Get-Content (Join-Path $root 'var\log\setup.log.full') -Tail 50
```

A successful run ends with `Ending cygwin install` and no
`connection error` / `out of retries` lines.

## Step 2 -- Drain Cygwin postinstall scripts (peflagsall + rebaseall)

This is the step that makes `fork()` reliable. Without it, packages we
extracted to random ASLR addresses, and any forked child (`solve-field`
calls `removelines`, `uniformize`, ...) crashes with
`child_info_fork::abort: Loaded to different address`.

```powershell
& "$root\bin\bash.exe" -lc @'
set -e
shopt -s nullglob
for f in /etc/postinstall/*.sh; do
  /usr/bin/dash "$f" || exit 1
  mv "$f" "$f.done"
done
exit 0
'@
```

(This is the same block used by `provide-cygwin.ps1` and
`provide-astrometry-dependencies.ps1` -- keep them aligned.)

## Step 3 -- Package the tree

The provisioning extractor expects the tgz to have a top-level
`./cygwin64-clean/` wrapper directory (see `provide-cygwin.ps1`:
"The tgz may contain a top-level "cygwin64" folder or the tree
directly"). Match that layout exactly so existing provisioning logic
keeps working.

```powershell
# Use a Cygwin tar built inside the new tree so the file modes serialize
# correctly. Cygwin's tar handles the Windows paths under --force-local.
$tgz = 'C:\Users\<you>\Desktop\cygwin64-clean.tgz'
$srcParent = Split-Path -Parent $root           # 'C:\'
$srcLeaf   = Split-Path -Leaf   $root           # 'cygwin64-clean'

& "$root\bin\bash.exe" -lc ("cd '/cygdrive/c' && tar --force-local -czf '" + ($tgz -replace '\\','/' -replace '^([A-Za-z]):','/cygdrive/$1') + "' '" + $srcLeaf + "'")
```

Verify the layout before committing:

```powershell
& "$root\bin\tar.exe" -tzf $tgz --force-local | Select-Object -First 5
# Expected output begins with:
#   ./cygwin64-clean/
#   ./cygwin64-clean/bin/
#   ./cygwin64-clean/bin/...
```

## Step 4 -- Smoke-test the regenerated tgz

In a fresh shell, extract the new tgz to a sandbox path and confirm
both `bash.exe` and `cygcheck.exe` run cleanly:

```powershell
$sandbox = "$env:TEMP\cygwin-clean-test"
Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $sandbox | Out-Null
& "$root\bin\tar.exe" -xzf $tgz --force-local -C ($sandbox -replace '\\','/' -replace '^([A-Za-z]):','/cygdrive/$1')

& "$sandbox\cygwin64-clean\bin\bash.exe" -lc 'uname -a; cygcheck -c cygwin | head -3'
```

The first line should report `CYGWIN_NT-10.0` and the package check
should show `cygwin` with status `OK`. If either fails, the postinstall
in Step 2 was incomplete -- re-run it before re-packaging.

## Step 5 -- Replace the asset

```powershell
Copy-Item $tgz `
    'C:\path\to\MAST_provisioning\server\providers\cygwin\assets\cygwin64-clean.tgz' `
    -Force
```

Then run the full provisioning suite on a disposable target VM end to
end -- the `astrometry` provider's verify step is the cheapest way to
catch a botched regeneration (its FITS smoke will explode if the new
`cygwin1.dll` is incompatible with the astrometry build).

## Historical: the original one-liner

For reference, the deleted `install-clean-cygwin.ps1` contained
exactly:

```powershell
.\setup-x86_64.exe --no-write-registry --download --no-desktop --no-shortcuts --no-startmenu --proxy bcproxy.weizmann.ac.il:8080 --root c:\cygwin64-clean --site https://cygwin.itefix.net --quiet-mode
```

Note the `--download` flag: that invocation downloaded the package
tarballs into a local cache under `c:\cygwin64-clean\var\cache\setup`
but did **not** install anything. The actual install + postinstall +
tar steps were always done by hand. Step 1 above is the install-mode
equivalent (no `--download`) of that line, with the package list made
explicit instead of relying on interactive chooser state.
