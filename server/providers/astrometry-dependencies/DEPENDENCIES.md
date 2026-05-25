# Astrometry.net Cygwin dependency reference

This file lists every Cygwin package whose runtime DLLs the astrometry.net
binaries link against. It is the canonical input for the `setup-x86_64.exe -P`
list used during host provisioning, and the source of truth for what must be
present in `C:\cygwin64\bin\` before `astrometry.tgz` is expanded.

The list was derived on 2026-05-25 by:

1. Running `cygcheck <bin>` over every executable and shared library under
   `/usr/local/astrometry/` after a clean build of astrometry.net 0.97.
2. Collecting the transitive DLL closure and mapping each `cyg*.dll`
   basename to its owning Cygwin package via `setup.ini` (the `install:`
   line that ships that DLL under `usr/bin/`).

Versions below are the ones the build was validated against. Cygwin
maintains ABI compatibility within a minor release; you do not need to
pin to these exact patch levels at install time, but `setup-x86_64.exe`
will of course always pull the current upstream version unless you point
it at a frozen mirror snapshot.

## Direct dependencies (linked by the astrometry binaries themselves)

| Package           | Version        | Provides                  | Notes                                      |
|-------------------|----------------|---------------------------|--------------------------------------------|
| `cygwin`          | 3.6.9-1        | `cygwin1.dll`             | Cygwin runtime; ABI-compat host required.  |
| `libcfitsio10`    | 4.6.4-1        | `cygcfitsio-10.dll`       | FITS I/O. Used by solve-field and friends. |
| `libwcs4`         | 4.18-1         | `cygwcs-4.dll`            | WCSLIB; world-coordinate-system math.      |
| `libnetpbm10`     | 10.80.00-1     | `cygnetpbm-10.dll`        | PNM utilities linked deps.                 |
| `libcairo2`       | 1.18.4-1       | `cygcairo-2.dll`          | Plot rendering (plot-constellations etc.). |
| `libpng16`        | 1.6.47-2       | `cygpng16-16.dll`         | PNG output for plot tools.                 |
| `libjpeg8`        | 3.1.4.1-1      | `cygjpeg-8.dll`           | JPEG support.                              |
| `python39`        | 3.9.16-1       | `libpython3.9.dll`        | Required by the SWIG-generated `_*.dll`s.  |

## Runtime PATH-resolved helpers (not linked, but solve-field forks them)

These are **not** discoverable via `cygcheck` since `solve-field` invokes them
through `/bin/sh -c <tool>`, not via dynamic linking. They must be enumerated
explicitly in the package list. Missing them produces failures like
`pnmfile: command not found` or `ImportError: No such file or directory`
mid-solve -- hours of debugging if you didn't know to look here.

| Package          | Provides (runtime)                  | Why                                                            |
|------------------|-------------------------------------|----------------------------------------------------------------|
| `netpbm`         | `pnmfile`, `pnmtofits`, `jpegtopnm` | `solve-field` calls `pnmfile` to identify uploaded image data. |
| `python39-numpy` | `numpy.linalg` + extensions         | `removelines` and `uniformize` are Python helpers in `solve-field`'s pipeline; they `import numpy.linalg`. |

## Transitive dependencies (pulled in by the above)

### cfitsio's remote-fetch chain (curl + auth)

| Package              | Version    | Provides                              |
|----------------------|------------|---------------------------------------|
| `libcurl4`           | 8.20.0-1   | `cygcurl-4.dll`                       |
| `libnghttp2_14`      | 1.69.0-1   | `cygnghttp2-14.dll`                   |
| `libssh2_1`          | 1.11.0-1   | `cygssh2-1.dll`                       |
| `libssl3`            | 3.5.6-1    | `cygssl-3.dll`, `cygcrypto-3.dll`     |
| `libssl1.1`          | 1.1.1w-1   | `cygcrypto-1.1.dll`                   |
| `libgssapi_krb5_2`   | 1.15.2-2   | `cyggssapi_krb5-2.dll`                |
| `libkrb5_3`          | 1.15.2-2   | `cygkrb5-3.dll`                       |
| `libkrb5support0`    | 1.15.2-2   | `cygkrb5support-0.dll`                |
| `libk5crypto3`       | 1.15.2-2   | `cygk5crypto-3.dll`                   |
| `libcom_err2`        | 1.44.5-1   | `cygcom_err-2.dll`                    |
| `libopenldap2`       | 2.6.13-1   | `cyglber-2.dll`, `cygldap-2.dll`      |
| `libsasl2_3`         | 2.1.27-1   | `cygsasl2-3.dll`                      |
| `libidn2_0`          | 2.3.8-1    | `cygidn2-0.dll`                       |
| `libpsl5`            | 0.21.5-1   | `cygpsl-5.dll`                        |
| `libunistring5`      | 1.4.1-1    | `cygunistring-5.dll`                  |
| `libbrotlicommon1`   | 1.2.0-1    | `cygbrotlicommon-1.dll`               |
| `libbrotlidec1`      | 1.2.0-1    | `cygbrotlidec-1.dll`                  |

### Cairo's font/X11 chain (plot tools)

| Package              | Version    | Provides                              |
|----------------------|------------|---------------------------------------|
| `libpixman1_0`       | 0.46.4-1   | `cygpixman-1-0.dll`                   |
| `libfreetype6`       | 2.13.3-1   | `cygfreetype-6.dll`                   |
| `libfontconfig1`     | 2.18.0-1   | `cygfontconfig-1.dll`                 |
| `libexpat1`          | 2.8.0-1    | `cygexpat-1.dll`                      |
| `libX11_6`           | (latest)   | `cygX11-6.dll`                        |
| `libXau6`            | (latest)   | `cygXau-6.dll`                        |
| `libXdmcp6`          | (latest)   | `cygXdmcp-6.dll`                      |
| `libXext6`           | (latest)   | `cygXext-6.dll`                       |
| `libXrender1`        | (latest)   | `cygXrender-1.dll`                    |
| `libxcb1`            | 1.17.0-2   | `cygxcb-1.dll`                        |
| `libxcb-render0`     | 1.17.0-2   | `cygxcb-render-0.dll`                 |
| `libxcb-shm0`        | 1.17.0-2   | `cygxcb-shm-0.dll`                    |

### Base runtime (compression, charset, libgcc)

| Package    | Version    | Provides              | In `cygwin64-clean.tgz` today? |
|------------|------------|-----------------------|--------------------------------|
| `libbz2_1` | 1.0.8-2    | `cygbz2-1.dll`        | yes                            |
| `zlib0`    | 1.3.2-1    | `cygz.dll`            | yes                            |
| `libzstd1` | 1.5.7-1    | `cygzstd-1.dll`       | yes                            |
| `libiconv2`| 1.19-2     | `cygiconv-2.dll`      | yes                            |
| `libintl8` | 0.22.5-1   | `cygintl-8.dll`       | yes                            |
| `libgcc1`  | 13.4.0-1   | `cyggcc_s-seh-1.dll`  | yes                            |

(`libssl3` and `libssl1.1` are also already in `cygwin64-clean.tgz`. `cygwin`
itself is too. Of the 42 distinct packages above, 9 are already in
`cygwin64-clean.tgz` and 33 must be added.)

## One-line setup-x86_64.exe invocation

```cmd
setup-x86_64.exe ^
  --root C:\cygwin64 ^
  --site https://cygwin.itefix.net ^
  --proxy bcproxy.weizmann.ac.il:8080 ^
  --no-shortcuts --no-desktop --no-startmenu --no-write-registry ^
  --quiet-mode ^
  --packages cygwin,libcfitsio10,libwcs4,libnetpbm10,libcairo2,libpng16,libjpeg8,python39,libcurl4,libnghttp2_14,libssh2_1,libssl3,libssl1.1,libgssapi_krb5_2,libkrb5_3,libkrb5support0,libk5crypto3,libcom_err2,libopenldap2,libsasl2_3,libidn2_0,libpsl5,libunistring5,libbrotlicommon1,libbrotlidec1,libpixman1_0,libfreetype6,libfontconfig1,libexpat1,libX11_6,libXau6,libXdmcp6,libXext6,libXrender1,libxcb1,libxcb-render0,libxcb-shm0,libbz2_1,zlib0,libzstd1,libiconv2,libintl8,libgcc1
