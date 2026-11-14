<#
.SYNOPSIS
    Resolves a list of people's names to Entra ID UPNs. Read only. No group writes.

.DESCRIPTION
    Reads a list of names from a file, runs 4 fallback resolution strategies against Microsoft Graph,
    prints a color coded console table, exports a CSV, and emits a clean copy paste block of
    resolved UPNs for Add-UsersToEntraGroup.ps1.

    Required scope: User.Read.All

.PARAMETER NameFile
    Path to a .txt file (one name per line) or a .csv file with a Name column
    (if there is no Name column, the first column is used). Accepts "Last, First Middle"
    and "First Last" formats. Blank lines and lines starting with # are ignored.

.PARAMETER OutputFolder
    Folder for the results CSV. Defaults to your Downloads folder.

.EXAMPLE
    Connect-MgGraph -Scopes "User.Read.All"
    .\Resolve-UserUPNsFromNames.ps1 -NameFile "C:\lists\names.txt"

.NOTES
    Author: Austin Ragsdale
    PowerShell 5.1 compatible, tuned for 7.
#>

#Requires -Modules Microsoft.Graph.Users

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$NameFile,

    [string]$OutputFolder = (Join-Path $env:USERPROFILE "Downloads")
)

# ============================================================
# Config
# ============================================================
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath   = Join-Path $OutputFolder "Resolved_UPNs_$timestamp.csv"

# ============================================================
# Load names from file
# ============================================================
if ([System.IO.Path]::GetExtension($NameFile).ToLower() -eq ".csv") {
    $rows = @(Import-Csv -Path $NameFile)
    if ($rows.Count -eq 0) { Write-Error "No rows found in $NameFile."; return }
    $nameCol = if ($rows[0].PSObject.Properties.Name -contains "Name") { "Name" } else { @($rows[0].PSObject.Properties.Name)[0] }
    $rawNames = $rows | ForEach-Object { $_.$nameCol }
}
else {
    $rawNames = Get-Content -Path $NameFile
}
$rawNames = @($rawNames | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") })
if ($rawNames.Count -eq 0) { Write-Error "No names to process in $NameFile."; return }

# ============================================================
# Verify Graph connection
# ============================================================
try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    if ($ctx.Scopes -notcontains "User.Read.All" -and $ctx.Scopes -notcontains "Directory.Read.All") {
        Write-Warning "Current scopes: $($ctx.Scopes -join ', '). User.Read.All recommended."
    }
    Write-Host "Connected as: $($ctx.Account)  Tenant: $($ctx.TenantId)" -ForegroundColor Cyan
}
catch {
    Write-Error "Not connected to Graph. Run: Connect-MgGraph -Scopes 'User.Read.All'"
    return
}

# ============================================================
# Name parsing helpers
# ============================================================
function Get-NameParts {
    param([string]$Raw)

    $r = $Raw.Trim()

    # "Last, First Middle" form
    if ($r -match ",") {
        $parts = $r -split ",", 2
        $last  = $parts[0].Trim()
        $rest  = $parts[1].Trim()
        $restParts = $rest -split "\s+"
        $first = $restParts[0]
        $middle = if ($restParts.Count -gt 1) { ($restParts[1..($restParts.Count - 1)] -join " ") } else { "" }
        return [PSCustomObject]@{
            First    = $first
            Middle   = $middle
            Last     = $last
            FullFL   = "$first $last"
            FullLF   = "$last, $first"
        }
    }

    # "First Last" form
    $parts = $r -split "\s+"
    if ($parts.Count -ge 2) {
        $first = $parts[0]
        $last  = $parts[-1]
        $middle = if ($parts.Count -gt 2) { ($parts[1..($parts.Count - 2)] -join " ") } else { "" }
        return [PSCustomObject]@{
            First    = $first
            Middle   = $middle
            Last     = $last
            FullFL   = "$first $last"
            FullLF   = "$last, $first"
        }
    }

    return [PSCustomObject]@{
        First    = $r
        Middle   = ""
        Last     = ""
        FullFL   = $r
        FullLF   = $r
    }
}

