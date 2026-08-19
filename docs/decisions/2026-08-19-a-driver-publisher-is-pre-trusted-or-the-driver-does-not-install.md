---
decided: 2026-08-19
status: accepted
issue: MAST_provisioning#110
areas:
  - providers
  - instruments
  - failure reporting
---

# A driver publisher is pre-trusted, or the driver does not install

**Why:** the first provisioning run to happen on an interactive session stopped at a Windows *"Would you like to install this device software?"* consent dialog for a PlaneWave driver, and then a second for Texas Instruments. The dialog was not new. What was new was a desktop to display it on.

`provide-planewave.ps1` was the only driver-installing provider with no publisher pre-trust. `provide-zwo.ps1`, `provide-stage.ps1`, `provide-usbpcap.ps1` and `provide-intel-nic-driver.ps1` all import their vendor's certificate into `LocalMachine\TrustedPublisher` first, and zwo's comment states the failure that buys: *"silent /S install exit 0 without the driver ever binding -- the run reports success but no ASI camera is recognized."*

mast04 shows what that leaves behind. Its `TrustedPublisher` store holds NoMachine, DigiCert, Tomasz Mon (USBPcap), SUZHOU ZWO, TSIF MGU IMENI M.V. LOMONOSOVA (Standa/XIMC) and Nmap — every vendor whose provider pre-trusts. Its driver store holds `XIMC`, `ZWO`, `Nmap Project`, `NoMachine`, FTDI, Intel, Realtek. Neither store mentions PlaneWave or Texas Instruments. `pwi4.exe` is installed and `planewave-smoke.txt` reads `planewave_ok`.

So in Session 0 the prompt could not be shown, the driver install failed, the installer exited 0, and the module reported success — the shape `#62` is about. The control group is what makes it conclusive: every pre-trusting provider has its driver present, and the one that does not, does not.

**What:**

- Both publisher certificates ship as provider assets — `planewave-driver-publisher.cer` and `ti-tiva-driver-publisher.cer` — and `Import-MastPublisherCert` adds them to `LocalMachine\TrustedPublisher` **before** the installer runs, unconditionally.
- PWI4's bundled drivers are staged with `pnputil /add-driver` **outside the idempotent installer guard**: `LMountDriver\usb_dev_cserial.inf` (the L-mount USB serial driver) and `StellarisDrivers\usb_dev_serial.inf` + `boot_usb.inf` (the TI microcontrollers in PlaneWave's accessory electronics). `/add-driver` without `/install`, because no PlaneWave hardware is attached during provisioning.
- The provider then asserts the **outcome**: `pnputil /enum-drivers` must name both publishers, or it throws. Staging without checking would have reproduced the original defect one layer up.

**The second half is the whole point for mast01-mast04.** The provider skips the installer entirely when `pwi4.exe` already exists — the guard that stops a re-run blocking on PWI4's "already installed" modal. On a unit that already carries PWI4, trusting the publisher therefore changes nothing: the installer never runs again and the drivers still never install. Only staging outside that guard makes an already-provisioned unit repairable by a re-run. zwo reached the same conclusion for the same reason and its comment says so.

**The certificates were taken from a machine that had just validated them.** After the operator consented on mast05, Windows placed both certificates in that unit's `TrustedPublisher` store; they were exported from there rather than extracted from the installer's catalogs. Each file's SHA-1 equals the thumbprint Windows recorded — `DA80895E...E1CF` for PlaneWave, `19731ADB...B8A1` for TI Tiva — so the asset is provably the certificate that was trusted, not a lookalike.

**Rejected:**

- **Vendoring the `.inf`/`.cat` files as assets.** They ship inside the PWI4 installer and land in the install tree, so a copy would be a second source of truth that ages independently of the installer beside it. Reading them from the install tree keeps one.
- **Staging the `StellarisDrivers\win2k\` variants** that sit beside the chosen ones. They are legacy, and the three staged here are what Windows itself selected on mast05.
- **Suppressing the prompt globally** (policy, or disabling driver-signature enforcement). A blanket setting to fix two known publishers, and it would hide the next unsigned thing rather than trust a named one.
- **Treating a missing `.inf` as fatal per file.** The list is a vendor layout that can change between PWI4 releases. A missing individual file warns; staging *nothing* throws, because that means the layout moved and this fix quietly stopped working.

**Unsettled:**

- **Both certificates are expired** — PlaneWave 2018-11-30, TI 2016-03-20. Expected for driver signing, where the catalogs are timestamped and the signatures stay valid, and Windows accepted them on mast05. Not separately proven that pre-trusting an expired certificate suppresses the prompt on a *fresh* machine; the next unit is the test.
- **Nothing here repairs mast01-mast04.** The fix makes them repairable by a re-run of the module; running it is a supervised fleet operation and has not been done.
- **What actually depends on these drivers is unestablished.** PWI4 reaches the mount over the network and runs without them, which is why four units ran for months with nothing looking wrong. Whether MAST drives the focuser, rotator or Delta-T over USB is a question for the people who wired them, not something the driver store answers.
- **No other provider was audited this way.** The comparison that found this — "the pattern is present in four providers and absent in the fifth" — was done by eye, and only for pre-trust.
