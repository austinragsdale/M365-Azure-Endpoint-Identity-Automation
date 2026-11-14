<#
.SYNOPSIS
    Bulk updates Intune device Primary User and Device Category from an Excel file.

.DESCRIPTION
    This script reads device mappings from an Excel file and updates each device's
    Primary User and Device Category in Microsoft Intune via Microsoft Graph API.

.PARAMETER ExcelPath
    Path to the Excel file containing device mappings.
    Required columns: "Device name", "Category", "Primary user UPN"

.PARAMETER DryRun
    Performs a dry run without making any changes. Shows what would be updated.

.PARAMETER LogPath
    Path to the log file. Defaults to the same directory as the Excel file.

.EXAMPLE
    .\Set-IntunePrimaryUserAndCategory.ps1 -ExcelPath "C:\Temp\DeviceMappings.xlsx" -DryRun

.EXAMPLE
    .\Set-IntunePrimaryUserAndCategory.ps1 -ExcelPath "C:\Temp\DeviceMappings.xlsx"

.NOTES
    Author: Austin Ragsdale
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, ImportExcel modules
    Permissions: DeviceManagementManagedDevices.ReadWrite.All, User.Read.All
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ExcelPath,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string]$LogPath
)

#region Configuration
$ErrorActionPreference = "Continue"
$RequiredScopes = @(
    "DeviceManagementManagedDevices.ReadWrite.All",
    "User.Read.All"
)

# Set default log path if not specified
if (-not $LogPath) {
    $LogPath = Join-Path (Split-Path $ExcelPath -Parent) "IntuneDeviceUpdate_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}

# Initialize log file
"" | Out-File -FilePath $LogPath -Force
#endregion

#region Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to console with color
    switch ($Level) {
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        default   { Write-Host $logEntry -ForegroundColor Cyan }
    }

    # Write to log file
    $logEntry | Out-File -FilePath $LogPath -Append
}

function Get-IntuneDeviceByName {
    param([string]$DeviceName)

    try {
        # Escape single quotes in device name for OData filter
        $escapedName = $DeviceName.Replace("'", "''")
        $filter = "deviceName eq '$escapedName'"

        $device = Get-MgDeviceManagementManagedDevice -Filter $filter -ErrorAction Stop | Select-Object -First 1
        return $device
    }
    catch {
        Write-Log "    Error searching for device '$DeviceName': $($_.Exception.Message)" -Level ERROR
        return $null
    }
}

function Get-UserIdByUPN {
    param([string]$UserPrincipalName)

    if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
        return $null
    }

    try {
        $user = Get-MgUser -UserId $UserPrincipalName -ErrorAction Stop
        return $user.Id
    }
    catch {
        Write-Log "    Error looking up user '$UserPrincipalName': $($_.Exception.Message)" -Level ERROR
        return $null
    }
}

function Set-DevicePrimaryUser {
    param(
        [string]$DeviceId,
        [string]$UserId
    )

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')/users/`$ref"
    $body = @{
        "@odata.id" = "https://graph.microsoft.com/beta/users('$UserId')"
    } | ConvertTo-Json

    try {
        # First, try to remove existing primary user (ignore errors if none exists)
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            # No existing user to remove, continue
        }

        # Set the new primary user
        Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" | Out-Null
        return $true
    }
    catch {
        throw $_
    }
}

function Set-DeviceCategory {
    param(
        [string]$DeviceId,
        [string]$CategoryId
    )

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')/deviceCategory/`$ref"
    $body = @{
        "@odata.id" = "https://graph.microsoft.com/beta/deviceManagement/deviceCategories('$CategoryId')"
    } | ConvertTo-Json

    try {
        Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $body -ContentType "application/json" | Out-Null
        return $true
    }
    catch {
        throw $_
    }
}
#endregion

#region Main Script
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "     INTUNE DEVICE BULK UPDATE - Primary User and Category           " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "*** DRY RUN MODE - No changes will be made ***" -ForegroundColor Yellow
    Write-Host ""
}

