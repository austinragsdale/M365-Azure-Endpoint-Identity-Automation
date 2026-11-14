<#
.SYNOPSIS
    Exports every Intune managed device with its device category to Excel and prints a count per category.
.PARAMETER OutputPath
    Excel file to create. Default: IntuneDeviceCategories.xlsx in your Downloads folder.
.EXAMPLE
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
    .\Export-IntuneDeviceCategories.ps1
.NOTES
    Author: Austin Ragsdale
    Requires an existing Graph session, Microsoft.Graph.DeviceManagement and ImportExcel.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $env:USERPROFILE 'Downloads\IntuneDeviceCategories.xlsx')
)

Import-Module ImportExcel

Write-Host "Fetching all Intune managed devices with device category..." -ForegroundColor Cyan

$devices = Get-MgDeviceManagementManagedDevice -All -Property DeviceName, UserPrincipalName, DeviceCategoryDisplayName, OperatingSystem, ManagementAgent

Write-Host "Retrieved $($devices.Count) devices" -ForegroundColor Green

$results = $devices | Select-Object DeviceName, UserPrincipalName, DeviceCategoryDisplayName, OperatingSystem

$outPath = $OutputPath
if (Test-Path $outPath) { Remove-Item $outPath -Force }

$results | Export-Excel -Path $outPath -WorksheetName "Device Categories" -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter

Write-Host "Exported to: $outPath" -ForegroundColor Green
Write-Host ""
Write-Host "Category Breakdown:" -ForegroundColor Cyan
$results | Group-Object DeviceCategoryDisplayName | Sort-Object Count -Descending | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)"
}
