---
decided: 2026-08-18
status: proposed
issue: MAST_provisioning#92
areas:
  - static analysis
  - failure reporting
---

# An ignored failure says so, and PSAvoidUsingEmptyCatchBlock is live

**Why:** `PSAvoidUsingEmptyCatchBlock` was the one rule scoped out of the PSScriptAnalyzer adoption (`2026-08-18-powershell-is-linted-by-psscriptanalyzer.md`) and the highest-value one in the set: a `catch {}` discards the error and continues, which is the mechanism behind every issue in the #55 / #62 / #67-#69 family -- a provider being wrong and quiet at the same time. 113 sites, too many to judge inside the change that introduced the tool.

**What:** every one of them now records what it swallowed, and the rule is enforced.

```powershell
try { ${p}.Refresh() } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
```

`Write-Verbose`, so a normal run is exactly as quiet as before and the detail is there for whoever asks. An ignored failure should be *recoverable*, not broadcast: these are ignored precisely because they do not matter to the run, and promoting 113 of them to console output would bury the lines that do. `PSAvoidUsingEmptyCatchBlock` is out of `ExcludeRules`, so nothing new can be added silently. No annotations and no attributes were needed -- there is nothing left to suppress.

**The survey came first**, as #92 asked, grouping the 113 by whether continuing is correct rather than by file. 81 were one-line `try { X } catch {}`; 66 sat in providers and 23 in client scripts, so two-thirds are code that runs on a unit.

| Intent | Count |
|---|---|
| The handle may already be gone: `.Refresh()`, `.Kill()`, `.Close()`, `Stop-Process`, `taskkill` | 56 |
| Needed reading | 23 |
| State change | 19 |
| Probe or read, where absence is the answer | 15 |

Two patterns explained most of it, and neither is a defect. **17 use `-ErrorAction Stop` inside the try** -- that is not carelessness, it is the idiomatic PowerShell existence test: `Get-LocalUser -Name x -ErrorAction Stop` in a `try` is *how* you ask whether something exists, and the empty catch is the answer "no". And **20 already carry `-ErrorAction SilentlyContinue` or `2>$null`** on the guarded call.

**Reading the 42 state-changing and unclear ones found no bugs**, which is worth recording as a result rather than glossed over. The most suspicious cluster was `bootstrap-winrm.ps1`'s network-category ladder -- per-adapter `Set-NetConnectionProfile`, a registry `Category=1` fallback, an `nlasvc` restart, a raw TCP probe, each swallowed. It is sound by construction, and its own comment says why: *"the authoritative gate is the 5985 verification at the end of this script."* Each rung is allowed to fail because a later explicit check decides. Same shape in `provide-jupyter.ps1`, where the `Set-Content` of a captured stdout is best-effort but the next three lines `throw` on timeout, a null exit code and a non-zero one.

So the rule's value here was not a bug count. It was that a 113-rung ladder of deliberate best-effort behaviour was **completely silent**, and now every rung reports when it fires. That is the difference between "this failure does not matter" being a design and being an assumption.

**Rejected:**

- **Annotating all 113** with `# pssa-ignore` comments. Cheapest and no behaviour change, and it would have been 113 suppressions of the rule this repo had just called the most valuable in the set -- the reflexive-suppression trap, delivering nothing operationally.
- **Deleting the ~20 try/catch wrappers whose call already has `-ErrorAction SilentlyContinue` or `2>$null`.** This was in the agreed plan and was dropped on inspection: `ErrorAction` governs NON-terminating errors only, and a stream redirect governs neither, so the `try/catch` is the only thing between a terminating error and the caller. Removing them would have let those escape in code that continues today -- a behaviour change in the unsafe direction, in unit-side code.
- **Logging at `Write-Host` or `Write-MastLog`** so a technician sees each ignored failure live. Rejected deliberately (Eli, 2026-08-18): a run's console is the operator interface and 113 new lines of "ignored: ..." would drown the output that matters. Verbose keeps them out of a normal run and out of the transcript unless the run asks for them.
- **A per-site message describing the operation** instead of one uniform prefix. More informative in principle; in practice the exception message already names the thing that failed, and 113 hand-written strings is 113 chances to describe the code wrongly.

**Unsettled:**

- **`Write-Verbose` is invisible in a normal provisioning run** -- providers execute via `powershell.exe -NonInteractive -File ...` with no `-Verbose`, so these lines exist for a deliberate diagnostic re-run. That is the intent, but it means the ladders are still silent by default; only the *capability* to see them is new.
- **Nothing verifies that the later "authoritative gate" actually exists** for each best-effort ladder. `bootstrap-winrm` and `provide-jupyter` were read and do have one. The other 40 sites were classified by their guarded operation, not by proving a downstream assertion covers them.
- **The uniform `"ignored: ..."` prefix is greppable but unstructured.** If these ever want to be counted or correlated (how often does the `nlasvc` restart fail in the field?), they will need a proper event rather than a verbose string.
