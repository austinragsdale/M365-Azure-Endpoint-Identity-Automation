# Active Directory (on-prem)

Discovery, auditing, and cleanup for on-prem Active Directory, mostly used when planning a move to the cloud.

| Script | What it does | Changes anything? |
|---|---|---|
| [Export-GPOInventory](#export-gpoinventory) | Documents every Group Policy Object (links, filtering, settings areas) and marks each one Active or Inactive with the reason. | READ-ONLY |
| [Get-PasswordNeverExpiresUsers](#get-passwordneverexpiresusers) | Reports every AD user with "Password never expires" turned on, with days since password change and last logon. | READ-ONLY |
| [Move-ComputersToDecommissionedOU](#move-computerstodecommissionedou) | Moves AD computer accounts into a decommissioned OU so they drop out of Entra Connect sync, confirming each move. | WRITES (`-WhatIf`) |

---

## Export-GPOInventory

**READ-ONLY** · [View script](Export-GPOInventory.ps1)

Documents every Group Policy Object (links, filtering, settings areas) and marks each one Active or Inactive with the reason. Built for planning a cloud migration.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** A read-only inventory of every Group Policy Object in a domain, built for planning a cloud migration. Shows which GPOs actually matter and which are dead weight.

**How it works:**
1. For every GPO, reports: status, links (domain, OUs, sites), enforcement, security filtering (who actually has Apply permission), WMI filter, whether the AD and SYSVOL versions match, and which setting areas are configured (Registry, Security, Drive Maps, Folder Redirection, Scripts, and more).
2. Marks each GPO Active or Inactive with the reason: unlinked, links disabled, all settings disabled, empty, or nobody has Apply permission.
3. Lists the GPOs applied to the Domain Controllers OU in precedence order.
4. With `-IncludeDCRsop`, runs gpresult on every domain controller to capture what actually applied.
5. Saves an HTML report per GPO unless `-SkipHtmlReports` is used.
6. Handles PowerShell 5.1 quirks in the XML reports.

**Inputs:** `-Domain`, `-Server`, `-OutputPath`, `-IncludeDCRsop`, `-SkipHtmlReports`.

**Outputs:** A timestamped folder with GPO-Summary.csv, GPO-Links.csv, DomainControllersOU-Inheritance.csv, DC-AppliedPolicy.csv (optional), and HTML reports.

**Requirements:** GroupPolicy and ActiveDirectory modules (RSAT or a domain controller). Domain user read rights. `-IncludeDCRsop` needs local admin on each domain controller.

**Changes anything?** READ-ONLY.

</details>

---

## Get-PasswordNeverExpiresUsers

**READ-ONLY** · [View script](Get-PasswordNeverExpiresUsers.ps1)

Reports every AD user with "Password never expires" turned on, with days since password change and last logon.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Reports every on-prem AD user with "Password never expires" turned on, a common audit and security finding.

**How it works:**
1. Starts a transcript log.
2. Queries AD for users with Password never expires set, optionally limited to one OU.
3. Excludes disabled accounts unless `-IncludeDisabledAccounts` is used.
4. For each user: resolves the manager's name and calculates days since the password was set and days since last logon.
5. Exports a CSV and prints a summary (total, enabled, disabled, locked out, never set) plus the five oldest passwords.

**Inputs:** `-SearchBase`, `-OutputPath`, `-IncludeDisabledAccounts`, `-Server`.

**Outputs:** CSV report and transcript log.

**Requirements:** ActiveDirectory module. Domain user read rights.

**Changes anything?** READ-ONLY.

</details>

---

## Move-ComputersToDecommissionedOU

**WRITES (`-WhatIf`)** · [View script](Move-ComputersToDecommissionedOU.ps1)

Moves AD computer accounts into a decommissioned OU so they drop out of Entra Connect sync, confirming each move.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Moves computer accounts in on-prem AD into a decommissioned OU, so they drop out of Entra Connect sync scope during a hybrid-to-cloud migration.

**How it works:**
1. Checks that the ActiveDirectory module is present and that the target OU exists.
2. Takes device names from `-DeviceNames` or prompts for them.
3. Searches the whole domain for each computer (not just the default Computers container), removing a trailing `$` if typed.
4. Stops and asks if more than one match is found. Skips computers already in the target OU.
5. Confirms each move, then moves the computer.
6. Logs everything and prints a summary.

**Inputs:** `-TargetOU`, `-DeviceNames`, `-WhatIf`, `-LogPath`.

**Outputs:** Log file and console summary.

**Requirements:** ActiveDirectory module (RSAT or a domain controller). Rights to move computer objects.

**Changes anything?** WRITES to AD. Supports `-WhatIf` and confirms each move.

</details>

---

[Back to the toolkit](../README.md)
