# Security

Threat hunting and security tool rollouts, built to run across a fleet through an RMM tool.

| Script | What it does | Changes anything? |
|---|---|---|
| [Find-UnauthorizedScreenConnect](#find-unauthorizedscreenconnect) | Fleet-wide threat hunt for rogue ScreenConnect remote-access clients from a 2026 attack campaign. | READ-ONLY |

## Subfolders

- [FortiEDR Readiness](FortiEDR-Readiness/): pre-rollout checks for the FortiEDR agent

---

## Find-UnauthorizedScreenConnect

**READ-ONLY** · [View script](Find-UnauthorizedScreenConnect.ps1)

Fleet-wide threat hunt for rogue ScreenConnect remote-access clients from a 2026 attack campaign. Runs 14 checks (services, tasks, files, network, Defender exclusions, and more) and rates the device CLEAN, REVIEW, SUSPICIOUS, or COMPROMISED.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** A read-only threat hunt for a 2026 attack campaign in which attackers installed rogue ScreenConnect remote-access clients on MSP-managed machines. Built to run across a whole fleet through an RMM tool.

**How it works:** Runs more than a dozen independent checks and reports each finding with a severity:
1. **Services:** every ScreenConnect-style client service, identified by its program file rather than its display name, compared against your allowed instance IDs and relay hosts. Also detects your own client being stopped or set to manual, which this campaign does.
2. **Installed programs** (both 32-bit and 64-bit registry views).
3. **Folders** used by the campaign, disguised client folders, and foreign client install folders.
4. **Scheduled tasks**, plus event 4698 (task created) to catch tasks that were later deleted, if auditing is on.
5. **Running processes** whose command line contains campaign strings.
6. **Run keys** for the machine and every loaded user profile.
7. **Files** in Windows\Temp, Public, ScreenConnect temp, and every user's Temp folder (skippable with `-SkipUserTempScan`).
8. **netsh portproxy** rules (the campaign forwarded a local port to an attacker IP).
9. **Hosts file** changes.
10. **Live network:** DNS cache and current connections to known bad infrastructure.
11. **Defender exclusions**, read from the registry if a third-party antivirus is primary. The campaign adds exclusions for msiexec.exe and powershell.exe.
12. **Software restriction and AppLocker rules** aimed at ScreenConnect temp folders.
13. **MSI install history** since the campaign started.
14. **Technician client version** on technician workstations, since newer versions block the attack path back to the technician.

It restarts itself in 64-bit PowerShell if launched as 32-bit. Hash and filename matches are treated as weak signals because the attacker rebuilds files for each victim. The strongest check is "any ScreenConnect client that is not yours".

**Inputs:** `-AllowedThumbprints` and `-AllowedRelayHosts` (required: your own ScreenConnect instance IDs and relay host; the scan stops with `RESULT: ERROR` if either is missing), `-SkipUserTempScan`, `-AlwaysExitZero`.

**Outputs:** First line is `RESULT: CLEAN | REVIEW | SUSPICIOUS | COMPROMISED`, then one line per finding. Exit codes: 0 clean or info only, 1 medium or high findings, 2 critical, 3 script error. `-AlwaysExitZero` keeps RMM task results green so later steps still run.

**Requirements:** Windows PowerShell 5.1, SYSTEM context, run through an RMM tool. **Do not run it through ScreenConnect's own Run Command.**

**Changes anything?** READ-ONLY. Nothing is removed, stopped, or quarantined.

**Credit:** Indicators from public reporting by Huntress, ConnectWise, Sophos, and Blackpoint.

</details>

---

[Back to the toolkit](../README.md)
