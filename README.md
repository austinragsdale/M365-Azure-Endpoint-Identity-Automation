# M365 & Azure: Endpoint and Identity Automation

[![PSScriptAnalyzer](https://github.com/austinragsdale/M365-Azure-Endpoint-Identity-Automation/actions/workflows/lint.yml/badge.svg)](https://github.com/austinragsdale/M365-Azure-Endpoint-Identity-Automation/actions/workflows/lint.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

PowerShell scripts I've written for Microsoft 365 work: Entra ID, Intune, Autopilot, Exchange Online, on-prem AD, and a lot of AD-to-Entra ID migrations.

Every one of these started as a script for a real tenant. I've stripped out the client-specific stuff (names, domains, IDs) and turned it into parameters, so they should run anywhere.

| Folder | What's in it |
|---|---|
| [Migration](Migration/) | Moving devices and user profiles from on-prem AD to cloud-only Entra ID (14 scripts) |
| [Intune](Intune/) | Device inventory, compliance, primary users, policy backup, Autopilot, on-device fixes (14) |
| [Entra ID](Entra-ID/) | Groups, licensing, matching names to UPNs, password expiry (4) |
| [Conditional Access](Conditional-Access/) | Back up CA policies and import them into the same or another tenant (2) |
| [Security](Security/) | A ScreenConnect threat hunt and FortiEDR rollout checks (4) |
| [Active Directory](Active-Directory/) | GPO inventory, password audit, moving computers out of sync scope (3) |
| [Exchange Online](Exchange-Online/) | Cleaning out an oversized mailbox (1) |
| [Automation Runbooks](Automation-Runbooks/) | An Azure Automation job that runs on a managed identity (1) |
| [Azure](Azure/) | |

## Before you run anything

Read the script first. Anything that changes a tenant or a device has a `-WhatIf` or `-DryRun` switch, and the deletes ask before they delete. Use them.

For the Graph scripts:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Connect-MgGraph -Scopes "User.Read.All"        # use the scopes the script asks for, nothing more
Get-MgContext                                   # make sure you're in the right tenant
Get-Help .\Some-Script.ps1 -Full
```

There's a bit more in [docs/](docs/): [getting started](docs/Getting-Started.md), [which permissions each script needs](docs/Permissions.md), and [running scripts unattended](docs/App-Registration.md).

## Other people's tools I use

Not mine, so they're linked instead of copied in here:

- [Export Microsoft Entra ID users to CSV](https://www.alitajran.com/export-microsoft-entra-id-users-to-csv-powershell/) by Ali Tajran. Every user with manager, MFA methods and last sign-in.
- [Get-WindowsAutopilotInfo](https://www.powershellgallery.com/packages/Get-WindowsAutopilotInfo) from Microsoft. Grabs Autopilot hardware hashes.
- [ForensiT User Profile Wizard](https://www.forensit.com/domain-migration.html). The profile migration tool my User Profile Migration scripts are built around.

---

Austin Ragsdale. I work on Intune, Entra ID and Microsoft 365. MIT licensed, see [LICENSE](LICENSE).
