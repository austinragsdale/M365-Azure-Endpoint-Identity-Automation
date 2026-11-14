<#
.SYNOPSIS
    Bulk delete devices from Microsoft Intune and Entra ID for hybrid to cloud-only migration.

.DESCRIPTION
    This script deletes devices from:
    1. Microsoft Intune (Managed Devices)
    2. Entra ID (Azure AD Devices)

    You can input devices by:
    - Passing device names as a parameter: -DeviceNames "PC1","PC2","PC3"
    - Entering them interactively when prompted

    Features:
    - Interactive Graph authentication
    - Dry-run mode (-WhatIf) to preview actions without making changes
    - Confirmation prompts before each deletion
    - Detailed logging to file

.PARAMETER DeviceNames
    Array of device names to delete. If not provided, you'll be prompted to enter them.

.PARAMETER WhatIf
    Run in dry-run mode. Shows what would be deleted without actually deleting.

.PARAMETER LogPath
    Path for the log file. Defaults to Downloads folder with timestamp.

.EXAMPLE
    .\Remove-DevicesFromIntuneAndEntra.ps1 -WhatIf
    Enter devices interactively and preview what would be deleted (dry-run mode)

.EXAMPLE
    .\Remove-DevicesFromIntuneAndEntra.ps1 -DeviceNames "DESKTOP-ABC123","LAPTOP-XYZ789"
    Delete specific devices with confirmation prompts

.EXAMPLE
    .\Remove-DevicesFromIntuneAndEntra.ps1
    Enter devices interactively and delete with confirmation prompts

.NOTES
    Author: Austin Ragsdale
    Requires: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement modules
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$DeviceNames,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $env:USERPROFILE "Downloads\CloudDeviceRemoval_$(Get-Date -Format 'yyyyMMdd_HHmmss').log")
)

#region Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'Info'    { Write-Host $logEntry -ForegroundColor Cyan }
        'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
        'Error'   { Write-Host $logEntry -ForegroundColor Red }
        'Success' { Write-Host $logEntry -ForegroundColor Green }
    }

    Add-Content -Path $LogPath -Value $logEntry
}

function Get-DeviceNamesFromUser {
    Write-Host ""
    Write-Host "Enter device names one per line." -ForegroundColor White
    Write-Host "When finished, type 'DONE' and press Enter." -ForegroundColor White
    Write-Host ""

    $devices = @()
    while ($true) {
        $userInput = Read-Host "Device name (or DONE to finish)"
        if ($userInput.ToUpper() -eq 'DONE') {
            break
        }
        if (-not [string]::IsNullOrWhiteSpace($userInput)) {
            $devices += $userInput.Trim()
            Write-Host "  Added: $($userInput.Trim())" -ForegroundColor Green
        }
    }
    return $devices
}

function Connect-ToGraph {
    Write-Log "Connecting to Microsoft Graph..." -Level Info

    try {
        # Check if already connected
        $context = Get-MgContext
        if ($context) {
            Write-Log "Already connected as $($context.Account)" -Level Info
            $reconnect = Read-Host "Do you want to reconnect with a different account? (Y/N)"
            if ($reconnect -eq 'Y') {
                Disconnect-MgGraph | Out-Null
            } else {
                return $true
            }
        }

        # Connect with required scopes
        Connect-MgGraph -Scopes @(
            "DeviceManagementManagedDevices.ReadWrite.All",
            "Device.ReadWrite.All",
            "Directory.ReadWrite.All"
        ) -NoWelcome

        $context = Get-MgContext
        Write-Log "Successfully connected as $($context.Account)" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to connect to Microsoft Graph: $_" -Level Error
        return $false
    }
}

function Get-IntuneDevice {
    param([string]$DeviceName)

    try {
        # Escape single quotes for OData filter (e.g., "O'Brien-PC" becomes "O''Brien-PC")
        $escapedName = $DeviceName.Replace("'", "''")
        $filter = "deviceName eq '$escapedName'"
        $device = Get-MgDeviceManagementManagedDevice -Filter $filter -ErrorAction Stop
        return $device
    }
    catch {
        Write-Log "Error searching for Intune device '$DeviceName': $_" -Level Error
        return $null
    }
}

