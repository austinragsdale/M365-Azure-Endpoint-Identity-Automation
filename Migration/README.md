# Migration: on-prem AD to cloud-only Entra ID

Tools for planning and tracking a move from hybrid or on-prem Active Directory to cloud-only Entra ID joined devices.

| Script | What it does | Changes anything? |
|---|---|---|
| [Get-DevicesToMigrate](#get-devicestomigrate) | Lists every device that still needs to move from hybrid joined or registered to cloud-only Entra joined, filtered by the Intune device categories you choose. | READ-ONLY |
| [Get-DeviceMigrationStatus](#get-devicemigrationstatus) | A quick YES/NO table showing whether specific devices have shown up in Entra ID and Intune yet. | READ-ONLY |
| [Export-DeviceMigrationWorkbook](#export-devicemigrationworkbook) | Builds one Excel workbook of every Windows device with its join type, Intune category, primary user, and migration status (Already migrated, Needs migration, Needs re-registration, Needs investigation). | READ-ONLY |
| [Update-WorkbookDeviceCategories](#update-workbookdevicecategories) | Offline helper that fills in the category column of the migration workbook from an Intune category export, without calling Graph again. | LOCAL FILES |
| [Find-MissingDeviceCategories](#find-missingdevicecategories) | Checks every device marked "N/A" for category in the migration workbook against Intune, and sorts them into: has a category, in Intune without one, or not in Intune at all. | READ-ONLY |

## Subfolders

- [User Profile Migration](User-Profile-Migration/): the 9-step ForensiT toolchain that moves each person's Windows profile to their Entra ID account

---

## Get-DevicesToMigrate

**READ-ONLY** · [View script](Get-DevicesToMigrate.ps1)

Lists every device that still needs to move from hybrid joined or registered to cloud-only Entra joined, filtered by the Intune device categories you choose. Use it to plan migration waves.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Lists the devices that still need to move from hybrid joined or registered to cloud-only Entra joined, limited to chosen device categories, so migration waves can be planned.

**How it works:**
1. Pulls all Intune managed devices and keeps only those in the chosen categories.
2. Pulls all Entra ID devices and matches them by Entra device ID to get the join type.
3. Keeps only migration candidates: hybrid joined, registered, or unknown. Devices already Entra joined are excluded.
4. Sorts by category, join type, and name, then exports a CSV.
5. Prints breakdowns by join type, category, and compliance, plus devices with no Entra record.

**Inputs:** `-Category` (one or more Intune device categories), `-OutputPath`.

**Outputs:** CSV and console statistics.

**Requirements:** Microsoft Graph device modules. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All.

**Changes anything?** READ-ONLY.

</details>

---

## Get-DeviceMigrationStatus

**READ-ONLY** · [View script](Get-DeviceMigrationStatus.ps1)

A quick YES/NO table showing whether specific devices have shown up in Entra ID and Intune yet. Use it on migration day to confirm each device made it.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** A quick check during a migration of whether specific devices have appeared in Entra ID and Intune yet.

**How it works:** For each device name, queries Entra ID and Intune and prints a color-coded table with YES or NO columns.

**Inputs:** `-DeviceNames` (required).

**Outputs:** Console table.

**Requirements:** Modules: Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement, an existing Graph session. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All.

**Changes anything?** READ-ONLY.

</details>

---

## Export-DeviceMigrationWorkbook

**READ-ONLY** · [View script](Export-DeviceMigrationWorkbook.ps1)

Builds one Excel workbook of every Windows device with its join type, Intune category, primary user, and migration status (Already migrated, Needs migration, Needs re-registration, Needs investigation).

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Builds one Excel workbook of every Windows device with its join type, Intune device category, primary user, and migration status, to plan and track a move to cloud-only Entra ID.

**How it works:**
1. Connects to Graph if needed.
2. Pulls all Entra ID devices (for join type) and all Intune devices (for category and primary user).
3. Keeps Windows devices only, handling missing join types and device IDs.
4. Gives each device a status: Already migrated, Needs migration, Needs re-registration, or Needs investigation.
5. Removes duplicates by device name, keeping the record with the best join type.
6. Sorts and exports to Excel, then prints counts by status and by category.

**Inputs:** `-OutputPath` (default: AllDevices.xlsx in your Downloads folder).

**Outputs:** Excel workbook and console summary.

**Requirements:** Microsoft Graph device modules and ImportExcel. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All.

**Changes anything?** READ-ONLY in the tenant. Writes a local Excel file.

</details>

---

## Update-WorkbookDeviceCategories

**LOCAL FILES** · [View script](Update-WorkbookDeviceCategories.ps1)

Offline helper that fills in the category column of the migration workbook from an Intune category export, without calling Graph again.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** An offline helper that fills in the device category column of the device workbook from the category export, without calling Graph again.

**How it works:** Loads the device workbook and the category workbook, matches rows by device name, updates the category where it is "N/A" or out of date, saves the workbook, and prints a category breakdown.

**Inputs:** `-DeviceWorkbook` (from Export-DeviceMigrationWorkbook) and `-CategoryWorkbook` (from Export-IntuneDeviceCategories). Both default to your Downloads folder.

**Outputs:** The updated device workbook (overwritten in place).

**Requirements:** ImportExcel.

**Changes anything?** LOCAL FILES. Overwrites the device workbook.

</details>

---

## Find-MissingDeviceCategories

**READ-ONLY** · [View script](Find-MissingDeviceCategories.ps1)

Checks every device marked "N/A" for category in the migration workbook against Intune, and sorts them into: has a category, in Intune without one, or not in Intune at all.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Takes the devices marked "N/A" for category in the device workbook and checks whether Intune actually has a category for them, so the workbook can be corrected.

**How it works:**
1. Reads the "N/A" devices from the workbook.
2. Pulls all Intune devices and builds a lookup by device name.
3. Sorts each device into one of three groups: has a category in Intune (update the workbook), in Intune without a category, or not in Intune at all.
4. Prints the results and exports them to Excel.

**Inputs:** `-DeviceWorkbook` and `-OutputPath`. Both default to your Downloads folder.

**Outputs:** Excel results file and console lists.

**Requirements:** Microsoft.Graph.DeviceManagement, ImportExcel.

**Changes anything?** READ-ONLY in the tenant. Writes a local Excel file.

</details>

---

[Back to the toolkit](../README.md)
