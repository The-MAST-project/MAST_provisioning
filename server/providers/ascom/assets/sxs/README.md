# Bundled NetFx3 SxS source - REQUIRED ASSET

This directory holds **one subdirectory per Windows build**, each containing
the `microsoft-windows-netfx3-ondemand-package*` .cab (and its companion
manifests) taken from an installation image of that build:

```
sxs/
  19044/   Windows 10 LTSC 2021  -- mast01..mast06 and every production unit
  26100/   Windows 11 IoT Enterprise LTSC 2024 -- the dev VM (MAST-WIS-01)
```

The subdirectory name is the OS build number, matching
`[Environment]::OSVersion.Version.Build` exactly. `provide-ascom.ps1` selects
the directory for the build it is running on and passes **that** path to DISM
as `-FoDSource`.

**Why per-build and not one flat directory:** the cab filename encodes no
version -- `microsoft-windows-netfx3-ondemand-package~31bf3856ad364e35~amd64~~.cab`
is the name on both 19044 and 26100 -- so a flat directory can only hold one,
and the other silently wins. Shipping the 26100 payload to a 19044 fleet is
exactly what #124 was: DISM answered `0x800f081f, the source files could not
be found` with the source present and readable, because it was the wrong
generation.

**The payload is build-specific, not edition-specific.** The 19044 cab here
came from a Windows 10 *consumer* medium (build 19041.3803) and enables NetFx3
on Windows 10 IoT Enterprise LTSC 19044 -- verified on mast06, which went
`DisabledWithPayloadRemoved` to `Enabled`, DISM exit 3010. Any medium in the
same servicing family will do; it does not have to be the LTSC SKU.

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

Run `fetch-from-iso.ps1 -Build <build> -IsoPath <iso>`; it mounts the image,
copies the NetFx3 payload out of `sources\sxs\` into `sxs\<build>\`, and
verifies a cab landed. Do **not** copy the entire contents of `sources\sxs\`
by hand -- that is how two unused Internet Explorer packages ended up bundled
and staged onto every unit (removed in PR #126).

For reference, the older manual route was:

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
**Production builds (the driver without `--test-mode`) do NOT pass the
override** -- the build fails loudly if the SxS bundle isn't present.

## Why not check the .cab into git

The .cab is ~70 MB and changes with each Windows servicing release. The
asset is operator-supplied at install time, the same way the NoMachine
`.lic` files are. Source: official
Windows IoT 11 LTSC 2024 ISO from the Microsoft Volume Licensing Service
Center or equivalent.
