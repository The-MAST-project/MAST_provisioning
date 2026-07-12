"""Autonomous provisioning driver -- the platform-agnostic Python orchestrator.

Port of server/check-and-provision.ps1. Runs on the prov server (any OS) and
provisions the Windows units over the transport in prov.transport (SSH-first,
WinRM fallback). It matches the PowerShell driver's phase order, Log-Event
strings, activity outcomes, and exit-code semantics (see DECISIONS.md 2026-07-12
and the behavioral spec the port was written against).

What stays PowerShell and is *invoked*, not reimplemented: build-mast.ps1 (the
payload build), client/mast-pull-staging.ps1 (SMB pull on the unit), and
client/execute-mast-provisioning.ps1 (provisioning on the unit). Transfer is SMB
for all server platforms.

Remote-path note: every C:\\... / \\\\server\\share string here is a LITERAL for
the Windows unit -- never a pathlib.Path (which would mangle it on a non-Windows
server). Local server paths use Path/os.

Scope note (this pass): the transfer runs the pull synchronously and reports the
outcome; the PowerShell driver's live TRANSFER_PROGRESS second-session polling is
deferred (run_ps heartbeat still shows liveness). Inventory is a lean functional
port. Full behavioral acceptance is the real VM run.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from prov import logevents as L
from prov import transport
from prov.maintenance_window import in_maintenance_window
from prov.proxy_assert import ProxyPosture, get_proxy_dirty_surfaces
from prov.retention import run_retention
from prov.staging_size import staging_payload_size

# --- unit-side literal paths (Windows units; never pathlib) ------------------
UNIT_STATUS_DIR = r"C:\MAST\status"
UNIT_AVAIL = r"C:\MAST\status\availability.json"
UNIT_INSTALLED = r"C:\MAST\installed-manifest.json"
UNIT_SMOKE_DIR = r"C:\MAST\logs\smoke"
UNIT_PULL_SCRIPT = r"C:\MAST\mast-pull-staging.ps1"
# Detached-execute (item 6): the standalone runner + the files the driver writes
# for it (config has no secret; the SMB pass is a machine-bound DPAPI blob).
UNIT_DETACHED_RUNNER = r"C:\MAST\mast-run-detached.ps1"
UNIT_DETACHED_CFG = r"C:\MAST\status\detached-run.json"
UNIT_SMB_BLOB = r"C:\MAST\status\smb-cred.dpapi"
UNIT_EXECUTE_RESULT = r"C:\MAST\status\execute-result.json"
DETACHED_TASK = "MAST-Execute-Detached"
EXECUTE_POLL_INTERVAL_S = 15

AVAIL_TTL_S = 7200          # 2 h; matches execute-lease default
WINRM_PORT = transport.WINRM_PORT

# Phase watchdogs (item 6): each long phase has a hard timeout so a hung step
# fails with a structured event instead of blocking the loop forever. Quick
# remote reads (inventory/availability/manifest/smoke/proxy/archive) get a short
# ceiling; build/transfer/execute get generous ones sized to a slow real link.
PROBE_TIMEOUT_S = 180
BUILD_TIMEOUT_S = 1800
TRANSFER_TIMEOUT_S = 3600
EXECUTE_TIMEOUT_S = 3600

EXIT_OK = 0
EXIT_UNIT_FAIL = 1
EXIT_FATAL = 2


def _ps_lit(s: str) -> str:
    """A value as a PowerShell single-quoted string literal (doubles quotes)."""
    return "'" + transport._ps_escape("" if s is None else str(s)) + "'"


def _powershell_exe() -> str:
    """Resolve a PowerShell executable portably: pwsh (cross-platform) first,
    then Windows powershell.exe. Raises if neither is on PATH."""
    for exe in ("pwsh", "powershell.exe", "powershell"):
        found = shutil.which(exe)
        if found:
            return found
    raise RuntimeError("no PowerShell found on PATH (need pwsh or powershell.exe)")


def _parse_json_or_none(text: str) -> Any:
    text = (text or "").strip()
    if not text:
        return None
    try:
        return transport.parse_json_text(text)
    except json.JSONDecodeError:
        return None


def _marker_json(stdout: str, marker: str) -> Any:
    """Extract the JSON payload that a remote snippet emitted after ``marker``."""
    for line in (stdout or "").splitlines():
        if line.startswith(marker):
            return _parse_json_or_none(line[len(marker):])
    return None


@dataclass
class Config:
    repo_top: Path
    unit_registry: Path
    vault_creds: Path
    modules: list[str] = field(default_factory=list)
    only_hosts: list[str] = field(default_factory=list)
    proxy_mode: str = "weizmann"
    dry_run: bool = False
    force: bool = False
    test_mode: bool = False
    maint_window_start: int = -1
    maint_window_end: int = -1
    retain_runs: int = 60


class Driver:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.run_id = "run-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        self.run_start = datetime.now(timezone.utc)
        self.log = L.RunLog(self.run_id)
        self.log.install_as_transport_sink()
        self.log_root = self.log.log_root
        self.exit_code = EXIT_OK
        self.units_checked = 0
        self.prov_server = os.environ.get("COMPUTERNAME") or socket.gethostname()

    # -- top-level ----------------------------------------------------------
    def run(self) -> int:
        trigger = "TaskScheduler" if os.environ.get("USERNAME") == "SYSTEM" else "manual"
        self.log.event("RUN_START", run_id=self.run_id, trigger=trigger)

        if not self.cfg.unit_registry.exists():
            self.log.event("FATAL", reason="unit_registry_missing", path=self.cfg.unit_registry)
            return EXIT_FATAL
        if not self.cfg.vault_creds.exists():
            self.log.event("FATAL", reason="vault_creds_missing", path=self.cfg.vault_creds)
            return EXIT_FATAL

        units = [u for u in (transport.load_json_file(self.cfg.unit_registry) or [])
                 if u and u.get("hostname")]
        creds = transport.load_json_file(self.cfg.vault_creds)
        if not creds.get("unit"):
            self.log.event("FATAL", reason="creds_unit_missing")
            return EXIT_FATAL
        smb = creds.get("smb") or {}
        if not (smb.get("user") and smb.get("pass")):
            self.log.event("FATAL", reason="creds_smb_missing", hint="vault/creds.json needs smb.user/pass")
            return EXIT_FATAL

        # Basic auth wants the bare local username (strip a leading '.\').
        raw_user = creds["unit"]["user"]
        self.unit_cred = {"user": raw_user, "pass": creds["unit"]["pass"]}
        self.smb_user = smb["user"]
        self.smb_pass = smb["pass"]

        self._preflight_smb()

        if self.cfg.only_hosts:
            units = [u for u in units if u["hostname"] in self.cfg.only_hosts]
        self.log.event("RUN_PLAN", units=",".join(u["hostname"] for u in units),
                       dry_run=self.cfg.dry_run, force=self.cfg.force)

        for unit in units:
            self._process_unit(unit)

        self._finish()
        return self.exit_code

    def _preflight_smb(self) -> None:
        # The Windows SMB-server checks (Get-SmbServerConfiguration etc.) are
        # Windows-only; on any other server OS the share is served by Samba and
        # this check is skipped (deployment infra, not driver code).
        if os.name != "nt":
            self.log.event("PREFLIGHT_SMB_SKIP", reason="non_windows_server", server_os=os.name)
            return
        # On Windows, defer to the existing PS preflight helper for parity.
        script = (self.cfg.repo_top / "server" / "lib" / "preflight-smb.ps1")
        ps = (
            f". {_ps_lit(str(script))}; "
            f"$r = Test-MastSmbHostReady -ShareNames @('mast-staging','mast-shared') "
            f"-TransferUser {_ps_lit(self.smb_user)} -TransferPass {_ps_lit(self.smb_pass)} -Quiet; "
            f"Write-Output ('SMBRESULT ' + ($r | ConvertTo-Json -Compress -Depth 6))"
        )
        out = subprocess.run([_powershell_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass",
                              "-Command", ps], text=True, capture_output=True)
        res = _marker_json(out.stdout, "SMBRESULT ")
        if res and not res.get("Ok", res.get("ok")):
            failures = res.get("Failures") or res.get("failures") or []
            self.log.event("PREFLIGHT_SMB_FAIL", failures=";".join(map(str, failures)))
            self.exit_code = EXIT_UNIT_FAIL
        else:
            self.log.event("PREFLIGHT_SMB_OK")

    # -- per unit -----------------------------------------------------------
    def _resolve_modules(self, unit: dict) -> list[str]:
        if self.cfg.modules:
            out: list[str] = []
            for m in self.cfg.modules:
                out += [p for p in str(m).split(",") if p]
            return out
        if unit.get("modules"):
            return list(unit["modules"])
        providers = self.cfg.repo_top / "server" / "providers"
        return sorted(p.name for p in providers.iterdir()
                      if (p / "module.json").exists()) if providers.is_dir() else []

    def _process_unit(self, unit: dict) -> None:
        self.units_checked += 1
        host = unit["hostname"]
        unit_start = datetime.now(timezone.utc)
        modules = self._resolve_modules(unit)
        payload_hash = ""
        git_sha = ""
        lease_held = False
        session = None

        resolved = ""
        try:
            resolved = socket.gethostbyname(host)
        except OSError:
            pass
        self.log.event("UNIT_BEGIN", unit=host, resolved_ip=resolved)

        def dur() -> int:
            return int((datetime.now(timezone.utc) - unit_start).total_seconds())

        try:
            # Phase 1 -- reachability. Probe both transports (SSH-first, WinRM
            # fallback): reachable if EITHER port is open, so a unit whose WinRM
            # regressed (post-reboot Public-profile 401) is still driven over SSH.
            if not (self._tcp_open(host, transport.SSH_PORT) or self._tcp_open(host, WINRM_PORT)):
                self.log.event("UNIT_UNREACHABLE", unit=host, resolved_ip=resolved)
                self.log.activity(host, "UNREACHABLE", "ssh_and_winrm_ports_closed", dur())
                self.exit_code = EXIT_UNIT_FAIL
                return

            # Phase 2 -- open a session (SSH-first, WinRM fallback).
            session = transport.connect_unit(host, self.unit_cred)

            try:
                self._inventory(session, unit)                      # 2a-inv (non-fatal)
                self._reclaim_availability(session, host)           # 2a

                installed = _parse_json_or_none(self._ps_out(
                    session, f"if (Test-Path '{UNIT_INSTALLED}') {{ Get-Content '{UNIT_INSTALLED}' -Raw }} else {{ '' }}",
                    "installed"))
                installed_hash = installed.get("payload_hash") if installed else None

                # Phase 4 -- build (always).
                payload_hash, git_sha = self._build(unit, host, modules, dur)
                if payload_hash is None:
                    return  # BUILD_FAIL already logged

                # Phase 5 -- hash compare / dry-run.
                if installed_hash == payload_hash and not self.cfg.force:
                    self.log.event("UNIT_SKIP", unit=host, reason="already_current", payload_hash=payload_hash)
                    self.log.activity(host, "SKIP", "already_current", dur(), payload_hash, git_sha)
                    return
                self.log.event("HASH_CHECK", unit=host, installed=installed_hash or "none",
                               built=payload_hash, result="NEEDS_UPDATE")
                if self.cfg.dry_run:
                    self.log.event("DRYRUN_STOP", unit=host, reason="would_transfer_and_execute")
                    self.log.activity(host, "SKIP", "dry_run", dur(), payload_hash, git_sha)
                    return

                # Phase 5b -- maintenance window.
                mw = in_maintenance_window(
                    unit, override_start=self.cfg.maint_window_start,
                    override_end=self.cfg.maint_window_end)
                if mw.tz_error:
                    self.log.event("MAINT_TZ_WARN", unit=host, tz=mw.tz, err=mw.tz_error)
                if not mw.allowed:
                    self.log.event("MAINT_SKIP", unit=host, reason="outside_window",
                                   current=mw.current, window=mw.window, tz=mw.tz)
                    self.log.activity(host, "SKIP_MAINTENANCE",
                                      f"outside_window current={mw.current} window={mw.window}",
                                      dur(), payload_hash, git_sha)
                    return

                # Phase 6 -- mark unavailable / take lease.
                self._set_unavailable(session, host, payload_hash)
                lease_held = True

                # Phase 7 -- transfer (SMB pull).
                if not self._transfer(session, host, dur, payload_hash, git_sha):
                    return  # TRANSFER_FAIL already logged

                # Phase 8 -- execute (detached; may reconnect and replace session).
                ok, session = self._execute(session, host, dur, payload_hash, git_sha)
                if not ok:
                    return  # EXECUTE_FAIL already logged

                # Phase 9 -- smoke.
                if not self._smoke(session, host, modules, dur, payload_hash, git_sha):
                    return  # UNIT_FAIL already logged

                # Phase 9b -- proxy-posture assertion.
                if not self._proxy_assert(session, host, dur, payload_hash, git_sha):
                    return  # UNIT_FAIL already logged

                # Phase 10 -- mark available again.
                self._set_available(session, host)
                lease_held = False

                self.log.event("UNIT_OK", unit=host, payload_hash=payload_hash)
                self.log.activity(host, "OK", "updated", dur(), payload_hash, git_sha)
            finally:
                self._release_and_archive(session, host, lease_held)
                transport._dispose_winrm_session(session)
        except Exception as e:  # noqa: BLE001 -- mirror PS outer catch (EXCEPTION)
            err = f"{type(e).__name__}: {e}"
            self.log.event("EXCEPTION", unit=host, error=err)
            try:
                self.log.last_err_log.write_text(err + "\n", encoding="utf-8")
            except OSError:
                pass
            self.log.activity(host, "FAIL", f"exception:{type(e).__name__}", dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL

    # -- phase helpers ------------------------------------------------------
    @staticmethod
    def _tcp_open(host: str, port: int, timeout: float = 5.0) -> bool:
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return True
        except OSError:
            return False

    def _ps_out(self, session: Any, script: str, label: str,
                timeout_s: int = PROBE_TIMEOUT_S) -> str:
        # tee_stdout=False: these are internal probes whose stdout is a marker the
        # caller parses -- keep them out of the controller log (esp. the big
        # base64 archive pull). timeout_s bounds a hung remote read (watchdog).
        r = transport.run_ps(session, script, label=label, echo=False,
                             tee_stdout=False, timeout_s=timeout_s)
        return (r.std_out or b"").decode("utf-8", "replace")

    def _inventory(self, session: Any, unit: dict) -> None:
        """Lean functional port of the inventory phase: collect NICs + identity,
        write a per-unit JSON, persist the primary MAC to the registry. Non-fatal."""
        host = unit["hostname"]
        try:
            script = (
                "$a = Get-NetAdapter -Physical | ForEach-Object { [ordered]@{ name=$_.Name; "
                "mac=$_.MacAddress; status=$_.Status; media=$_.PhysicalMediaType } }; "
                "$o = [ordered]@{ hostname=$env:COMPUTERNAME; adapters=@($a); "
                "collected_utc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }; "
                "Write-Output ('INV ' + ($o | ConvertTo-Json -Compress -Depth 6))"
            )
            inv = _marker_json(self._ps_out(session, script, "inventory"), "INV ")
            if not inv:
                self.log.event("INVENTORY_WARN", unit=host, error="no inventory returned")
                return
            inv_dir = L.prov_logs_base() / "unit-inventory"
            inv_dir.mkdir(parents=True, exist_ok=True)
            (inv_dir / f"{host}.json").write_text(json.dumps(inv, indent=2), encoding="utf-8", newline="\n")
            macs_up = [a["mac"] for a in inv.get("adapters", [])
                       if str(a.get("status")).lower() == "up" and "802.3" in str(a.get("media", ""))]
            self.log.event("INVENTORY_OK", unit=host, site=unit.get("site", ""), macs_up=len(macs_up))
            if macs_up and unit.get("mac") != macs_up[0]:
                self._persist_mac(unit, macs_up[0])
        except Exception as e:  # noqa: BLE001 -- inventory never fails the run
            self.log.event("INVENTORY_WARN", unit=host, error=f"{type(e).__name__}: {e}")

    def _persist_mac(self, unit: dict, mac: str) -> None:
        try:
            units = transport.load_json_file(self.cfg.unit_registry)
            for u in units:
                if u.get("hostname") == unit["hostname"]:
                    u["mac"] = mac
            L.write_status_atomic(self.cfg.unit_registry, units)
            unit["mac"] = mac
            self.log.event("REGISTRY_MAC_SET", unit=unit["hostname"], mac=mac)
        except Exception as e:  # noqa: BLE001
            self.log.event("REGISTRY_MAC_WARN", unit=unit["hostname"], error=f"{type(e).__name__}: {e}")

    def _reclaim_availability(self, session: Any, host: str) -> None:
        avail = _parse_json_or_none(self._ps_out(
            session, f"if (Test-Path '{UNIT_AVAIL}') {{ Get-Content '{UNIT_AVAIL}' -Raw }} else {{ '' }}",
            "avail"))
        if not avail or avail.get("available") is not False:
            return
        owner = avail.get("lease_owner")
        exp = avail.get("expected_return_utc")
        is_stale = False
        if exp:
            try:
                is_stale = datetime.now(timezone.utc) > datetime.fromisoformat(exp.replace("Z", "+00:00"))
            except ValueError:
                pass
        if owner == self.run_id:
            self.log.event("AVAIL_LEASE_SELF", unit=host, owner=owner, reason=avail.get("reason"))
        else:
            self.log.event("AVAIL_LEASE_RECLAIM", unit=host, prior_run=owner,
                           reason=avail.get("reason"), expires=exp or "none", stale=is_stale)

    def _build(self, unit: dict, host: str, modules: list[str], dur) -> tuple[str | None, str | None]:
        # test_mode in the event is the auditable record of whether this build
        # passed -AllowMissing* (dev/test) or ran as a production build that
        # fails loud on any missing input (item 7). Production omits --test-mode.
        self.log.event("BUILD_START", unit=host, test_mode=self.cfg.test_mode)
        build_script = self.cfg.repo_top / "build" / "build-mast.ps1"
        build_log = self.log_root / f"{self.run_id}-{host}-build.log"
        args = [_powershell_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(build_script), "-Top", str(self.cfg.repo_top),
                "-HostName", host, "-ProxyMode", self.cfg.proxy_mode]
        if unit.get("site"):
            args += ["-Site", unit["site"]]
        else:
            self.log.event("SITE_MISSING", unit=host, note="no site in registry entry; build-mast default applies")
        if modules:
            args += ["-Modules", ",".join(modules)]
        if self.cfg.test_mode:
            args += ["-TestMode", "-AllowMissingNoMachineLicense", "-AllowMissingGithubToken"]
        try:
            with build_log.open("wb") as fh:
                rc = subprocess.run(args, stdout=fh, stderr=subprocess.STDOUT,
                                    timeout=BUILD_TIMEOUT_S).returncode
        except subprocess.TimeoutExpired:
            self.log.event("BUILD_FAIL", unit=host, reason="timeout",
                           timeout_s=BUILD_TIMEOUT_S, log=str(build_log))
            self.log.activity(host, "BUILD_FAIL", "timeout", dur())
            self.exit_code = EXIT_UNIT_FAIL
            return None, None
        if rc != 0:
            self.log.event("BUILD_FAIL", unit=host, exit_code=rc, log=str(build_log))
            self.log.activity(host, "BUILD_FAIL", "exception", dur())
            self.exit_code = EXIT_UNIT_FAIL
            return None, None
        staging_dir = self.cfg.repo_top / "staging" / host / "01-provisioning"
        bm = transport.load_json_file(staging_dir / "build-manifest.json")
        payload_hash, git_sha = bm.get("payload_hash"), bm.get("git_sha")
        self.log.event("BUILD_OK", unit=host, payload_hash=payload_hash, git_sha=git_sha)
        self._staging_dir = staging_dir
        return payload_hash, git_sha

    def _set_unavailable(self, session: Any, host: str, payload_hash: str) -> None:
        since = datetime.now(timezone.utc)
        expected = since + timedelta(seconds=AVAIL_TTL_S)
        self._write_unit_json(session, UNIT_AVAIL, {
            "available": False, "reason": "provisioning",
            "since_utc": since.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expected_return_utc": expected.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "lease_owner": self.run_id, "payload_hash": payload_hash,
        })
        self.log.event("AVAIL_SET", unit=host, available="false", reason="provisioning",
                       expected_return_utc=expected.strftime("%Y-%m-%dT%H:%M:%SZ"), lease_owner=self.run_id)

    def _transfer(self, session: Any, host: str, dur, payload_hash: str, git_sha: str) -> bool:
        unit_stage = rf"C:\mast-staging\{self.run_id}"
        src_unc = rf"\\{self.prov_server}\mast-staging\{host}\01-provisioning"
        size = staging_payload_size(self._staging_dir)
        self.log.event("TRANSFER_START", unit=host, files=size.files, bytes=size.bytes,
                       src_unc=src_unc, dst_local=unit_stage)
        # Ship the pull script (it runs before the payload arrives), then run it.
        pull_src = (self.cfg.repo_top / "client" / "mast-pull-staging.ps1").read_text(encoding="utf-8")
        transport.upload_file(session, UNIT_PULL_SCRIPT, pull_src, label="pull-script")
        script = (
            f"$r = & {_ps_lit(UNIT_PULL_SCRIPT)} -ProvServer {_ps_lit(self.prov_server)} "
            f"-UnitHostname {_ps_lit(host)} -SmbUser {_ps_lit(self.smb_user)} "
            f"-SmbPass {_ps_lit(self.smb_pass)} -UnitStage {_ps_lit(unit_stage)} "
            f"-SrcUNC {_ps_lit(src_unc)}; "
            f"Write-Output ('PULLRESULT ' + ($r | ConvertTo-Json -Compress -Depth 6))"
        )
        try:
            out = self._ps_out(session, script, f"transfer:{host}", timeout_s=TRANSFER_TIMEOUT_S)
        except TimeoutError:
            self.log.event("TRANSFER_FAIL", unit=host, reason="timeout", timeout_s=TRANSFER_TIMEOUT_S, duration_s=dur())
            self.log.activity(host, "TRANSFER_FAIL", "timeout", dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL
            return False
        res = _marker_json(out, "PULLRESULT ") or {}
        outcome, rc = res.get("outcome"), res.get("rc")
        if outcome == "NET_USE_FAIL":
            self.log.event("TRANSFER_FAIL", unit=host, reason="net_use_failed", rc=rc, detail=res.get("detail"), duration_s=dur())
            self.log.activity(host, "TRANSFER_FAIL", f"net_use_rc_{rc}", dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL
            return False
        if outcome == "ROBOCOPY_ERROR":
            self.log.event("TRANSFER_FAIL", unit=host, reason="robocopy_error", rc=rc, detail=res.get("detail"), duration_s=dur())
            self.log.activity(host, "TRANSFER_FAIL", f"robocopy_rc_{rc}", dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL
            return False
        # Success (incl. NET_USE_HUNG / DISK_INSUFFICIENT fall-through, matching PS).
        note = {0: "no_changes", 1: "files_copied"}.get(rc, f"robocopy_warning_rc_{rc}")
        self.log.event("TRANSFER_OK", unit=host, bytes=size.bytes, robocopy_rc=rc, note=note)
        self._unit_stage = unit_stage
        return True

    def _write_detached_inputs(self, session: Any, stage: str) -> None:
        """Write the detached runner's inputs: config (no secret) + the SMB pass
        as a machine-bound DPAPI-LocalMachine blob (a network-logon session CAN
        LocalMachine-Protect; the runner decrypts it in the interactive session)."""
        self._write_unit_json(session, UNIT_DETACHED_CFG, {
            "run_id": self.run_id, "staging_path": stage, "prov_server": self.prov_server,
            "smb_user": self.smb_user, "held_by": self.prov_server,
        })
        enc = (
            "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security; "
            f"$b=[Text.Encoding]::UTF8.GetBytes({_ps_lit(self.smb_pass)}); "
            "$e=[Security.Cryptography.ProtectedData]::Protect($b,$null,"
            "[Security.Cryptography.DataProtectionScope]::LocalMachine); "
            f"[IO.File]::WriteAllBytes({_ps_lit(UNIT_SMB_BLOB)},$e)"
        )
        transport.run_ps(session, enc, label="dpapi-blob", echo=False, tee_stdout=False, timeout_s=PROBE_TIMEOUT_S)

    def _execute(self, session: Any, host: str, dur, payload_hash: str, git_sha: str) -> tuple[bool, Any]:
        """Detached execute (item 6): run execute-mast-provisioning.ps1 as a
        detached scheduled task (via client/mast-run-detached.ps1) and poll its
        result marker, reconnecting if the transport session drops mid-run -- so a
        WinRM/SSH blip no longer kills the run. Returns (ok, session) since a
        reconnect replaces the session for the downstream phases.

        NOTE: reboot-survival (execute's -AllowReboot dropping the unit) can't be
        validated on the VM (see reference memory); the session-drop path is the
        common case and is handled here."""
        self.log.event("EXECUTE_START", unit=host, run_id=self.run_id, mode="detached")
        stage = self._unit_stage
        self._write_detached_inputs(session, stage)
        runner_src = (self.cfg.repo_top / "client" / "mast-run-detached.ps1").read_text(encoding="utf-8")
        transport.upload_file(session, UNIT_DETACHED_RUNNER, runner_src, label="detached-runner")

        reg = self._ps_out(session, f"& {_ps_lit(UNIT_DETACHED_RUNNER)} -Register", f"execute-register:{host}")
        if "DETACHED_REGISTERED" not in reg:
            self.log.event("EXECUTE_FAIL", unit=host, reason="detached_register_failed",
                           detail=reg.strip()[:200], duration_s=dur())
            self.log.activity(host, "EXECUTE_FAIL", "detached_register_failed", dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL
            return False, session

        poll_ps = (f"if (Test-Path {_ps_lit(UNIT_EXECUTE_RESULT)}) "
                   f"{{ Get-Content {_ps_lit(UNIT_EXECUTE_RESULT)} -Raw }}")
        deadline = time.monotonic() + EXECUTE_TIMEOUT_S
        result = None
        last_beat = 0.0
        while time.monotonic() < deadline:
            try:
                result = _parse_json_or_none(self._ps_out(session, poll_ps, f"execute-poll:{host}"))
                if result and result.get("status") == "done":
                    break
                now = time.monotonic()
                if now - last_beat >= 90:
                    self.log.event("EXECUTE_RUNNING", unit=host, elapsed_s=dur(),
                                   status=(result or {}).get("status", "starting"))
                    last_beat = now
            except Exception as e:  # noqa: BLE001 -- session dropped; reconnect and keep polling
                self.log.event("EXECUTE_RECONNECT", unit=host, error=f"{type(e).__name__}: {e}")
                transport._dispose_winrm_session(session)
                try:
                    session = transport.connect_unit(host, self.unit_cred)
                except Exception as e2:  # noqa: BLE001
                    self.log.event("EXECUTE_RECONNECT_WAIT", unit=host, error=f"{type(e2).__name__}: {e2}")
            time.sleep(EXECUTE_POLL_INTERVAL_S)

        try:
            self._ps_out(session, f"schtasks /delete /tn {DETACHED_TASK} /f", f"execute-cleanup:{host}")
        except Exception:  # noqa: BLE001
            pass

        if not result or result.get("status") != "done":
            self.log.event("EXECUTE_FAIL", unit=host, reason="timeout", timeout_s=EXECUTE_TIMEOUT_S, duration_s=dur())
            self.log.activity(host, "EXECUTE_FAIL", "timeout", dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL
            return False, session
        rc = int(result.get("exit_code", 1))
        if rc != 0:
            self.log.event("EXECUTE_FAIL", unit=host, exit_code=rc, duration_s=dur())
            self.log.activity(host, "EXECUTE_FAIL", f"exit_{rc}", dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL
            return False, session
        self.log.event("EXECUTE_OK", unit=host, duration_s=dur(), mode="detached")
        return True, session

    def _smoke(self, session: Any, host: str, modules: list[str], dur, payload_hash: str, git_sha: str) -> bool:
        self.log.event("SMOKE_START", unit=host)
        mod_lits = ",".join(_ps_lit(m) for m in modules)
        script = (
            f"$mods = @({mod_lits}); $o = [ordered]@{{}}; "
            f"foreach ($m in $mods) {{ $p = Join-Path '{UNIT_SMOKE_DIR}' ($m + '-smoke.txt'); "
            "if (Test-Path $p) { $c = (Get-Content $p -Raw).Trim(); $o[$m] = if ($c) { $c } else { '<empty>' } } "
            "else { $o[$m] = '<missing>' } }; "
            "Write-Output ('SMOKE ' + ($o | ConvertTo-Json -Compress -Depth 4))"
        )
        results = _marker_json(self._ps_out(session, script, f"smoke:{host}"), "SMOKE ") or {}
        fails = []
        for m in modules:
            val = results.get(m, "<missing>")
            if val in ("<missing>", "<empty>"):
                self.log.event("SMOKE_RESULT", unit=host, module=m, status="FAIL", reason=val)
                fails.append(m)
            else:
                self.log.event("SMOKE_RESULT", unit=host, module=m, status="OK")
        if fails:
            self.log.event("UNIT_FAIL", unit=host, reason="smoke_failures", modules=",".join(fails))
            self.log.activity(host, "FAIL", "smoke:" + "+".join(fails), dur(), payload_hash, git_sha)
            self.exit_code = EXIT_UNIT_FAIL
            return False
        return True

    def _proxy_assert(self, session: Any, host: str, dur, payload_hash: str, git_sha: str) -> bool:
        script = (
            "$r = [ordered]@{ "
            "http_proxy=[Environment]::GetEnvironmentVariable('http_proxy','Machine'); "
            "https_proxy=[Environment]::GetEnvironmentVariable('https_proxy','Machine'); "
            "wininet_enable=0; wininet_server=''; winhttp='' }; "
            "try { $p = Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' -EA Stop; "
            "if ($null -ne $p.ProxyEnable) { $r.wininet_enable=[int]$p.ProxyEnable }; "
            "if ($null -ne $p.ProxyServer) { $r.wininet_server=[string]$p.ProxyServer } } catch {}; "
            "try { $r.winhttp = (netsh winhttp show proxy 2>$null | Out-String) } catch {}; "
            "Write-Output ('PROXY ' + ($r | ConvertTo-Json -Compress -Depth 4))"
        )
        p = _marker_json(self._ps_out(session, script, f"proxy:{host}"), "PROXY ") or {}
        posture = ProxyPosture(
            http_proxy=p.get("http_proxy") or None,
            https_proxy=p.get("https_proxy") or None,
            wininet_enable=int(p.get("wininet_enable") or 0),
            wininet_server=p.get("wininet_server") or None,
            winhttp=p.get("winhttp") or None,
        )
        dirty = get_proxy_dirty_surfaces(posture)
        if self.cfg.proxy_mode == "direct":
            if dirty.advisory:
                self.log.event("PROXY_ASSERT_WARN", unit=host, mode="direct", advisory="; ".join(dirty.advisory))
            if dirty.critical:
                self.log.event("PROXY_ASSERT_FAIL", unit=host, mode="direct", dirty="; ".join(dirty.critical))
                self.log.event("UNIT_FAIL", unit=host, reason="proxy_dirty_on_direct", dirty="; ".join(dirty.critical))
                self.log.activity(host, "FAIL", "proxy_dirty_on_direct", dur(), payload_hash, git_sha)
                self.exit_code = EXIT_UNIT_FAIL
                return False
            self.log.event("PROXY_ASSERT_OK", unit=host, mode="direct")
        else:
            if not dirty.critical and not dirty.advisory:
                self.log.event("PROXY_ASSERT_WARN", unit=host, mode="weizmann",
                               note="no proxy surface set; unit should end on Weizmann proxy")
            else:
                self.log.event("PROXY_ASSERT_OK", unit=host, mode="weizmann")
        return True

    def _set_available(self, session: Any, host: str) -> None:
        self._write_unit_json(session, UNIT_AVAIL, {
            "available": True,
            "since_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
        self.log.event("AVAIL_SET", unit=host, available="true")

    def _release_and_archive(self, session: Any, host: str, lease_held: bool) -> None:
        if session is None:
            return
        if lease_held:
            try:
                self._write_unit_json(session, UNIT_AVAIL, {
                    "available": False, "reason": "provisioning_incomplete",
                    "released_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })
                self.log.event("AVAIL_RELEASE", unit=host, reason="provisioning_incomplete")
            except Exception as e:  # noqa: BLE001
                self.log.event("AVAIL_RELEASE_WARN", unit=host, error=f"{type(e).__name__}: {e}")
        # Pull the unit's per-run session dir back for the archive.
        try:
            unit_sess = rf"C:\MAST\logs\sessions\{self.run_id}"
            present = self._ps_out(session, f"if (Test-Path '{unit_sess}') {{ 'yes' }} else {{ 'no' }}", "archive-check").strip()
            if present.endswith("yes"):
                dest = self.log_root / f"unit-{host}"
                self._download_dir(session, unit_sess, dest)
                self.log.event("UNIT_LOGS_ARCHIVED", unit=host, src=unit_sess, dest=str(dest))
            else:
                self.log.event("UNIT_LOGS_ABSENT", unit=host, src=unit_sess)
        except Exception as e:  # noqa: BLE001
            self.log.event("UNIT_LOGS_ARCHIVE_WARN", unit=host, error=f"{type(e).__name__}: {e}")

    def _download_dir(self, session: Any, unit_dir: str, dest: Path) -> None:
        """Pull a unit directory's text files back by base64 over the session."""
        dest.mkdir(parents=True, exist_ok=True)
        script = (
            f"Get-ChildItem -LiteralPath '{unit_dir}' -File -Recurse | ForEach-Object {{ "
            f"$rel = $_.FullName.Substring('{unit_dir}'.Length).TrimStart('\\'); "
            "$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)); "
            "Write-Output ('FILE ' + $rel + ' ' + $b64) }"
        )
        for line in self._ps_out(session, script, "archive-pull").splitlines():
            if not line.startswith("FILE "):
                continue
            _, rel, b64 = line.split(" ", 2)
            target = dest / rel.replace("\\", "/")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(base64.b64decode(b64))

    def _write_unit_json(self, session: Any, unit_path: str, obj: dict) -> None:
        j = json.dumps(obj)  # JSON uses double quotes -> safe inside a PS single-quoted literal
        d = unit_path.rsplit("\\", 1)[0]
        script = (
            f"$d = '{d}'; New-Item -ItemType Directory -Force -Path $d | Out-Null; "
            f"$tmp = '{unit_path}.tmp'; "
            f"[System.IO.File]::WriteAllText($tmp, '{j}', (New-Object System.Text.UTF8Encoding($false))); "
            f"Move-Item -Force $tmp '{unit_path}'"
        )
        transport.run_ps(session, script, label="write-json", echo=False)

    # -- finish -------------------------------------------------------------
    def _finish(self) -> None:
        run_end = datetime.now(timezone.utc)
        duration_s = int((run_end - self.run_start).total_seconds())
        fail_states = {"FAIL", "UNREACHABLE", "BUILD_FAIL", "TRANSFER_FAIL", "EXECUTE_FAIL"}
        outcomes = self.log.unit_outcomes
        units_updated = sum(1 for o in outcomes.values() if o == "OK")
        units_failed = sum(1 for o in outcomes.values() if o in fail_states)
        last_run = {
            "run_id": self.run_id,
            "started_utc": self.run_start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "ended_utc": run_end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "duration_s": duration_s,
            "units_checked": self.units_checked,
            "units_updated": units_updated,
            "units_failed": units_failed,
            "unit_outcomes": outcomes,
            "exit_code": self.exit_code,
        }
        try:
            L.write_status_atomic(L.last_run_path(), last_run)
            L.write_status_atomic(self.log_root / "last-run.json", last_run)
        except OSError as e:
            self.log.event("HEARTBEAT_WRITE_FAIL", err=str(e))
        try:
            pruned = run_retention(L.prov_logs_base() / "sessions", self.cfg.retain_runs,
                                   logger=lambda m: self.log.event("RETENTION_WARN", msg=m))
            if pruned:
                self.log.event("RETENTION_PRUNED", count=len(pruned), retained=self.cfg.retain_runs)
        except Exception as e:  # noqa: BLE001
            self.log.event("RETENTION_FAIL", err=f"{type(e).__name__}: {e}")
        self.log.event("RUN_END", exit_code=self.exit_code, units_checked=self.units_checked,
                       units_updated=units_updated, units_failed=units_failed, duration_s=duration_s)
