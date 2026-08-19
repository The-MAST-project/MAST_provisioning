@echo off
REM *** VM TESTING ONLY - DO NOT USE ON PRODUCTION UNITS ***
REM Runs bootstrap-winrm.ps1 with -VmTestRun, which adds a hosts file entry
REM mapping mast-wis-control -> 192.168.56.1 (the VirtualBox host-only host IP).
REM Right-click -> Run as administrator.
setlocal
REM Deliberately NOT the script directory: on a bare unit this file is on the
REM bootstrap USB, and a cmd.exe sitting there holds the volume open so the
REM eject at the end of bootstrap fails. Nothing needs this working directory --
REM the .ps1 finds mast-client-util.ps1 and the Npcap installer via $PSScriptRoot.
cd /d "%SystemDrive%\"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-winrm.ps1" -VmTestRun %*
set "EC=%ERRORLEVEL%"
echo.
if %EC% neq 0 (
    echo Exit code %EC%. See ProgramData\MAST\logs\bootstrap-winrm.log
    echo.
)
pause
exit /b %EC%
