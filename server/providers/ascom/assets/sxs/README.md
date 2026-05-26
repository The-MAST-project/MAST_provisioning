# Bundled NetFx3 SxS source - REQUIRED ASSET

This directory must contain the `microsoft-windows-netfx3-ondemand-package*`
.cab file (and the small companion `.mum` / `.cat` / `.xml` manifests) from
a matching **Windows IoT Enterprise LTSC 2024** installation image. The
ASCOM provider passes this directory to DISM as `-FoDSource` to enable
.NET Framework 3.5 from a deterministic local input.

## Why this is a required asset, not optional

The alternative is `dism.exe /Online /Enable-Feature` pulling NetFx3 from
the Windows Update CDN. That introduces three external dependencies into
every provisioning run:

1. Windows Update CDN reachability through whatever proxy mode the run
   chose (`--proxy-mode weizmann` or `--proxy-mode direct`).
2. CDN throughput at the moment of the run.
3. No transient 5xx from the CDN.

Runs #9..#12 showed online enable taking 5-8 minutes on a good day and
hanging indefinitely on a bad one. Bundling makes the input local and
deterministic; DISM still does the same enable work, just from a `/Source:`
path on disk. **Reliability matters more than the ~70 MB of repo budget**,
which is why this asset is mandatory in production builds.

## What to drop here

From a Windows IoT Enterprise LTSC 2024 ISO (build 10.0.26100.x), copy
the **entire contents** of `sources\sxs\` into this directory:

```
server/providers/ascom/assets/sxs/
  microsoft-windows-netfx3-ondemand-package~31bf3856ad364e35~amd64~~10.0.26100.<N>.cab
  microsoft-windows-netfx3-ondemand-package.cab     (sometimes a symlink or alias)
  <small .mum / .cat / .xml manifest files>
```

Use the SxS folder from a Windows IoT 11 LTSC 2024 image specifically.
DISM tolerates minor version skew but pinning to the OS version we
actually deploy to keeps the input set tight.

## How to verify the bundle is correct

```powershell
Get-ChildItem -LiteralPath . -Filter '*.cab' -Recurse
# Should list at least one microsoft-windows-netfx3-ondemand-package* file.
```

`build-mast.ps1` runs the equivalent check at build time. A missing or
empty SxS directory aborts the build with the message:

```
NetFx3 SxS source missing under '...\ascom\assets\sxs'. Drop the
Windows IoT 11 LTSC SxS files there (see provider README), or pass
-AllowMissingNetFx3Sxs for dev/test.
```

The dev/test override exists so the VirtualBox dev VM can build without
the SxS bundle on hand. `vm/run-prov-test.py` passes
`-AllowMissingNetFx3Sxs` automatically; when that override is in effect,
the provider falls back to the online DISM path with a one-line warning.
**Production builds (`server/check-and-provision.ps1`) do NOT pass the
override** -- the build fails loudly if the SxS bundle isn't present.

## Why not check the .cab into git

The .cab is ~70 MB and changes with each Windows servicing release. The
asset is operator-supplied at install time, the same way the NoMachine
`.lic` files and `vault/tokens/mast_github.txt` are. Source: official
Windows IoT 11 LTSC 2024 ISO from the Microsoft Volume Licensing Service
Center or equivalent.
