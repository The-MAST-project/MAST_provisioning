NoMachine seat allocation (Product Id WEDS)
===========================================

THIS DIRECTORY HOLDS THE ALLOCATION TABLE, NOT THE CERTIFICATES.

    allocated.csv   which seat each host uses   (tracked)
    README.txt      this file                   (tracked)

The certificates live in exactly one place -- the gitignored credential store
that build-mast.ps1 actually reads:

    vault\nomachine-licenses\server-NN.lic

The build takes the seat NAME for a host from allocated.csv here, and the
certificate that name refers to from the store there. Put a .lic in this
directory and nothing will ship it: the build fails on sight rather than let
an unread copy sit here drifting.

That guard is not tidiness. On 2026-08-23 a stale 2025 set was restored into
this directory -- the one that documents the certificates rather than the one
that ships them. Units were unaffected, because the build never reads here
(see "Nothing owed" below), but nobody could tell that at the time: this file
then claimed the ten .lic files here were the live set, so the reasonable
reading was that two units had just been given expired certificates. The
build now refuses to start with a .lic in this directory, so the question
cannot arise again.

Getting or restoring the certificates
-------------------------------------

Source of truth is the mast-ns-control share, not any working tree:

    \\mast-ns-control\mast-share\Downloads\NoMachine\
        Licenses 2026\files.zip   <- the current set. USE THIS ONE.
        licenses\                 <- the 2025 set, EXPIRED 2026-07-01.

Both use the same ten filenames, so an expired certificate is
indistinguishable from a current one by name alone. Check the Expiry field of
whatever you copy into the store:

    Select-String -Path vault\nomachine-licenses\*.lic -Pattern '^Expiry:'

The live 2026-2027 set is LI06X02774 through LI06X02783, issued 2026-06-22,
expiring 2027-07-01; server-NN maps to LI06X0{2773+NN}.

The build now checks this for you: it reads the Expiry field of the
certificate it is about to stage and REFUSES TO BUILD on an expired one,
before anything reaches a unit. Inside 60 days of expiry it builds and warns,
because renewal is a purchase with lead time that provisioning cannot make
happen.

The .lic files are gitignored (vault\*), so a clone does not carry them and a
`git clean` cannot take them. Re-fetch from the share above, never from
another unit. This README and allocated.csv ARE tracked.

Allocation
----------

allocated.csv is build input for the PRODUCTION UNITS ONLY. mast01-mast08 are
provisioned, so build-mast.ps1 resolves the row here, copies the named
certificate out of the store, and stages it as nomachine.lic;
provide-nomachine.ps1 on the unit installs that staged file as
<install>\etc\server.lic.

mast00, mastw and mast-ns-spec are NOT provisioned. Their certificates were
installed by hand and their rows (or absence) here are a record, nothing more.
Changing a row does not touch them.

There is no node-lock. A certificate is a signed text file naming no host and
no MAC, NoMachine keeps no activation state on disk, and nothing phones home.
Moving a seat is a file copy plus `Restart-Service nxservice -Force` (nxservice,
not nxhtd). The one-installation-per-subscription limit is contractual only, so
nothing will warn you about a duplicate -- which is how LI06X02774 came to run
on both mast00 and mastw between 2026-07-01 and 2026-08-24.

Current state (2026-08-24)
--------------------------

Eleven hosts want a certificate and ten exist. mastw released its seat so
mast08 could be licensed: server-02.lic moved from mastw to mast08, and
mastw's own server.lic was renamed aside, leaving mast00 as the sole user of
server-01.

mastw is UNLICENSED ON PURPOSE, and this is meant to be temporary:

  - if further subscriptions are purchased, mastw should get one;
  - mastw is expected to join the fleet under a MASTxx unit name, at which
    point it takes a seat through allocated.csv like any production unit.

mastw therefore no longer runs Enterprise Desktop at all. An unlicensed
Enterprise Desktop does not degrade -- it refuses connections outright
(`NX> 630 ERROR: No subscription found on this server`) -- so on 2026-08-24
mastw was moved to the FREE NoMachine product (8.11.3, from the same share),
which needs no certificate and reports `Subscription id: None, period:
Unlimited`. Remote access works again.

Reinstating a seat on mastw therefore means reinstalling Enterprise Desktop
and giving it a certificate from the share, not just dropping a file in.
Its released Enterprise certificate was preserved at
C:\MAST\tmp\nomachine-etc-backup-20260824 on the machine, but that copy is an
audit trail only -- it is LI06X02774, which is mast00's live subscription, so
do NOT reinstate from it. Take a free row from allocated.csv and the matching
file from the share.

Nothing owed (corrected 2026-08-25)
-----------------------------------

An earlier version of this section said mast05, mast06 and mast07 needed their
certificates refreshed because mast06 and mast07 "hold expired 2025
certificates". That was wrong, and the reason it was wrong is the subject of
this README.

The stale set restored on 2026-08-23 went into THIS directory, which the build
does not read. The store was untouched -- its files still carry their 2026-07-07
timestamps -- so every unit built since has been staged a current certificate.
The payloads that actually went to those three units say so:

    mast05  LI06X02781  expiry 2027-07-01     (server-08.lic)
    mast06  LI06X02782  expiry 2027-07-01     (server-09.lic)
    mast07  LI06X02783  expiry 2027-07-01     (server-10.lic)

each matching its allocated.csv row. No refresh is owed.

The mistaken entry is itself the clearest illustration of the hazard: whoever
found a stale set here reasonably concluded the units had received it, because
this README told them the certificates here were the ones that ship. A
misleading layout produced a false incident report, and the report was believed
for two days.

Rationale, and the full history of how the duplicate arose:
docs/decisions/2026-08-24-a-nomachine-seat-is-a-file-and-mastw-gives-one-up.md
