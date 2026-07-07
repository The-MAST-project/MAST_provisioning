@echo off
REM *** VM TESTING ONLY - DO NOT USE ON PRODUCTION UNITS ***
REM Runs bootstrap-winrm.ps1 with -VmTestRun, which adds a hosts file entry
REM mapping mast-wis-control -> 192.168.56.1 (the VirtualBox host-only host IP).
REM Right-click -> Run as administrator.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-winrm.ps1" -VmTestRun %*
set "EC=%ERRORLEVEL%"
echo.
if %EC% neq 0 (
    echo Exit code %EC%. See ProgramData\MAST\logs\bootstrap-winrm.log
    echo.
)
pause
exit /b %EC%
