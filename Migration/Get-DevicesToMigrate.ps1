<#
.SYNOPSIS
    Export Intune managed devices requiring migration from Hybrid/Registered join to cloud-only Entra ID.

.DESCRIPTION
    Queries ALL Intune managed devices in the device categories given in -Category,
    cross-references with Entra ID devices to determine join type (TrustType),
    filters to migration candidates (Hybrid Azure AD Joined, Azure AD Registered, Unknown),
    and exports CSV with detailed device information sorted by category/join type/name.

.PARAMETER Category
    One or more Intune device category names to include. Required.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\MigrationPriorityDevices_<timestamp>.csv

.EXAMPLE
    .\Get-DevicesToMigrate.ps1 -Category "Corporate Office"
    Uses default output path in current directory.

.EXAMPLE
    .\Get-DevicesToMigrate.ps1 -Category "Corporate Office","Sales" -OutputPath "C:\Reports\MigrationDevices.csv"
    Exports to specified path.

.NOTES
    Author: Austin Ragsdale
    Requires: Microsoft.Graph modules (Authentication, DeviceManagement, Identity.DirectoryManagement)
    Permissions: Device.Read.All, DeviceManagementManagedDevices.Read.All
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Category,

    [Parameter()]
    [string]$OutputPath = ".\MigrationPriorityDevices_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

#region Logging Function
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage -ForegroundColor White }
    }
}
#endregion

#region Helper Functions
function Get-JoinTypeFromTrustType {
    param([string]$TrustType)

    switch ($TrustType) {
        "ServerAd"  { return "Hybrid Azure AD Joined" }
        "Workplace" { return "Azure AD Registered" }
        "AzureAd"   { return "Azure AD Joined" }
        default     { return "Unknown" }
    }
}

function Test-GraphConnection {
    try {
        $context = Get-MgContext
        if ($null -eq $context) {
            return $false
        }

        $requiredScopes = @(
            'Device.Read.All',
            'DeviceManagementManagedDevices.Read.All'
        )

        $missingScopes = $requiredScopes | Where-Object { $context.Scopes -notcontains $_ }

        if ($missingScopes.Count -gt 0) {
            Write-Log "Connected to Graph but missing required scopes: $($missingScopes -join ', ')" -Level WARNING
            return $false
        }

        Write-Log "Existing Graph connection verified with required scopes." -Level SUCCESS
        return $true
    }
    catch {
        return $false
    }
}
#endregion

