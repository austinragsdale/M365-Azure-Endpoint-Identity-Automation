# New-MigrationUserLookup.ps1
# Compares On-Prem AD export with Azure AD export and builds the final ForensIT CSV
# Creates entries for BOTH sAMAccountName AND UPN username formats
# Run this AFTER running both export scripts

param(
    [string]$Folder = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Compare AD Exports & Build Final CSV" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$OnPremFile = Join-Path $Folder "OnPrem-AD-Users.csv"
$AzureFile = Join-Path $Folder "UserMapping-Full-Report.csv"

# Check files exist
if (-not (Test-Path $OnPremFile)) {
    Write-Host "ERROR: On-Prem export not found: $OnPremFile" -ForegroundColor Red
    Write-Host "Run Export-ADUsersForMigration.ps1 first!" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $AzureFile)) {
    Write-Host "ERROR: Azure AD export not found: $AzureFile" -ForegroundColor Red
    Write-Host "Run Export-EntraUserMapping.ps1 first!" -ForegroundColor Yellow
    exit 1
}

# Load both exports
Write-Host "`nLoading On-Prem AD export..." -ForegroundColor Yellow
$onPremUsers = Import-Csv $OnPremFile
Write-Host "  Found $($onPremUsers.Count) on-prem users" -ForegroundColor Green

Write-Host "Loading Azure AD export..." -ForegroundColor Yellow
$azureUsers = Import-Csv $AzureFile
Write-Host "  Found $($azureUsers.Count) Azure AD users" -ForegroundColor Green

# Build Azure lookup by on-prem sAMAccountName
$azureByOnPremSam = @{}
foreach ($user in $azureUsers) {
    if ($user.OnPremSamAccountName) {
        $sam = $user.OnPremSamAccountName.ToLower()
        $azureByOnPremSam[$sam] = $user
    }
}

# Compare and categorize
Write-Host "`nComparing exports..." -ForegroundColor Yellow

$matched = @()
$onPremOnly = @()

foreach ($user in $onPremUsers) {
    $sam = $user.sAMAccountName.ToLower()

    if ($azureByOnPremSam.ContainsKey($sam)) {
        $azureUser = $azureByOnPremSam[$sam]
        $matched += [PSCustomObject]@{
            OnPremSamAccountName = $user.sAMAccountName
            OnPremUPNUsername = $user.UPNUsername
            OnPremFullUPN = $user.FullUPN
            OnPremDisplayName = $user.DisplayName
            AzureUPN = $azureUser.AzureUPN
            AzureDisplayName = $azureUser.DisplayName
            SamAndUPNDifferent = ($user.sAMAccountName.ToLower() -ne $user.UPNUsername.ToLower())
        }
    }
    else {
        $onPremOnly += [PSCustomObject]@{
            sAMAccountName = $user.sAMAccountName
            UPNUsername = $user.UPNUsername
            DisplayName = $user.DisplayName
            FullUPN = $user.FullUPN
            Reason = "Not synced to Azure AD"
        }
    }
}

# Output results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "COMPARISON RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`n  Matched users:              $($matched.Count)" -ForegroundColor Green
Write-Host "  On-Prem only (not synced):  $($onPremOnly.Count)" -ForegroundColor Yellow

$differentFormats = ($matched | Where-Object { $_.SamAndUPNDifferent -eq $true }).Count
Write-Host "`n  Users with DIFFERENT sAMAccountName vs UPN: $differentFormats" -ForegroundColor Cyan
Write-Host "  (These users need BOTH entries in the CSV)" -ForegroundColor Cyan

# Save comparison reports
$matchedPath = Join-Path $Folder "Comparison-Matched.csv"
$matched | Export-Csv -Path $matchedPath -NoTypeInformation -Encoding UTF8
Write-Host "`nMatched users saved to: $matchedPath" -ForegroundColor Green

if ($onPremOnly.Count -gt 0) {
    $onPremOnlyPath = Join-Path $Folder "Comparison-OnPremOnly.csv"
    $onPremOnly | Export-Csv -Path $onPremOnlyPath -NoTypeInformation -Encoding UTF8
    Write-Host "On-Prem only users saved to: $onPremOnlyPath" -ForegroundColor Yellow
}

# Build the final ForensIT CSV with BOTH formats for each user
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "BUILDING FINAL FORENSIT CSV" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$csvEntries = @{}  # Use hashtable to avoid duplicates
$csvEntries["onprem,azure"] = $true  # Header

foreach ($user in $matched) {
    $azureUPN = $user.AzureUPN
    $sam = $user.OnPremSamAccountName.ToLower()
    $upnUsername = $user.OnPremUPNUsername.ToLower()

    # Always add sAMAccountName entry
    $entry1 = "$sam,$azureUPN"
    $csvEntries[$entry1] = $true

    # If UPN username is different, add that entry too
    if ($sam -ne $upnUsername -and -not [string]::IsNullOrWhiteSpace($upnUsername)) {
        $entry2 = "$upnUsername,$azureUPN"
        $csvEntries[$entry2] = $true
    }

    # Also add Azure UPN username if different from both
    if ($azureUPN -match "^([^@]+)@") {
        $azureUsername = $matches[1].ToLower()
        if ($azureUsername -ne $sam -and $azureUsername -ne $upnUsername) {
            $entry3 = "$azureUsername,$azureUPN"
            $csvEntries[$entry3] = $true
        }
    }
}

# Convert to array and sort
$finalCsv = @("onprem,azure")
$csvEntries.Keys | Where-Object { $_ -ne "onprem,azure" } | Sort-Object | ForEach-Object {
    $finalCsv += $_
}

$finalCsvPath = Join-Path $Folder "UserLookup-FINAL.csv"
$finalCsv | Out-File -FilePath $finalCsvPath -Encoding UTF8

Write-Host "`nFinal ForensIT CSV saved to: $finalCsvPath" -ForegroundColor Green
Write-Host "Total entries: $($finalCsv.Count - 1)" -ForegroundColor White

# Show example of users with both formats
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "EXAMPLE: Users with BOTH formats in CSV" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$examples = $matched | Where-Object { $_.SamAndUPNDifferent -eq $true } | Select-Object -First 5
foreach ($ex in $examples) {
    Write-Host "`n$($ex.OnPremDisplayName):" -ForegroundColor White
    Write-Host "  $($ex.OnPremSamAccountName.ToLower()),$($ex.AzureUPN)" -ForegroundColor Gray
    Write-Host "  $($ex.OnPremUPNUsername.ToLower()),$($ex.AzureUPN)" -ForegroundColor Gray
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nFiles created:" -ForegroundColor White
Write-Host "  - Comparison-Matched.csv       (review the mapping)" -ForegroundColor White
if ($onPremOnly.Count -gt 0) {
    Write-Host "  - Comparison-OnPremOnly.csv    (users not synced to Azure)" -ForegroundColor Yellow
}
Write-Host "  - UserLookup-FINAL.csv     (USE THIS FOR FORENSIT)" -ForegroundColor Green

Write-Host "`nThe final CSV includes:" -ForegroundColor White
Write-Host "  - sAMAccountName entries (e.g., jsmith)" -ForegroundColor White
Write-Host "  - UPN username entries (e.g., john.smith)" -ForegroundColor White
Write-Host "  - Azure UPN username entries (if different)" -ForegroundColor White
Write-Host "`nAll pointing to the correct Azure AD UPN for each user." -ForegroundColor Green
