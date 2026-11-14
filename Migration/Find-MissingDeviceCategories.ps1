<#
.SYNOPSIS
    Finds devices marked "N/A" for category in the device workbook and checks whether Intune
    actually has a category for them, so the workbook can be corrected.
.PARAMETER DeviceWorkbook
    Device workbook to check (from Export-DeviceMigrationWorkbook.ps1).
    Default: AllDevices.xlsx in your Downloads folder.
.PARAMETER OutputPath
    Excel file for the results. Default: NA_Devices_CategoryLookup.xlsx in your Downloads folder.
.EXAMPLE
    .\Find-MissingDeviceCategories.ps1
.NOTES
    Author: Austin Ragsdale
    Requires Microsoft.Graph.DeviceManagement and ImportExcel.
#>
[CmdletBinding()]
param(
    [string]$DeviceWorkbook = (Join-Path $env:USERPROFILE 'Downloads\AllDevices.xlsx'),
    [string]$OutputPath = (Join-Path $env:USERPROFILE 'Downloads\NA_Devices_CategoryLookup.xlsx')
)

Import-Module ImportExcel

Write-Host "=== Finding Device Categories for N/A Devices ===" -ForegroundColor Cyan

# Verify Graph connection
$context = Get-MgContext
if (-not $context) {
    Write-Host "Not connected to Graph. Connecting..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes "Device.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome
}

# Get N/A devices from the spreadsheet
$allDevices = Import-Excel $DeviceWorkbook
$naDevices = $allDevices | Where-Object { $_.DeviceCategory -eq "N/A" }

Write-Host "Found $($naDevices.Count) devices with N/A category in spreadsheet" -ForegroundColor Cyan
Write-Host ""

# Get all Intune devices
Write-Host "Fetching all Intune managed devices..." -ForegroundColor Cyan
$intuneDevices = Get-MgDeviceManagementManagedDevice -All -Property DeviceName, AzureADDeviceId, DeviceCategoryDisplayName, UserPrincipalName

# Build lookup by device name
$intuneByName = @{}
foreach ($device in $intuneDevices) {
    if ($device.DeviceName) {
        $intuneByName[$device.DeviceName] = $device
    }
}

Write-Host "Retrieved $($intuneDevices.Count) Intune devices" -ForegroundColor Green
Write-Host ""

# Look up each N/A device by name in Intune
$results = foreach ($device in $naDevices) {
    $intuneMatch = $intuneByName[$device.DeviceName]

    [PSCustomObject]@{
        DeviceName = $device.DeviceName
        UserPrincipalName = $device.UserPrincipalName
        JoinType = $device.JoinType
        Sheet_Category = $device.DeviceCategory
        Intune_Category = if ($intuneMatch -and $intuneMatch.DeviceCategoryDisplayName) {
            $intuneMatch.DeviceCategoryDisplayName
        } else {
            "NOT FOUND IN INTUNE"
        }
        InIntune = if ($intuneMatch) { "Yes" } else { "No" }
    }
}

# Summary
$foundInIntune = $results | Where-Object { $_.InIntune -eq "Yes" }
$hasCategory = $foundInIntune | Where-Object { $_.Intune_Category -ne "NOT FOUND IN INTUNE" -and $_.Intune_Category }
$notInIntune = $results | Where-Object { $_.InIntune -eq "No" }

Write-Host "=== RESULTS ===" -ForegroundColor Cyan
Write-Host "Total N/A devices: $($results.Count)"
Write-Host "Found in Intune: $($foundInIntune.Count)"
Write-Host "Have category in Intune: $($hasCategory.Count)"
Write-Host "NOT in Intune: $($notInIntune.Count)"
Write-Host ""

# Show devices that have categories in Intune
if ($hasCategory.Count -gt 0) {
    Write-Host "=== Devices WITH Category in Intune (should update) ===" -ForegroundColor Green
    $hasCategory | Format-Table DeviceName, Intune_Category, JoinType -AutoSize
}

# Show devices not in Intune at all
if ($notInIntune.Count -gt 0) {
    Write-Host "=== Devices NOT in Intune ===" -ForegroundColor Yellow
    $notInIntune | Select-Object DeviceName, JoinType -First 20 | Format-Table -AutoSize
    if ($notInIntune.Count -gt 20) {
        Write-Host "... and $($notInIntune.Count - 20) more"
    }
}

# Export full results
$outPath = $OutputPath
if (Test-Path $outPath) { Remove-Item $outPath -Force }
$results | Export-Excel -Path $outPath -WorksheetName "NA Device Lookup" -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter

Write-Host ""
Write-Host "Full results exported to: $outPath" -ForegroundColor Green
