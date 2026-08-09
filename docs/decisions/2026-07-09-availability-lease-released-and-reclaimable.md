---
decided: 2026-07-09
status: accepted
issue: MAST_provisioning#10
areas:
  - scheduling
  - orchestration
  - unit-config
---

# Availability lease is released on every exit and reclaimable by a new run

**Why:** `check-and-provision.ps1` marks a unit unavailable (availability.json,
`available:false` + `lease_owner=<run-id>` + a 2 h `expected_return_utc`) before
provisioning, but only wrote `available:true` again on the happy-path end. Any early exit
-- a smoke-failure `continue`, a caught EXCEPTION, or a mid-run bail -- skipped that write,
leaving a live lease. The start-of-cycle check then honored the live lease of that prior run
(owner != the new run-id, not yet TTL-stale) and SKIPped, so an immediate re-run no-op'd
until the 2 h TTL. Seen on mast03 2026-07-08: the 08:19 run's lease blocked an 08:36 re-run
until the sidecar was hand-deleted. availability.json conflates two consumers -- the science
scheduler ("do not observe with me") and the driver ("do not re-provision me") -- and only
the second was buggy.

**What:** Two changes, keyed on the fact that the unit-side `execute-lease.json` is the real
mutual-exclusion guard and check-and-provision is the sole writer of availability.json.
(1) **Reclaim:** the start-of-cycle availability check now reclaims a lease held by any run
other than the current one (`AVAIL_LEASE_RECLAIM`, then re-provision), instead of SKIPping on
a live non-current lease -- an overlapping cycle would still SKIP at the execute-lease, so
this cannot cause a double-execute. This subsumes the former `AVAIL_LEASE_LIVE` (SKIP) and
`AVAIL_STALE_RECOVER` events (the TTL-expiry signal survives as a `stale=` field on the
reclaim event). (2) **Release:** a per-unit `$leaseHeld` flag drives the per-unit `finally`
to release the lease on every exit path that left it held, writing `available:false` +
`released_utc` but NO live lease -- the scheduler keeps avoiding the unverified unit while a
re-run reclaims it immediately. A failed unit only becomes `available:true` after a
successful provision.

**Rejected:**

- **Release only, without the reclaim path.** This is the fix as #10 item 2 first framed it
  ("`LEASE_RELEASE` should actually clear/expire the sidecar"). Rejected as insufficient on its
  own: a dead WinRM session -- the network-drop case, and the one unattended running will hit
  most -- cannot write anything, so a release-only fix still strands the lease exactly when
  nobody is watching. Reclaim is what makes the guarantee hold without a cooperative exit.
- **Reclaim only, treating a just-ended run's lease as stale.** The alternative also named on
  item 2. Rejected because it leaves availability.json lying to the science scheduler for the
  gap between the run ending and the next cycle: the unit reads as leased-and-busy when it is
  merely unverified. Doing both keeps each consumer's answer true.
- **Shortening the 2 h TTL** so stale leases self-clear sooner. Not taken: the TTL exists for
  the scheduler's benefit, and tuning it to paper over a driver bug would trade a correctness
  fix for a timing guess, while making genuine long runs look abandoned.
- **Splitting availability.json into two sidecars**, one per consumer, since the file conflates
  the scheduler's question with the driver's. Recognized but not done -- the conflation is real,
  and the record notes it, but only the driver's half was broken and splitting a file the
  science scheduler also reads is a cross-system change that this batch did not want to carry.

**Unsettled:**

- **The two-consumer conflation stays.** availability.json still answers both "do not observe
  with me" and "do not re-provision me" from one set of fields. This decision fixes the second
  without separating them, so a future change to either contract has to reason about both.
- **`available:false` + `released_utc` with no live lease is a new third state** for a reader
  that previously saw only leased or available. The science scheduler was believed to key on
  `available` alone and therefore to be unaffected, but that was reasoned from the contract
  rather than verified against the scheduler's code.
- **The dead-session path is covered by reclaim on the *next* run**, which means a unit that
  fails with a dropped session stays unavailable to the scheduler until a cycle comes round.
  Acceptable while cycles are manual; the unattended cadence was expected to make it moot.

**Implications:** availability.json no longer blocks the driver from re-provisioning; the
science-scheduler contract (`available:false` means "do not observe") is unchanged, and a
half-provisioned unit stays `available:false` until a clean run. This is the availability-lease
item of `MAST_provisioning#10` (autonomous-loop activation batch); it removes one of the manual
"delete the sidecar and re-run" interventions that unattended cadence would otherwise hit
constantly.