function Get-SurnameCandidates {
    param([string]$Last)

    $candidates = @($Last)

    # Strip trailing honorifics/qualifiers like "KUHN MR" -> "KUHN"
    $suffixes = @("MR", "MRS", "MS", "DR", "JR", "SR", "II", "III", "IV")
    $tokens = $Last -split "\s+"
    if ($tokens.Count -gt 1) {
        $lastToken = $tokens[-1].ToUpper()
        if ($suffixes -contains $lastToken) {
            $stripped = ($tokens[0..($tokens.Count - 2)] -join " ")
            $candidates += $stripped
        }
        $firstToken = $tokens[0].ToUpper()
        if ($suffixes -contains $firstToken) {
            $stripped = ($tokens[1..($tokens.Count - 1)] -join " ")
            $candidates += $stripped
        }
    }

    return ($candidates | Select-Object -Unique)
}

# ============================================================
# Resolution strategies
# ============================================================
function Resolve-User {
    param([string]$Raw)

    $parts = Get-NameParts -Raw $Raw
    $result = [PSCustomObject]@{
        RawName        = $Raw
        Status         = "NotFound"
        UPN            = ""
        DisplayName    = ""
        UserId         = ""
        AllCandidates  = ""
        Strategy       = ""
    }

    # Strategy 1: displayName eq "First Last"
    try {
        $q = $parts.FullFL.Replace("'", "''")
        $r1 = Get-MgUser -Filter "displayName eq '$q'" -Property "id,displayName,userPrincipalName,givenName,surname" -ErrorAction Stop
        if ($r1) {
            $arr = @($r1)
            if ($arr.Count -eq 1) {
                $result.Status = "Resolved"
                $result.UPN = $arr[0].UserPrincipalName
                $result.DisplayName = $arr[0].DisplayName
                $result.UserId = $arr[0].Id
                $result.Strategy = "displayName eq First Last"
                return $result
            }
            elseif ($arr.Count -gt 1) {
                $result.Status = "Ambiguous"
                $result.AllCandidates = ($arr | ForEach-Object { "$($_.DisplayName) <$($_.UserPrincipalName)>" }) -join " | "
                $result.Strategy = "displayName eq First Last"
                return $result
            }
        }
    } catch { }

    # Strategy 2: displayName eq "Last, First"
    try {
        $q = $parts.FullLF.Replace("'", "''")
        $r2 = Get-MgUser -Filter "displayName eq '$q'" -Property "id,displayName,userPrincipalName,givenName,surname" -ErrorAction Stop
        if ($r2) {
            $arr = @($r2)
            if ($arr.Count -eq 1) {
                $result.Status = "Resolved"
                $result.UPN = $arr[0].UserPrincipalName
                $result.DisplayName = $arr[0].DisplayName
                $result.UserId = $arr[0].Id
                $result.Strategy = "displayName eq Last, First"
                return $result
            }
            elseif ($arr.Count -gt 1) {
                $result.Status = "Ambiguous"
                $result.AllCandidates = ($arr | ForEach-Object { "$($_.DisplayName) <$($_.UserPrincipalName)>" }) -join " | "
                $result.Strategy = "displayName eq Last, First"
                return $result
            }
        }
    } catch { }

    # Strategy 3: startswith(surname,X) and startswith(givenName,Y), with surname suffix stripping
    if ($parts.First -and $parts.Last) {
        $surnameCandidates = Get-SurnameCandidates -Last $parts.Last
        foreach ($sc in $surnameCandidates) {
            try {
                $sQ = $sc.Replace("'", "''")
                $gQ = $parts.First.Replace("'", "''")
                $r3 = Get-MgUser -Filter "startswith(surname,'$sQ') and startswith(givenName,'$gQ')" -Property "id,displayName,userPrincipalName,givenName,surname" -ErrorAction Stop
                if ($r3) {
                    $arr = @($r3)
                    if ($arr.Count -eq 1) {
                        $result.Status = "Resolved"
                        $result.UPN = $arr[0].UserPrincipalName
                        $result.DisplayName = $arr[0].DisplayName
                        $result.UserId = $arr[0].Id
                        $result.Strategy = "startswith surname='$sc' givenName='$($parts.First)'"
                        return $result
                    }
                    elseif ($arr.Count -gt 1) {
                        $result.Status = "Ambiguous"
                        $result.AllCandidates = ($arr | ForEach-Object { "$($_.DisplayName) <$($_.UserPrincipalName)>" }) -join " | "
                        $result.Strategy = "startswith surname='$sc' givenName='$($parts.First)'"
                        return $result
                    }
                }
            } catch { }
        }
    }

    # Strategy 4: $search with ConsistencyLevel eventual
    try {
        $searchTerm = if ($parts.First -and $parts.Last) { "$($parts.First) $($parts.Last)" } else { $Raw }
        $searchQ = $searchTerm.Replace('"', '\"')
        $r4 = Get-MgUser -Search "`"displayName:$searchQ`"" -ConsistencyLevel eventual -CountVariable c -Property "id,displayName,userPrincipalName,givenName,surname" -ErrorAction Stop
        if ($r4) {
            $arr = @($r4)
            if ($arr.Count -eq 1) {
                $result.Status = "Resolved"
                $result.UPN = $arr[0].UserPrincipalName
                $result.DisplayName = $arr[0].DisplayName
                $result.UserId = $arr[0].Id
                $result.Strategy = "search displayName"
                return $result
            }
            elseif ($arr.Count -gt 1) {
                $result.Status = "Ambiguous"
                $result.AllCandidates = ($arr | ForEach-Object { "$($_.DisplayName) <$($_.UserPrincipalName)>" }) -join " | "
                $result.Strategy = "search displayName"
                return $result
            }
        }
    } catch { }

    return $result
}

# ============================================================
# Run resolution
# ============================================================
Write-Host "`nResolving $($rawNames.Count) names..." -ForegroundColor Cyan
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($name in $rawNames) {
    $i++
    Write-Progress -Activity "Resolving users" -Status "$i of $($rawNames.Count): $name" -PercentComplete (($i / $rawNames.Count) * 100)
    $res = Resolve-User -Raw $name
    $results.Add($res) | Out-Null
}
Write-Progress -Activity "Resolving users" -Completed

# ============================================================
# Console output
# ============================================================
Write-Host "`n===== RESULTS =====" -ForegroundColor Cyan
$fmt = "{0,-32} {1,-10} {2,-45} {3}"
Write-Host ($fmt -f "RawName", "Status", "UPN", "DisplayName") -ForegroundColor White
Write-Host ($fmt -f ("-" * 30), ("-" * 10), ("-" * 43), ("-" * 30)) -ForegroundColor DarkGray

foreach ($r in $results) {
    $line = $fmt -f $r.RawName, $r.Status, $r.UPN, $r.DisplayName
    switch ($r.Status) {
        "Resolved"  { Write-Host $line -ForegroundColor Green }
        "Ambiguous" { Write-Host $line -ForegroundColor Yellow }
        default     { Write-Host $line -ForegroundColor Yellow }
    }
    if ($r.Status -eq "Ambiguous" -and $r.AllCandidates) {
        Write-Host "    Candidates: $($r.AllCandidates)" -ForegroundColor DarkYellow
    }
}

# ============================================================
# Summary
# ============================================================
$resolved  = @($results | Where-Object Status -eq "Resolved")
$ambiguous = @($results | Where-Object Status -eq "Ambiguous")
$notfound  = @($results | Where-Object Status -eq "NotFound")

Write-Host "`n===== SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Resolved:  {0}" -f $resolved.Count)  -ForegroundColor Green
Write-Host ("Ambiguous: {0}" -f $ambiguous.Count) -ForegroundColor Yellow
Write-Host ("NotFound:  {0}" -f $notfound.Count)  -ForegroundColor Yellow
Write-Host ("Total:     {0}" -f $results.Count)

# ============================================================
# CSV export
# ============================================================
$results | Select-Object RawName, Status, UPN, DisplayName, UserId, AllCandidates, Strategy |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV: $csvPath" -ForegroundColor Cyan

# ============================================================
# Copy paste block of resolved UPNs
# ============================================================
Write-Host "`n===== COPY BELOW =====" -ForegroundColor Magenta
foreach ($r in $resolved) {
    Write-Host $r.UPN
}
Write-Host "===== COPY ABOVE =====" -ForegroundColor Magenta

if ($ambiguous.Count -gt 0 -or $notfound.Count -gt 0) {
    Write-Host "`nReview Ambiguous/NotFound rows in the CSV before running the add script." -ForegroundColor Yellow
}
