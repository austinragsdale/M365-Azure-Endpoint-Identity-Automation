# Intune: Admin

Run these from your own machine. They all talk to Intune through Microsoft Graph, and a few use the `/beta` endpoint because that's the only place some of the data lives.

| Script | What it's for |
|---|---|
| [Export-EntraIntuneDeviceInventory](Export-EntraIntuneDeviceInventory.ps1) | One device list combining Entra ID and Intune |
| [Export-IntuneDeviceCategories](Export-IntuneDeviceCategories.ps1) | Every device and its category, in Excel |
| [Get-NonCompliantWindowsDevices](Get-NonCompliantWindowsDevices.ps1) | Which setting is failing on which device |
| [Get-DevicePrimaryUser](Get-DevicePrimaryUser.ps1) | Untangle "Enrolled user exists" compliance failures |
| [Set-IntunePrimaryUserAndCategory](Set-IntunePrimaryUserAndCategory.ps1) | Bulk set primary user and category from a spreadsheet |
| [Remove-DevicesFromIntuneAndEntra](Remove-DevicesFromIntuneAndEntra.ps1) | Delete retired devices from both places |
| [Export-MacOSUpdateProfiles](Export-MacOSUpdateProfiles.ps1) | Compare two macOS update profiles for conflicts |
| [Export-CompliancePolicies](Export-CompliancePolicies.ps1) | Back up every compliance policy to JSON |
| [Import-CompliancePolicies](Import-CompliancePolicies.ps1) | Import compliance policies into the same or another tenant |

## Export-EntraIntuneDeviceInventory

Entra ID and Intune each have their own idea of what devices exist. This pulls both, matches them on the Entra device ID, and gives you one CSV with join type (Entra joined, hybrid, registered), owner, OS, compliance and last activity for each device.

```powershell
.\Export-EntraIntuneDeviceInventory.ps1 -OutputPath "C:\Temp\Devices.csv"
```

I mostly use it at the start of an AD-to-cloud migration to see where every device stands. Devices that only exist in Intune (usually personal phones) are included too. Read-only.

## Export-IntuneDeviceCategories

Quick one. Every Intune device with its category, exported to Excel, plus a count per category on screen.

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
.\Export-IntuneDeviceCategories.ps1
```

Needs ImportExcel. Its output also feeds Update-WorkbookDeviceCategories in the [Migration](../../Migration/) folder.

## Get-NonCompliantWindowsDevices

The Intune portal tells you a device is noncompliant. It's a lot less helpful about *why*, especially across a few hundred devices. This lists every Windows device that isn't compliant and every failing setting on it, one row per device, policy and setting.

```powershell
.\Get-NonCompliantWindowsDevices.ps1 -OutputFolder C:\Temp
```

It treats anything that isn't "compliant" as a problem: noncompliant, error, in grace period, unknown. It also pulls every Windows device without a server-side filter, because server-side filtering can miss some. The summary at the end counts failures by setting, with its own section for Secure Boot.

Read-only.

## Get-DevicePrimaryUser

For devices failing the "Enrolled user exists" compliance check. That usually happens because Intune and Entra ID disagree about who the device belongs to. This puts all four user links side by side so the mismatch is obvious: Intune enrolled user, Intune primary user, Entra registered owner and Entra registered users.

```powershell
.\Get-DevicePrimaryUser.ps1 -DeviceNames "LAPTOP-001","DESKTOP-002"
```

Read-only. Saves a CSV with one row per device.

## Set-IntunePrimaryUserAndCategory

After a migration, devices tend to show up in Intune with the wrong primary user or none at all. This fixes them in bulk from an Excel sheet with three columns: `Device name`, `Category` and `Primary user UPN`.

```powershell
.\Set-IntunePrimaryUserAndCategory.ps1 -ExcelPath "C:\Temp\DeviceMappings.xlsx" -DryRun
.\Set-IntunePrimaryUserAndCategory.ps1 -ExcelPath "C:\Temp\DeviceMappings.xlsx"
```

It clears any existing primary user and then assigns the new one. Device names with apostrophes are handled. At the end you get counts for each failure type (device, user or category not found) and a CSV of anything that failed, so you can fix the sheet and re-run just those.

Needs ImportExcel and the Intune Administrator role.

## Remove-DevicesFromIntuneAndEntra

Deletes devices from Intune and Entra ID in one pass, for retired hardware or devices being re-enrolled during a migration.

```powershell
.\Remove-DevicesFromIntuneAndEntra.ps1 -WhatIf
.\Remove-DevicesFromIntuneAndEntra.ps1 -DeviceNames "DESKTOP-ABC123","LAPTOP-XYZ789"
```

Leave off `-DeviceNames` and it lets you type them in, one per line (type DONE to finish). It shows you the list, asks before deleting, and stops if two devices share a name.

> **Back up BitLocker keys first.** Deleting a device from Entra ID also deletes the recovery keys stored on it, and you can't undo it.

Needs Intune Administrator plus Cloud Device Administrator.

## Export-MacOSUpdateProfiles

For when a Settings Catalog macOS update policy and a custom profile (often one a compliance vendor pushes) seem to be fighting each other. It exports both to JSON so you can diff them. If the custom profile has a .mobileconfig payload, it decodes it from Base64 so you can actually read the settings.

```powershell
.\Export-MacOSUpdateProfiles.ps1 -SettingsCatalogName "macOS Automated Updates" -CustomProfileName "macOS Software Update"
```

Part of each name is enough. If the Settings Catalog policy isn't found, it lists the ones that exist. Read-only.

## Export-CompliancePolicies / Import-CompliancePolicies

A backup and restore pair for compliance policies, all platforms. Use them to restore a policy someone deleted, or to build a new tenant's compliance baseline in one go instead of clicking through the portal.

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All","Group.Read.All"

.\Export-CompliancePolicies.ps1 -OutputPath C:\Backups\Compliance

.\Import-CompliancePolicies.ps1 -Path C:\Backups\Compliance            # dry run
.\Import-CompliancePolicies.ps1 -Path C:\Backups\Compliance -Apply -Assign
```

The export writes one JSON file per policy, with the read-only fields already removed, and an `assignments.csv` that records group *names*. Group IDs are different in every tenant, so the import looks groups up by name when you use `-Assign`.

The import is a dry run unless you add `-Apply`, and it never overwrites a policy that already exists. A few things it deals with for you:

- Graph won't create a compliance policy without an action for noncompliance, so if a file has none it adds the default (mark noncompliant immediately).
- Notification templates that don't exist in the new tenant are dropped from the action. The action itself stays.
- Groups that don't exist in the new tenant are reported, not created.

Custom compliance scripts aren't carried over. They're tenant-specific.

---

[Back to Intune](../README.md)