Write-Log "Script started"
Write-Log "Excel Path: $ExcelPath"
Write-Log "Log Path: $LogPath"
Write-Log "DryRun Mode: $DryRun"

# Import required modules
Write-Log "Importing required PowerShell modules..."
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Import-Module ImportExcel -ErrorAction Stop
    Write-Log "All modules imported successfully" -Level SUCCESS
}
catch {
    Write-Log "Failed to import required modules: $_" -Level ERROR
    Write-Log "Run: Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Users, ImportExcel -Scope CurrentUser" -Level INFO
    exit 1
}

# Import Excel data
Write-Log "Importing device mappings from Excel..."
try {
    $rawData = Import-Excel -Path $ExcelPath
    # Filter out empty rows
    $deviceMappings = $rawData | Where-Object {
        $_."Device name" -and
        $_."Device name".ToString().Trim() -ne ""
    }
    $totalDevices = @($deviceMappings).Count
    Write-Log "Loaded $totalDevices device mappings (filtered empty rows)" -Level SUCCESS
}
catch {
    Write-Log "Failed to import Excel file: $_" -Level ERROR
    exit 1
}

if ($totalDevices -eq 0) {
    Write-Log "No devices found in Excel file. Check column names." -Level ERROR
    exit 1
}

# Validate Excel columns
Write-Log "Validating Excel columns..."
$requiredColumns = @("Device name", "Category", "Primary user UPN")
$excelColumns = $deviceMappings[0].PSObject.Properties.Name
$missingColumns = @()
foreach ($col in $requiredColumns) {
    if ($col -notin $excelColumns) {
        $missingColumns += $col
    }
}
if ($missingColumns.Count -gt 0) {
    Write-Log "Missing required columns: $($missingColumns -join ', ')" -Level ERROR
    Write-Log "Found columns: $($excelColumns -join ', ')" -Level INFO
    exit 1
}
Write-Log "Excel column validation passed" -Level SUCCESS

# Connect to Microsoft Graph
Write-Log "Checking Microsoft Graph connection..."
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Log "Not connected to Graph. Connecting now..." -Level WARNING
        Connect-MgGraph -Scopes $RequiredScopes -NoWelcome
        $context = Get-MgContext
    }
    Write-Log "Connected to Microsoft Graph as: $($context.Account)" -Level SUCCESS
}
catch {
    Write-Log "Failed to connect to Microsoft Graph: $_" -Level ERROR
    exit 1
}

