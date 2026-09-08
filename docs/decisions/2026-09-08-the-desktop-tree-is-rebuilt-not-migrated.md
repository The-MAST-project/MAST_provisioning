---
decided: 2026-09-08
status: accepted
issue: MAST_provisioning#191
areas:
  - operator tooling
  - providers
  - fleet migration
---

# Desktop\MAST is rebuilt from scratch, and Vendor is the one folder that is not

**Why:** the desktop layout needed four changes at once — a folder renamed, tools promoted out of `Vendor` into class folders, web shortcuts re-pointed through Chrome, and two shortcuts added — and every one of them implies a migration step for the units that already carry the old tree. A chain of adopt-and-remove blocks is dead code the moment the fleet has converted, and the provider already carried one: `${legacyNames}`, six hard-coded names from the pre-`MAST\` layout, still running on every unit years after the layout it referred to.

**What was decided:** the provider **clears `Desktop\MAST` and rebuilds it** on every run it touches. Shortcuts are derived state — each one points at something installed elsewhere — so recreating them is cheaper than tracking how the tree got to where it is. A rename then needs no migration step, `${legacyNames}` is deleted rather than extended, and the sweep's name-to-folder map subsumes it: a stray at a desktop root whose name the provider owns is deleted rather than swept into `Vendor` as a duplicate of the one just placed.

Four things make that safe rather than destructive:

- **The contents are cleared, not the folder.** An Explorer window sitting on `Desktop\MAST` holds the directory itself and would fail a recursive remove — the same class of collision as #190, with a different holder. Its children are not held that way. This replaced an earlier plan to build `Desktop\MAST.new` and rename over the old tree, which reintroduces the delete it was meant to avoid.
- **`Vendor` survives.** It is the one folder holding files this script did not make. A shortcut swept there came from a third-party installer that has already run and is idempotent — chrome skips on `chrome.exe`, zwo on `ASIStudio.exe`, vscode on `Code.exe` — so wiping it destroys something nothing can put back. **Measured, not reasoned:** the first VM run of the rebuild deleted `ProfileExplorer.lnk` and left `Vendor` holding nothing but its README. Only names the provider has since promoted into a class folder are pruned from it.
- **A promoted third-party tool is created from the resolved exe, never inherited from the sweep.** That is what lets `Vendor` be preserved and the class folders still be authoritative, and it is the only way PWI4 or ASICap can appear in `MAST Unit Operation` on a unit whose installers all ran months ago. Paths are resolved at run time and a missing tool is a `[WARN]`, not a failure — mast06 ran 13 days with a missing ZWO ASCOM registration (#188), so per-unit variance is demonstrated rather than hypothetical.
- **The bootstrap report is dropped.** `MAST Bootstrap Report.txt` was the one non-derived file inside the class folders: `client/bootstrap.ps1` writes it once at first touch and nothing regenerates it, since `bootstrap-reassert` returns at the `-ReassertOnly` branch long before the writer and the writer is not one of the nine re-assertable elements. Its content — MACs for the DHCP reservations, the BIOS power checklist, the provisioning handoff steps — is all spent by the time a unit is provisioned; on mast01 the report is dated 2026-07-06 against READMEs dated 2026-09-02. Bootstrap now always writes it to the desktop root, where an operator reads it before provisioning, and the sweep removes it afterwards. The `bootstrap.log` it was rendered from stays under `C:\MAST\logs`.

**Implications:**

- **Anything a person leaves in a class folder is removed on the next run**, and the folder READMEs now say so. `Vendor` is where a hand-placed shortcut survives.
- **Web shortcuts are `.lnk` files launching `chrome.exe` with the URL as an argument**, because nothing in provisioning sets a default browser and the unit resolves `http` to IE, which cannot render the Swagger page. They fall back to a plain `.url` where Chrome is absent — a shortcut that opens in the wrong browser still opens. `verify-desktop-shortcuts.ps1`'s staleness check reads the `.lnk`'s `Arguments` and accepts either form; left reading the `.url` INI it would have silently stopped verifying anything.
- **Each web shortcut carries its own `IconLocation`** (`imageres.dll` indices, checked with `ExtractIconEx` to confirm they resolve), or the folder shows a row of identical Chrome icons.
- Two of the tools install per-user into the `mast` profile — VS Code and MongoDB Compass — while their shortcuts sit on the all-users desktop. That is pre-existing on the fleet (Compass has shipped this way), it works on an autologin-`mast` unit, and the Development README says it plainly rather than pretending otherwise.
- **The rebuild makes an operator-facing rename free, and one was overdue.** `MAST Proxy` is now `Weizmann Proxy`: it selects the Weizmann campus proxy, bcproxy, and there is no MAST proxy for it to have been named after. On a unit carrying the old tree the old shortcut simply does not come back — no adopt-and-remove step was written, which is the whole argument for the rebuild in one line. Renaming it also exposed two defects in the tool behind it, both fixed: it opened on a bare menu without showing the setting an operator came to read, and its Quit option never quit, because a bare `break` inside a PowerShell `switch` exits the switch rather than an enclosing loop, so the menu redrew forever and the only way out was closing the window.
- `module.json` gains `-CloneTop "C:\MAST\src"`, mirroring what the `mast` provider is handed, so the workspace glob's root is a build-visible argument and therefore covered by the per-module hash.

**Unsettled:** the Grafana shortcut, which is the item that opened #191. It needs the proxy bypass (fixed the same day, see the 2026-09-08 no_proxy record) *and* an answer to Grafana's `401` on `/api/search` — anonymous viewer access, or a credential story. Left out rather than shipped as a link to a login page.
