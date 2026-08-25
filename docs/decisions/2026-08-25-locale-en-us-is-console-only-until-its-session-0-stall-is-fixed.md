---
decided: 2026-08-25
status: accepted
issue: MAST_provisioning#148
areas:
  - bootstrap
  - firmware
  - drift
---

# locale-en-us is console-only until its Session 0 stall is fixed

`locale-en-us` moves from `reassert: routine` to `reassert: console`, so the `bootstrap-reassert` provider stops running it on every cycle. This amends one row of the classification in `2026-08-24-bootstrap-elements-declare-whether-they-may-be-re-run.md`; everything else in that record stands, and the four categories are unchanged.

**Why.** The element's `Set-WinHomeLocation -GeoId 244` activates the COM server `CDPComActivityStore`, registered `RunAs = Interactive User`. In Session 0 there is no interactive session to launch it into, so the activation waits out a **600 second** timeout, Windows logs DCOM 10016, and the cmdlet **then succeeds anyway**. Measured on one machine, same build, same command:

| Session | Elapsed |
|---|---|
| SSH / WinRM (`session=0`) | **600.2 s** |
| Console (`session=1`) | **0 s** |

Every provisioning run reaches a unit over SSH or WinRM, which is Session 0. So `bootstrap-reassert` (MAST_provisioning#147) was adding ten minutes to every cycle on every unit — a cost that had existed in the element for months but had only ever been paid once per unit, at a console, where it is free.

**Bootstrap itself keeps calling it.** First touch runs at a console, in an interactive session, where the call costs nothing. The element is not broken; it is *console-shaped*. `console` is exactly the classification for that, and the mechanism added in #143 stage 3 already refuses to run a `console` element remotely.

**What changed in code.** The element leaves `$script:MastBootstrapElementActions` — a `console` element must not be dispatchable, and `Test-MastBootstrapDispatchCoverage` enforces that in both directions — so the main flow calls `Invoke-MastBootstrapElementLocaleEnUs` directly instead of dispatching by id. The function stays; only its reachability by id goes away. Counts move to 7 routine, 7 console, 3 provider, 2 on-demand.

**This is a containment, not a fix.** MAST_provisioning#148 stays open. A unit whose home location is genuinely wrong still needs the geo set, and doing that remotely will still cost ten minutes; the real fix is either to guard the call on current state, or to reach the setting without the COM path. What this record buys is that the fleet stops paying for it on every cycle in the meantime.

**The generalisable point.** This is the Session 0 interactivity hazard the repo already knows from the ASCOM installer's interactive `pause`. `locale-en-us` hid longer only because it *recovers* after ten minutes instead of hanging forever — a slow success is harder to notice than a failure, and nothing in the run reported it. The other `routine` elements deserve the same question: which of them assume an interactive session, and what does each do when it does not get one?
