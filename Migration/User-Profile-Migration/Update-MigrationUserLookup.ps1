# Apply fixes to CSV
param(
    [string]$CsvPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\UserLookup-FINAL.csv",
    [string]$FixesPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\Fixes-Report-v2.csv",
    [string]$OutputPath = "C:\ProgramData\ForensiT\User Profile Wizard Corporate\Deployment Files\CSV-xml\UserLookup-CORRECTED.csv"
)

# Load fixes
$fixes = Import-Csv $FixesPath
$fixMap = @{}
foreach ($fix in $fixes) {
    $key = "$($fix.OnPrem),$($fix.OldAzure)"
    $fixMap[$key] = $fix.NewAzure
}

Write-Host "Loaded $($fixMap.Count) fixes to apply"

# Apply fixes to CSV
$csvContent = Get-Content $CsvPath -Encoding UTF8
$outputLines = @()
$appliedCount = 0

foreach ($line in $csvContent) {
    $trimmedLine = $line.Trim()
    if ($fixMap.ContainsKey($trimmedLine)) {
        $parts = $trimmedLine.Split(',')
        $newLine = "$($parts[0]),$($fixMap[$trimmedLine])"
        $outputLines += $newLine
        $appliedCount++
    }
    else {
        $outputLines += $line
    }
}

# Save output
$outputLines | Out-File $OutputPath -Encoding UTF8

Write-Host "Applied $appliedCount fixes"
Write-Host "Saved to: $OutputPath"