#region Main Script
try {
    Write-Log "========================================" -Level INFO
    Write-Log "Migration Priority Devices Export Tool" -Level INFO
    Write-Log "========================================" -Level INFO
    Write-Host ""

    # Verify or establish Graph connection
    Write-Log "Checking Microsoft Graph connection..." -Level INFO

    if (-not (Test-GraphConnection)) {
        Write-Log "Connecting to Microsoft Graph..." -Level INFO

        $requiredScopes = @(
            'Device.Read.All',
            'DeviceManagementManagedDevices.Read.All'
        )

        try {
            Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
            Write-Log "Successfully connected to Microsoft Graph." -Level SUCCESS
        }
        catch {
            Write-Log "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Level ERROR
            exit 1
        }
    }

    $context = Get-MgContext
    Write-Log "Tenant: $($context.TenantId)" -Level INFO
    Write-Log "Account: $($context.Account)" -Level INFO
    Write-Host ""

    # Step 1: Query ALL Intune managed devices
    Write-Log "Querying ALL Intune managed devices (this may take several minutes)..." -Level INFO

    $intuneDevices = @()
    $pageCount = 0

    try {
        $deviceParams = @{
            All = $true
            Select = @(
                'id',
                'deviceName',
                'userPrincipalName',
                'azureADDeviceId',
                'managementAgent',
                'complianceState',
                'lastSyncDateTime',
                'model',
                'serialNumber',
                'deviceCategoryDisplayName'
            )
        }

        $intuneDevices = Get-MgDeviceManagementManagedDevice @deviceParams

        Write-Log "Retrieved $($intuneDevices.Count) total Intune managed devices." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to query Intune devices: $($_.Exception.Message)" -Level ERROR
        throw
    }

    # Step 2: Filter to the requested categories
    Write-Log "Filtering to device categories: $($Category -join ', ')..." -Level INFO

    $targetCategories = @($Category)
    $filteredDevices = $intuneDevices | Where-Object {
        $_.DeviceCategoryDisplayName -in $targetCategories
    }

    Write-Log "Found $($filteredDevices.Count) devices matching target categories." -Level SUCCESS

    if ($filteredDevices.Count -eq 0) {
        Write-Log "No devices found with specified categories. Exiting." -Level WARNING
        exit 0
    }

    # Step 3: Query ALL Entra ID devices for join type cross-reference
    Write-Log "Querying ALL Entra ID devices for join type cross-reference..." -Level INFO

    $entraDevices = @{}

    try {
        $entraDeviceParams = @{
            All = $true
            Select = @('deviceId', 'displayName', 'trustType')
        }

        $entraDeviceList = Get-MgDevice @entraDeviceParams

        # Build hashtable for fast lookup: azureADDeviceId → Entra device object
        foreach ($device in $entraDeviceList) {
            if ($device.DeviceId) {
                $entraDevices[$device.DeviceId] = $device
            }
        }

        Write-Log "Retrieved $($entraDeviceList.Count) Entra ID devices for cross-reference." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to query Entra ID devices: $($_.Exception.Message)" -Level ERROR
        throw
    }

    # Step 4: Cross-reference and map join types
    Write-Log "Cross-referencing Intune devices with Entra ID join types..." -Level INFO

    $enrichedDevices = foreach ($device in $filteredDevices) {
        $entraDevice = $null
        $trustType = $null
        $entraDeviceId = $null

        if ($device.AzureADDeviceId) {
            $entraDevice = $entraDevices[$device.AzureADDeviceId]
            if ($entraDevice) {
                $trustType = $entraDevice.TrustType
                $entraDeviceId = $entraDevice.Id
            }
        }

        $joinType = Get-JoinTypeFromTrustType -TrustType $trustType

        [PSCustomObject]@{
            DeviceName             = $device.DeviceName
            UserPrincipalName      = $device.UserPrincipalName
            DeviceCategory         = $device.DeviceCategoryDisplayName
            JoinType               = $joinType
            TrustType              = if ($trustType) { $trustType } else { "N/A" }
            ManagementType         = $device.ManagementAgent
            ComplianceState        = $device.ComplianceState
            LastSyncDateTime       = $device.LastSyncDateTime
            Model                  = $device.Model
            SerialNumber           = $device.SerialNumber
            AzureADDeviceId        = $device.AzureADDeviceId
            EntraDeviceId          = $entraDeviceId
            IntuneDeviceId         = $device.Id
        }
    }

    Write-Log "Cross-reference complete." -Level SUCCESS

    # Step 5: Filter to migration candidates (exclude "Azure AD Joined")
    Write-Log "Filtering to migration candidates (excluding Azure AD Joined devices)..." -Level INFO

    $migrationCandidates = $enrichedDevices | Where-Object {
        $_.JoinType -in @('Hybrid Azure AD Joined', 'Azure AD Registered', 'Unknown')
    }

    Write-Log "Found $($migrationCandidates.Count) devices requiring migration." -Level SUCCESS

    if ($migrationCandidates.Count -eq 0) {
        Write-Log "No migration candidates found. All devices are already Azure AD Joined." -Level WARNING
        exit 0
    }

    # Step 6: Sort and export
    Write-Log "Sorting by DeviceCategory, JoinType, DeviceName..." -Level INFO

    $sortedDevices = $migrationCandidates | Sort-Object DeviceCategory, JoinType, DeviceName

    Write-Log "Exporting to CSV: $OutputPath" -Level INFO

    try {
        $sortedDevices | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Log "CSV export completed successfully." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to export CSV: $($_.Exception.Message)" -Level ERROR
        throw
    }

    # Step 7: Summary statistics
    Write-Host ""
    Write-Log "========================================" -Level INFO
    Write-Log "SUMMARY STATISTICS" -Level INFO
    Write-Log "========================================" -Level INFO

    Write-Log "Total Intune devices queried: $($intuneDevices.Count)" -Level INFO
    Write-Log "Devices in target categories ($($Category -join '/')): $($filteredDevices.Count)" -Level INFO
    Write-Log "Migration candidates (excluding Azure AD Joined): $($migrationCandidates.Count)" -Level INFO
    Write-Host ""

    # Breakdown by join type
    Write-Log "Breakdown by Join Type:" -Level INFO
    $joinTypeStats = $migrationCandidates | Group-Object JoinType | Sort-Object Count -Descending
    foreach ($stat in $joinTypeStats) {
        Write-Log "  $($stat.Name): $($stat.Count)" -Level INFO
    }
    Write-Host ""

    # Breakdown by device category
    Write-Log "Breakdown by Device Category:" -Level INFO
    $categoryStats = $migrationCandidates | Group-Object DeviceCategory | Sort-Object Name
    foreach ($stat in $categoryStats) {
        Write-Log "  $($stat.Name): $($stat.Count)" -Level INFO
    }
    Write-Host ""

    # Breakdown by compliance state
    Write-Log "Breakdown by Compliance State:" -Level INFO
    $complianceStats = $migrationCandidates | Group-Object ComplianceState | Sort-Object Count -Descending
    foreach ($stat in $complianceStats) {
        Write-Log "  $($stat.Name): $($stat.Count)" -Level INFO
    }
    Write-Host ""

    # Devices with no Entra ID match (orphaned)
    $orphanedDevices = $migrationCandidates | Where-Object { $_.JoinType -eq "Unknown" }
    if ($orphanedDevices.Count -gt 0) {
        Write-Log "WARNING: $($orphanedDevices.Count) devices have no Entra ID match (Unknown join type)." -Level WARNING
        Write-Log "These may be orphaned, stale, or have mismatched azureADDeviceId." -Level WARNING
        Write-Host ""
    }

    Write-Log "Export path: $OutputPath" -Level SUCCESS
    Write-Log "Script completed successfully." -Level SUCCESS
    Write-Log "========================================" -Level INFO
}
catch {
    Write-Log "Script failed with error: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
finally {
    # Optional: Disconnect from Graph (comment out if you want to keep the session)
    # Disconnect-MgGraph -ErrorAction SilentlyContinue
}
#endregion