function Get-EntraDevice {
    param([string]$DeviceName)

    try {
        # Escape single quotes for OData filter (e.g., "O'Brien-PC" becomes "O''Brien-PC")
        $escapedName = $DeviceName.Replace("'", "''")
        $filter = "displayName eq '$escapedName'"
        $device = Get-MgDevice -Filter $filter -ErrorAction Stop
        return $device
    }
    catch {
        Write-Log "Error searching for Entra ID device '$DeviceName': $_" -Level Error
        return $null
    }
}

function Remove-IntuneDeviceObject {
    param(
        [Parameter(Mandatory)]
        $Device,
        [switch]$WhatIf
    )

    $deviceName = $Device.DeviceName
    $deviceId = $Device.Id

    if ($WhatIf) {
        Write-Log "[WHATIF] Would delete Intune device: $deviceName (ID: $deviceId)" -Level Warning
        return $true
    }

    try {
        Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId -ErrorAction Stop
        Write-Log "Successfully deleted Intune device: $deviceName" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to delete Intune device '$deviceName': $_" -Level Error
        return $false
    }
}

function Remove-EntraDeviceObject {
    param(
        [Parameter(Mandatory)]
        $Device,
        [switch]$WhatIf
    )

    $deviceName = $Device.DisplayName
    $deviceId = $Device.Id

    if ($WhatIf) {
        Write-Log "[WHATIF] Would delete Entra ID device: $deviceName (ID: $deviceId)" -Level Warning
        return $true
    }

    try {
        Remove-MgDevice -DeviceId $deviceId -ErrorAction Stop
        Write-Log "Successfully deleted Entra ID device: $deviceName" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to delete Entra ID device '$deviceName': $_" -Level Error
        return $false
    }
}
#endregion

#region Main Script
Clear-Host
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  Cloud Device Removal Script" -ForegroundColor Magenta
Write-Host "  Intune + Entra ID Bulk Deletion" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""

# Check if running in WhatIf mode
if ($WhatIfPreference) {
    Write-Host ">>> RUNNING IN DRY-RUN MODE (WhatIf) <<<" -ForegroundColor Yellow
    Write-Host ">>> No changes will be made <<<" -ForegroundColor Yellow
    Write-Host ""
}

# Initialize log file
Write-Log "Script started" -Level Info
if ($WhatIfPreference) {
    Write-Log "Running in DRY-RUN mode (WhatIf)" -Level Warning
}

# Check for required modules
$requiredModules = @(
    'Microsoft.Graph.DeviceManagement',
    'Microsoft.Graph.Identity.DirectoryManagement'
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Log "Required module '$module' not found. Installing..." -Level Warning
        try {
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
            Write-Log "Module '$module' installed successfully" -Level Success
        }
        catch {
            Write-Log "Failed to install module '$module': $_" -Level Error
            exit 1
        }
    }
    try {
        Import-Module $module -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to import module '$module': $_" -Level Error
        exit 1
    }
}

# Connect to Graph
if (-not (Connect-ToGraph)) {
    Write-Log "Cannot proceed without Graph connection. Exiting." -Level Error
    exit 1
}

# Get device names - either from parameter or interactive input
if (-not $DeviceNames -or $DeviceNames.Count -eq 0) {
    $DeviceNames = Get-DeviceNamesFromUser
}

if ($DeviceNames.Count -eq 0) {
    Write-Log "No devices specified. Exiting." -Level Warning
    exit 0
}

Write-Log "Loaded $($DeviceNames.Count) devices to process" -Level Info

# Display summary
Write-Host ""
Write-Host "Devices to process:" -ForegroundColor White
$DeviceNames | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host ""

# Confirm before proceeding
if (-not $WhatIfPreference) {
    $confirm = Read-Host "Do you want to proceed with deletion of $($DeviceNames.Count) device(s)? (Y/N)"
    if ($confirm -ne 'Y') {
        Write-Log "Operation cancelled by user" -Level Warning
        exit 0
    }
}

# Process each device
$results = @{
    IntuneDeleted = 0
    IntuneNotFound = 0
    IntuneFailed = 0
    EntraDeleted = 0
    EntraNotFound = 0
    EntraFailed = 0
}

