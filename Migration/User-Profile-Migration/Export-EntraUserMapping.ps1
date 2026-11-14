# Export-EntraUserMapping.ps1
# Exports Azure AD users with their on-prem sAMAccountName for perfect CSV mapping
# Requires: Microsoft.Graph PowerShell module

#Requires -Modules Microsoft.Graph.Users

param(
    [string]$OutputFolder = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "User Mapping Export Tool (Microsoft Graph)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check if Microsoft.Graph module is installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Write-Host "`nMicrosoft.Graph module not found. Installing..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Microsoft Graph
Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Yellow
Write-Host "You will be prompted to sign in with an admin account." -ForegroundColor White

try {
    Connect-MgGraph -Scopes "User.Read.All" -NoWelcome
    Write-Host "Connected successfully!" -ForegroundColor Green
}
catch {
    Write-Host "Failed to connect: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get all users with on-prem attributes
Write-Host "`nFetching all users from Azure AD..." -ForegroundColor Yellow

$users = Get-MgUser -All -Property @(
    "id",
    "userPrincipalName",
    "displayName",
    "onPremisesSamAccountName",
    "onPremisesUserPrincipalName",
    "onPremisesDomainName",
    "accountEnabled"
) | Where-Object { $_.onPremisesSamAccountName -ne $null }

Write-Host "Found $($users.Count) synced users with on-prem accounts" -ForegroundColor Green

# Create the mapping
Write-Host "`nBuilding user mapping..." -ForegroundColor Yellow

$mapping = @()
foreach ($user in $users) {
    $mapping += [PSCustomObject]@{
        OnPremSamAccountName = $user.onPremisesSamAccountName
        AzureUPN = $user.userPrincipalName
        DisplayName = $user.displayName
        OnPremUPN = $user.onPremisesUserPrincipalName
        OnPremDomain = $user.onPremisesDomainName
        Enabled = $user.accountEnabled
    }
}

# Export full mapping report
$mappingReportPath = Join-Path $OutputFolder "UserMapping-Full-Report.csv"
$mapping | Export-Csv -Path $mappingReportPath -NoTypeInformation -Encoding UTF8
Write-Host "Full mapping report saved to: $mappingReportPath" -ForegroundColor Green

# Create the ForensIT CSV format (onprem,azure)
Write-Host "`nGenerating ForensIT lookup CSV..." -ForegroundColor Yellow

$forensitCsv = @()
$forensitCsv += "onprem,azure"  # Header

foreach ($user in $mapping) {
    $onpremLower = $user.OnPremSamAccountName.ToLower()
    $azureUPN = $user.AzureUPN

    # Add the sAMAccountName entry
    $forensitCsv += "$onpremLower,$azureUPN"

    # If the Azure UPN username is different from sAMAccountName, add that too
    if ($azureUPN -match "^([^@]+)@") {
        $azureUsername = $matches[1].ToLower()
        if ($azureUsername -ne $onpremLower) {
            $forensitCsv += "$azureUsername,$azureUPN"
        }
    }
}

# Remove duplicates while preserving order
$forensitCsv = $forensitCsv | Select-Object -Unique

$forensitCsvPath = Join-Path $OutputFolder "UserLookup-FROM-GRAPH.csv"
$forensitCsv | Out-File -FilePath $forensitCsvPath -Encoding UTF8
Write-Host "ForensIT lookup CSV saved to: $forensitCsvPath" -ForegroundColor Green

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "EXPORT COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nFiles created:" -ForegroundColor White
Write-Host "  1. $mappingReportPath" -ForegroundColor White
Write-Host "     (Full report with all user details)" -ForegroundColor Gray
Write-Host "  2. $forensitCsvPath" -ForegroundColor White
Write-Host "     (Ready-to-use ForensIT lookup CSV)" -ForegroundColor Gray

Write-Host "`nTotal synced users: $($users.Count)" -ForegroundColor White
Write-Host "Total CSV entries: $($forensitCsv.Count - 1)" -ForegroundColor White

# Disconnect
Disconnect-MgGraph | Out-Null
Write-Host "`nDisconnected from Microsoft Graph." -ForegroundColor Gray
