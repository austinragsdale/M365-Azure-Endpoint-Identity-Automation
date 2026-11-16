# Intune: Autopilot

## Export-AutopilotHardwareHash

[Export-AutopilotHardwareHash.ps1](Export-AutopilotHardwareHash.ps1)

Saves a device's hardware hash to a USB stick so you can import it into Autopilot. It works from the first setup screen: press Shift+F10, run PowerShell, then run the script from the stick.

It finds the USB drive, installs Microsoft's [Get-WindowsAutopilotInfo](https://www.powershellgallery.com/packages/Get-WindowsAutopilotInfo) and saves the hash as `AutopilotHWID_<serial>.csv` on the stick. Then import it under Intune > Devices > Enrollment > Windows Autopilot devices.

It needs internet access to reach the PowerShell Gallery and has to run as admin. It trusts the Gallery and installs NuGet if needed, so that changes the local PowerShell setup a little. That doesn't matter on a device you're about to wipe.

## Install-UpdatesDuringAutopilot

Folder: [Install-UpdatesDuringAutopilot/](Install-UpdatesDuringAutopilot/)

This one fixes a real gap. During Autopilot pre-provisioning (the technician phase), Intune ignores the "Install Windows quality updates" setting. Devices get built, shipped and handed to users already a month or more behind on patches. This is a Win32 app that installs the current security updates during pre-provisioning, before the device leaves.

What it does:

- Installs **software updates only**. No drivers, because a firmware update can stop the device at a BIOS prompt with nobody there to press a key.
- Filters out feature updates (twice, by category and by title), so a 24H2 device stays 24H2.
- Installs updates one at a time, so one failure doesn't hide the rest.
- Retries the update search if Windows Setup is still busy (error 8024004A).
- Skips Windows Insider devices.
- Relaunches as 64-bit if Intune starts it as 32-bit (the update API needs 64-bit).

It only reports success if it actually worked. Installing nothing counts as a failure, and if a cumulative update was pending it has to be one of the ones installed. On success it writes a tag file for Intune detection and exits 0, or 3010 if a reboot is needed. On failure there's no tag file, so Intune shows the app as failed. It also has a soft time limit (`-MaxRuntimeMinutes`, default 60) so it exits cleanly instead of being killed by Intune with no exit code.

### Setting it up in Intune

Package the folder (minus Test-DeviceInSetup.ps1) with the Win32 Content Prep Tool, then:

| Setting | Value |
|---|---|
| Install command | `install.cmd None` |
| Uninstall command | `uninstall.cmd` |
| Install behavior | System |
| Detection rule | File exists: `C:\ProgramData\AutopilotUpdates\ESP-QualityUpdates.tag` |
| Requirement rule | Script: `Test-DeviceInSetup.ps1`, output string equals `InOOBE` |
| Assignment | Required, to your pre-provisioning device group |

`install.cmd` passes its first argument through as the reboot mode. That lets you switch between `None` (update stays staged) and `Soft` (returns 3010, ESP reboots and resumes) from the Intune console without repackaging. Test `Soft` before relying on it, because it depends on Autopilot's automatic sign-in working. If an update ring with a quality deferral reaches the device during provisioning, add `-LiftQualityDeferral`. That sets the deferral to 0 for the run and puts it back afterwards.

`uninstall.cmd` only deletes the tag file. It doesn't remove installed updates.

**Test-DeviceInSetup.ps1** is the requirement script. It returns `InOOBE` only while the device is still in first-time setup, so this app can never kick off Windows Update on a machine someone is already using. Upload it on the Requirements tab, not inside the package.

---

[Back to Intune](../README.md)
