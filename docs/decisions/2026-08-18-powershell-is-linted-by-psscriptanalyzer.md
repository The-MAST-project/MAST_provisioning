---
decided: 2026-08-18
status: proposed
issue: MAST_provisioning#73
areas:
  - static analysis
  - reproducibility
  - failure reporting
---

# PowerShell is linted by PSScriptAnalyzer, and two of its rules are not worth running

**Why:** `#65` gated Python with the fleet ruff standard and PowerShell with a **parse sweep** -- `[Parser]::ParseFile` over every `.ps1`/`.psm1`, which catches syntax errors and nothing else. That left 115 of 160 tracked code files effectively unlinted, in the language that actually runs on the units.

**What:** PSScriptAnalyzer 1.25.0, pinned, blocking, and green. `PSScriptAnalyzerSettings.psd1` records the rule set the way `ruff.toml` does; `tools/install-psscriptanalyzer.ps1` owns the pin and both install paths; `tools/invoke-psscriptanalyzer.ps1` is the one entry point CI and a workstation share. A fifth CI job, `pssa`, on `windows-latest`.

**The measurement decided the shape**, as `#73` said it would. 742 findings over 113 tracked files at adoption, only 24 files clean:

| Disposition | Count |
|---|---|
| `PSAvoidUsingWriteHost`, excluded repo-wide | 438 |
| Style / Information families, excluded | 114 |
| `PSAvoidUsingEmptyCatchBlock`, deferred | 113 |
| Two rules excluded on evidence (below) | 31 |
| Accepted at the site (attribute) or by annotation | 8 |
| **Actually fixed** | **38** |

**`Write-Host` is the correct call here, not a defect** -- 59% of the pile in one rule. These are console-facing provisioning scripts whose output IS the operator interface; a technician watching a unit provision reads it. They are not modules emitting objects, so `Write-Output` would put log chatter into return values.

**Two rules were excluded because they found nothing real**, and both for the same underlying reason -- their scope analysis does not follow scriptblocks, and this codebase is mostly scriptblocks:

- **`PSUseUsingScopeModifierInNewRunspaces`: 12 findings, 12 verified wrong.** It does not recognise a `param()` block inside a `Start-Job`/`Invoke-Command` scriptblock, which is how every one of them in this repo receives its values. The clincher: fixing a genuine bug -- `param($host, $line)` shadowing the readonly automatic `$host`, renamed to `$unitHost` -- *added* a twelfth false finding, because the automatic variable had been invisible to the rule and a normal one is not. A rule that manufactures findings from correct fixes cannot gate this tree.
- **`PSReviewUnusedParameter`: 19 findings, 11 wrong and 8 real but harmless.** The false ones include `build-mast.ps1`'s `-Site` and `-ImdiskMountType`, both used inside a `switch` body the rule does not enter. Zero defects in 19 findings.

The 8 harmless ones are worth recording even though the rule is gone, because each is a caller passing a value the callee ignores: `provide-phd2`, `provide-stage` and `provide-vscode` ignore an `-InstallRoot` their `module.json` passes; `provide-npcap` ignores `-AssetsRoot`; `client/mast-pull-staging.ps1` ignores `-UnitHostname`, which `transport.pull_staging_args` sends to it; and `provide-openssh-server`'s `-MastUser` and `provide-mast-validation`'s `-TimeoutSeconds` are accepted from nobody at all. None is a defect; together they are a small map of contract drift.

**What the 38 fixes found.** Two were Error-severity and real: `param($host, ...)` shadowing the automatic `$host` inside an `Invoke-Command` block, and an argument string assigned to `$args`, the automatic array of unbound arguments. Three `-ne $null` comparisons had `$null` on the right, which array-filters instead of comparing -- `CLAUDE.md` already required the opposite. Fifteen were dead variables, ten of them the same idiom: provider scripts capturing `Start-ProvisionLog`'s return into `${log}` and never reading it (the function's work is its `Start-Transcript` side effect, so nothing was ever unlogged). Eighteen functions used unapproved verbs and were renamed across 78 references.

