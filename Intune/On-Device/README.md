# Intune: On-Device

Scripts deployed to Windows devices through Intune (platform scripts or remediations) or an RMM tool. They run as SYSTEM.

| Script | What it does | Changes anything? |
|---|---|---|
| [Repair-DefenderCompliance](#repair-defendercompliance) | Fixes the common causes of Intune "Antivirus required" failures: restarts Defender, turns on real-time protection, updates signatures, removes policies that disable it, and triggers a compliance re-check. | WRITES (device) |
| [Enable-WindowsLocationServices](#enable-windowslocationservices) | Turns on Location Services on Autopilot devices where it was left off. | WRITES (device) |

---

## Repair-DefenderCompliance

**WRITES (device)** · [View script](Repair-DefenderCompliance.ps1)

Fixes the common causes of Intune "Antivirus required" failures: restarts Defender, turns on real-time protection, updates signatures, removes policies that disable it, and triggers a compliance re-check.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Runs on a device to fix the common causes of the Intune "Antivirus required" compliance failure when Microsoft Defender is the antivirus.

**How it works:**
1. Logs a "before" snapshot: Defender service state, running mode, real-time protection, signature age and version, and tamper protection.
2. Makes sure the Defender service (WinDefend) is running and set to automatic.
3. Turns real-time protection on.
4. Forces a signature update, falling back to MpCmdRun if the cmdlet fails.
5. Removes Group Policy registry values that disable Defender, if present.
6. Makes Windows Security Center register Defender again.
7. Restarts the Intune Management Extension and starts the MDM sync task so Intune rechecks compliance quickly.
8. Logs an "after" snapshot.

**Inputs:** None.

**Outputs:** Log file in `C:\ProgramData`.

**Requirements:** Runs as SYSTEM (Intune remediation or RMM). Windows PowerShell 5.1. A reboot afterwards is recommended.

**Changes anything?** WRITES on the device: services, Defender settings, and policy registry keys. If tamper protection is on, some changes are blocked, which is expected. **It removes policy keys that disable Defender, so do not run it where a third-party antivirus or an intentional GPO is meant to control Defender.**

</details>

---

## Enable-WindowsLocationServices

**WRITES (device)** · [View script](Enable-WindowsLocationServices.ps1)

Turns on Location Services on Autopilot devices where it was left off. Uses Windows' built-in admin tool, because direct registry edits get overwritten within seconds.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Turns on the Windows Location Services master switch on devices built by Autopilot with the privacy settings page hidden. Those devices start with location off, and users see "Location has been turned off by an admin" with no way to fix it.

**How it works:**
1. Reads the current state. If location is already on, it exits successfully.
2. Runs `SystemSettingsAdminFlows.exe SetCamSystemGlobal location 1`, the same built-in tool the Settings app uses when an admin flips the switch. Writing the registry directly does not work, because Windows overwrites those values within seconds (confirmed with Process Monitor).
3. Waits 5 seconds, checks again, and exits 0 for success or 1 for failure.
4. Leaves per-app location permissions to the user.

**Inputs:** None.

**Outputs:** Log file in `C:\ProgramData`. Exit code 0 or 1.

**Requirements:** Intune platform script, run as SYSTEM, 64-bit PowerShell.

**Changes anything?** WRITES on the device. Turns on Location Services.

</details>

---

[Back to the toolkit](../../README.md)
