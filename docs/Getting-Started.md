# Getting started

## 1. PowerShell version

Most scripts run in Windows PowerShell 5.1 or PowerShell 7. Remove-OldMailboxMessages needs PowerShell 7. Scripts deployed to devices (On-Device, Autopilot, Security) are written for Windows PowerShell 5.1 running as SYSTEM.

## 2. Install the modules

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser   # Entra ID, Intune, Exchange through Graph
Install-Module ImportExcel -Scope CurrentUser       # scripts that read or write Excel
# Active Directory scripts need RSAT: Settings > Optional features > RSAT: Active Directory
```

## 3. Connect to Microsoft Graph

Connect with only the permissions the script lists in its help:

```powershell
Connect-MgGraph -Scopes "Device.Read.All","DeviceManagementManagedDevices.Read.All"
Get-MgContext   # confirm the account and tenant before running anything
```

## 4. Read the help, then preview

```powershell
Get-Help .\Intune\Admin\Remove-DevicesFromIntuneAndEntra.ps1 -Full
.\Intune\Admin\Remove-DevicesFromIntuneAndEntra.ps1 -DeviceNames "LAPTOP-001" -WhatIf
```

Scripts that change things support `-WhatIf` or `-DryRun`. Run that first and read the output.

## 5. Running scripts downloaded from GitHub

Windows blocks downloaded scripts by default. After reviewing a script, unblock it:

```powershell
Unblock-File .\Script-Name.ps1
```

---

[Back to the toolkit](../README.md)
