#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement

<#
.SYNOPSIS
    Checks Entra ID and Intune enrollment status for a list of device names.

.DESCRIPTION
    Queries Microsoft Graph for each supplied device name and displays a formatted
    table showing whether the device is present in Entra ID and enrolled in Intune.

.PARAMETER DeviceNames
    One or more device display names to check. Mandatory.

.EXAMPLE
    .\Get-DeviceMigrationStatus.ps1 -DeviceNames "LAPTOP-001","LAPTOP-002","DESKTOP-003"

.EXAMPLE
    .\Get-DeviceMigrationStatus.ps1 -DeviceNames "LAPTOP-001"

.NOTES
    Requires the Microsoft.Graph.Identity.DirectoryManagement and
    Microsoft.Graph.DeviceManagement modules, and an active Connect-MgGraph
    session with at least Device.Read.All and DeviceManagementManagedDevices.Read.All
    permissions.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = 'One or more device display names to check.')]
    [string[]] $DeviceNames
)

# Verify an active Graph session exists before running any queries.
try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) {
        Write-Error 'No active Microsoft Graph session found. Run Connect-MgGraph before executing this script.'
        exit 1
    }
}
catch {
    Write-Error "Failed to retrieve Microsoft Graph context: $_"
    exit 1
}

# Column widths match the original one-liner layout.
$deviceColWidth  = 20
$entraColWidth   = 15
$intuneColWidth  = 10
$separatorLength = 45

$separator  = '-' * $separatorLength
$headerLine = "{0,-$deviceColWidth} {1,-$entraColWidth} {2,-$intuneColWidth}" -f 'DEVICE', 'ENTRA ID', 'INTUNE'

Write-Host ''
Write-Host '===== DEVICE MIGRATION STATUS =====' -ForegroundColor Cyan
Write-Host $headerLine -ForegroundColor White
Write-Host $separator -ForegroundColor Gray

foreach ($deviceName in $DeviceNames) {
    # Query Entra ID for the device by display name.
    $entraDevice = Get-MgDevice `
        -Filter "displayName eq '$deviceName'" `
        -ErrorAction SilentlyContinue

    # Query Intune for the managed device by device name.
    $intuneDevice = Get-MgDeviceManagementManagedDevice `
        -Filter "deviceName eq '$deviceName'" `
        -ErrorAction SilentlyContinue

    # Print the device name column without a newline so the YES/NO columns
    # can be written in colour on the same line.
    Write-Host ("{0,-$deviceColWidth}" -f $deviceName) -NoNewline

    if ($entraDevice) {
        Write-Host (" {0,-$entraColWidth}" -f 'YES') -ForegroundColor Green -NoNewline
    }
    else {
        Write-Host (" {0,-$entraColWidth}" -f 'NO') -ForegroundColor Red -NoNewline
    }

    if ($intuneDevice) {
        Write-Host ("{0,-$intuneColWidth}" -f 'YES') -ForegroundColor Green
    }
    else {
        Write-Host ("{0,-$intuneColWidth}" -f 'NO') -ForegroundColor Red
    }
}

Write-Host $separator -ForegroundColor Gray
