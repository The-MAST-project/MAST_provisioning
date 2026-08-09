---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#22
areas:
  - drift
  - orchestration
  - failure reporting
---

# Classify before the hash gate, always-run modules, and tier-2 staleness

Supersedes parts of the same-day `2026-08-02-per-module-drift-decides-what-runs.md`:
three defects found reviewing #33 before it merged. That record's two-tier model and
its targeting-at-execute decision stand; what changes is when `classify()` runs, what
a target set includes, and how old tier-2 data is treated.

**Why:**

1. The tier-2 `needs-repair` verdict was **unreachable for the case it exists for**.
   The unit publishes an aggregate `payload_hash` only when it is fully provisioned --
   every module hash-matched and clean -- which is exactly the state a runtime failure
   arises in (payload unchanged, service died). The driver compared that hash first and
   returned `already_current`, so `classify()` never ran and `validation.json` was never
   read.
2. Targeting by module name **dropped the order-terminal providers**:
   `execute-mast-provisioning.ps1` filters commands strictly by module, so a
   `-Modules zwo` run skipped `reboot` (order 9999), `mast-services-finalize` (9500)
   and the order-9000 `proxy` re-assert -- an installer's pending reboot would leave no
   flag and the orchestrator would never learn.
3. Nothing clears `validation.json` (`run-verify-only.ps1` is its only writer and is
   operator-run), so a pre-repair `fail` re-targeted the repaired module on every later
   payload change, indefinitely.

**What:**

1. The per-module compare now runs **before** the aggregate-hash skip; the hash decides
   only whether a no-drift result means "skip" or "run the full set".
2. `module.json` gains `"always": true`, collected by the build into
   `build-manifest.json`'s `always_modules`; `DriftReport.targets` folds them into any
   non-empty target set in build order, and `DriftReport.drifted` still reports what
   actually drifted. They never cause a run on their own.
3. `classify` ignores a tier-2 entry whose report `checked_at` predates that module's
   `installed_at` -- it describes a build no longer on the unit. An unparseable timestamp
   keeps the verdict rather than silently suppressing a reported failure.

**Rejected:**

- **Keeping the aggregate hash as a gate and making tier-2 reachable some other way** --
  for instance by publishing the hash even when a verify fails. Rejected because it
  would corrupt the meaning of the aggregate hash, which is exactly "this unit matches
  the build". Demoting it from a gate to a fast-skip input costs one pure-logic
  classification per cycle over data already fetched.
- **Adding the order-terminal providers to every target set by name** (`reboot`,
  `mast-services-finalize`, `proxy`). Rejected as a hardcoded list in the driver that
  would drift from the providers themselves; `"always": true` declared on the module
  keeps the fact where the module is defined.
- **Letting always-run modules trigger a run on their own.** Rejected -- they fold into
  a non-empty target set only. Otherwise every cycle would run something and the
  no-drift skip would never fire.
- **Having `run-verify-only.ps1` clear `validation.json`** at the start of a
  provisioning run, so stale entries cannot survive. Not taken: it is operator-run and
  is the file's only writer, so making the driver depend on an operator action ordering
  is fragile. Comparing `checked_at` against `installed_at` decides staleness from the
  data itself.
- **Suppressing a tier-2 verdict with an unparseable timestamp.** Deliberately the
  other way: the verdict is kept, because silently dropping a reported failure is the
  worse error.

**Unsettled:**

- **`validation.json` still has no lifecycle.** Staleness is now *detected* rather than
  prevented, and the file still accumulates entries nobody clears.
- **`always_modules` is a new build-manifest field** with a single intended use; nothing
  validates that a module declaring `"always": true` is genuinely order-terminal, so
  the mechanism is available to be misused.
- **The three defects were all found by review rather than by tests**, and two of them
  (the unreachable tier-2 path, the dropped terminal providers) only manifest in
  scenarios the suite did not construct. What else the suite does not construct is
  unknown.
- **Four earlier drift flow tests were asserting the wrong thing** -- they asserted no
  exit code and were in fact ending at `EXIT_UNIT_FAIL` on a missing smoke marker. They
  now answer smoke for the build's modules and assert `EXIT_OK`. Tests that pass for the
  wrong reason were present in this area once.

**Implications:** The aggregate hash is now a *fast-skip* input rather than a gate, so
`classify()` runs every cycle. `fleet-drift-report.py` grew a Tier-2 section: it had
parsed `validated_at` and never rendered it, which is what let the staleness stay
invisible. Also removed in the same pass: a dead `inst_hash == _UNKNOWN` comparison and
the unreachable `build_modules` fallback flagged in review.
