---
decided: 2026-09-17
status: accepted
issue: MAST_provisioning#186
areas:
  - transfer
  - failure reporting
---

# A slow transfer is one that ran long, not one with a low rate

**Why:** `TRANSFER_SLOW` was added to catch a failure with no error message. On 2026-09-02, labcomp2 sat on VLAN 2 while the units sat on VLAN 1, so every payload byte crossed the gateway; four of six units fell to 0.14-0.25 MB/s and burned the full `TRANSFER_TIMEOUT_S` before failing. Nothing reported it, because a crawling transfer and a fast one produce the same robocopy summary. The signal was a rate compared against `TRANSFER_SLOW_FLOOR_MBPS = 40.0`, calibrated on the bench baseline of 13.855 GB at 108-112 MB/s.

Per-module trimming (#195) then removed the thing that made a rate meaningful. The ordinary pull went from 14.9 GB to one or two orders of magnitude less, where SMB session setup and per-file overhead decide the duration rather than bandwidth. `1,028,708` bytes in 1.8 s reads as **0.5 MB/s** and is a perfectly healthy transfer.

Measured across the eleven transfers logged on 2026-09-14/15: **ten of them tripped the alarm.** Every unit, every run, except the one full-payload pull that ran at 101.9 MB/s. A signal that fires on every healthy run is worse than no signal — it trains the reader to skip the line, and the one time it means something it looks like all the others.

**What:** `transfer_is_slow(byte_count, seconds)` in `server/prov/driver.py`, called in place of the inline rate comparison, requires **both** halves: the rate is below the fleet's own baseline, *and* the transfer ran at least `TRANSFER_SLOW_MIN_SECONDS = 30.0`.

Duration is the symptom the signal was always for. What made the routed path a problem was not its MB/s in the abstract — it was four units crawling for an hour until a watchdog killed them. A pull that finished in two seconds has not done that, whatever its rate reads. The same eleven transfers replayed through the new predicate raise **zero** alarms, and the collapse is still caught: the tests pin 14.9 GB at 3600 s and the merely-degraded 14.9 GB at 744 s, both true.

It takes `landed_bytes` rather than the pre-scan, for the reason #189 already established: a rate derived from bytes that did not move is fiction.

**Rejected:** *a byte-count floor instead of a duration floor.* It works on today's numbers but states the wrong thing — it says "this payload was big enough to measure" where the real claim is "this transfer took long enough to hurt". A future payload shape would need the constant re-derived; the duration reading would not. *Lowering the MB/s floor.* Any floor low enough to pass a 1 MB pull in 1.8 s is far too low to catch a degraded full payload, which is the case the signal exists for. *Dropping the signal.* The failure it detects is silent, cost a night, and has no other detector.

**Unsettled:** a trimmed pull that collapses on a routed path is now not reported. At 0.2 MB/s a 20 MB payload takes 100 s rather than 3 — visible in `TRANSFER_OK`'s own `seconds` and `mbps` fields, but nothing raises it. That is deliberate: the alternative is a second threshold for small payloads, and the previous constant was already one threshold too many for the shapes the payload now takes. If a routed path is reintroduced the full-payload case will still be caught, and the deployment note in `docs/provisioning-server-setup.md` remains the actual defense.

**Implications:** this closes out the transfer work begun in #186. With the per-host content store (#202) and per-module trimming (#195) both landed, the ordinary run moves ~1-20 MB where it once moved 14.9 GB, and the remaining full-payload transfers are `--force` and first provisioning — the first of which means "no classification, no skips" by definition. Tier 2 of #186 (a durable unit-side destination so robocopy computes a real delta) is **declined**: it would want `/MIR`, a containment assertion, and a per-run identity marker to recover 139 s on runs that are rare and explicitly unconditional. The reasoning is recorded on #186 rather than left as an open ticket implying pending work.
