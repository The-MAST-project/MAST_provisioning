---
decided: 2026-08-24
status: accepted
issue: MAST_provisioning#137
areas:
  - licensing
  - operator tooling
---

# An unlicensed NoMachine refuses connections, so mastw runs the free product

**Why:** releasing mastw's seat earlier the same day (`2026-08-24-a-nomachine-seat-is-a-file-and-mastw-gives-one-up`) left an open question: whether Enterprise Desktop without a certificate degrades or stops. That record recorded it as unknown, on the grounds that mastw's log showed `ERROR! Your NoMachine subscription is expired` alongside a session-level `WARNING!` while the service kept running.

It stops. mastw became unreachable over NoMachine immediately:

```
NX> 630 ERROR: No subscription found on this server.
NX> 630 ERROR: Please contact NoMachine to acquire a valid subscription.
```

`nxservice` stays `Running` and port 4000 stays open, which is what made the log ambiguous -- the server is up and refuses to serve. Reading "expired" in a log as "degraded" was the wrong inference.

**What:** mastw runs the **free NoMachine product** instead of Enterprise Desktop. Enterprise Desktop 9.0.188 was uninstalled (`unins000.exe /VERYSILENT`, exit 0 in 25s, both `Program Files\NoMachine` and `ProgramData\NoMachine` removed) and free NoMachine 8.11.3 installed in its place. It needs no certificate:

```
NX> 722  Subscription type: S.        Subscription id: None.
NX> 722  Subscription period: Unlimited.   expiry: Unlimited.
NX> 111 New connections to NoMachine server are enabled.
```

Remote access is restored, the seat stays released for mast08, and mastw now cannot consume a subscription even by accident.

**The free installer already on the share was used deliberately**, at `\\mast-ns-control\mast-share\Downloads\NoMachine\nomachine_8.11.3_3_x64.exe`. It is 8.11.3 from May 2024, a major version behind the 9.0.188 Enterprise clients the team runs, and a newer free build was not fetched. Reasons: the file is on the share beside the Enterprise installers, so it needs no internet from the unit and no version choice by whoever repeats this; NoMachine clients connect to older servers; and mastw is the workshop machine, so a version skew costs little if it turns up. If a 9.x client cannot reach it, fetching a current free build is the fix -- this is the cheap option, not the considered-best one.

**`Program Files\NoMachine\etc` was preserved** to `C:\MAST\tmp\nomachine-etc-backup-20260824` before the uninstall, because the uninstaller removes the whole tree. It is an audit trail, not a restore path: the certificate in it is `LI06X02774`, which is **mast00's live subscription**, and restoring it is exactly the duplicate that was just eliminated. The README says so at the point where someone would reach for it.

**Rejected:**

- **Leaving mastw with a broken Enterprise Desktop.** The seat had to move for mast08, but nothing about that required mastw to lose remote access; the two were only coupled because the failure mode was mis-predicted.
- **Fetching the current free NoMachine.** See above -- reconsider on a client-compatibility problem.
- **Keeping Enterprise Desktop and pointing it at the free-tier certificate.** The free `server.lic` ships with the free product and is not interchangeable with an Enterprise install; mixing them is unsupported and would leave a machine whose product and certificate disagree.
- **Giving mastw the last unallocated seat and buying one for mast08 later.** Same seat arithmetic, but it puts the shortfall on the production unit rather than the workshop machine.

**Unsettled:**

- **Free-tier limits are not characterised.** The free product reports `Users`/`Connections` differently from Enterprise and is licensed for non-commercial use; nobody has checked whether its terms fit a research institute's workshop machine, or which Enterprise features (multi-session, virtual desktops) mastw loses.
- **Nothing manages mastw's NoMachine.** It is not provisioned, so this install is hand-made and will not be re-asserted, patched, or version-tracked by anything. When mastw joins the fleet as a `MASTxx` unit the `nomachine` module takes over and will install Enterprise Desktop over the top -- that transition has not been tested and the free product may need removing first.
- **The 8.11.3 / 9.0.188 skew is untested** against the clients actually in use.
