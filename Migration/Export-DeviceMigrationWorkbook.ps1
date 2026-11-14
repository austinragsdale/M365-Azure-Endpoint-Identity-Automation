<#
.SYNOPSIS
    Exports every Windows device with its join type, Intune device category, primary user,
    and migration status to an Excel workbook, for planning a move to cloud-only Entra ID.
.PARAMETER OutputPath
    Excel file to create. Default: AllDevices.xlsx in your Downloads folder.
.EXAMPLE
    .\Export-DeviceMigrationWorkbook.ps1
.NOTES
    Author: Austin Ragsdale
    Requires Microsoft.Graph device modules and ImportExcel.
    Scopes: Device.Read.All, DeviceManagementManagedDevices.Read.All
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $env:USERPROFILE 'Downloads\AllDevices.xlsx')
)

Import-Module ImportExcel

#region Logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}
#endregion

try {
    Write-Log "=== All Devices Export with Device Category ==="

    # Verify Graph connection
    $context = Get-MgContext
    if (-not $context) {
        Write-Log "Not connected to Graph. Connecting..." -Level WARN
        Connect-MgGraph -Scopes "Device.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome
    } else {
        Write-Log "Connected as: $($context.Account)" -Level SUCCESS
    }

    # Step 1: Get all Entra ID devices (for join type)
    Write-Log "Fetching all Entra ID devices..."
    $entraDevices = Get-MgDevice -All -Property Id, DisplayName, DeviceId, TrustType, OperatingSystem, IsManaged, ApproximateLastSignInDateTime
    Write-Log "Retrieved $($entraDevices.Count) Entra ID devices" -Level SUCCESS

    # Step 2: Get all Intune managed devices (for device category and user)
    Write-Log "Fetching all Intune managed devices..."
    $intuneDevices = Get-MgDeviceManagementManagedDevice -All -Property Id, DeviceName, AzureADDeviceId, UserPrincipalName, DeviceCategoryDisplayName, ManagementAgent, ComplianceState, LastSyncDateTime
    Write-Log "Retrieved $($intuneDevices.Count) Intune devices" -Level SUCCESS

    # Build Intune lookup by AzureADDeviceId
    $intuneLookup = @{}
    foreach ($device in $intuneDevices) {
        if ($device.AzureADDeviceId) {
            $intuneLookup[$device.AzureADDeviceId] = $device
        }
    }

    # Step 3: Filter to Windows only and build combined list
    Write-Log "Building combined device list (Windows only)..."

    $joinTypeMap = @{
        "AzureAd" = "Azure AD Joined"
        "ServerAd" = "Hybrid Azure AD Joined"
        "Workplace" = "Azure AD Registered"
    }

    $statusMap = @{
        "Azure AD Joined" = "Already migrated"
        "Hybrid Azure AD Joined" = "Needs migration"
        "Azure AD Registered" = "Needs re-registration"
        "Unknown" = "Needs investigation"
    }

    $joinTypePriority = @{
        "Azure AD Joined" = 1
        "Hybrid Azure AD Joined" = 2
        "Azure AD Registered" = 3
        "Unknown" = 4
    }

    $allDevices = foreach ($entra in $entraDevices) {
        # Windows only
        if ($entra.OperatingSystem -ne "Windows") { continue }

        # Handle null TrustType
        $trustType = $entra.TrustType
        $joinType = "Unknown"
        if ($trustType -and $joinTypeMap.ContainsKey($trustType)) {
            $joinType = $joinTypeMap[$trustType]
        }

        # Handle null DeviceId for Intune lookup
        $intuneMatch = $null
        if ($entra.DeviceId) {
            $intuneMatch = $intuneLookup[$entra.DeviceId]
        }

        # Get device category
        $deviceCategory = "N/A"
        if ($intuneMatch -and $intuneMatch.DeviceCategoryDisplayName) {
            $deviceCategory = $intuneMatch.DeviceCategoryDisplayName
        }

        # Get status
        $status = "Needs investigation"
        if ($statusMap.ContainsKey($joinType)) {
            $status = $statusMap[$joinType]
        }

        [PSCustomObject]@{
            DeviceName = $entra.DisplayName
            UserPrincipalName = if ($intuneMatch -and $intuneMatch.UserPrincipalName) { $intuneMatch.UserPrincipalName } else { "N/A" }
            JoinType = $joinType
            DeviceCategory = $deviceCategory
            DuplicateCount = 1
            Status = $status
            AzureADDeviceId = $entra.DeviceId
        }
    }

    Write-Log "Total Windows device objects: $($allDevices.Count)"

    # Step 4: Deduplicate by DeviceName (keep best join type)
    Write-Log "Deduplicating by device name..."

    $uniqueDevices = $allDevices | Group-Object DeviceName | ForEach-Object {
        $count = $_.Count
        $best = $_.Group | Sort-Object {
            $jt = $_.JoinType
            if ($jt -and $joinTypePriority.ContainsKey($jt)) { $joinTypePriority[$jt] } else { 99 }
        } | Select-Object -First 1

        [PSCustomObject]@{
            DeviceName = $best.DeviceName
            UserPrincipalName = $best.UserPrincipalName
            JoinType = $best.JoinType
            DeviceCategory = $best.DeviceCategory
            DuplicateCount = $count
            Status = $best.Status
        }
    }

    Write-Log "Unique devices: $($uniqueDevices.Count)" -Level SUCCESS

    # Step 5: Sort and export
    $sorted = $uniqueDevices | Sort-Object {
        $jt = $_.JoinType
        if ($jt -and $joinTypePriority.ContainsKey($jt)) { $joinTypePriority[$jt] } else { 99 }
    }, DeviceName

    $outPath = $OutputPath
    if (Test-Path $outPath) { Remove-Item $outPath -Force }

    $sorted | Export-Excel -Path $outPath -WorksheetName "All Devices" -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter

    Write-Log "Exported to: $outPath" -Level SUCCESS

    # Summary
    Write-Host ""
    Write-Log "=== SUMMARY ==="
    Write-Log "Total unique Windows devices: $($sorted.Count)"
    Write-Host ""
    Write-Log "By Status:"
    $sorted | Group-Object Status | Sort-Object {
        switch ($_.Name) { "Already migrated" {1}; "Needs migration" {2}; "Needs re-registration" {3}; "Needs investigation" {4} }
    } | ForEach-Object { Write-Log "  $($_.Name): $($_.Count)" }

    Write-Host ""
    Write-Log "By Device Category:"
    $sorted | Group-Object DeviceCategory | Sort-Object Count -Descending | ForEach-Object {
        Write-Log "  $($_.Name): $($_.Count)"
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
}
