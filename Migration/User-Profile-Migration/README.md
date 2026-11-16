# User Profile Migration (ForensiT)

When a device moves from AD to Entra ID, the user signs in with a new account and gets a brand new, empty Windows profile. [ForensiT User Profile Wizard](https://www.forensit.com/domain-migration.html) fixes that by re-assigning their existing profile (desktop, documents, settings, everything) to the new Entra account.

The hard part isn't ForensiT. It's the lookup file that tells it which old AD account belongs to which new Entra account. If an entry is wrong, that person signs in to an empty profile on migration day and calls the help desk. These scripts build that file, check it, fix it and then deploy the migration.

You need a ForensiT User Profile Wizard Corporate license. Most of the scripts default to ForensiT's `CSV-xml` deployment folder, so if you use the standard install path you can usually run them without any parameters.

## The order I run them in

```
1  Export-ADUsersForMigration        on a DC         AD users, both username formats
2  Export-EntraUserMapping           Graph           synced Entra users + their on-prem username
3  New-MigrationUserLookup           local           combines 1 and 2 into the lookup file
4  Export-ForensiTAzureIdXml         Graph           fresh ForensiTAzureID.xml
5  Set-ProfileFolderNamesToUsername  local          optional: folders named jsmith, not "John Smith"
6  Test-MigrationUserLookup          local           anything that will fail?
7  Repair-MigrationUserLookup        local           work out fixes for the failures
8  Update-MigrationUserLookup        local           apply the fixes you approved
9  Start-EntraProfileMigration       RMM, on device  run the migration
```

Do step 2 **before** you turn off Entra Connect sync. Once sync is off, the link between the AD and Entra accounts is gone.

## 1. Export-ADUsersForMigration

[Export-ADUsersForMigration.ps1](Export-ADUsersForMigration.ps1). Run on a domain controller or anything with RSAT.

Exports every enabled AD user with their sAMAccountName, UPN and display name. The thing to watch is users whose two usernames don't match, like `jsmith` vs `john.smith`. Their profile folder could be named after either one, so they need two entries in the lookup file. The script counts them and shows a few examples.

```powershell
.\Export-ADUsersForMigration.ps1 -OutputPath C:\Temp\OnPrem-AD-Users.csv
```

Copy the CSV to wherever you're running the rest.

## 2. Export-EntraUserMapping

[Export-EntraUserMapping.ps1](Export-EntraUserMapping.ps1)

Pulls every synced user from Entra ID along with the on-prem username Entra Connect stamped on them (`onPremisesSamAccountName`). That gives you an exact old-to-new match with no guessing from display names, which is why it has to run while sync is still on.

```powershell
.\Export-EntraUserMapping.ps1
```

Writes a full mapping report and a lookup CSV in ForensiT's `onprem,azure` format, with a second entry for anyone whose UPN username is different.

## 3. New-MigrationUserLookup

[New-MigrationUserLookup.ps1](New-MigrationUserLookup.ps1)

Combines the two exports into the final lookup file, with both username formats for every matched user. It also gives you a list of AD users who *aren't* synced. They won't migrate, and it's better to find that out now. If either export is missing, it tells you which script to run.

```powershell
.\New-MigrationUserLookup.ps1 -Folder C:\Temp\Migration
```

## 4. Export-ForensiTAzureIdXml

[Export-ForensiTAzureIdXml.ps1](Export-ForensiTAzureIdXml.ps1)

ForensiT uses ForensiTAzureID.xml to find each user's Entra object ID. An out-of-date copy is one of the most common reasons a migration fails. This rebuilds it straight from Graph (tenant ID, verified domains and every user) and backs up the old one first.

```powershell
.\Export-ForensiTAzureIdXml.ps1
```

## 5. Set-ProfileFolderNamesToUsername (optional)

[Set-ProfileFolderNamesToUsername.ps1](Set-ProfileFolderNamesToUsername.ps1)

By default, migrated profile folders get named after the display name, so you end up with `C:\Users\John Smith`. This changes the names in the XML to the UPN username so you get `C:\Users\jsmith` instead, and strips out characters Windows doesn't allow in folder names.

```powershell
.\Set-ProfileFolderNamesToUsername.ps1 -WhatIf
```

It backs up the XML before changing it.

## 6. Test-MigrationUserLookup

[Test-MigrationUserLookup.ps1](Test-MigrationUserLookup.ps1)

Checks every Entra UPN in the lookup file against the XML. Anything missing from the XML will fail on migration day. You either get "ALL CSV ENTRIES ARE VALID" or a red list of problems.

```powershell
.\Test-MigrationUserLookup.ps1
```

Run it before every wave, not just once. People get renamed and hired in the middle of a project.

## 7. Repair-MigrationUserLookup

[Repair-MigrationUserLookup.ps1](Repair-MigrationUserLookup.ps1)

For the entries that failed step 6, it uses the entries that *did* pass to work out the right account. For example, if `jsmith` failed but `john.smith` is valid, it maps `jsmith` to that account too. It keeps both entries per user and writes a corrected file plus a fix report. It never overwrites the input.

```powershell
.\Repair-MigrationUserLookup.ps1
```

**It assumes short usernames are first initial + last name.** If the client uses a different pattern, don't trust the results without reading the fix report.

## 8. Update-MigrationUserLookup

[Update-MigrationUserLookup.ps1](Update-MigrationUserLookup.ps1)

Read the fix report from step 7 and edit it if you need to. Then this applies it to the lookup file and saves a new, corrected copy.

```powershell
.\Update-MigrationUserLookup.ps1 -CsvPath .\UserLookup-FINAL.csv -FixesPath .\Fixes-Report-v2.csv -OutputPath .\UserLookup-CORRECTED.csv
```

## 9. Start-EntraProfileMigration

[Start-EntraProfileMigration.ps1](Start-EntraProfileMigration.ps1). Deployed through RMM, runs as SYSTEM.

Downloads your ForensiT migration package to the device and runs it. ForensiT moves the profile and reboots.

```powershell
.\Start-EntraProfileMigration.ps1 -DownloadUrl 'https://example.com/Migrate-Entra.exe' -ProvisioningPackageName '*Entra Migration*'
```

Before it starts, it cleans up after any earlier failed attempt, which is what makes re-runs work:

- Deletes ForensiT's "already migrated" flag. Otherwise a re-run sits waiting for someone to press a key.
- Deletes the half-extracted folder from the failed run.
- Removes the migration provisioning package if it was already applied.

It checks the downloaded file's size before running it, so a failed download doesn't get executed. If your RMM tool can't pass parameters, set the defaults at the top of the script. With no download URL it exits with an error instead of guessing.

---

[Back to Migration](../README.md)
