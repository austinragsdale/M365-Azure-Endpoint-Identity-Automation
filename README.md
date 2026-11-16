# M365 & Azure: Endpoint and Identity Automation

[![PSScriptAnalyzer](https://github.com/austinragsdale/M365-Azure-Endpoint-Identity-Automation/actions/workflows/lint.yml/badge.svg)](https://github.com/austinragsdale/M365-Azure-Endpoint-Identity-Automation/actions/workflows/lint.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

PowerShell tools for administering Microsoft 365: Entra ID, Intune, Autopilot, Exchange Online, on-prem Active Directory, and migrations to cloud-only Entra ID.

Every script was built for and used in real tenant work, then generalized to run in any tenant. Client-specific values are parameters, never hardcoded.

## What's inside

| Area | What it covers | Scripts |
|---|---|---|
| [Migration](Migration/) | AD to cloud-only Entra ID: device planning and user profile migration | 14 |
| [Entra ID](Entra-ID/) | Groups, licensing, name-to-UPN matching, password expiry | 4 |
| [Intune](Intune/) | Inventory, compliance policy backup and import, primary users, device fixes, Autopilot | 14 |
| [Exchange Online](Exchange-Online/) | Bulk mailbox cleanup | 1 |
| [Active Directory](Active-Directory/) | GPO inventory, password audit, OU moves | 3 |
| [Security](Security/) | Threat hunting, EDR rollout readiness | 4 |
| [Automation Runbooks](Automation-Runbooks/) | Scheduled Azure Automation jobs with managed identity | 1 |
| [Conditional Access](Conditional-Access/) | Policy backup, restore, and bulk import between tenants | 2 |
| [Azure](Azure/) | | |

Each folder's README lists its scripts with a plain-English description, whether the script changes anything, and the permissions it needs.

## Safety first

- Every script is labeled **READ-ONLY**, **LOCAL FILES**, or **WRITES**.
- Scripts that change things support `-WhatIf` or `-DryRun`. Run that first.
- Destructive actions (deletes, moves) confirm before acting.

## Getting started

1. Install the Microsoft Graph PowerShell SDK: `Install-Module Microsoft.Graph -Scope CurrentUser`
2. Connect with only the permissions the script lists: `Connect-MgGraph -Scopes "User.Read.All"`
3. Read the script's help: `Get-Help .\Script-Name.ps1 -Full`

More detail: [Getting started](docs/Getting-Started.md) · [Permissions by script](docs/Permissions.md) · [Unattended authentication](docs/App-Registration.md)

## Recommended community tools

Scripts by other authors that are worth using. They are linked here, not copied into this repo.

| Tool | Author | What it does |
|---|---|---|
| [Export Microsoft Entra ID users to CSV](https://www.alitajran.com/export-microsoft-entra-id-users-to-csv-powershell/) | Ali Tajran | Exports every Entra ID user with manager, MFA methods, and last sign-in |
| [Get-WindowsAutopilotInfo](https://www.powershellgallery.com/packages/Get-WindowsAutopilotInfo) | Microsoft | Collects Autopilot hardware hashes |
| [ForensiT User Profile Wizard](https://www.forensit.com/domain-migration.html) | ForensiT | The profile migration tool the User Profile Migration scripts drive |

## About

Built by Austin Ragsdale, Endpoint and Identity Engineer (Intune, Entra ID, Microsoft 365). Licensed under [MIT](LICENSE).
