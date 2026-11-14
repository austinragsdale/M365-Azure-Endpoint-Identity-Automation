<#
.SYNOPSIS
    Offline helper. Copies Intune device categories from one workbook into the device workbook,
    matching rows by device name. Does not connect to Graph.
.PARAMETER DeviceWorkbook
    Workbook to update (from Export-DeviceMigrationWorkbook.ps1). It is overwritten with the result.
    Default: AllDevices.xlsx in your Downloads folder.
.PARAMETER CategoryWorkbook
    Workbook with the categories (from Export-IntuneDeviceCategories.ps1).
    Default: IntuneDeviceCategories.xlsx in your Downloads folder.
.EXAMPLE
    .\Update-WorkbookDeviceCategories.ps1
.NOTES
    Author: Austin Ragsdale
    Requires ImportExcel.
#>
[CmdletBinding()]
param(
    [string]$DeviceWorkbook = (Join-Path $env:USERPROFILE 'Downloads\AllDevices.xlsx'),
    [string]$CategoryWorkbook = (Join-Path $env:USERPROFILE 'Downloads\IntuneDeviceCategories.xlsx')
)

Import-Module ImportExcel

Write-Host "Loading AllDevices.xlsx..." -ForegroundColor Cyan
$allDevices = Import-Excel $DeviceWorkbook
Write-Host "Loaded $($allDevices.Count) devices"

Write-Host "Loading IntuneDeviceCategories.xlsx..." -ForegroundColor Cyan
$intuneCategories = Import-Excel $CategoryWorkbook
Write-Host "Loaded $($intuneCategories.Count) Intune devices with categories"

# Build lookup by device name
$categoryLookup = @{}
foreach ($device in $intuneCategories) {
    if ($device.DeviceName -and $device.DeviceCategoryDisplayName) {
        $categoryLookup[$device.DeviceName] = $device.DeviceCategoryDisplayName
    }
}

# Update categories
$updatedCount = 0
$updatedDevices = foreach ($device in $allDevices) {
    $newCategory = $device.DeviceCategory

    if ($categoryLookup.ContainsKey($device.DeviceName)) {
        $newCategory = $categoryLookup[$device.DeviceName]
        if ($device.DeviceCategory -eq "N/A" -or $device.DeviceCategory -ne $newCategory) {
            $updatedCount++
        }
    }

    [PSCustomObject]@{
        DeviceName = $device.DeviceName
        UserPrincipalName = $device.UserPrincipalName
        JoinType = $device.JoinType
        DeviceCategory = $newCategory
        DuplicateCount = $device.DuplicateCount
        Status = $device.Status
    }
}

Write-Host "Updated $updatedCount device categories" -ForegroundColor Green

# Export
$outPath = $DeviceWorkbook
if (Test-Path $outPath) { Remove-Item $outPath -Force }

$updatedDevices | Export-Excel -Path $outPath -WorksheetName "All Devices" -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter

Write-Host "Saved to: $outPath" -ForegroundColor Green
Write-Host ""
Write-Host "Category Breakdown:" -ForegroundColor Cyan
$updatedDevices | Group-Object DeviceCategory | Sort-Object Count -Descending | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)"
}
