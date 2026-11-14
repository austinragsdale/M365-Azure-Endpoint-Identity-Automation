# Intune: Admin

Reports and bulk actions run from an admin workstation through Microsoft Graph.

| Script | What it does | Changes anything? |
|---|---|---|
| [Export-EntraIntuneDeviceInventory](#export-entraintunedeviceinventory) | Combines Entra ID and Intune device records into one inventory with join type, owner, compliance, and last activity. | READ-ONLY |
| [Export-IntuneDeviceCategories](#export-intunedevicecategories) | Exports every Intune device with its category to Excel and prints a count per category. | READ-ONLY |
| [Get-NonCompliantWindowsDevices](#get-noncompliantwindowsdevices) | Lists every Windows device that is not compliant and the exact policy setting failing on each one, including a Secure Boot summary. | READ-ONLY |
| [Get-DevicePrimaryUser](#get-deviceprimaryuser) | Shows every user linked to a device in both Intune and Entra ID side by side, to troubleshoot "Enrolled user exists" compliance failures. | READ-ONLY |
| [Set-IntunePrimaryUserAndCategory](#set-intuneprimaryuserandcategory) | Bulk sets each device's primary user and device category from a spreadsheet. | WRITES (`-DryRun`) |
| [Remove-DevicesFromIntuneAndEntra](#remove-devicesfromintuneandentra) | Deletes retired devices from both Intune and Entra ID, confirming each one. | WRITES, deletes (`-WhatIf`) |
| [Export-MacOSUpdateProfiles](#export-macosupdateprofiles) | Exports a Settings Catalog profile and a custom macOS update profile to JSON, decoding the custom profile's payload, so conflicting settings can be compared. | READ-ONLY |

---

## Export-EntraIntuneDeviceInventory

**READ-ONLY** · [View script](Export-EntraIntuneDeviceInventory.ps1)

Combines Entra ID and Intune device records into one inventory with join type, owner, compliance, and last activity.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Builds one complete device list by combining Entra ID device records with Intune managed device records. Mainly used to plan a move from on-prem AD to cloud-only Entra ID.

**How it works:**
1. Checks for or creates a Graph connection.
2. Pulls every Entra ID device and every Intune managed device, with paging.
3. Matches them on the Entra device ID.
4. For each device, works out the join type (Entra joined, hybrid joined, registered), management type, OS, owner, compliance state, and last activity.
5. Adds devices found only in Intune (rare, usually personal phones).
6. Exports a CSV and prints summary counts.

**Inputs:** `-OutputPath`.

**Outputs:** CSV inventory and console statistics.

**Requirements:** Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All.

**Changes anything?** READ-ONLY.

</details>

---

## Export-IntuneDeviceCategories

**READ-ONLY** · [View script](Export-IntuneDeviceCategories.ps1)

Exports every Intune device with its category to Excel and prints a count per category.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** A quick export of every Intune managed device with its device category, plus a count per category. Also feeds Update-WorkbookDeviceCategories.

**How it works:** Pulls all Intune managed devices (name, primary user, category, OS), exports them to Excel with filters and a frozen header row, and prints a breakdown by category.

**Inputs:** `-OutputPath` (default: IntuneDeviceCategories.xlsx in your Downloads folder).

**Outputs:** Excel workbook and a console breakdown.

**Requirements:** An existing Graph session (`Connect-MgGraph -Scopes DeviceManagementManagedDevices.Read.All`). Modules: Microsoft.Graph.DeviceManagement, ImportExcel.

**Changes anything?** READ-ONLY in the tenant. Writes a local Excel file.

</details>

---

## Get-NonCompliantWindowsDevices

**READ-ONLY** · [View script](Get-NonCompliantWindowsDevices.ps1)

Lists every Windows device that is not compliant and the exact policy setting failing on each one, including a Secure Boot summary.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Finds every Windows device that is not fully compliant in Intune and shows exactly which setting, in which policy, is failing.

**How it works:**
1. Pulls every Windows managed device with no server-side filter, because filtering on the server can miss devices.
2. Treats anything that is not "compliant" as in scope: noncompliant, error, in grace period, unknown, and so on.
3. For each device, pulls every compliance policy state and every setting state inside it, so nothing is hidden.
4. If a policy reports a state but returns no settings, logs the policy itself.
5. Prints a compliance state breakdown, a count of failures by setting, and a dedicated Secure Boot section.
6. Exports one CSV row per device, policy, and setting.

**Inputs:** `-OutputFolder`.

**Outputs:** Detailed CSV and console summaries.

**Requirements:** Module: Microsoft.Graph.Authentication (installs automatically). Graph permissions: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All. Uses the Graph `/beta` endpoint.

**Changes anything?** READ-ONLY.

</details>

---

## Get-DevicePrimaryUser

**READ-ONLY** · [View script](Get-DevicePrimaryUser.ps1)

Shows every user linked to a device in both Intune and Entra ID side by side, to troubleshoot "Enrolled user exists" compliance failures.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Troubleshoots devices failing the Intune "Enrolled user exists" compliance check by showing every user link the device has, side by side.

**How it works:** For each device name, pulls four things from Graph:
1. The Intune managed device record (enrolled user, UPN, IDs)
2. The Intune primary user
3. The matching Entra ID device object
4. The Entra ID registered owner and registered users

Everything goes into one CSV row per device, so mismatches between the four are easy to spot.

**Inputs:** `-DeviceNames` (required), `-OutputFolder`.

**Outputs:** CSV and console output per device.

**Requirements:** Module: Microsoft.Graph.Authentication. Graph permissions: DeviceManagementManagedDevices.Read.All, Device.Read.All, User.Read.All. Uses the Graph `/beta` endpoint.

**Changes anything?** READ-ONLY.

</details>

---

## Set-IntunePrimaryUserAndCategory

**WRITES (`-DryRun`)** · [View script](Set-IntunePrimaryUserAndCategory.ps1)

Bulk sets each device's primary user and device category from a spreadsheet. Built for fixing devices after a migration.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Bulk sets each Intune device's primary user and device category from an Excel mapping sheet. Used after a migration, when devices arrive in Intune with a wrong or missing primary user.

**How it works:**
1. Imports the Excel file and checks for the required columns: "Device name", "Category", "Primary user UPN".
2. Connects to Graph and loads all device categories into a lookup that ignores upper or lower case.
3. For each row: finds the device in Intune (handling apostrophes in names), the user, and the category.
4. Sets the primary user by first removing any existing one, then assigning the new one.
5. Sets the device category.
6. Counts results: Successful, Failed, Device not found, User not found, Category not found.
7. Writes a log file and a CSV of failed devices.

**Inputs:** `-ExcelPath` (required), `-DryRun`, `-LogPath`.

**Outputs:** Log file, failed-devices CSV, and a console summary.

**Requirements:** Modules: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, ImportExcel. Graph permissions: DeviceManagementManagedDevices.ReadWrite.All, User.Read.All. Role: Intune Administrator. Uses the Graph `/beta` endpoint.

**Changes anything?** WRITES. Changes primary user and category. `-DryRun` previews.

</details>

---

## Remove-DevicesFromIntuneAndEntra

**WRITES, deletes (`-WhatIf`)** · [View script](Remove-DevicesFromIntuneAndEntra.ps1)

Deletes retired devices from both Intune and Entra ID, confirming each one. **Deleting from Entra ID also deletes the device's BitLocker keys, so back them up first.**

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Deletes devices from both Intune and Entra ID in bulk. Used when retiring devices, or when re-enrolling them during a hybrid-to-cloud migration.

**How it works:**
1. Checks for the required Graph modules and connects with the needed permissions.
2. Takes device names from `-DeviceNames`, or prompts you to type them one per line (type DONE to finish).
3. Shows the list and asks for confirmation.
4. For each device:
   - Finds it in Intune and deletes it, stopping to ask if more than one device has the same name
   - Finds it in Entra ID and deletes it
   - Escapes apostrophes in device names for the Graph filter
5. Prints deleted, not found, and failed counts for each service, and logs everything.

**Inputs:** `-DeviceNames` (optional), `-WhatIf`, `-LogPath`.

**Outputs:** Log file and console summary.

**Requirements:** Modules: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement. Graph permissions: DeviceManagementManagedDevices.ReadWrite.All, Device.ReadWrite.All. Roles: Intune Administrator plus Cloud Device Administrator.

**Changes anything?** WRITES, deletes. Supports `-WhatIf` and confirms each device. **Deleting a device from Entra ID cannot be undone and also deletes the BitLocker recovery keys stored on it. Back up BitLocker keys first.**

</details>

---

## Export-MacOSUpdateProfiles

**READ-ONLY** · [View script](Export-MacOSUpdateProfiles.ps1)

Exports a Settings Catalog profile and a custom macOS update profile to JSON, decoding the custom profile's payload, so conflicting settings can be compared.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Exports two macOS software update profiles side by side so you can check them for conflicting settings: a Settings Catalog policy and a custom configuration profile (for example one pushed by a compliance vendor).

**How it works:**
1. Connects to Graph.
2. Finds the Settings Catalog policy by name and exports it, with all its settings, to JSON. If it is not found, lists the available policies.
3. Finds the custom profile by name and exports it. If it contains a .mobileconfig payload, decodes it from Base64 so the actual settings are readable.
4. Prints a summary and disconnects.

**Inputs:** `-SettingsCatalogName` and `-CustomProfileName` (required; part of the name is enough), `-OutputPath`.

**Outputs:** Two JSON files.

**Requirements:** Module: Microsoft.Graph.Authentication. Graph permission: DeviceManagementConfiguration.Read.All. Uses the Graph `/beta` endpoint.

**Changes anything?** READ-ONLY.

</details>

---

[Back to the toolkit](../../README.md)
