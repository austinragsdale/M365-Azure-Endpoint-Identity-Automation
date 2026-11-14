#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Retrieves the two macOS update configuration profiles for comparison.
.DESCRIPTION
    Pulls both the Settings Catalog and Custom profile for macOS software updates
    and saves each to JSON, decoding the custom profile's .mobileconfig payload,
    so conflicting settings can be compared.
.PARAMETER SettingsCatalogName
    Name (or part of the name) of the Settings Catalog policy.
.PARAMETER CustomProfileName
    Name (or part of the name) of the custom configuration profile.
.PARAMETER OutputPath
    Folder for the JSON files. Defaults to your Downloads folder.
.EXAMPLE
    .\Export-MacOSUpdateProfiles.ps1 -SettingsCatalogName "macOS Automated Updates" -CustomProfileName "macOS Software Update"
.NOTES
    Author: Austin Ragsdale
    Uses the Microsoft Graph /beta endpoint.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SettingsCatalogName,

    [Parameter(Mandatory)]
    [string]$CustomProfileName,

    [string]$OutputPath = "$env:USERPROFILE\Downloads"
)

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
Write-Host "Connected!`n" -ForegroundColor Green

# ============================================
# 1. Get Settings Catalog Profile
# ============================================
Write-Host "=== Retrieving Settings Catalog Profile ===" -ForegroundColor Yellow

$settingsCatalogUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
$allSettingsCatalog = Invoke-MgGraphRequest -Uri $settingsCatalogUri -Method GET

# Find the Settings Catalog profile
$automatedUpdatesProfile = $allSettingsCatalog.value | Where-Object {
    $_.name -like "*$SettingsCatalogName*"
}

if ($automatedUpdatesProfile) {
    Write-Host "Found: $($automatedUpdatesProfile.name)" -ForegroundColor Green
    Write-Host "ID: $($automatedUpdatesProfile.id)" -ForegroundColor Gray

    # Get the full settings
    $settingsUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$($automatedUpdatesProfile.id)')/settings?`$expand=settingDefinitions"
    $settings = Invoke-MgGraphRequest -Uri $settingsUri -Method GET

    # Combine policy info with settings
    $fullSettingsCatalog = @{
        ProfileType = "Settings Catalog"
        PolicyInfo = $automatedUpdatesProfile
        Settings = $settings.value
    }

    # Export
    $scFileName = "$outputPath\1_SettingsCatalogProfile.json"
    $fullSettingsCatalog | ConvertTo-Json -Depth 30 | Out-File -FilePath $scFileName -Encoding UTF8
    Write-Host "Exported to: $scFileName`n" -ForegroundColor Cyan
} else {
    Write-Host "WARNING: Could not find Settings Catalog profile matching '$SettingsCatalogName'" -ForegroundColor Red
    Write-Host "Available Settings Catalog profiles:" -ForegroundColor Yellow
    $allSettingsCatalog.value | ForEach-Object { Write-Host "  - $($_.name)" }
}

# ============================================
# 2. Get Custom Profile
# ============================================
Write-Host "=== Retrieving Custom Profile ===" -ForegroundColor Yellow

$deviceConfigUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
$allDeviceConfigs = Invoke-MgGraphRequest -Uri $deviceConfigUri -Method GET

# Find the custom profile
$customProfile = $allDeviceConfigs.value | Where-Object {
    $_.displayName -like "*$CustomProfileName*"
}

if ($customProfile) {
    Write-Host "Found: $($customProfile.displayName)" -ForegroundColor Green
    Write-Host "ID: $($customProfile.id)" -ForegroundColor Gray
    Write-Host "Type: $($customProfile.'@odata.type')" -ForegroundColor Gray

    # Get full details
    $detailUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations('$($customProfile.id)')"
    $customProfileDetail = Invoke-MgGraphRequest -Uri $detailUri -Method GET

    # If it's a custom profile, decode the payload
    $decodedPayload = $null
    if ($customProfileDetail.payload) {
        try {
            $decodedPayload = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($customProfileDetail.payload))
            Write-Host "Decoded .mobileconfig payload successfully" -ForegroundColor Green
        } catch {
            Write-Host "Could not decode payload" -ForegroundColor Yellow
        }
    }

    $fullCustomProfile = @{
        ProfileType = "Custom (.mobileconfig)"
        ProfileInfo = $customProfileDetail
        DecodedPayload = $decodedPayload
    }

    # Export
    $customFileName = "$outputPath\2_CustomProfile.json"
    $fullCustomProfile | ConvertTo-Json -Depth 30 | Out-File -FilePath $customFileName -Encoding UTF8
    Write-Host "Exported to: $customFileName`n" -ForegroundColor Cyan
} else {
    Write-Host "WARNING: Could not find Custom profile matching '$CustomProfileName'" -ForegroundColor Red
    Write-Host "Available Device Configuration profiles:" -ForegroundColor Yellow
    $allDeviceConfigs.value | ForEach-Object { Write-Host "  - $($_.displayName)" }
}

# ============================================
# Summary
# ============================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Export Complete!" -ForegroundColor Green
Write-Host "Files saved to: $outputPath" -ForegroundColor Cyan
Write-Host "  1. 1_SettingsCatalogProfile.json" -ForegroundColor White
Write-Host "  2. 2_CustomProfile.json" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Disconnect-MgGraph | Out-Null
Write-Host "Disconnected from Microsoft Graph." -ForegroundColor Gray
