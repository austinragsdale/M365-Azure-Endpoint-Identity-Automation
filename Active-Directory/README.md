# Active Directory (on-prem)

Mostly discovery and cleanup I run when a client is getting ready to move to the cloud. All three need the ActiveDirectory module, so run them on a DC or a machine with RSAT.

| Script | What it's for |
|---|---|
| [Export-GPOInventory](Export-GPOInventory.ps1) | Document every GPO and figure out which ones actually do anything |
| [Get-PasswordNeverExpiresUsers](Get-PasswordNeverExpiresUsers.ps1) | Find accounts with "password never expires" turned on |
| [Move-ComputersToDecommissionedOU](Move-ComputersToDecommissionedOU.ps1) | Move computers into an OU that Entra Connect doesn't sync |

## Export-GPOInventory

The first thing I run when planning a migration. Most domains have years of GPOs piled up and only some of them still matter. This goes through all of them and marks each one **Active** or **Inactive**, with the reason: unlinked, links disabled, all settings disabled, empty, or nobody actually has Apply permission.

```powershell
.\Export-GPOInventory.ps1
.\Export-GPOInventory.ps1 -IncludeDCRsop -OutputPath C:\Temp\Discovery
```

For each GPO you also get its links, enforcement, security filtering, WMI filter, whether the AD and SYSVOL versions match, and which setting areas are in use (registry, security, drive maps, folder redirection, scripts and so on). That last part is what you need to decide what gets rebuilt in Intune.

You get a folder of CSVs plus an HTML report per GPO. Skip the HTML with `-SkipHtmlReports` if the domain has hundreds of them. `-IncludeDCRsop` also runs gpresult on every DC to show what actually applied there (that part needs local admin on the DCs).

Read-only.

## Get-PasswordNeverExpiresUsers

A common audit finding. Lists every user with "password never expires" set, along with their manager, days since the password was last changed and days since last logon.

```powershell
.\Get-PasswordNeverExpiresUsers.ps1
.\Get-PasswordNeverExpiresUsers.ps1 -SearchBase "OU=Corp Users,DC=contoso,DC=com" -IncludeDisabledAccounts
```

Disabled accounts are left out unless you add `-IncludeDisabledAccounts`. Prints a quick summary and the five oldest passwords, and saves the full list as a CSV. Read-only.

## Move-ComputersToDecommissionedOU

During a hybrid-to-cloud move, you pull computers out of Entra Connect's sync scope by moving them into an OU that isn't synced. Doing that by hand in ADUC gets old fast.

```powershell
.\Move-ComputersToDecommissionedOU.ps1 -TargetOU "OU=Decommissioned Computers,DC=contoso,DC=com" -WhatIf
.\Move-ComputersToDecommissionedOU.ps1 -TargetOU "OU=Decommissioned Computers,DC=contoso,DC=com" -DeviceNames "DESKTOP-ABC123","LAPTOP-XYZ789"
```

Leave off `-DeviceNames` and it prompts you to type them in. It searches the whole domain for each computer, not just the Computers container, and doesn't care if you type a trailing `$`. If it finds two matches it stops and asks. It confirms each move and logs everything.

Make sure the target OU really is out of sync scope first. Otherwise this does nothing useful.

---

[Back to the toolkit](../README.md)
