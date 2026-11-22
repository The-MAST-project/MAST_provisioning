---
decided: 2026-11-19
status: accepted
areas:
  - astrometry
  - providers
  - archive extraction
---

# Cygwin tree symlinks are made by Cygwin's ln, not by Windows' tar

**Why:** `provide-cygwin.ps1` failed outright on a Windows 10 IoT Enterprise LTSC 2021 VM installed from the release ISO (build 19044.1288). Its `System32\tar.exe` is bsdtar 3.3.2, which cannot create symlinks, and `cygwin64-clean.tgz` holds 700 of them. Investigating that showed the fleet is damaged too, more quietly. On mast03 and mast08 (19044.4529, bsdtar 3.5.2) the extract had succeeded, but bsdtar wrote most relative links as copies of their targets, and every **absolute** link as an empty file. The archive has 313 absolute links:
- 296 under `/etc/pki` (the CA trust store);
- 10 under `/etc/crypto-policies`;
- `/etc/ssl/certs` and `/lib/security/cacerts` (the Java trust store);
- `/etc/hosts`, `/etc/services`, `/etc/protocols`, `/etc/networks` and `/etc/mtab`.

All 313 were empty files on both units. So were the relative links whose targets resolve only through Cygwin's own paths: `/lib/terminfo`, `/usr/libexec/p11-kit/trust-extract-compat` and `/usr/sbin/update-alternatives` were checked on mast03. A native Windows symlink could not hold those targets correctly in any case: Windows would resolve `/usr/...` against the drive root. `astrometry.tgz` goes through the same extract and holds one relative link (`bin/plotann.py`).

**What:** `server/lib/cygwin-archive.ps1` is shared by both providers.
- `Get-MastArchiveSymlinks` lists the archive's links with bsdtar's mtree writer (`--format=mtree --options 'mtree:!all,type,link'`), which gives one escaped entry per line.
- `Expand-MastArchiveWithoutSymlinks` extracts everything else, excluding the links with `-X`.
- `Restore-MastArchiveSymlinks` has Cygwin's `ln -s` create each link. It creates a link only where the path is missing or an empty regular file, and keeps an existing link, directory or non-empty file.
- The bash script is passed as a file, not with `-c`, because PowerShell 5.1 does not escape double quotes inside a native argument and the quoted script arrived cut in two.
- `provide-cygwin.ps1` runs the restore after robocopy, before postinstall. It also runs it on its "already healthy" skip path, so an ordinary `cygwin` module run repairs a unit extracted the old way.
- `provide-astrometry.ps1` uses the same three steps.

**Rejected:**
- **Patching the VM to the fleet's update level and leaving the code alone.** The fleet's own `tar` produced the damage above, and the units' exact update (KB5039211) is no longer in the Update Catalog.
- **Overwriting every link path on a run (`ln -sfn`).** That would replace the working copies, and any file a later package upgrade put at such a path (`astrometry-dependencies` runs Cygwin's `setup.exe --upgrade-also`), with the 2025 archive's link.
- **Installing the Cygwin base from the frozen package cache with `setup.exe`,** which creates its own links. It might retire `cygwin64-clean.tgz` outright. But whether the cache holds the base packages that did not change between 3.6.5 and 3.6.9 was not checked, and it is a larger change.
- **Parsing `tar -tv` output.** Its date and owner columns vary with locale and version; the mtree form does not.

**Unsettled:**
- Whether anything on a unit actually used the broken files. Cygwin's TLS trust store and `/etc/hosts` were empty, but nothing was traced to a failure from it.
- Repaired units keep their relative-link copies. They work, but `ls -l` shows files where the tree has links.
- The fix was run end to end only on bsdtar 3.5.2 (19044.3086), plus 3.7 and macOS's 3.5.3 for the listing and exclude steps. Release media's bsdtar 3.3.2 was not run with it.
- `REGENERATING-CLEAN-TGZ.md` checks the archive with Cygwin's own tar, which extracts links correctly, so it would not catch a link-bearing archive that Windows' tar mishandles.

**Implications:** the fleet is repaired by running the `cygwin` and `astrometry` modules on each unit, once this is merged. A fresh unit no longer depends on Windows' tar handling links.
