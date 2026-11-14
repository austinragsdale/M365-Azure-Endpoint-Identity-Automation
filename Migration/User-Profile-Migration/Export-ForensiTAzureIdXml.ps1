# Export-ForensiTAzureIdXml.ps1
# Regenerates the ForensiTAzureID.xml file from Microsoft Graph
# This ensures all current Azure AD users are included

param(
    [string]$OutputPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\ForensiTAzureID.xml"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ForensIT Azure ID XML Generator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check for Microsoft Graph module
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Write-Host "Installing Microsoft.Graph.Users module..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
    Write-Host "Installing Microsoft.Graph.Identity.DirectoryManagement module..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser -Force
}

Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Identity.DirectoryManagement

# Connect to Graph
Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Yellow
Write-Host "(A browser window will open for authentication)" -ForegroundColor Gray
Connect-MgGraph -Scopes "User.Read.All", "Organization.Read.All" -NoWelcome

# Get tenant info for the root element
Write-Host "`nGetting tenant information..." -ForegroundColor Yellow
$org = Get-MgOrganization
$tenantId = $org.Id
$tenantName = ($org.VerifiedDomains | Select-Object -ExpandProperty Name) -join " "
$tenantDisplayName = $org.DisplayName

Write-Host "  Tenant ID: $tenantId" -ForegroundColor Green
Write-Host "  Tenant Name: $tenantDisplayName" -ForegroundColor Green
Write-Host "  Domains: $tenantName" -ForegroundColor Green

# Get all users
Write-Host "`nFetching all Azure AD users..." -ForegroundColor Yellow
$users = Get-MgUser -All -Property "id", "userPrincipalName", "displayName" |
    Where-Object { $_.userPrincipalName -ne $null } |
    Sort-Object userPrincipalName

Write-Host "  Found $($users.Count) users" -ForegroundColor Green

# Build XML
Write-Host "`nGenerating XML file..." -ForegroundColor Yellow

$xmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<?xml-stylesheet type='text/xsl' href='style.xsl'?>
<ForensiTAzureID ObjectId="$tenantId" Name="$tenantName" DisplayName="$tenantDisplayName">
"@

foreach ($user in $users) {
    # Escape XML special characters
    $upn = [System.Security.SecurityElement]::Escape($user.UserPrincipalName)
    $displayName = [System.Security.SecurityElement]::Escape($user.DisplayName)
    $objectId = $user.Id

    $xmlContent += @"

    <User>
        <UserPrincipalName>$upn</UserPrincipalName>
        <ObjectId>$objectId</ObjectId>
        <DisplayName>$displayName</DisplayName>
    </User>
"@
}

$xmlContent += @"

</ForensiTAzureID>
"@

# Backup existing file
if (Test-Path $OutputPath) {
    $backupPath = $OutputPath -replace "\.xml$", "-BACKUP-$(Get-Date -Format 'yyyyMMdd-HHmmss').xml"
    Copy-Item $OutputPath $backupPath
    Write-Host "`nBacked up existing XML to:" -ForegroundColor Yellow
    Write-Host "  $backupPath" -ForegroundColor Gray
}

# Save new XML
$xmlContent | Out-File -FilePath $OutputPath -Encoding UTF8

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nNew XML saved to: $OutputPath" -ForegroundColor Green
Write-Host "Total users in XML: $($users.Count)" -ForegroundColor White

Write-Host "`nNext step: Re-run Test-MigrationUserLookup.ps1 to verify all CSV entries are now valid." -ForegroundColor Yellow
