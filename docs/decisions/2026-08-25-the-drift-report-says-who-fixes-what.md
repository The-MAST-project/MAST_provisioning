---
decided: 2026-08-25
status: accepted
issue: MAST_provisioning#143
areas:
  - drift
  - bootstrap
  - operator tooling
---

# The drift report says who fixes what, and a re-assert annotates rather than clears

Stage 5 of MAST_provisioning#143. `tools/fleet-drift-report.py` stops printing a flat list of element ids a unit "may need" and starts saying which of them fix themselves and which need a person.

**Why a flat list was not enough.** Since #147 a provisioning run applies the `routine` elements on every cycle. So a missing list now contains two populations that call for opposite responses: elements that will be gone by tomorrow morning without anyone doing anything, and elements only reachable by walking to the unit. Printing them undifferentiated makes a fleet that is quietly converging look identical to one that needs four site visits. The classification added in stage 1 is exactly the key needed to split them, and until now the report did not read it.

**Unstamped means nothing is KNOWN, not that nothing is missing.** `bootstrap_gaps()` gave a unit with no `bootstrap_version` an empty missing list. Without a stamped version there is nothing to compare `since:` against, so the honest answer is that *every* element is unverified — the opposite of zero. The effect was that the unit whose state is least known was the one the report had least to say about, which is precisely backwards. mast02 predates stamping and is that unit.

To be accurate about the old behaviour: such a unit was never silent. It rendered as `UNSTAMPED` and `_render_result` counted it, so it always reached the RESULT line and the exit code. What it lacked was anything **actionable** — no list, so no way to know whether it needed a trip.

**A recent re-assert annotates; it does not suppress.** A unit can be behind on `bootstrap_version` and still have had every routine element applied an hour ago — "behind but converging" rather than "behind and unattended". The report now shows that from the `bootstrap-reassert` facts already in `installed-manifest.json`. It deliberately does **not** clear the unit's flag: `bootstrap_version` still does not advance on a re-assert (`2026-08-24-a-re-assert-run-does-not-claim-the-unit-is-bootstrapped.md`), the console elements are still outstanding, and those are exactly what a work order must keep saying. **Decided by Eli:** annotate.

**What:**

- `bootstrap_gaps()` splits `missing` by `reassert:` into `self_healing`, `needs_console` and the rest, treats unstamped as all-elements-unverified, and carries the unit's re-assert facts.
- The bootstrap section prints the split per unit, plus a re-assert line — `re-asserted <when> (N routine element(s) applied)`, or a `[WARN]` when the last one failed.
- The RESULT block names the units that actually need a person, or says plainly that every gap self-heals on the next cycle. The exit code is unchanged: any gap is still a gap.
- The golden fixture gains a realistic element set with mixed classifications and a unit carrying re-assert facts. It was passing `"elements": {}`, so none of this would have been covered — and its own docstring asks it to keep every section reachable.

**Cost accepted:** the report now needs `bootstrap-elements.json` to carry `reassert:` on every element to classify anything, and an element missing it lands in an `unclassified` bucket rather than being silently dropped. The build guard already fails on a missing or misspelled `reassert`, so this should not arise; the bucket exists so that if it ever does, the id is still visible rather than vanishing from the work order.