# Fetch device categories and build CASE-INSENSITIVE lookup table
Write-Log "Fetching Intune device categories..."
try {
    $categories = Get-MgDeviceManagementDeviceCategory -All

    # Create case-insensitive dictionary
    $categoryLookup = New-Object 'System.Collections.Generic.Dictionary[string,string]'([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($cat in $categories) {
        $categoryLookup[$cat.DisplayName] = $cat.Id
    }

    Write-Log "Loaded $($categories.Count) device categories" -Level SUCCESS
}
catch {
    Write-Log "Failed to fetch device categories: $_" -Level ERROR
    exit 1
}

# Process devices
Write-Host ""
Write-Log "Processing $totalDevices devices..."
Write-Host ("-" * 70) -ForegroundColor Gray

# Initialize counters
$successCount = 0
$failedCount = 0
$notFoundCount = 0
$userNotFoundCount = 0
$categoryNotFoundCount = 0

$failedDevices = [System.Collections.ArrayList]::new()
$counter = 0

foreach ($device in $deviceMappings) {
    $counter++
    $deviceName = $device."Device name".ToString().Trim()
    $categoryName = $device."Category".ToString().Trim()
    $userUPN = $device."Primary user UPN".ToString().Trim()

    $progressPercent = [math]::Round(($counter / $totalDevices) * 100)
    $statusMsg = "Processing $deviceName - $counter of $totalDevices"
    Write-Progress -Activity "Updating Intune Devices" -Status $statusMsg -PercentComplete $progressPercent

    Write-Log "[$counter/$totalDevices] Processing: $deviceName"

    # Find device in Intune
    $intuneDevice = Get-IntuneDeviceByName -DeviceName $deviceName
    if (-not $intuneDevice) {
        Write-Log "  Device not found in Intune: $deviceName" -Level WARNING
        $notFoundCount++
        [void]$failedDevices.Add([PSCustomObject]@{
            DeviceName = $deviceName
            Category = $categoryName
            UserUPN = $userUPN
            Reason = "Device not found in Intune"
        })
        continue
    }

    $deviceId = $intuneDevice.Id
    Write-Log "  Found device ID: $deviceId"

    # Lookup user
    $userId = Get-UserIdByUPN -UserPrincipalName $userUPN
    if (-not $userId) {
        Write-Log "  User not found: $userUPN" -Level WARNING
        $userNotFoundCount++
        [void]$failedDevices.Add([PSCustomObject]@{
            DeviceName = $deviceName
            Category = $categoryName
            UserUPN = $userUPN
            Reason = "User not found: $userUPN"
        })
        continue
    }
    Write-Log "  Found user ID: $userId"

    # Lookup category (case-insensitive)
    $categoryId = $null
    if ($categoryLookup.ContainsKey($categoryName)) {
        $categoryId = $categoryLookup[$categoryName]
    }

    if (-not $categoryId) {
        Write-Log "  Category not found: '$categoryName'" -Level WARNING
        $categoryNotFoundCount++
        [void]$failedDevices.Add([PSCustomObject]@{
            DeviceName = $deviceName
            Category = $categoryName
            UserUPN = $userUPN
            Reason = "Category not found: $categoryName"
        })
        continue
    }
    Write-Log "  Found category ID: $categoryId"

    # Update device
    try {
        if ($DryRun) {
            Write-Log "  [DRYRUN] Would set Primary User to: $userUPN" -Level INFO
            Write-Log "  [DRYRUN] Would set Category to: $categoryName" -Level INFO
            $successCount++
        }
        else {
            # Set Primary User
            Set-DevicePrimaryUser -DeviceId $deviceId -UserId $userId
            Write-Log "  Set Primary User: $userUPN" -Level SUCCESS

            # Set Device Category
            Set-DeviceCategory -DeviceId $deviceId -CategoryId $categoryId
            Write-Log "  Set Category: $categoryName" -Level SUCCESS

            $successCount++
        }
    }
    catch {
        Write-Log "  Failed to update device: $($_.Exception.Message)" -Level ERROR
        $failedCount++
        [void]$failedDevices.Add([PSCustomObject]@{
            DeviceName = $deviceName
            Category = $categoryName
            UserUPN = $userUPN
            Reason = $_.Exception.Message
        })
    }
}

Write-Progress -Activity "Updating Intune Devices" -Completed

# Summary
Write-Host ""
Write-Host ("-" * 70) -ForegroundColor Gray
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "                         SUMMARY                                      " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "*** DRY RUN COMPLETE - No changes were made ***" -ForegroundColor Yellow
    Write-Host ""
}

$totalErrors = $failedCount + $notFoundCount + $userNotFoundCount + $categoryNotFoundCount

Write-Host "Total Devices Processed: $totalDevices" -ForegroundColor White
Write-Host "  Successful:            $successCount" -ForegroundColor Green
Write-Host "  Failed (API Error):    $failedCount" -ForegroundColor Red
Write-Host "  Device Not Found:      $notFoundCount" -ForegroundColor Yellow
Write-Host "  User Not Found:        $userNotFoundCount" -ForegroundColor Yellow
Write-Host "  Category Not Found:    $categoryNotFoundCount" -ForegroundColor Yellow
Write-Host ""

Write-Log "Script completed. Success: $successCount, Errors: $totalErrors"

# Export failed devices if any
if ($failedDevices.Count -gt 0) {
    $failedPath = Join-Path (Split-Path $ExcelPath -Parent) "FailedDevices_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $failedDevices | Export-Csv -Path $failedPath -NoTypeInformation
    Write-Log "Failed devices exported to: $failedPath" -Level WARNING
    Write-Host "Failed devices exported to: $failedPath" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Log file: $LogPath" -ForegroundColor Cyan
Write-Host ""
#endregion
