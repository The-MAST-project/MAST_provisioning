---
decided: 2026-08-19
status: accepted
issue: MAST_provisioning#54
areas:
  - operator tooling
  - drift
  - providers
---

# The operator's FastAPI shortcut lands on `/docs`, not the API root

**Why:** the `MAST Unit (FastAPI)` shortcut under `Desktop\MAST\Operations` pointed at `http://localhost:8000/`, which the unit does not serve: `create_app()` in MAST_unit registers `/favicon.ico`, the unit router and the component routers, and no root route, so the shortcut opened a bare `404 {"detail": "Not Found"}`. The operator-facing entry point to the unit API showed an error page.

The target was chosen when there was nothing better to offer. MAST_unit#39 has since applied contract-tier tags across the surface, so `/docs` renders the endpoints grouped by what a consumer may depend on, and MAST_unit#42 is trialing that page as the API's canonical live contract location. That is the page an operator wanting to drive a unit by hand should meet.

**What:** the `-FastApiUrl` argument in `server/providers/desktop-shortcuts/module.json` now reads `http://localhost:8000/docs`, in both the `command` and the `verify` line, with the provider's own default in `provide-desktop-shortcuts.ps1` and the `Operations\README.txt` text it writes moved to match. Five occurrences, no logic change.

The interesting part is that the drift machinery already covers it, and this is the first change to exercise that. `docs/per-module-tracking-plan.md` uses this exact repoint as its worked example, because the target lives in `module.json`'s `command` args rather than in any `commandfile` -- so a design that hashed only the payload bytes and verified only presence would have left the stale shortcut invisible to both. Both rules landed ahead of the change they were written for: `Get-ModuleContentHash` in `build/build-manifest-lib.ps1` folds `cmd:<command>` lines into each module's hash, and `verify-desktop-shortcuts.ps1` reads the deployed `URL=` line out of the `.url` file and compares it to the injected `-FastApiUrl`, reporting `FastAPI shortcut STALE` on a mismatch. A unit still carrying the root URL therefore drifts, re-runs only `desktop-shortcuts`, and can say which module was stale -- with no help from this change.

That coupling is also the trap: the URL is injected separately into `command` and into `verify`, and the two must move together. Left out of step, the module deploys one target and then fails its own currency check on every cycle afterwards.

The root 404 itself is fixed on the unit side -- `read_root` in `src/app.py` redirects `/` to `/docs`, and the same change corrects a `redocs_url` misspelling that had been leaving ReDoc served at `/redoc`. That is MAST_unit#170, recorded in that repo's `DECISIONS.md` under 2026-08-19 ("The API root redirects to `/docs`, and ReDoc is off for real"), which carries the alternatives weighed for the redirect. The two changes are independent: either alone gets an operator to a useful page.

**Rejected:** *leaving the shortcut on the root and relying on the unit-side redirect alone.* It would work, and it would make the shortcut's recorded target a name for something whose behavior lives in another repo -- so `verify-desktop-shortcuts.ps1` would go on asserting a URL nobody intends anyone to land on, and a reader of `module.json` could not tell what the shortcut opens. Naming the real destination costs nothing.

*Deriving the URL from the unit's hostname* (`http://<unit>:8000/docs`) instead of `localhost`, so the shortcut could be copied elsewhere. The shortcut exists on the unit's own Public desktop, reached over NoMachine in the unit's session; `localhost` is correct there and needs no per-unit injection.

**Unsettled:** the mast services ship manual-start and the unit service is presently launched by hand under the VS Code debugger, so the shortcut still meets a connection refusal whenever nothing is listening on 8000. This change improves the target, not the availability of what is behind it.

Nothing here was exercised on a unit: the repoint was reasoned from the provider sources and MAST_unit's route table, not observed. The first full cycle on a real unit is what will show the module drifting and re-running as described, and whether a unit whose `.url` still holds the root URL reports `FastAPI shortcut STALE` as expected.

Whether `/docs` should be reachable on a production unit at all -- it is an interactive client pointed at live hardware -- has not been asked. The epic's premise is that it should be.

**Implications:** anything else naming a unit's HTTP entry point can now say `/docs` and be consistent with both the shortcut and the bare root. The remaining `#54` items (the dark theme and the hostname wallpaper) are per-user desktop appearance and unrelated to this one.
