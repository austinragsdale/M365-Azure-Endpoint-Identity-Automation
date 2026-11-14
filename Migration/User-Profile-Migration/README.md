# User Profile Migration (ForensiT toolchain)

When a device moves from on-prem AD to Entra ID, ForensiT User Profile Wizard can move each person's existing Windows profile (desktop, documents, settings) to their new Entra ID account. It needs a lookup file that maps each old AD account to the new Entra account. If an entry is wrong, that user signs in to a new, empty profile.

These scripts build that lookup file, check it, repair it, and deploy the migration. Run them in order:

```
Step 1  Export-ADUsersForMigration        (domain controller)  -> AD user export
Step 2  Export-EntraUserMapping           (Graph)              -> Entra user export
Step 3  New-MigrationUserLookup           (combines 1 and 2)   -> lookup file
Step 4  Export-ForensiTAzureIdXml         (Graph)              -> ForensiTAzureID.xml
Step 5  Set-ProfileFolderNamesToUsername  (optional)           -> profile folders named by username
Step 6  Test-MigrationUserLookup          (validation)         -> entries that would fail
Step 7  Repair-MigrationUserLookup        (repair)             -> fix report
Step 8  Update-MigrationUserLookup        (apply fixes)        -> corrected lookup file
Step 9  Start-EntraProfileMigration       (deploy via RMM)     -> profile migrated on each device
```

Requires a ForensiT User Profile Wizard Corporate license.