**Suppression has to work differently here, and that shaped the tooling.** PSScriptAnalyzer has **no per-line suppression comment** -- no `# noqa`, no `# pyright: ignore` -- and its settings cannot exclude a rule per path the way `ruff.toml`'s `per-file-ignores` does. Without something, accepting one finding would mean dropping its rule everywhere.

Where a function or param block exists, the native `[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` with a `Justification` is used, because PSSA honours it directly (the five credential findings). Where it does not -- three `ForEach-Object` false positives at script top level -- `tools/invoke-psscriptanalyzer.ps1` reads an annotation of our own:

    # pssa-ignore: <RuleName> -- why this one is accepted

on the flagged line or directly above it. It must name the rule (there is no blanket form) and it must carry a reason, which the runner enforces by failing without one. **A stale annotation fails too**: if the line stops reporting the rule it dismisses, that is an error rather than cruft -- the same service `ruff` does with an unused `noqa`.

The first design was a baseline file keyed `<rule>|<path>|<line>`, and it was rejected after being written: a line-numbered record rots silently, because editing a file above an accepted finding both frees the finding and leaves the stale entry able to dismiss whatever moves onto that line. Annotations travel with the code. The stale check earned itself immediately -- its first run caught the runner's own comment help, where a literal example was being read as a real annotation.

**Rejected:**

- **Renaming the plural-noun functions** (`PSUseSingularNouns`, 18). `Get-MastServiceNames` returns four names and `Get-ConfiguredSites` returns a list; the plural is accurate and the singular would make them read as single-item getters.
- **Excluding `PSUseApprovedVerbs`** (19) to avoid 78 call-site edits. In PowerShell the verb is how a reader guesses what a command does, so an unapproved one is a real discoverability cost -- and the churn turned out to be contained: 16 of the 18 functions were single-file locals with 2 to 5 references each.
- **Clearing `PSAvoidUsingEmptyCatchBlock`** in this change. It is the highest-value rule in the set for this repo -- a swallowed error is exactly the failure #55, #62 and #67-#69 describe -- and precisely why 113 sites cannot be read inside the adoption that introduces the tool. Each needs judging; some are deliberate best-effort cleanup and some are bugs. Tracked in #92.
- **Suppressing the 31 findings from the two excluded rules** instead of excluding them. Thirty-one attributes for rules that found no defects is how a rule becomes suppressed reflexively, and then it is not a gate.
- **A step inside the existing `pester` job** rather than a fifth job. It is already the Windows runner, but that file's own argument for independent signals applies: a red lint must not hide which of the two broke.
- **Vendoring the module** the way `provide-mast` vendors uv. PSSA is dev/CI tooling that never reaches a unit, and `Install-Module` works on the runners.

**Unsettled:**

- **The `pssa` job has not run on a runner.** Verified on the prov workstation (parse sweep clean, Pester 76/0, lint clean) and the YAML parses with five jobs, but as with #65 and #87, until Actions has executed it this is YAML.
- **`Install-Module` fails on the prov workstation** -- PowerShellGet's NuGet-client bootstrap dies behind bcproxy with a `NullReferenceException`. The installer falls back to fetching the `.nupkg` directly, which works, but the fallback is load-bearing there rather than a nicety.
- **An annotation is matched to a finding by line adjacency**, so it is only as stable as the statement it sits above. Moving the flagged expression and leaving the comment behind is caught (it reports stale), but splitting one flagged line into two could quietly move the finding out from under its annotation.
- **Whether this becomes the fleet pattern** (`#73`'s last step). `MAST_common`, `MAST_unit`, `MAST_spec` and `MAST_control` all carry PowerShell and none has a linting job. The settings file here is the candidate to promote, but the exclusions were argued from *this* repo's evidence and the false-positive findings above may not generalise.
- **`PSUseApprovedVerbs` was left applying to `docs/decisions/`**, which is untouched by the renames: the archive is frozen and an accepted record's body is never edited, so records naming `Generate-Commands` stay as written. Nothing enforces that a future record uses the new names.
