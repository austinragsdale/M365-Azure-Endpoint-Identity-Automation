@echo off
REM Usage: install.cmd [None|Soft] [extra script switches]
REM
REM Argument 1 is the reboot mode and is passed straight through to -Reboot, so the
REM behavior can be flipped from the Intune install command WITHOUT repackaging the
REM .intunewin. Defaults to None if nothing is passed.
REM
REM   install.cmd None    no reboot requested, update stays staged (safe default)
REM   install.cmd Soft    return 3010, ESP reboots and resumes, update is committed
REM
REM Add -LiftQualityDeferral as a later argument only if an update ring with a nonzero
REM quality deferral reaches the device during provisioning.
setlocal

set "MODE=%~1"
if "%MODE%"=="" set "MODE=None"
shift

REM The script re-launches itself 64-bit if needed, so either host is fine here.
set "PSEXE=%windir%\System32\WindowsPowerShell\v1.0\powershell.exe"

"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Install-ESPQualityUpdates.ps1" -Reboot %MODE% %1 %2 %3

exit /b %ERRORLEVEL%
