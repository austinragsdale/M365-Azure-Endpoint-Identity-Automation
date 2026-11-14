# Intune: Autopilot

Tools for Windows Autopilot enrollment and pre-provisioning.

| Script | What it does | Changes anything? |
|---|---|---|
| [Export-AutopilotHardwareHash](#export-autopilothardwarehash) | Saves a device's Autopilot hardware hash to a USB drive for import into Intune. | LOCAL FILES |
| [Install-UpdatesDuringAutopilot](#install-updatesduringautopilot) | Win32 app package that installs the latest Windows security updates during Autopilot pre-provisioning so devices do not ship unpatched. | WRITES (device) |
| [Test-DeviceInSetup](#test-deviceinsetup) | Requirement rule for the update package. | READ-ONLY |

---

## Export-AutopilotHardwareHash

**LOCAL FILES** · [View script](Export-AutopilotHardwareHash.ps1)

Saves a device's Autopilot hardware hash to a USB drive for import into Intune. Works at the first setup screen.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Captures a device's Autopilot hardware hash to a USB drive so it can be imported into Intune. Runs at the first setup screen (Shift+F10) or on a working device.

**How it works:**
1. Finds the inserted USB drive and stops with an error if there is none.
2. Installs the NuGet provider and trusts the PowerShell Gallery if needed.
3. Installs Microsoft's `Get-WindowsAutopilotInfo` script.
4. Reads the serial number and saves the hash to `AutopilotHWID_<serial>.csv` on the USB drive.
5. Prints the next steps: Intune > Devices > Enrollment > Windows Autopilot devices > Import.

**Inputs:** None.

**Outputs:** CSV file on the USB drive.

**Requirements:** Windows PowerShell 5.1, run as administrator. Internet access to the PowerShell Gallery.

**Changes anything?** LOCAL FILES. Trusting the PowerShell Gallery and installing a script change the local PowerShell configuration.

**Credit:** Uses Microsoft's community script `Get-WindowsAutopilotInfo`.

</details>

---

## Install-UpdatesDuringAutopilot

**WRITES (device)** · [View script](Install-UpdatesDuringAutopilot/Install-UpdatesDuringAutopilot.ps1)

Win32 app package that installs the latest Windows security updates during Autopilot pre-provisioning so devices do not ship unpatched. Skips drivers and feature updates, checks the result, and reports real success or failure to Intune.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Files** (all in the `Install-UpdatesDuringAutopilot` folder): `Install-UpdatesDuringAutopilot.ps1` (main script), `install.cmd`, `uninstall.cmd`, and `Test-DeviceInSetup.ps1` (the next entry).

**Intune detection rule:** file exists `C:\ProgramData\AutopilotUpdates\ESP-QualityUpdates.tag`.

**Purpose:** Installs the monthly Windows security updates during Autopilot pre-provisioning (the technician phase), before the device ships. Microsoft's own "Install Windows quality updates" setting is ignored at that stage, so without this app devices reach users unpatched.

**How the main script works:**
1. Restarts itself in 64-bit PowerShell if Intune launched it as 32-bit, because the Windows Update API needs 64-bit.
2. Skips Windows Insider devices by reading the flighting registry, not the build number.
3. Starts the Windows Update service.
4. Optionally (`-LiftQualityDeferral`), sets the update ring's quality deferral to 0 for the run and restores it afterwards, so the newest cumulative update is offered.
5. Searches for software updates only, excluding drivers, because firmware updates can stop the device at a BIOS prompt that needs someone at the keyboard. Retries the search if Windows Setup is still busy (error 8024004A).
6. Filters out feature updates by category ID and again by title, so the device stays on its current Windows version (for example 24H2 stays 24H2).
7. Downloads and installs updates one at a time, so one failure does not hide the others.
8. Applies two success checks: installing nothing counts as failure, and if a cumulative update was pending, it must be among those installed.
9. Writes a tag file used by Intune detection, then exits 0 (success), 3010 (success, reboot needed), or 1 (failed; no tag is written, so Intune reports failure).
10. Has a soft time limit (`-MaxRuntimeMinutes`) so it exits cleanly instead of being killed by Intune with no exit code.

**Other files:**
- **install.cmd:** The Intune install command. Its first argument (`None` or `Soft`) is passed through as the reboot mode, so behavior can be changed from the Intune console without repackaging.
- **uninstall.cmd:** Deletes the detection tag file only. It does not remove installed updates.

**Parameters (main script):** `-Reboot None|Soft`, `-LiftQualityDeferral`, `-IncludeMicrosoftUpdate`, `-SearchRetryCount`, `-SearchRetryDelaySeconds`, `-MaxRuntimeMinutes`.

**Requirements:** Intune Win32 app, SYSTEM context, assigned to the pre-provisioning device group. `Soft` reboot mode depends on Autopilot's automatic sign-in working, so test it first. Packaging steps are in the folder README (the `.intunewin` build output is not stored in the repo).

**Changes anything?** WRITES. Installs Windows updates.

</details>

---

## Test-DeviceInSetup

**READ-ONLY** · [View script](Install-UpdatesDuringAutopilot/Test-DeviceInSetup.ps1)

Requirement rule for the update package. Lets it run only during first-time setup, never on devices already in use.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** An Intune requirement script for the update package (the previous entry). Returns "InOOBE" only while the device is still in first-time setup, so the app can never run Windows Update on a device that is already in production.

**How it works:** Checks whether the device is still in the out-of-box experience (OOBE) and returns "InOOBE" if it is.

**Inputs:** None.

**Outputs:** The text "InOOBE", which Intune checks.

**Requirements:** Uploaded on the Win32 app's Requirements tab, not inside the package.

**Changes anything?** READ-ONLY.

</details>

---

[Back to the toolkit](../../README.md)
