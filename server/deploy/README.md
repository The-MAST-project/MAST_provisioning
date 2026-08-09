# Running the provisioning loop as a supervised service

The autonomous loop is `server/check_and_provision.py --loop`: it runs a full
provisioning cycle over all registered units, sleeps `--interval-seconds`
(default 1800), and repeats. Per-unit maintenance windows already gate the
disruptive steps, so the loop just fires on cadence and each unit provisions
only inside its window. A cycle that throws is logged and does not stop the loop.
SIGINT/SIGTERM stop it gracefully (it finishes the current cycle / wakes from the
inter-cycle wait). `--max-cycles N` bounds a run (handy for a supervised one-shot
or testing).

Install `pip install -r server/requirements.txt` first (pywinrm, paramiko, and
`tzdata` on Windows).

## Linux (systemd)
Edit `mast-provision.service` (paths, `User`, `MAST_SERVER_ROOT`) and:

```
sudo cp mast-provision.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mast-provision
journalctl -u mast-provision -f
```

## Windows (NSSM)
Run the same loop under NSSM (or a Startup scheduled task). With NSSM:

```
nssm install MAST-Provision "C:\Python312\python.exe" "server\check_and_provision.py --loop"
nssm set MAST-Provision AppDirectory "C:\Users\...\MAST_provisioning"
nssm set MAST-Provision AppStopMethodConsole 15000
nssm start MAST-Provision
```

NSSM's stop sends a console Ctrl-C (SIGINT), which the loop's handler catches for
a graceful shutdown. On Windows the driver's log/status root defaults to
`<SystemDrive>\MAST`; set `MAST_SERVER_ROOT` to override.

> The loop is platform-agnostic Python; only this wrapper differs per OS. The
> steps it drives stay Windows/PowerShell on the units (see DECISIONS.md
> 2026-07-12). This replaces the older `install-scheduled-task.ps1` +
> `check-and-provision.ps1` path once the PowerShell driver is retired.