foreach ($deviceName in $DeviceNames) {
    $deviceName = $deviceName.Trim()
    Write-Host ""
    Write-Log "Processing device: $deviceName" -Level Info
    Write-Host ("-" * 50) -ForegroundColor DarkGray

    # Step 1: Find and delete from Intune
    Write-Log "Searching for device in Intune..." -Level Info
    $intuneDevice = Get-IntuneDevice -DeviceName $deviceName

    if ($intuneDevice) {
        # Handle multiple matches
        if ($intuneDevice.Count -gt 1) {
            Write-Log "Found $($intuneDevice.Count) Intune devices matching '$deviceName'" -Level Warning
            for ($i = 0; $i -lt $intuneDevice.Count; $i++) {
                Write-Host "  [$i] $($intuneDevice[$i].DeviceName) - ID: $($intuneDevice[$i].Id) - Last Sync: $($intuneDevice[$i].LastSyncDateTime)" -ForegroundColor Gray
            }
        }

        foreach ($intuneObj in $intuneDevice) {
            Write-Log "Found Intune device: $($intuneObj.DeviceName) (ID: $($intuneObj.Id))" -Level Info

            if (-not $WhatIfPreference) {
                $confirmIntune = Read-Host "Delete this device from Intune? (Y/N)"
                if ($confirmIntune -ne 'Y') {
                    Write-Log "Skipped Intune deletion for $deviceName" -Level Warning
                    continue
                }
            }

            if (Remove-IntuneDeviceObject -Device $intuneObj -WhatIf:$WhatIfPreference) {
                $results.IntuneDeleted++
            } else {
                $results.IntuneFailed++
            }
        }
    } else {
        Write-Log "Device '$deviceName' not found in Intune" -Level Warning
        $results.IntuneNotFound++
    }

    # Step 2: Find and delete from Entra ID
    Write-Log "Searching for device in Entra ID..." -Level Info
    $entraDevice = Get-EntraDevice -DeviceName $deviceName

    if ($entraDevice) {
        # Handle multiple matches
        if ($entraDevice.Count -gt 1) {
            Write-Log "Found $($entraDevice.Count) Entra ID devices matching '$deviceName'" -Level Warning
            for ($i = 0; $i -lt $entraDevice.Count; $i++) {
                Write-Host "  [$i] $($entraDevice[$i].DisplayName) - ID: $($entraDevice[$i].Id) - Trust Type: $($entraDevice[$i].TrustType)" -ForegroundColor Gray
            }
        }

        foreach ($entraObj in $entraDevice) {
            Write-Log "Found Entra ID device: $($entraObj.DisplayName) (ID: $($entraObj.Id))" -Level Info

            if (-not $WhatIfPreference) {
                $confirmEntra = Read-Host "Delete this device from Entra ID? (Y/N)"
                if ($confirmEntra -ne 'Y') {
                    Write-Log "Skipped Entra ID deletion for $deviceName" -Level Warning
                    continue
                }
            }

            if (Remove-EntraDeviceObject -Device $entraObj -WhatIf:$WhatIfPreference) {
                $results.EntraDeleted++
            } else {
                $results.EntraFailed++
            }
        }
    } else {
        Write-Log "Device '$deviceName' not found in Entra ID" -Level Warning
        $results.EntraNotFound++
    }
}

# Summary
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SUMMARY" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta

if ($WhatIfPreference) {
    Write-Host "  [DRY-RUN MODE - No changes were made]" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  INTUNE:" -ForegroundColor White
Write-Host "    Deleted:   $($results.IntuneDeleted)" -ForegroundColor Green
Write-Host "    Not Found: $($results.IntuneNotFound)" -ForegroundColor Yellow
Write-Host "    Failed:    $($results.IntuneFailed)" -ForegroundColor Red

Write-Host ""
Write-Host "  ENTRA ID:" -ForegroundColor White
Write-Host "    Deleted:   $($results.EntraDeleted)" -ForegroundColor Green
Write-Host "    Not Found: $($results.EntraNotFound)" -ForegroundColor Yellow
Write-Host "    Failed:    $($results.EntraFailed)" -ForegroundColor Red

Write-Host ""
Write-Log "Script completed. Log saved to: $LogPath" -Level Info
Write-Host ""
#endregion
