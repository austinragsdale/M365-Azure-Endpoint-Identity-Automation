# Test-MigrationUserLookup.ps1
# Verifies all Azure UPNs in the CSV exist in the XML file

param(
    [string]$CsvPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\UserLookup-FINAL.csv",
    [string]$XmlPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\ForensiTAzureID.xml"
)

# Load CSV
$csv = Import-Csv $csvPath

# Load XML
[xml]$xml = Get-Content $xmlPath

# Build hashtable of XML UPNs (lowercase for comparison)
$xmlUPNs = @{}
foreach ($user in $xml.ForensiTAzureID.User) {
    $upn = $user.UserPrincipalName.ToLower()
    $xmlUPNs[$upn] = $true
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "CSV vs XML Comparison" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nXML file contains: $($xmlUPNs.Count) users" -ForegroundColor White
Write-Host "CSV file contains: $($csv.Count) entries" -ForegroundColor White

# Check each CSV entry
$found = 0
$missing = @()

foreach ($row in $csv) {
    $azureUPN = $row.azure.ToLower()
    if ($xmlUPNs.ContainsKey($azureUPN)) {
        $found++
    } else {
        $missing += [PSCustomObject]@{
            OnPrem = $row.onprem
            AzureUPN = $row.azure
        }
    }
}

Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "RESULTS:" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan

Write-Host "`nCSV entries found in XML: $found" -ForegroundColor Green

if ($missing.Count -eq 0) {
    Write-Host "CSV entries NOT in XML: 0" -ForegroundColor Green
    Write-Host "`nALL CSV ENTRIES ARE VALID!" -ForegroundColor Green
} else {
    Write-Host "CSV entries NOT in XML: $($missing.Count)" -ForegroundColor Red
    Write-Host "`nMISSING FROM XML (these will FAIL migration):" -ForegroundColor Red
    $missing | Format-Table -AutoSize
}