```

Cygwin's `setup-x86_64.exe` resolves dependencies recursively, so listing
only the top-level packages (`libcfitsio10`, `libwcs4`, `libnetpbm10`,
`libcairo2`, `libpng16`, `libjpeg8`, `python39`) is enough in practice for
the linked-DLL closure. The full 42-package list above exists so the install
is deterministic and reproducible without trusting upstream dep metadata to
be stable across Cygwin point releases.

`netpbm` and `python39-numpy` are *not* in any of those transitive trees
because nothing links against them at build time -- they are only invoked
at runtime via PATH. They must be listed explicitly.

## How to regenerate this list

After any rebuild of astrometry.net (new upstream version, different
configure flags, or different Cygwin minor release), regenerate by running
the host-side helper script:

```
bash C:\Users\labcomp2\Desktop\MAST\collect-dll-deps.sh
bash C:\Users\labcomp2\Desktop\MAST\map-dlls-final.sh
```

The first emits `/tmp/dll-deps/cyg-dlls.txt` (the closed-over DLL set);
the second maps each entry to its owning Cygwin package via the cached
`setup.ini`. Update the tables above if the closure changed.

## Smoke test

After provisioning (setup.exe install + astrometry.tgz expansion), this
must exit 0 and print the version banner:

```cmd
C:\cygwin64\usr\local\astrometry\bin\solve-field.exe
```

Expected first lines of output:

```
ERROR: You didn't specify any files to process.
This program is part of the Astrometry.net suite.
For details, visit http://astrometry.net.
Git URL https://github.com/dstndstn/astrometry.net
Revision 0.97, date Mon_Dec_2_14:50:59_2024_-0500.
```

A non-zero exit (especially -1073741511 = STATUS_ENTRYPOINT_NOT_FOUND or
exit 127) indicates a DLL is missing or a version mismatch between
`cygwin1.dll` and the rest. In that case re-run `cygcheck` against
solve-field and re-derive the package list.
