---
decided: 2026-09-14
status: accepted
issue: MAST_provisioning#189
areas:
  - transfer
  - failure reporting
  - orchestration
---

# `TRANSFER_OK` means the payload arrived, and the byte count is a measurement

**Why:** the phase reported success, with the **full expected byte count**, after a robocopy that moved 1.9% of the payload. Two gaps combined, and neither is visible from the other.

robocopy's exit codes are a bitmask in which **1 means "files copied successfully"** — and a process killed with `taskkill /f` also exits 1. `Get-RobocopyOutcome` maps everything below 8 to `OK`, so an operator, a watchdog, an OOM, a unit reboot or an SMB session teardown all landed in the success branch. And nothing looked at the destination: the `bytes=` in `TRANSFER_OK` was `prov.staging_size`'s **server-side pre-scan**, so it reported the whole payload regardless of what was copied, and `mbps` derived from it was fiction whenever the copy was short.

On 2026-09-02, `run-20260902-170559`, mast03: `TRANSFER_OK bytes=14877375466 robocopy_rc=1 mbps=12.8` against a destination holding **276,694,669 bytes in 7 files** of an expected 542. The unit's `robocopy.log` was 23 lines and stopped mid-payload with no summary block. The driver then executed, which "succeeded" because the script ran, and the run ended `UNIT_FAIL reason=smoke_failures modules=bootstrap-reassert,desktop-appearance,mast-services-standdown` — three modules failing because their files had never arrived, several phases from the cause. The `mbps=12.8` invited a throughput investigation that had nothing to do with the fault.

`2026-07-19-transfer-phase-fails-closed.md` established that this phase fails closed. Against this failure mode it failed **open**, while publishing a byte count that positively asserted the payload was there.

**What:** measure the destination, assert on it, and report the measurement.

`client/mast-pull-staging.ps1` gains two pure functions. `Get-MastDirectorySize` walks the destination explicitly rather than with `Get-ChildItem -Recurse`, which does not descend reparse points — the same under-measurement that understated the disk guard by ~10 GB in `#7` item 6. A missing path reads as zero rather than throwing, because the driver's comparison says more than an exception would. `Test-MastRobocopyCompleted` keys on the `Ended :` trailer, which a completed run always writes and a killed one never does; the log was already captured and already tailed into `$rbSummary`, so the evidence was in hand and merely unasserted. Both ride back in `PULLRESULT` as `landed_files`, `landed_bytes` and `completed`.

`prov.driver._transfer` then treats `outcome == "OK"` as necessary and not sufficient, in three ordered checks: absent figures are `unverified_transfer`, a missing trailer is `robocopy_incomplete`, and a mismatch against the size it computed is `short_transfer`. `TRANSFER_START` renames `bytes=` to `expected_bytes=`; `TRANSFER_OK` reports the **measured** count, and `mbps` is derived from it.

**The two checks are independent on purpose.** The destination comparison catches every short copy, including causes nobody has enumerated. The trailer catches an abnormal termination whose size happens to match. Neither subsumes the other.

**Absent figures fail rather than pass.** A unit still carrying a pull script from before this change reports none, and treating that as success would restore exactly the hole being closed — the same fail-closed-on-unknown rule the outcome whitelist already applies.

**This became more necessary after #195, not less.** Trimming made expected bytes a computed per-unit number, so a reader can no longer spot a wrong figure against a known 14.9 GB. It is also a prerequisite for a staging relay, which adds "the copy on the relay is stale or incomplete" as a further way to be wrong.

**Rejected:**

- **Adding the missing codes to a blacklist.** The same shape `2026-07-19` already rejected for outcomes, and it cannot work here at all: a killed process's `1` is genuinely indistinguishable from a successful `1` by exit code alone.
- **A tolerance on the byte comparison.** robocopy copies exactly; a mismatch is real. A tolerance would only hide the small short copies, which are the ones hardest to spot by eye.
- **Requiring the trailer *instead of* measuring the destination** (option A alone). It is cheap and it is kept, but it only catches abnormal termination — a source that was itself incomplete, or an exclusion list that dropped too much, would pass it.
- **Reporting the measurement without asserting on it** (option C alone). That makes the log honest and changes nothing the driver does: on the mast03 run it would have written `bytes=276694669` and still executed against 1.9% of a payload. In an unattended loop only the assertion stops the run.
- **Re-deriving the expected figure on the unit.** The server already computed it for the disk guard; a second derivation is a second place for the two to disagree.
- **Tightening the bitmask mapping as the fix.** Worth doing for clarity and deliberately not load-bearing, since the ambiguity of `1` survives it.

**Unsettled:**

- **A source-side corruption still passes.** Both checks compare against what the server *thinks* it staged; neither hashes content. `payload_hash` exists and is not verified against the delivered tree.
- **`landed_files`/`landed_bytes` are a new coupling between the pull script and the driver** that nothing enforces beyond `test_pull_staging_args_match_the_script`, which covers the argument list rather than the result shape.
- **The destination walk costs a stat pass over the payload on every transfer.** Seconds on a trimmed payload; unmeasured on a full one over a slow disk.
