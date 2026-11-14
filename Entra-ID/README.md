# Entra ID

User, group, and license administration through Microsoft Graph.

| Script | What it does | Changes anything? |
|---|---|---|
| [Add-UsersToEntraGroup](#add-userstoentragroup) | Adds a list of users to any Entra ID group from a typed list, .txt, or .csv. | WRITES (`-WhatIf`) |
| [Resolve-UserUPNsFromNames](#resolve-userupnsfromnames) | Turns a list of people's names, such as "SMITH, JOHN A" from an HR export, into Entra ID sign-in addresses using four matching methods. | READ-ONLY |
| [Add-LicenseToUsers](#add-licensetousers) | Assigns a license to everyone in a spreadsheet. | WRITES (`-DryRun`) |
| [Get-PasswordExpiryReport](#get-passwordexpiryreport) | Before you turn on password expiration, shows who will be forced to change their password immediately and who will be hit within two weeks, split into cloud-only and synced accounts. | READ-ONLY |

---

## Add-UsersToEntraGroup

**WRITES (`-WhatIf`)** · [View script](Add-UsersToEntraGroup.ps1)

Adds a list of users to any Entra ID group from a typed list, .txt, or .csv. Skips existing members, blocks groups synced from AD, and logs every result.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Bulk adds users to any Entra ID security group or Microsoft 365 group from a list of sign-in addresses (UPNs).

**How it works:**
1. Loads the user list from one of three sources: a list typed on the command line (`-Upn`), a `.txt` file with one UPN per line, or a `.csv` file. For CSV files it finds the right column automatically (UPN, UserPrincipalName, Email, or EmailAddress).
2. Cleans the list: trims spaces, drops blank lines and lines starting with `#`, and removes duplicates regardless of upper or lower case.
3. Confirms a Microsoft Graph session exists and prints the signed-in account, tenant ID, and permissions so you can confirm you are in the right tenant. Asks for confirmation unless `-SkipConfirm` is used.
4. Finds the group by display name (`-GroupName`) or object ID (`-GroupId`). If more than one group has the same name, it stops and lists them.
5. Stops if the group is synced from on-prem AD, because those groups can only be changed in AD.
6. Loads the group's current members once, so existing members are skipped without extra Graph calls.
7. For each user: looks them up, skips them if they are already a member, otherwise adds them.
8. Prints a color-coded summary and writes a timestamped CSV log.

**Inputs:** `-GroupName` or `-GroupId`, plus `-UpnFile` or `-Upn`. Optional: `-OutputFolder`, `-SkipConfirm`, `-WhatIf`.

**Outputs:** Color-coded console results (Added, Already member, Not found, Error) and a CSV log. No CSV is written in `-WhatIf` mode.

**Requirements:** PowerShell 5.1 or 7. Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Users. Graph permissions: Group.ReadWrite.All, GroupMember.ReadWrite.All, User.Read.All. Role: Groups Administrator or User Administrator.

**Changes anything?** WRITES. Adds group members. Supports `-WhatIf`.

</details>

---

## Resolve-UserUPNsFromNames

**READ-ONLY** · [View script](Resolve-UserUPNsFromNames.ps1)

Turns a list of people's names, such as "SMITH, JOHN A" from an HR export, into Entra ID sign-in addresses using four matching methods. Flags names with more than one match.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Turns a list of people's names, as they appear in an HR or app export (for example "SMITH MR, JOHN A" or "Jane Doe"), into their Entra ID UPNs. Use it when someone gives you names instead of email addresses, before adding those users to a group or license.

**How it works:**
1. Reads the list of names.
2. Parses each name, handling both "Last, First Middle" and "First Last" formats, and removes titles such as "MR".
3. Tries up to four lookups against Microsoft Graph, stopping at the first one that works:
   - Display name equals "First Last"
   - Display name equals "Last, First"
   - Surname starts with the last name and given name starts with the first name, with suffixes removed
   - A full-text Graph search (uses the `ConsistencyLevel: eventual` header)
4. Labels each name Resolved, Ambiguous (more than one match, with all candidates listed), or NotFound.
5. Prints a color-coded results table, exports a CSV, and prints the resolved UPNs as a block ready to paste into Add-UsersToEntraGroup.

**Inputs:** `-NameFile` (required): a .txt file with one name per line, or a .csv with a Name column. Optional `-OutputFolder`.

**Outputs:** Console table, CSV of results, and a copy-paste UPN list.

**Requirements:** PowerShell 5.1 or 7. Module: Microsoft.Graph.Users. Graph permission: User.Read.All.

**Changes anything?** READ-ONLY.

</details>

---

## Add-LicenseToUsers

**WRITES (`-DryRun`)** · [View script](Add-LicenseToUsers.ps1)

Assigns a license to everyone in a spreadsheet. Sets usage location first, checks that enough licenses are available, and skips users who already have it.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Bulk assigns a Microsoft 365 license (for example Exchange Online Plan 1) to users listed in a spreadsheet.

**How it works:**
1. Opens the Excel file with the ImportExcel module and reads the chosen email column. It reads without headers so it can handle workbooks that have two columns with the same name.
2. Builds a clean user list: trimmed, duplicates removed, original order kept.
3. Connects to Graph and looks up the license's SKU ID from the tenant by name, so no license GUID is hardcoded.
4. Checks that enough licenses are available before starting.
5. For each user: finds them, sets usage location if it is blank (Microsoft requires it before licensing), skips them if the license is already assigned, otherwise assigns it.
6. Writes a text log and a CSV summary. Safe to run again, because users who already have the license are skipped.

**Inputs:** `-Path` and `-UpnColumnNumber` (required). Optional: `-WorksheetName` (default Sheet1), `-SkuPartNumber` (default EXCHANGESTANDARD), `-UsageLocation` (default US), `-LogFolder`, `-DryRun`.

**Outputs:** Text log and CSV results.

**Requirements:** Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, ImportExcel (installs automatically if missing). Graph permissions: User.ReadWrite.All, Organization.Read.All. Role: License Administrator or higher.

**Changes anything?** WRITES. Assigns licenses and may set usage location. `-DryRun` previews without changes.

</details>

---

## Get-PasswordExpiryReport

**READ-ONLY** · [View script](Get-PasswordExpiryReport.ps1)

Before you turn on password expiration, shows who will be forced to change their password immediately and who will be hit within two weeks, split into cloud-only and synced accounts.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Before switching a tenant from "passwords never expire" to an expiration policy (such as 90 days), shows exactly who will be forced to change their password the moment the policy changes, and who will be hit in the next two weeks.

**How it works:**
1. Connects to Graph with read-only access.
2. Pulls all enabled member accounts (no guests, no disabled accounts) with their last password change date, password policies, sync status, and licenses. Unlicensed accounts such as shared mailboxes are filtered out.
3. Puts each user into a group:
   - EXPIRED: password last changed 90 or more days ago (will expire the moment the policy changes)
   - AT-RISK: changed 76 to 89 days ago (will expire within 14 days)
   - OK: everyone else
   - UNKNOWN: no timestamp, flagged for manual review
4. Marks each account as cloud-only or synced from on-prem AD. This matters because while Entra Connect is syncing passwords, the Entra expiration setting only applies to cloud-only accounts. Synced accounts follow the on-prem AD policy.
5. Exports a CSV sorted worst-first and prints a summary, including how many EXPIRED and AT-RISK accounts are synced versus cloud-only.
6. Disconnects from Graph.

**Inputs:** `-OutputPath`, `-ExpireDays` (default 90), `-AtRiskWindow` (default 14).

**Outputs:** Timestamped CSV and a console summary.

**Requirements:** Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Users. Graph permission: User.Read.All.

**Changes anything?** READ-ONLY.

</details>

---

[Back to the toolkit](../README.md)
