<#
.SYNOPSIS
    Export complete device inventory from Entra ID and Intune for AD → Cloud migration.

.DESCRIPTION
    Queries all devices from both Entra ID (Get-MgDevice) and Intune (Get-MgDeviceManagementManagedDevice).
    Correlates and enriches data with join type, trust type, management state, OS, owner, and activity.
    Exports to CSV for migration planning and reporting.

.PARAMETER OutputPath
    Full path for the CSV export. Default: DeviceInventory_<timestamp>.csv in your Downloads folder

.EXAMPLE
    .\Export-EntraIntuneDeviceInventory.ps1

.EXAMPLE
    .\Export-EntraIntuneDeviceInventory.ps1 -OutputPath "C:\Temp\Devices.csv"

.NOTES
    Author: Austin Ragsdale
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement
    Permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $env:USERPROFILE "Downloads\DeviceInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv")
)

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement

#region Functions

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "SUCCESS" { "Green" }
            default { "Cyan" }
        }
    )
}

function Get-EntraJoinType {
    <#
    .DESCRIPTION
        Determines join type from Entra ID device object.
        - TrustType = "AzureAd" → Azure AD Joined
        - TrustType = "ServerAd" → Hybrid Azure AD Joined
        - TrustType = "Workplace" → Azure AD Registered (personal/BYOD)
        - Null/empty → Unknown
    #>
    param($Device)

    $trustType = $Device.TrustType

    switch ($trustType) {
        "AzureAd"   { return "Azure AD Joined" }
        "ServerAd"  { return "Hybrid Azure AD Joined" }
        "Workplace" { return "Azure AD Registered" }
        default     { return "Unknown" }
    }
}

function Get-DeviceOwner {
    <#
    .DESCRIPTION
        Retrieves the registered owner (user) of an Entra device.
        Uses /devices/{id}/registeredOwners endpoint.
    #>
    param([string]$DeviceId)

    try {
        $owners = Get-MgDeviceRegisteredOwner -DeviceId $DeviceId -ErrorAction SilentlyContinue
        if ($owners) {
            $ownerNames = $owners | ForEach-Object {
                $_.AdditionalProperties['displayName']
            }
            return ($ownerNames -join "; ")
        }
        return "None"
    }
    catch {
        return "Error"
    }
}

#endregion

#region Main Script

