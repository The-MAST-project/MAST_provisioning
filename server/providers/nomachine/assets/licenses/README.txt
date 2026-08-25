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

That guard is not tidiness. A second copy beside this README is how expired
certificates reached mast06 and mast07 on 2026-08-23 -- somebody refreshed
"the licences" in the directory that documents them, which is not the
directory that ships them. Until 2026-08-25 this file said the ten .lic files
were here, and the paragraph below still told you to replace them here.

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

Owed
----

mast05, mast06 and mast07 need their certificates refreshed by a provisioning
run: mast06 and mast07 hold expired 2025 certificates, and mast05 is
unverified. Replace the files in the STORE (vault\nomachine-licenses) -- that
changes what the build stages, and so the nomachine module's content hash, and
an ordinary run classifies each unit as NEEDS_UPDATE and converges it. No
--force, no hand-install.

(This paragraph used to say "this directory", which would have changed
nothing that ships. That is the same confusion that put the expired set on
mast06 and mast07 in the first place.)

Rationale, and the full history of how the duplicate arose:
docs/decisions/2026-08-24-a-nomachine-seat-is-a-file-and-mastw-gives-one-up.md
