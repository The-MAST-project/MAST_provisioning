---
decided: 2026-07-09
status: accepted
issue: MAST_provisioning#10
areas:
  - timesync
  - scheduling
  - platform independence
---

# Registry timezones stay IANA; the driver maps IANA->Windows for 5.1

**Why:** `unit-registry.json` stores IANA timezone ids (`Asia/Jerusalem`), but the driver
runs under Windows PowerShell 5.1 (.NET Framework 4.x), whose `TimeZoneInfo.FindSystemTimeZoneById`
only knows Windows ids and has no `TryConvertIanaIdToWindowsId` (that arrived in .NET 6). The
lookup therefore threw and `check-and-provision.ps1` silently fell back to server-local time --
defeating the already-shipped maintenance-window enforcement. It only looked fine because the
prov server is itself in Israel; on a differently-zoned (or Linux) server it would mis-time every
window. Observed in production on mast01/mast03 2026-07-06 (`MAINT_TZ_WARN ... 'Asia/Jerusalem'
was not found`). The setup doc compounded the drift by telling operators to use Windows names
(`tzutil /l`) while the live registry used IANA.

**What:** Keep IANA as the canonical registry form (portable: .NET 6+/`pwsh`/a future Linux prov
server resolve IANA natively) and add a resolver, `server/lib/mast-timezone.ps1`, that the driver
dot-sources. `Resolve-TimeZoneInfo` tries the id directly first (a valid Windows id, or IANA under
.NET 6+), then falls back to a small curated IANA->Windows map for the 5.1 path, and throws if the
id resolves under neither. `Test-InMaintenanceWindow` calls it instead of `FindSystemTimeZoneById`
directly; the `MAINT_TZ_WARN` fallback now fires only for a genuinely unresolvable id. Pester
coverage in `server/tests/mast-timezone.Tests.ps1`; the setup doc now prescribes IANA.

**Rejected:**

- **Store Windows ids in `unit-registry.json`** (`Israel Standard Time` instead of
  `Asia/Jerusalem`). This was the other candidate named on #10 item 1, and it is the smaller
  change -- no resolver, no map, the 5.1 lookup just works. Rejected to preserve the
  Linux-portability direction stated in `autonomous-provisioning-requirements.md`: Windows ids are
  the parochial form, and baking them into the registry would have to be undone by whichever
  change moves the prov server off Windows. The judgment was that the registry is the long-lived
  artifact and the 5.1 runtime is the temporary one, so the shim belongs on the runtime side.
- **Probing or auto-deriving the mapping** rather than curating a small table. Not pursued:
  the fleet's zone set is tiny and known, and a derived mapping would fail in the same silent
  direction as the bug being fixed.

**Unsettled:**

- **The fallback stays a warning, not a failure.** `MAINT_TZ_WARN` still lets a run proceed on
  server-local time when an id resolves under neither path. #10 item 1 flags promoting it to a
  hard failure "once windows become load-bearing for unattended fleet runs" -- deliberately not
  done here, because at the time of the decision the loop was not yet activated and a hard failure
  would have blocked runs on a fault that had never been seen outside the IANA case just fixed.
- **A new fleet timezone must be added to the map by hand.** A raw Windows name still passes
  through, so the failure mode of forgetting is a fallback to server-local time rather than an
  error. That is the same silent shape as the original bug, narrowed to a case nobody has hit.
- **The shim's lifetime is unknown.** It exists only for the 5.1 driver. Whether the driver stays
  on 5.1 long enough to justify curating the table was open on this date; the Python port was
  raised three days later and would resolve IANA natively through `zoneinfo`.

**Implications:** The gating timezone fix from `MAST_provisioning#10` (the autonomous-loop
activation batch) is in place, so maintenance windows mean what the registry says regardless of
where the prov server sits. The map in `mast-timezone.ps1` becomes a small maintenance surface
that grows with the fleet's geography.