| Script | What it does | Changes anything? |
|---|---|---|
| [Export-ADUsersForMigration](#export-adusersformigration) | Exports every enabled AD user with both username formats (jsmith and john.smith) and flags users whose two formats differ, since they need two lookup entries. | LOCAL FILES |
| [Export-EntraUserMapping](#export-entrausermapping) | Exports synced Entra ID users with the on-prem username Entra Connect stored on them, giving an exact old-to-new account link without guessing from names. | READ-ONLY |
| [New-MigrationUserLookup](#new-migrationuserlookup) | Combines Steps 1 and 2 into the final lookup file, with both username formats for every user, and reports AD users who will not migrate because they are not synced. | LOCAL FILES |
| [Export-ForensiTAzureIdXml](#export-forensitazureidxml) | Rebuilds ForensiT's Azure ID file directly from Microsoft Graph, backing up the old one first. | LOCAL FILES |
| [Set-ProfileFolderNamesToUsername](#set-profilefoldernamestousername) | Makes migrated profile folders use the username (jsmith) instead of the display name (John Smith). | LOCAL FILES (`-WhatIf`) |
| [Test-MigrationUserLookup](#test-migrationuserlookup) | Checks every lookup entry against the Azure ID file and lists any that would fail on migration day. | READ-ONLY |
| [Repair-MigrationUserLookup](#repair-migrationuserlookup) | Works out the correct account for entries that failed Step 6 and writes a fix report for you to review. | LOCAL FILES |
| [Update-MigrationUserLookup](#update-migrationuserlookup) | Applies the reviewed fix report to the lookup file. | LOCAL FILES |
| [Start-EntraProfileMigration](#start-entraprofilemigration) | Deployed through RMM. | WRITES (device) |

---

## Export-ADUsersForMigration

**LOCAL FILES** · [View script](Export-ADUsersForMigration.ps1)

**Step 1.** Exports every enabled AD user with both username formats (jsmith and john.smith) and flags users whose two formats differ, since they need two lookup entries.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 1. Exports every enabled AD user with both their pre-Windows 2000 username (sAMAccountName) and their UPN.

**How it works:**
1. Loads the ActiveDirectory module and shows the domain's DNS and NetBIOS names.
2. Exports all enabled users with sAMAccountName, UPN, the part of the UPN before the @, and display name.
3. Flags users whose sAMAccountName differs from their UPN username (for example `jsmith` versus `john.smith`). Their profile folder could be named after either one, so both need a lookup entry.
4. Saves the CSV and prints the number of mismatches with examples.

**Inputs:** `-OutputPath`.

**Outputs:** AD user CSV. Copy it to your workstation for the next step.

**Requirements:** ActiveDirectory module. Run on a domain controller or a computer with RSAT.

**Changes anything?** LOCAL FILES.

</details>

---

## Export-EntraUserMapping

**READ-ONLY** · [View script](Export-EntraUserMapping.ps1)

**Step 2.** Exports synced Entra ID users with the on-prem username Entra Connect stored on them, giving an exact old-to-new account link without guessing from names. Run it before turning off sync.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 2. Exports synced Entra ID users with the on-prem username that Entra Connect stored on them. This links old and new accounts exactly, without guessing from names.

**How it works:**
1. Installs Microsoft.Graph.Users if missing and connects with User.Read.All.
2. Pulls every user that has an `onPremisesSamAccountName`, meaning they are synced from AD.
3. Writes a full mapping report.
4. Builds a lookup file in `onprem,azure` format: one entry for the sAMAccountName, plus a second entry for the UPN username if it differs. Duplicates are removed.

**Inputs:** `-OutputFolder`.

**Outputs:** Full mapping report CSV and a lookup CSV.

**Requirements:** Module: Microsoft.Graph.Users. Graph permission: User.Read.All. **Run this before Entra Connect sync is turned off**, while users are still synced.

**Changes anything?** READ-ONLY in the tenant. Writes local files.

</details>

---

## New-MigrationUserLookup

**LOCAL FILES** · [View script](New-MigrationUserLookup.ps1)

**Step 3.** Combines Steps 1 and 2 into the final lookup file, with both username formats for every user, and reports AD users who will not migrate because they are not synced.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 3. Combines the AD export (step 1) and the Entra export (step 2) into the final lookup file.

**How it works:**
1. Checks that both export files exist, and says which script to run if one is missing.
2. Builds a lookup of Entra users by their on-prem username.
3. Sorts every AD user as matched or AD-only (not synced, so they will not migrate).
4. Counts matched users whose two username formats differ, since they need two lookup entries.
5. Saves a matched report and an AD-only report.
6. Builds the final lookup file with both username formats for every matched user.

**Inputs:** `-Folder` containing both exports.

**Outputs:** Comparison reports and the final lookup CSV.

**Requirements:** PowerShell only.

**Changes anything?** LOCAL FILES.

</details>

---

## Export-ForensiTAzureIdXml

**LOCAL FILES** · [View script](Export-ForensiTAzureIdXml.ps1)

**Step 4.** Rebuilds ForensiT's Azure ID file directly from Microsoft Graph, backing up the old one first. An out-of-date file is a common cause of failed migrations.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 4. Rebuilds the ForensiTAzureID.xml file directly from Microsoft Graph. ForensiT uses this file to find each user's Entra object ID, and an out-of-date file is a common cause of failed migrations.

**How it works:**
1. Installs and loads the Graph modules if needed, and connects with User.Read.All and Organization.Read.All.
2. Gets the tenant ID, name, and verified domains for the file's header.
3. Pulls every user with a UPN.
4. Writes the XML in ForensiT's format, escaping special characters.
5. Backs up any existing XML with a timestamp before replacing it.

**Inputs:** `-OutputPath`.

**Outputs:** ForensiTAzureID.xml and a backup of the previous file.

**Requirements:** Modules: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement. Graph permissions: User.Read.All, Organization.Read.All.

**Changes anything?** READ-ONLY in the tenant. Writes local files.

</details>

---

## Set-ProfileFolderNamesToUsername

**LOCAL FILES (`-WhatIf`)** · [View script](Set-ProfileFolderNamesToUsername.ps1)

**Step 5 (optional).** Makes migrated profile folders use the username (jsmith) instead of the display name (John Smith).

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 5 (optional). Changes each user's display name in ForensiTAzureID.xml to their UPN username, so migrated profile folders are named like `jsmith` instead of `John Smith`.

**How it works:**
1. Checks the XML exists and makes a timestamped backup.
2. For each user, takes the part of the UPN before the @ and removes characters Windows does not allow in folder names (`\ / : * ? " < > |`).
3. Replaces the display name with that value, or with `-WhatIf` only shows what would change.
4. Saves the XML and prints how many users were changed and skipped.

**Inputs:** `-XmlPath`, `-WhatIf`.

**Outputs:** Updated XML and a backup.

**Requirements:** PowerShell 5.1 or later.

**Changes anything?** LOCAL FILES. Edits the XML after backing it up. Supports `-WhatIf`.

</details>

---

## Test-MigrationUserLookup

**READ-ONLY** · [View script](Test-MigrationUserLookup.ps1)

**Step 6.** Checks every lookup entry against the Azure ID file and lists any that would fail on migration day. Run it before every wave.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 6. Confirms that every Entra UPN in the lookup file exists in ForensiTAzureID.xml. Any that do not will fail on migration day. Run it before every migration wave.

**How it works:** Loads the lookup file and the XML, builds a list of UPNs from the XML (ignoring upper or lower case), checks every lookup entry, and prints either "ALL CSV ENTRIES ARE VALID" or a red list of entries missing from the XML.

**Inputs:** `-CsvPath`, `-XmlPath`.

**Outputs:** Console results.

**Requirements:** PowerShell only.

**Changes anything?** READ-ONLY.

</details>

---

## Repair-MigrationUserLookup

**LOCAL FILES** · [View script](Repair-MigrationUserLookup.ps1)

**Step 7.** Works out the correct account for entries that failed Step 6 and writes a fix report for you to review. Assumes the first-initial-plus-last-name username pattern.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 7. For lookup entries that failed the check, works out the correct Entra account, keeping both username entries for each user.

**How it works:**
1. Loads every valid UPN from the XML.
2. First pass: collects every entry that is already valid, and indexes those by last name and full username.
3. Second pass: for each invalid entry, uses the valid ones to find the right UPN. For example, if `jsmith` is invalid but `john.smith` is valid, it uses that. It assumes short usernames are first initial plus last name.
4. Keeps both entries per user instead of dropping one.
5. Writes a corrected lookup file and a fix report for review.

**Inputs:** `-CsvPath`, `-XmlPath`, `-OutputFolder`.

**Outputs:** Corrected CSV and a fix report CSV.

**Requirements:** PowerShell only. **Assumes the first initial plus last name username pattern.** Check this matches the organization's naming before relying on the results.

**Changes anything?** LOCAL FILES. Writes new files and never overwrites the input.

</details>

---

## Update-MigrationUserLookup

**LOCAL FILES** · [View script](Update-MigrationUserLookup.ps1)

**Step 8.** Applies the reviewed fix report to the lookup file.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 8. Applies a fix report from step 7 (after you have reviewed or edited it) to the lookup file.

**How it works:** Loads the fix report into a list of old entry to new entry, goes through the lookup file replacing each matching entry, and saves a new corrected file with a count of the fixes applied.

**Inputs:** `-CsvPath`, `-FixReportPath`, `-OutputPath`.

**Outputs:** Corrected lookup CSV.

**Requirements:** PowerShell only.

**Changes anything?** LOCAL FILES. Writes a new file.

</details>

---

## Start-EntraProfileMigration

**WRITES (device)** · [View script](Start-EntraProfileMigration.ps1)

**Step 9.** Deployed through RMM. Cleans up leftovers from failed earlier attempts, downloads the migration package, checks it, and runs it. The device migrates and reboots.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Step 9. Deployed through an RMM tool (such as ConnectWise RMM) to download the ForensiT migration package to a device and run it. Cleans up after failed earlier attempts so re-runs work.

**How it works:**
1. Forces TLS 1.2 and sets up logging.
2. Pre-flight cleanup:
   - Deletes ForensiT's "already migrated" flag file, which otherwise makes a re-run stop and wait for keyboard input
   - Deletes the extraction folder left behind by a failed run
   - Removes a previously applied migration provisioning package
3. Downloads the package from the given URL to ProgramData and checks the file size.
4. Runs the package and waits for it to finish. ForensiT then migrates the profile and reboots the device.

**Inputs:** `-DownloadUrl` (required), `-PackageName`, `-ProvisioningPackageName`, `-MinimumSizeBytes`, `-LogPath`. If your RMM tool cannot pass parameters, set the defaults at the top of the script.

**Outputs:** Log file in `C:\ProgramData`.

**Requirements:** Runs as SYSTEM through RMM. Windows PowerShell 5.1. A ForensiT User Profile Wizard Corporate license and a configured migration package.

**Changes anything?** WRITES on the device. Runs the profile migration and reboots.

</details>

---

[Back to the toolkit](../../README.md)
