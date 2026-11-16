# Intune: On-Device

These run on the device itself, as SYSTEM, pushed through Intune (platform script or remediation) or an RMM tool. Both write a log under `C:\ProgramData`.

## Repair-DefenderCompliance

[Repair-DefenderCompliance.ps1](Repair-DefenderCompliance.ps1)

For devices stuck on the Intune "Antivirus required" compliance failure when Defender is the antivirus. It works through the usual causes in order:

1. Makes sure the Defender service is running and set to automatic
2. Turns real-time protection back on
3. Updates signatures (falls back to MpCmdRun if the cmdlet fails)
4. Removes Group Policy registry values that disable Defender
5. Gets Windows Security Center to register Defender again
6. Restarts the Intune Management Extension and kicks off an MDM sync so compliance gets rechecked quickly

It logs a before and after snapshot (service state, real-time protection, signature age, tamper protection), so you can see what actually changed. A reboot afterwards helps.

If tamper protection is on, some of these changes get blocked. That's expected.

> Step 4 removes policy keys that turn Defender off. **Don't run this where a third-party antivirus is supposed to be in charge**, or where a GPO is disabling Defender on purpose.

## Enable-WindowsLocationServices

[Enable-WindowsLocationServices.ps1](Enable-WindowsLocationServices.ps1)

If your Autopilot profile hides the privacy settings page during setup, devices come out with Location Services off. Users then see "Location has been turned off by an admin" with no way to turn it back on. This flips the master switch on.

The obvious fix, writing the registry values directly, doesn't work. Windows puts them back within seconds (I confirmed it with Process Monitor). This calls `SystemSettingsAdminFlows.exe SetCamSystemGlobal location 1` instead, the same built-in tool the Settings app uses when an admin flips the switch.

It checks first and exits right away if location is already on. After the change it waits 5 seconds and checks again, then exits 0 if it worked and 1 if it didn't. Per-app location permissions are left to the user.

Deploy it as a platform script running as SYSTEM in 64-bit PowerShell.

---

[Back to Intune](../README.md)
