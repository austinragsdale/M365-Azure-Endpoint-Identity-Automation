# Permissions by script

What each script needs to run. Grant only what the script you are running needs.

| Script | Requirements |
|---|---|
| Add-LicenseToUsers | Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, ImportExcel (installs automatically if missing). Graph permissions: User.ReadWrite.All, Organization.Read.All. Role: License Administrator or higher. |
| Add-UsersToEntraGroup | PowerShell 5.1 or 7. Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Users. Graph permissions: Group.ReadWrite.All, GroupMember.ReadWrite.All, User.Read.All. Role: Groups Administrator or User Administrator. |
| Enable-WindowsLocationServices | Intune platform script, run as SYSTEM, 64-bit PowerShell. |
| Export-ADUsersForMigration | ActiveDirectory module. Run on a domain controller or a computer with RSAT. |
| Export-AutopilotHardwareHash | Windows PowerShell 5.1, run as administrator. Internet access to the PowerShell Gallery. |
| Export-DeviceMigrationWorkbook | Microsoft Graph device modules and ImportExcel. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All. |
| Export-EntraIntuneDeviceInventory | Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All. |
| Export-EntraUserMapping | Module: Microsoft.Graph.Users. Graph permission: User.Read.All. **Run this before Entra Connect sync is turned off**, while users are still synced. |
| Export-ForensiTAzureIdXml | Modules: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement. Graph permissions: User.Read.All, Organization.Read.All. |
| Export-GPOInventory | GroupPolicy and ActiveDirectory modules (RSAT or a domain controller). Domain user read rights. `-IncludeDCRsop` needs local admin on each domain controller. |
| Export-IntuneDeviceCategories | An existing Graph session (`Connect-MgGraph -Scopes DeviceManagementManagedDevices.Read.All`). Modules: Microsoft.Graph.DeviceManagement, ImportExcel. |
| Export-MacOSUpdateProfiles | Module: Microsoft.Graph.Authentication. Graph permission: DeviceManagementConfiguration.Read.All. Uses the Graph `/beta` endpoint. |
| Find-MissingDeviceCategories | Microsoft.Graph.DeviceManagement, ImportExcel. |
| Find-UnauthorizedScreenConnect | Windows PowerShell 5.1, SYSTEM context, run through an RMM tool. **Do not run it through ScreenConnect's own Run Command.** |
| Get-DeviceMigrationStatus | Modules: Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement, an existing Graph session. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All. |
| Get-DevicePrimaryUser | Module: Microsoft.Graph.Authentication. Graph permissions: DeviceManagementManagedDevices.Read.All, Device.Read.All, User.Read.All. Uses the Graph `/beta` endpoint. |
| Get-DevicesToMigrate | Microsoft Graph device modules. Graph permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All. |
| Get-FortiEDRUsbCrashRisk | Administrator or SYSTEM. Runs through an RMM tool. |
| Get-NonCompliantWindowsDevices | Module: Microsoft.Graph.Authentication (installs automatically). Graph permissions: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All. Uses the Graph `/beta` endpoint. |
| Get-PasswordExpiryReport | Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Users. Graph permission: User.Read.All. |
| Get-PasswordNeverExpiresUsers | ActiveDirectory module. Domain user read rights. |
| Get-UsbDeviceInventory | SYSTEM, through an RMM tool. |
| Install-UpdatesDuringAutopilot | Intune Win32 app, SYSTEM context, assigned to the pre-provisioning device group. `Soft` reboot mode depends on Autopilot's automatic sign-in working, so test it first. Packaging steps are in the folder README (the `.intunewin` build output is not stored in the repo). |
| Move-ComputersToDecommissionedOU | ActiveDirectory module (RSAT or a domain controller). Rights to move computer objects. |
| New-MigrationUserLookup | PowerShell only. |
| Remove-DevicesFromIntuneAndEntra | Modules: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement. Graph permissions: DeviceManagementManagedDevices.ReadWrite.All, Device.ReadWrite.All. Roles: Intune Administrator plus Cloud Device Administrator. |
| Remove-OldMailboxMessages | PowerShell 7. Module: Microsoft.Graph.Authentication. Delegated permission: Mail.ReadWrite.Shared. The signed-in admin needs Full Access to the mailbox (allow 30 to 60 minutes after granting it). |
| Repair-DefenderCompliance | Runs as SYSTEM (Intune remediation or RMM). Windows PowerShell 5.1. A reboot afterwards is recommended. |
| Repair-MigrationUserLookup | PowerShell only. **Assumes the first initial plus last name username pattern.** Check this matches the organization's naming before relying on the results. |
| Resolve-UserUPNsFromNames | PowerShell 5.1 or 7. Module: Microsoft.Graph.Users. Graph permission: User.Read.All. |
| Set-IntunePrimaryUserAndCategory | Modules: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, ImportExcel. Graph permissions: DeviceManagementManagedDevices.ReadWrite.All, User.Read.All. Role: Intune Administrator. Uses the Graph `/beta` endpoint. |
| Set-ProfileFolderNamesToUsername | PowerShell 5.1 or later. |
| Start-EntraProfileMigration | Runs as SYSTEM through RMM. Windows PowerShell 5.1. A ForensiT User Profile Wizard Corporate license and a configured migration package. |
| Sync-CompanyDirectoryContacts | Azure Automation, PowerShell 7.2 runtime, no extra modules. Managed identity with User.Read.All (Entra app role) and Contacts.ReadWrite granted **only** through Exchange RBAC for Applications with a management scope. Granting Contacts.ReadWrite in Entra instead would give the runbook access to every mailbox in the tenant. |
| Test-DeviceInSetup | Uploaded on the Win32 app's Requirements tab, not inside the package. |
| Test-FortiEDRReadiness | SYSTEM or administrator. Runs through an RMM tool. |
| Test-MigrationUserLookup | PowerShell only. |
| Update-MigrationUserLookup | PowerShell only. |
| Update-WorkbookDeviceCategories | ImportExcel. |

---

[Back to the toolkit](../README.md)
