@echo off
REM Double-click this file (or run from cmd) to run bootstrap-winrm.ps1 in PowerShell.
REM Right-click -> Run as administrator if the script reports elevation is required.
setlocal
REM Deliberately NOT the script directory: on a bare unit this file is on the
REM bootstrap USB, and a cmd.exe sitting there holds the volume open so the
REM eject at the end of bootstrap fails. Nothing needs this working directory --
REM the .ps1 finds mast-client-util.ps1 and the Npcap installer via $PSScriptRoot.
cd /d "%SystemDrive%\"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-winrm.ps1" %*
set "EC=%ERRORLEVEL%"
echo.
if %EC% neq 0 (
    echo Exit code %EC%. See ProgramData\MAST\logs\bootstrap-winrm.log
    echo.
)
pause
exit /b %EC%
