NoMachine Enterprise Desktop subscriptions (Product Id WEDS)
============================================================

The ten server-NN.lic files here are the LIVE 2026-2027 set: subscriptions
LI06X02774 through LI06X02783, issued 2026-06-22, expiring 2027-07-01.
server-NN maps to LI06X0{2773+NN}.

Source of truth is the mast-ns-control share, NOT this directory:

    \\mast-ns-control\mast-share\Downloads\NoMachine\
        Licenses 2026\files.zip   <- the current set. USE THIS ONE.
        licenses\                 <- the 2025 set, EXPIRED 2026-07-01.

Both use the same ten filenames, so an expired certificate is
indistinguishable from a current one by name alone. Check the Expiry field
before trusting a copy; a stale set was restored from the wrong folder on
2026-08-23 and provisioned onto mast06 and mast07 before it was caught.

The .lic files are deliberately NOT git-tracked (they are purchased
credentials). They therefore live only in a working tree and can be lost to
an ordinary git clean -- re-fetch them from the share above, not from another
unit. This README and allocated.csv ARE tracked.

Allocation
----------

allocated.csv is provider input for the PRODUCTION UNITS ONLY. mast01-mast08
are provisioned, so provide-nomachine.ps1 reads that file and installs the
right certificate as <install>\etc\server.lic.

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

Reinstating it is a rename away -- its released certificate is kept beside
server.lic on the machine itself.

Owed
----

mast05, mast06 and mast07 need their certificates refreshed by a provisioning
run: mast06 and mast07 hold expired 2025 certificates, and mast05 is
unverified. Replacing the files in this directory changes the nomachine
module's content hash, so an ordinary run classifies each as NEEDS_UPDATE and
converges it -- no --force, no hand-install.

Rationale, and the full history of how the duplicate arose:
docs/decisions/2026-08-24-a-nomachine-seat-is-a-file-and-mastw-gives-one-up.md