try {
    Write-Log "=== Entra ID + Intune Device Inventory Script ===" -Level "INFO"
    Write-Log "Output will be saved to: $OutputPath" -Level "INFO"

    # Step 1: Verify Graph connection
    Write-Log "Verifying Microsoft Graph connection..." -Level "INFO"
    $context = Get-MgContext

    if (-not $context) {
        Write-Log "Not connected to Microsoft Graph. Connecting..." -Level "WARN"
        Connect-MgGraph -Scopes "Device.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome
        Write-Log "Connected successfully." -Level "SUCCESS"
    }
    else {
        Write-Log "Already connected as: $($context.Account)" -Level "SUCCESS"
        $requiredScopes = @("Device.Read.All", "DeviceManagementManagedDevices.Read.All")
        $missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }

        if ($missingScopes) {
            Write-Log "Missing required scopes: $($missingScopes -join ', '). Reconnecting..." -Level "WARN"
            Disconnect-MgGraph | Out-Null
            Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        }
    }

    # Step 2: Fetch all Entra ID devices with pagination
    Write-Log "Fetching all devices from Entra ID..." -Level "INFO"
    $entraDevices = @()
    $pageCount = 0

    try {
        $entraDevicesResponse = Get-MgDevice -All -Property Id, DisplayName, OperatingSystem, OperatingSystemVersion, `
            TrustType, IsCompliant, IsManaged, ApproximateLastSignInDateTime, ProfileType, DeviceId, AccountEnabled

        $entraDevices = $entraDevicesResponse | ForEach-Object { $_ }
        Write-Log "Retrieved $($entraDevices.Count) devices from Entra ID." -Level "SUCCESS"
    }
    catch {
        Write-Log "Error fetching Entra ID devices: $($_.Exception.Message)" -Level "ERROR"
        throw
    }

    # Step 3: Fetch all Intune managed devices with pagination
    Write-Log "Fetching all managed devices from Intune..." -Level "INFO"
    $intuneDevices = @()

    try {
        $intuneDevicesResponse = Get-MgDeviceManagementManagedDevice -All -Property Id, DeviceName, OperatingSystem, `
            OSVersion, AzureADDeviceId, UserPrincipalName, ManagementAgent, ComplianceState, LastSyncDateTime, `
            EnrolledDateTime, Model, Manufacturer, SerialNumber

        $intuneDevices = $intuneDevicesResponse | ForEach-Object { $_ }
        Write-Log "Retrieved $($intuneDevices.Count) devices from Intune." -Level "SUCCESS"
    }
    catch {
        Write-Log "Error fetching Intune devices: $($_.Exception.Message)" -Level "ERROR"
        throw
    }

    # Step 4: Build correlation lookup (Intune devices by Azure AD Device ID)
    Write-Log "Correlating Entra ID and Intune data..." -Level "INFO"
    $intuneByAadId = @{}
    foreach ($intuneDev in $intuneDevices) {
        if ($intuneDev.AzureADDeviceId) {
            $intuneByAadId[$intuneDev.AzureADDeviceId] = $intuneDev
        }
    }

    # Step 5: Build unified device inventory
    Write-Log "Building unified device inventory..." -Level "INFO"
    $inventory = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($entraDev in $entraDevices) {
        $joinType = Get-EntraJoinType -Device $entraDev
        $intuneMatch = $intuneByAadId[$entraDev.DeviceId]

        # Determine management type
        $managementType = if ($intuneMatch) {
            switch ($intuneMatch.ManagementAgent) {
                "mdm"               { "Intune (MDM)" }
                "eas"               { "Exchange ActiveSync" }
                "easMdm"            { "EAS + Intune" }
                "configurationManagerClient" { "ConfigMgr" }
                "configurationManagerClientMdm" { "Co-Managed (ConfigMgr + Intune)" }
                default             { $intuneMatch.ManagementAgent }
            }
        }
        elseif ($entraDev.IsManaged) {
            "Managed (non-Intune)"
        }
        else {
            "Unmanaged"
        }

        # Build enriched object
        $deviceObj = [PSCustomObject]@{
            DeviceName              = $entraDev.DisplayName
            EntraDeviceId           = $entraDev.Id
            AzureADDeviceId         = $entraDev.DeviceId
            IntuneDeviceId          = if ($intuneMatch) { $intuneMatch.Id } else { $null }
            OperatingSystem         = $entraDev.OperatingSystem
            OSVersion               = if ($intuneMatch) { $intuneMatch.OSVersion } else { $entraDev.OperatingSystemVersion }
            JoinType                = $joinType
            TrustType               = $entraDev.TrustType
            ManagementType          = $managementType
            IsCompliant             = $entraDev.IsCompliant
            ComplianceState         = if ($intuneMatch) { $intuneMatch.ComplianceState } else { "N/A" }
            AccountEnabled          = $entraDev.AccountEnabled
            LastSignIn              = $entraDev.ApproximateLastSignInDateTime
            LastSyncDateTime        = if ($intuneMatch) { $intuneMatch.LastSyncDateTime } else { $null }
            EnrolledDateTime        = if ($intuneMatch) { $intuneMatch.EnrolledDateTime } else { $null }
            UserPrincipalName       = if ($intuneMatch) { $intuneMatch.UserPrincipalName } else { "N/A" }
            Manufacturer            = if ($intuneMatch) { $intuneMatch.Manufacturer } else { "N/A" }
            Model                   = if ($intuneMatch) { $intuneMatch.Model } else { "N/A" }
            SerialNumber            = if ($intuneMatch) { $intuneMatch.SerialNumber } else { "N/A" }
        }

        $inventory.Add($deviceObj)
    }

    # Step 6: Add Intune-only devices (not in Entra ID - rare but possible for Android/iOS personal)
    $entraDeviceIds = $entraDevices.DeviceId
    $intuneOnlyDevices = $intuneDevices | Where-Object { $_.AzureADDeviceId -notin $entraDeviceIds }

    if ($intuneOnlyDevices) {
        Write-Log "Found $($intuneOnlyDevices.Count) Intune-only devices (no Entra ID object)." -Level "WARN"
        foreach ($intuneDev in $intuneOnlyDevices) {
            $deviceObj = [PSCustomObject]@{
                DeviceName              = $intuneDev.DeviceName
                EntraDeviceId           = $null
                AzureADDeviceId         = $intuneDev.AzureADDeviceId
                IntuneDeviceId          = $intuneDev.Id
                OperatingSystem         = $intuneDev.OperatingSystem
                OSVersion               = $intuneDev.OSVersion
                JoinType                = "Intune-Only (No Entra Object)"
                TrustType               = "N/A"
                ManagementType          = "Intune (MDM)"
                IsCompliant             = $null
                ComplianceState         = $intuneDev.ComplianceState
                AccountEnabled          = $null
                LastSignIn              = $null
                LastSyncDateTime        = $intuneDev.LastSyncDateTime
                EnrolledDateTime        = $intuneDev.EnrolledDateTime
                UserPrincipalName       = $intuneDev.UserPrincipalName
                Manufacturer            = $intuneDev.Manufacturer
                Model                   = $intuneDev.Model
                SerialNumber            = $intuneDev.SerialNumber
            }
            $inventory.Add($deviceObj)
        }
    }

    # Step 7: Export to CSV
    Write-Log "Exporting $($inventory.Count) devices to CSV..." -Level "INFO"
    $inventory | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Log "Export complete: $OutputPath" -Level "SUCCESS"

    # Step 8: Summary statistics
    Write-Log "=== SUMMARY ===" -Level "INFO"
    Write-Log "Total devices: $($inventory.Count)" -Level "INFO"

    $joinTypeSummary = $inventory | Group-Object JoinType | Select-Object Name, Count
    Write-Log "Join Type Breakdown:" -Level "INFO"
    $joinTypeSummary | ForEach-Object { Write-Log "  - $($_.Name): $($_.Count)" -Level "INFO" }

    $managementSummary = $inventory | Group-Object ManagementType | Select-Object Name, Count
    Write-Log "Management Type Breakdown:" -Level "INFO"
    $managementSummary | ForEach-Object { Write-Log "  - $($_.Name): $($_.Count)" -Level "INFO" }

    $osSummary = $inventory | Group-Object OperatingSystem | Select-Object Name, Count | Sort-Object Count -Descending
    Write-Log "Operating System Breakdown:" -Level "INFO"
    $osSummary | ForEach-Object { Write-Log "  - $($_.Name): $($_.Count)" -Level "INFO" }

}
catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    exit 1
}
finally {
    Write-Log "Script execution completed." -Level "INFO"
}

#endregion
