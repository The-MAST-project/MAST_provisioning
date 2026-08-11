---
decided: 2026-08-11
status: accepted
issue: MAST_provisioning#67
areas:
  - providers
  - failure reporting
  - services
---

# A verify asserts what provisioning owns, and reports the rest

**Why:** the first full-set provisioning of the fleet (2026-08-11, made possible by #63) left every unit at `fully_provisioned = false` with the same three modules failing verify — `usbpcap`, `planewave`, `diagnostics`. All three had been invisible before, because none was in the judged set.

None of the three was reporting a broken unit. Each was asserting something provisioning does not own:

- **`usbpcap` (#67)** demanded the kernel driver service be registered. The NSIS installer can silently no-op that registration, which is a real defect — in the *provider*. Asserting it in the verify made a permanently-red module out of USB capture tooling that has nothing to do with the observing chain.
- **`planewave` (#68)** demanded `mast-pwi4` be `Running`. The fleet's resting state is `Stopped/Manual`, enforced by `mast-services-finalize` (order 9500, `always`), whose own verify fails unless it finds exactly that. Two modules asserting opposite states about one service is **unsatisfiable** — no run could make both clean.
- **`diagnostics` (#69)** demanded PHD2's JSON-RPC port be bound, which only happens once PHD2 has connected to a camera. It had a `-TestMode` escape treating an unbound port as a warning, but that guard was aimed at the wrong axis: what makes the check meaningless is "no camera attached", and a production unit between sessions is indistinguishable from a VM with no hardware in that respect.

The common shape: three checks that could never pass in the fleet's normal state, each holding `fully_provisioned` false for every unit. A signal that is always red stops being read, and then hides the next real regression — the objection already recorded when closing #55, and the reason CI landed green (see the 2026-08-11 CI record).

**What:** each verify now asserts the outcome provisioning is responsible for, and *reports* what it cannot own.

- **`usbpcap`** asserts the capture CLI is installed. The driver service is reported: on an unregistered service the log states plainly that capture will not work until it is, and points at #67 against the provider. The module passes, because the module is optional tooling. `-AllowPendingReboot` becomes a no-op branch — subsumed by the CLI-only assertion — kept so the flag its callers still pass does not become a silent lie.
- **`planewave`** asserts the service is **registered and startable**: present, and not `Disabled`. `Manual` is the intended resting state; `Automatic` is reported rather than failed, since it is still startable. Whether PWI4 *works* is a runtime question that `diagnostics` already answers by launching it and reporting the pid.
- **`diagnostics`** reports the unbound PHD2 port whenever there is no camera connection, VM or not, naming which case it is. The `PHD2-launch` check above it still asserts that PHD2 is installed and launchable, which is the part provisioning can prove.

Verified on mast03, the unit that exhibited all three:

```
usbpcap      PASS
planewave    EXIT=0   mast-pwi4: registered, Status=Stopped StartType=Manual
diagnostics  EXIT=0   0 check(s) failed
             [WARN] PHD2-rpc-port: port=4400 not bound (no camera/guide scope connected)
                    -- reported, not asserted
```

with services left at `Stopped/Manual` afterwards.

**Rejected:**

- **Fixing `usbpcap`'s provider so the assertion could stand.** The right long-term answer and still tracked in #67, but it gates `fully_provisioned` for the whole fleet on diagnostic tooling in the meantime, and the fix needs a decision about whether the driver registers post-reboot or wants an explicit `sc create` — neither established.
- **Changing the resting state so `planewave` could keep asserting `Running`.** That inverts a deliberate fleet-wide decision (`mast-services-finalize` exists for it) to satisfy one verify.
- **Starting the service in `planewave`'s verify, checking, then stopping it.** Proves more, and duplicates what `diagnostics` already does — while giving a verify side effects on service state, which is a new hazard for a marginal gain.
- **Leaving `diagnostics`' VM-mode escape and adding a "no camera" case beside it.** Two conditions for one situation; the VM-ness was never the relevant axis.
- **Marking all three modules `verify: none`.** Simplest, and it throws away the checks that *are* meaningful — the CLI's presence, the service's registration, PHD2 launching at all.

**Unsettled:**

- **`diagnostics` still starts `mast-phd2` mid-verify** to give its own check a chance, so a verify continues to have side effects on service state. It survives because `mast-services-finalize` stops it again at 9500, and mast03 was left correct after this validation — but whether a verify may move service state is a convention that should be decided once, not per module. It is the same question raised in #68 and still open.
- **`mast-unit-heartbeat` in `diagnostics` asserts a runtime property too** — the unit API answering on `:8000`, which needs `mast-unit` running. It passed here only because a service was up from earlier work; on a unit at rest it is the same class of check as the three above. Not touched, because it was not part of the decision, but it is a fourth instance of the pattern.
- **Nothing yet proves the fleet reaches `fully_provisioned = true`.** These three were the known blockers on mast03; whether another module fails once they are cleared is unknown until a full run. The gate is `fully_provisioned`, and it has never been true on a complete set.
- **`usbpcap`'s driver service is still unregistered on the fleet.** Passing the verify does not install it; #67 stays open against the provider.
