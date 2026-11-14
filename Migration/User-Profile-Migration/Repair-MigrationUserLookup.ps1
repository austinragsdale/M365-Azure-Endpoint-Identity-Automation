# Repair-MigrationUserLookup.ps1
# Keeps both on-prem entries but ensures both point to a valid Azure AD UPN

param(
    [string]$CsvPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\UserLookup-FINAL.csv",
    [string]$XmlPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\ForensiTAzureID.xml",
    [string]$OutputFolder = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CSV Fix Tool v2 - Keep Both Entries" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Step 1: Load XML and extract all valid UPNs
Write-Host "`nLoading Azure AD XML file..." -ForegroundColor Yellow
[xml]$xmlContent = Get-Content $XmlPath -Encoding UTF8
$validUPNs = @{}

foreach ($user in $xmlContent.ForensiTAzureID.User) {
    $upn = $user.UserPrincipalName.ToLower()
    $validUPNs[$upn] = $user.UserPrincipalName  # Store original case
}

Write-Host "Loaded $($validUPNs.Count) valid UPNs from Azure AD XML" -ForegroundColor Green

# Step 2: First pass - build a map of valid mappings from CSV
Write-Host "`nFirst pass: Finding valid mappings in CSV..." -ForegroundColor Yellow
$csvContent = Get-Content $CsvPath -Encoding UTF8
$validMappings = @{}  # Key: pattern (lastname), Value: valid Azure UPN

foreach ($line in $csvContent) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line.Split(',')
    if ($parts.Count -lt 2) { continue }

    $onprem = $parts[0].Trim()
    $azure = $parts[1].Trim()

    if ($onprem -eq "onprem" -or [string]::IsNullOrWhiteSpace($azure)) { continue }

    $azureLower = $azure.ToLower()

    # If this is a valid mapping, store it
    if ($validUPNs.ContainsKey($azureLower)) {
        # Extract lastname from the azure email for matching
        if ($azure -match "^([^@]+)@") {
            $azureUsername = $matches[1].ToLower()

            # If it's firstname.lastname format, extract lastname
            if ($azureUsername -match "\.([^\.]+)$") {
                $lastName = $matches[1]
                if (-not $validMappings.ContainsKey($lastName)) {
                    $validMappings[$lastName] = $validUPNs[$azureLower]
                }
            }
            # Also store by full username
            $validMappings[$azureUsername] = $validUPNs[$azureLower]
        }
    }
}

Write-Host "Found $($validMappings.Count) valid mapping patterns" -ForegroundColor Green

# Step 3: Second pass - fix invalid mappings using valid ones
Write-Host "`nSecond pass: Fixing invalid mappings..." -ForegroundColor Yellow
$outputLines = @()
$fixes = @()
$stillInvalid = @()

foreach ($line in $csvContent) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        $outputLines += $line
        continue
    }

    $parts = $line.Split(',')
    if ($parts.Count -lt 2) {
        $outputLines += $line
        continue
    }

    $onprem = $parts[0].Trim()
    $azure = $parts[1].Trim()

    # Skip header
    if ($onprem -eq "onprem" -and $azure -eq "azure") {
        $outputLines += $line
        continue
    }

    # Skip empty azure values
    if ([string]::IsNullOrWhiteSpace($azure)) {
        $outputLines += $line
        continue
    }

    $azureLower = $azure.ToLower()

    # If already valid, keep as is
    if ($validUPNs.ContainsKey($azureLower)) {
        $outputLines += $line
        continue
    }

    # Invalid mapping - try to find the correct UPN
    $foundCorrectUPN = $null

    # Extract username part from the invalid azure email
    if ($azure -match "^([^@]+)@") {
        $targetUsername = $matches[1].ToLower()

        # Strategy 1: If it's short format (jsmith), look for lastname match
        if ($targetUsername -notmatch "\.") {
            # Try to extract lastname - assume format is firstinitial+lastname
            # e.g., "jsmith" -> lastname is "smith"
            if ($targetUsername -match "^[a-z](.+)$") {
                $possibleLastName = $matches[1]
                if ($validMappings.ContainsKey($possibleLastName)) {
                    $foundCorrectUPN = $validMappings[$possibleLastName]
                }
            }
        }

        # Strategy 2: Check if the exact username exists in valid mappings
        if (-not $foundCorrectUPN -and $validMappings.ContainsKey($targetUsername)) {
            $foundCorrectUPN = $validMappings[$targetUsername]
        }
    }

    if ($foundCorrectUPN) {
        $fixes += [PSCustomObject]@{
            OnPrem = $onprem
            OldAzure = $azure
            NewAzure = $foundCorrectUPN
        }
        $outputLines += "$onprem,$foundCorrectUPN"
    }
    else {
        # Still can't find valid mapping
        $stillInvalid += [PSCustomObject]@{
            OnPrem = $onprem
            Azure = $azure
        }
        $outputLines += $line  # Keep original
    }
}

# Step 4: Output results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nFIXES APPLIED ($($fixes.Count) entries corrected):" -ForegroundColor Green
if ($fixes.Count -gt 0) {
    $fixes | Format-Table -AutoSize | Out-String | Write-Host
}

Write-Host "`nSTILL INVALID ($($stillInvalid.Count) entries - may be external users or deleted accounts):" -ForegroundColor Yellow
if ($stillInvalid.Count -gt 0 -and $stillInvalid.Count -le 50) {
    $stillInvalid | Format-Table -AutoSize | Out-String | Write-Host
}
elseif ($stillInvalid.Count -gt 50) {
    $stillInvalid | Select-Object -First 30 | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "... and $($stillInvalid.Count - 30) more (see Mismatches-Report-v2.csv)" -ForegroundColor Yellow
}

# Step 5: Save files
$outputCsvPath = Join-Path $OutputFolder "UserLookup-FIXED.csv"
$outputLines | Set-Content -Path $outputCsvPath -Encoding UTF8
Write-Host "`nCorrected CSV saved to: $outputCsvPath" -ForegroundColor Green

$outputXmlPath = Join-Path $OutputFolder "ForensiTAzureID.xml"
if ((Resolve-Path $XmlPath).Path -ne [System.IO.Path]::GetFullPath($outputXmlPath)) { Copy-Item $XmlPath $outputXmlPath -Force }
Write-Host "XML copied to: $outputXmlPath" -ForegroundColor Green

$fixesReportPath = Join-Path $OutputFolder "Fixes-Report-v2.csv"
$fixes | Export-Csv -Path $fixesReportPath -NoTypeInformation
Write-Host "Fixes report saved to: $fixesReportPath" -ForegroundColor Green

$mismatchReportPath = Join-Path $OutputFolder "Mismatches-Report-v2.csv"
$stillInvalid | Export-Csv -Path $mismatchReportPath -NoTypeInformation
Write-Host "Remaining mismatches saved to: $mismatchReportPath" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "DONE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nThe fixed CSV keeps BOTH on-prem entries but ensures" -ForegroundColor White
Write-Host "they point to the SAME valid Azure AD UPN." -ForegroundColor White
