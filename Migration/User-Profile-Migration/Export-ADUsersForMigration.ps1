# Export-ADUsersForMigration.ps1
# Run this directly on a Domain Controller or server with AD role
# Exports all users with BOTH sAMAccountName AND UPN for ForensIT migration mapping

param(
    [string]$OutputPath = "C:\Temp\OnPrem-AD-Users.csv"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "On-Prem AD User Export" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Import-Module ActiveDirectory -ErrorAction Stop

$domain = Get-ADDomain
Write-Host "`nDomain: $($domain.DNSRoot)" -ForegroundColor Green
Write-Host "NetBIOS: $($domain.NetBIOSName)" -ForegroundColor Green

Write-Host "`nExporting all enabled users..." -ForegroundColor Yellow

$users = Get-ADUser -Filter {Enabled -eq $true} -Properties @(
    "sAMAccountName",
    "userPrincipalName",
    "displayName",
    "mail",
    "givenName",
    "sn",
    "Enabled",
    "profilePath",
    "homeDirectory"
)

Write-Host "Found $($users.Count) enabled users" -ForegroundColor Green

$export = @()
foreach ($user in $users) {
    # Extract username portion from UPN (e.g., "john.smith" from "john.smith@contoso.com")
    $upnUsername = $null
    if ($user.userPrincipalName -match "^([^@]+)@") {
        $upnUsername = $matches[1]
    }

    # Determine likely profile folder name
    # Windows typically uses sAMAccountName, but if user logs in with UPN first time, it might use UPN username
    $likelyProfileName = $user.sAMAccountName

    $export += [PSCustomObject]@{
        sAMAccountName = $user.sAMAccountName
        UPNUsername = $upnUsername
        FullUPN = $user.userPrincipalName
        DisplayName = $user.displayName
        FirstName = $user.givenName
        LastName = $user.sn
        Email = $user.mail
        ProfilePath = $user.profilePath
        HomeDirectory = $user.homeDirectory
        Enabled = $user.Enabled
        SamAndUPNMatch = ($user.sAMAccountName.ToLower() -eq $upnUsername.ToLower())
    }
}

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Save to CSV
$export | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

# Show summary of mismatches
$mismatches = $export | Where-Object { $_.SamAndUPNMatch -eq $false }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "EXPORT COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nFile saved to: $OutputPath" -ForegroundColor Green
Write-Host "Total users exported: $($export.Count)" -ForegroundColor White
Write-Host "`nUsers where sAMAccountName differs from UPN username: $($mismatches.Count)" -ForegroundColor Yellow

if ($mismatches.Count -gt 0) {
    Write-Host "`nExamples of mismatches:" -ForegroundColor Yellow
    $mismatches | Select-Object -First 10 sAMAccountName, UPNUsername, DisplayName | Format-Table -AutoSize
}

Write-Host "`nIMPORTANT: Profile folders could be named after EITHER format!" -ForegroundColor Yellow
Write-Host "Copy this file to your workstation for the next step." -ForegroundColor Yellow
