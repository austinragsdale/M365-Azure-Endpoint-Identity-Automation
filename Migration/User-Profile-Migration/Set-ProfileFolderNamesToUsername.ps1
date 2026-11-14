#Requires -Version 5.1
<#
.SYNOPSIS
    Converts DisplayName values in ForensiTAzureID.xml to UPN prefixes for profile folder naming.

.DESCRIPTION
    This script modifies the ForensiTAzureID.xml file so that the DisplayName field contains
    the UPN prefix (part before @) instead of the actual display name. This causes ForensIT
    Profile Wizard to create profile folders named after the UPN prefix rather than display names.

.NOTES
    - Creates a backup of the original XML file before modifying
    - Run this BEFORE running the migration package
#>

param(
    [string]$XmlPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\ForensiTAzureID.xml",
    [switch]$WhatIf
)

# Verify file exists
if (-not (Test-Path $XmlPath)) {
    Write-Error "XML file not found: $XmlPath"
    exit 1
}

# Create backup
$backupPath = $XmlPath -replace '\.xml$', "_BACKUP_$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"
Copy-Item -Path $XmlPath -Destination $backupPath -Force
Write-Host "Backup created: $backupPath" -ForegroundColor Green

# Load the XML
[xml]$xml = Get-Content -Path $XmlPath -Encoding UTF8

# Counter for tracking changes
$changedCount = 0
$skippedCount = 0

# Process each User node
foreach ($user in $xml.ForensiTAzureID.User) {
    $upn = $user.UserPrincipalName
    $currentDisplayName = $user.DisplayName

    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Warning "Skipping user with empty UPN (DisplayName: $currentDisplayName)"
        $skippedCount++
        continue
    }

    # Extract UPN prefix (part before @)
    if ($upn -match '^([^@]+)@') {
        $upnPrefix = $matches[1]

        # Sanitize for folder name (remove invalid characters)
        # Windows folder names cannot contain: \ / : * ? " < > |
        $sanitizedPrefix = $upnPrefix -replace '[\\/:*?"<>|]', '_'

        if ($WhatIf) {
            Write-Host "WHATIF: Would change DisplayName from '$currentDisplayName' to '$sanitizedPrefix' (UPN: $upn)"
        } else {
            $user.DisplayName = $sanitizedPrefix
            Write-Host "Changed: '$currentDisplayName' -> '$sanitizedPrefix'" -ForegroundColor Cyan
        }
        $changedCount++
    } else {
        Write-Warning "Could not extract prefix from UPN: $upn"
        $skippedCount++
    }
}

# Save the modified XML
if (-not $WhatIf) {
    $xml.Save($XmlPath)
    Write-Host "`nXML file updated successfully!" -ForegroundColor Green
}

Write-Host "`n=== Summary ===" -ForegroundColor Yellow
Write-Host "Users processed: $changedCount"
Write-Host "Users skipped: $skippedCount"
Write-Host "Backup location: $backupPath"

if ($WhatIf) {
    Write-Host "`nThis was a WHATIF run. No changes were made." -ForegroundColor Yellow
    Write-Host "Run without -WhatIf to apply changes." -ForegroundColor Yellow
}
