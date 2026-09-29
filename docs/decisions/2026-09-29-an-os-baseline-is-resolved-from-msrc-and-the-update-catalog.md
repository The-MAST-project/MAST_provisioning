---
decided: 2026-09-29
status: accepted
issue: MAST_provisioning#15
areas:
  - os patching
  - reproducibility
  - storage
---

# An OS patch baseline is resolved from MSRC and the Update Catalog, and its target UBR is MSRC's FixedBuild

**Why.** #15 wants OS updates applied deliberately, to a pinned patch level, with automatic Windows Update left off. That needs a server-side answer to two questions no code here answered: *which update files define this month's patch level for build N*, and *where are those bytes*. Measured on 2026-09-29, every production unit checked (mast03, mast05, mast08) is Windows 10 IoT Enterprise LTSC 2021 at **19044.4529** -- the June 2024 factory image -- so the first baseline is also a 27-month jump.

**What.** `server/prov/os_updates.py`, driven by `server/data/os-builds.json`:

- **Which KB:** the MSRC CVRF feed (`api.msrc.microsoft.com/cvrf/v3.0`), filtered to vendor fixes (`Type` 2) for the product names declared per role (`lcu`, `dotnet`). `fix_for_product` requires exactly one KB per product per release and raises otherwise.
- **Target UBR:** the remediation's `FixedBuild` (`10.0.19044.7725` for KB5122878). The first plan was to derive it from the bytes by expanding the MSU and reading the `Package_for_RollupFix` identity; the feed already states it, and reading it there keeps the server free of a CAB extractor, which Python's stdlib lacks and which would be a per-platform dependency.
- **Which file:** the Update Catalog, which has no API. `parse_catalog_search` reads the result rows; `select_row` requires **exactly one** row whose title is `YYYY-MM <catalog_title> (KB<n>)`. The title is declared, not derived from the MSRC product name, because the two sources spell products differently (`for x64` versus `for x64-based Systems`), and an exact match is what excludes the ARM64, x86, 22H2 and `Dynamic` rows a KB search returns (9 rows for KB5122878). `parse_download_dialog` yields the URL and the SHA1 (the dialog's base64 `digest`, which matches the SHA1 embedded in the filename).
- **Fetch:** `fetch` downloads to `<cache>/server/providers/windows-updates/assets/<build>/<filename>` -- the repo-relative key #48's one asset rule would give the file -- via a `.part` file, verifies the SHA1 before `os.replace`, and skips the download when the destination already hashes right.
- **Propose:** `write_baseline` writes `server/data/os-baselines/<build>/<baseline_id>.json` with every file's sha1, sha256, size and key. A re-proposal with the same files is a no-op; one with different files raises rather than overwriting, because a baseline a unit may already be pinned to must not change under it.

HTTP is `urllib` from the stdlib: no runtime dependency is added, and `urllib` honors `HTTPS_PROXY` / the system proxy, which is how labcomp2 reaches out. From labcomp2 at the institute, both MSRC and the Catalog answered direct and via `bcproxy`, and the LCU downloaded at 14.5 MB/s direct and 18.2 MB/s via the proxy. A live `propose` from the Mac fetched both 19044 files (1.02 GB) in 54 s; a re-run took 13 s.

**The Catalog forgets.** Searching for KB5039211, the June 2024 LCU the fleet runs, returns `We did not find any results`. `parse_catalog_search` raises `NotInCatalogError` for that, and the tests pin it against the real response. The consequence is the reason the fetch keys files as assets: **a baseline's bytes can only come from our own copy once Microsoft withdraws the KB**, so they must be retained, not re-downloaded on demand.

**Rejected.**

- *An online Windows Update Agent scan to discover what a unit needs.* Non-deterministic, needs `wuauserv`, fights `windows-update-lockdown`. #15 had already ruled it out.
- *The offline `wsusscn2.cab`.* Still published, but large, security-only (Microsoft has acknowledged LCUs missing from it), and it too needs `wuauserv` startable. At most a cross-check, never the driver.
- *Deriving `target_ubr` from the MSU*, above.
- *A fuzzy Catalog match* ("contains 21H2 and x64, not Dynamic"). It would pick a new variant Microsoft adds next month without anyone noticing; the exact declared title fails loudly instead.
- *Declaring 26100 now.* The dev VM runs it, but it is not a patch target, and a row nobody exercises rots silently.

**Unsettled.**

- **Where the bytes are retained.** They land in the machine-wide asset cache under their asset key, but nothing yet declares them in `server/data/vendor-inputs.json` / `assets.json` or gets them into the content store on mast-ns-control. That is deliberately not in this change. The store's `gc` keeps a blob only while another name hardlinks it, and today that second name is the `/Storage/mast-vendor` view the 2026-09-27 asset-store record calls redundant and slated for retirement. A blob held only there would be collected when the view goes, so the retention mechanism needs choosing with that in mind. mast-ns-control was also down when this was written.
- **Committing a baseline JSON is the approval.** That is the intent recorded on #15. No code enforces it, and no baseline is committed with this change.
- **The .NET `FixedBuild` is recorded but unused.** It is a composite string (`2.0.50727.9183 & 3.0.30729.9169 & 4.8.4806.0`); stage 2 decides how a unit's .NET patch level is read and compared.
- **Catalog scraping is fragile by nature.** The row and dialog regexes are pinned to pages saved on 2026-09-29; a Catalog redesign breaks them loudly (no rows, or a dialog without exactly one file), not silently.
