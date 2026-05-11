@echo off
REM Double-click this file (or run from cmd) to run bootstrap-winrm.ps1 in PowerShell.
REM Right-click -> Run as administrator if the script reports elevation is required.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-winrm.ps1" %*
set "EC=%ERRORLEVEL%"
echo.
if %EC% neq 0 (
    echo Exit code %EC%. See ProgramData\MAST\logs\bootstrap-winrm.log
    echo.
)
pause
exit /b %EC%
