# Migration: on-prem AD to cloud-only Entra ID

Scripts for planning and tracking a move from hybrid (or fully on-prem) AD to Entra joined devices. This is the device side. Moving each user's Windows profile over is in [User-Profile-Migration](User-Profile-Migration/).

| Script | What it's for |
|---|---|
| [Get-DevicesToMigrate](Get-DevicesToMigrate.ps1) | Which devices still need to move, by category |
| [Get-DeviceMigrationStatus](Get-DeviceMigrationStatus.ps1) | Migration day check: did these devices show up yet? |
| [Export-DeviceMigrationWorkbook](Export-DeviceMigrationWorkbook.ps1) | The tracking workbook: every Windows device and its status |
| [Update-WorkbookDeviceCategories](Update-WorkbookDeviceCategories.ps1) | Fill in categories in the workbook, offline |
| [Find-MissingDeviceCategories](Find-MissingDeviceCategories.ps1) | Chase down devices with no category |

## Get-DevicesToMigrate

For planning waves. I usually split waves by Intune device category (office, department, whatever the client uses), so this takes one or more categories and lists every device in them that isn't Entra joined yet: hybrid joined, registered or unknown.

```powershell
.\Get-DevicesToMigrate.ps1 -Category "Corporate Office"
.\Get-DevicesToMigrate.ps1 -Category "Corporate Office","Sales" -OutputPath "C:\Reports\MigrationDevices.csv"
```

Prints breakdowns by join type, category and compliance, and lists any device that's in Intune with no matching Entra record. Read-only.

## Get-DeviceMigrationStatus

The one I keep open on migration day. Give it device names and it shows YES/NO for whether each one has appeared in Entra ID and in Intune yet.

```powershell
.\Get-DeviceMigrationStatus.ps1 -DeviceNames "LAPTOP-001","LAPTOP-002","DESKTOP-003"
```

Needs an existing Graph session (`Connect-MgGraph` first). Read-only.

## Export-DeviceMigrationWorkbook

Builds the workbook I track the whole project in: every Windows device with its join type, Intune category, primary user and a status of **Already migrated**, **Needs migration**, **Needs re-registration** or **Needs investigation**.

```powershell
.\Export-DeviceMigrationWorkbook.ps1
```

When the same device name shows up more than once (it happens a lot in hybrid environments), it keeps the record with the best join type. Saves `AllDevices.xlsx` to your Downloads folder by default. Needs ImportExcel.

## Update-WorkbookDeviceCategories

Offline helper. It takes the category export from [Export-IntuneDeviceCategories](../Intune/Admin/) and fills in the category column in the migration workbook, matching by device name. It updates anything that's "N/A" or out of date. No Graph calls, so it's fast to re-run.

```powershell
.\Update-WorkbookDeviceCategories.ps1
```

It overwrites the workbook in place, so keep a copy if you care about the old version.

## Find-MissingDeviceCategories

Takes every device still marked "N/A" for category in the workbook and checks it against Intune. Each one lands in one of three buckets: it actually has a category (the workbook was just stale), it's in Intune with no category, or it's not in Intune at all. The last two are the ones that need someone to look at them.

```powershell
.\Find-MissingDeviceCategories.ps1
```

Reads the workbook from Downloads by default and saves the results to Excel. Read-only in the tenant.

---

[Back to the toolkit](../README.md)
