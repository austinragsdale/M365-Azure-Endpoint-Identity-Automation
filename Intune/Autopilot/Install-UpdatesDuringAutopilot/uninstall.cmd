@echo off
REM Nothing to uninstall. Installed Windows updates are not being removed. This only
REM clears the detection tag so the app can be re-run on the device if needed.
del /f /q "C:\ProgramData\AutopilotUpdates\ESP-QualityUpdates.tag" 2>nul
exit /b 0
