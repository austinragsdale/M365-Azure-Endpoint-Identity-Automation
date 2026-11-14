<#
.SYNOPSIS
    Bulk-assigns a Microsoft 365 license (default: Exchange Online Plan 1,
    EXCHANGESTANDARD) to a list of users sourced from an Excel file.

.DESCRIPTION
    Reads user UPNs from the chosen column of the supplied Excel workbook,
    then for each user:
      - Resolves the user in Entra ID via Microsoft Graph
      - Sets UsageLocation (default "US") if it is blank
      - Skips the user if the license is already assigned (directly)
      - Otherwise assigns the license
    Resolves the license SkuId dynamically from the tenant
    (no hardcoded GUID) and verifies that enough licenses are available
    before processing.

    Idempotent: re-running is safe. Already-licensed users are skipped.
    Run with -DryRun first to preview without making changes.

.PARAMETER Path
    Excel workbook that lists the users.

.PARAMETER UpnColumnNumber
    Column number that holds the UPNs (A = 1, B = 2, ... M = 13). Columns are read by
    number, so workbooks with duplicate header names still work.

.PARAMETER WorksheetName
    Worksheet to read. Default: Sheet1.

.PARAMETER SkuPartNumber
    License to assign, by SKU part number. Default: EXCHANGESTANDARD (Exchange Online Plan 1).
    List your tenant's SKUs with: Get-MgSubscribedSku | Select-Object SkuPartNumber

.PARAMETER UsageLocation
    Usage location set on users that have none. Default: US.

.PARAMETER LogFolder
    Folder for the log file. Default: your Downloads folder.

.PARAMETER DryRun
    Preview only. No changes are made.

.EXAMPLE
    # Dry run (no changes made - review the log before going live):
    .\Add-LicenseToUsers.ps1 -Path "C:\Temp\users.xlsx" -UpnColumnNumber 3 -DryRun

    # Live run (actually assigns licenses):
    .\Add-LicenseToUsers.ps1 -Path "C:\Temp\users.xlsx" -UpnColumnNumber 3

.NOTES
    Required Graph scopes : User.ReadWrite.All, Organization.Read.All
    Required admin role   : License Administrator (or higher, e.g. User Admin /
                            Global Admin). Privileged Role Admin NOT required.
    Modules               : Microsoft.Graph.Authentication,
                            Microsoft.Graph.Users,
                            Microsoft.Graph.Identity.DirectoryManagement,
                            ImportExcel

    Author : Austin Ragsdale
#>

#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter(Mandatory)]
    [ValidateRange(1, 16384)]
    [int] $UpnColumnNumber,

    [string] $WorksheetName = 'Sheet1',
    [string] $SkuPartNumber = 'EXCHANGESTANDARD',   # Exchange Online (Plan 1)
    [string] $UsageLocation = 'US',
    [string] $LogFolder = (Join-Path $env:USERPROFILE 'Downloads'),
    [switch] $DryRun   # pass -DryRun to preview without making changes
)

# --------------------------------------------------------------------------- #
#  CONFIGURATION                                                              #
# --------------------------------------------------------------------------- #
$SourceXlsx     = $Path
$SourceSheet    = $WorksheetName
$TargetSkuPart  = $SkuPartNumber
$DefaultUsageLocation = $UsageLocation

$LogFile        = Join-Path $LogFolder ("Add-LicenseToUsers_{0}_{1}.log" -f `
                    (Get-Date -Format 'yyyyMMdd-HHmmss'),
                    ($(if ($DryRun) { 'DRYRUN' } else { 'LIVE' })))

# --------------------------------------------------------------------------- #
#  HELPERS                                                                    #
# --------------------------------------------------------------------------- #
function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','SKIP','DRYRUN')]
        [string] $Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} [{1,-7}] {2}' -f $ts, $Level, $Message
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        'SKIP'    { Write-Host $line -ForegroundColor DarkGray }
        'DRYRUN'  { Write-Host $line -ForegroundColor Cyan }
        default   { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Ensure-Module {
    param([Parameter(Mandatory)][string] $Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Log "Module '$Name' not found - installing for CurrentUser." 'WARN'
        try {
            Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Log "Installed module '$Name'." 'SUCCESS'
        } catch {
            Write-Log "Failed to install module '$Name': $($_.Exception.Message)" 'ERROR'
            throw
        }
    }
    Import-Module $Name -ErrorAction Stop
}

# --------------------------------------------------------------------------- #
#  MAIN                                                                       #
# --------------------------------------------------------------------------- #
$ErrorActionPreference = 'Stop'

# Make sure log folder exists and start the log
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
Write-Log "==== Add-LicenseToUsers starting ===="
Write-Log ("Mode           : {0}" -f $(if ($DryRun) {'DRY RUN (no changes)'} else {'LIVE (changes WILL be applied)'}))
Write-Log "Source file    : $SourceXlsx"
Write-Log "Sheet          : $SourceSheet"
Write-Log "Target SKU     : $TargetSkuPart"
Write-Log "Log file       : $LogFile"

# 1. Sanity-check source file
if (-not (Test-Path $SourceXlsx)) {
    Write-Log "Source file not found: $SourceXlsx" 'ERROR'
    return
}

# 2. Modules
try {
    Ensure-Module -Name 'ImportExcel'
    Ensure-Module -Name 'Microsoft.Graph.Authentication'
    Ensure-Module -Name 'Microsoft.Graph.Users'
    Ensure-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement'
} catch {
    Write-Log "Module preparation failed. Aborting." 'ERROR'
    return
}

# 3. Read the workbook. -NoHeader bypasses duplicate-header validation (some
#    exports have two columns with the same name), -StartRow 2 skips the header
#    row, and the UPN column is referenced by number (P1 = column A, P2 = B, ...).
try {
    $raw = Import-Excel -Path $SourceXlsx -WorksheetName $SourceSheet -NoHeader -StartRow 2 -ErrorAction Stop
} catch {
    Write-Log "Failed to read Excel: $($_.Exception.Message)" 'ERROR'
    return
}

if (-not $raw -or $raw.Count -eq 0) {
    Write-Log "Workbook returned zero rows." 'ERROR'
    return
}

$upnPropName = "P$UpnColumnNumber"   # -NoHeader names the columns P1, P2, P3...
Write-Log "Reading UPNs from column $UpnColumnNumber ($upnPropName). Total rows: $($raw.Count)"

# 4. Build UPN list (trim, drop blanks, dedupe, preserve order)
$upns = @()
$seen = @{}
foreach ($row in $raw) {
    $v = $row.$upnPropName
    if (-not $v) { continue }
    $u = ([string]$v).Trim()
    if (-not $u -or $u -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Write-Log "Skipping row with invalid UPN value: '$v'" 'WARN'
        continue
    }
    $key = $u.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
        Write-Log "Duplicate UPN in source, ignoring extra: $u" 'WARN'
        continue
    }
    $seen[$key] = $true
    $upns += $u
}
Write-Log ("Unique UPNs to process: {0}" -f $upns.Count)
if ($upns.Count -eq 0) { Write-Log "Nothing to do." 'WARN'; return }

# 5. Connect to Graph
Write-Log "Connecting to Microsoft Graph (interactive)..."
try {
    Connect-MgGraph -Scopes 'User.ReadWrite.All','Organization.Read.All' -NoWelcome -ErrorAction Stop | Out-Null
} catch {
    Write-Log "Connect-MgGraph failed: $($_.Exception.Message)" 'ERROR'
    return
}
$ctx = Get-MgContext
Write-Log ("Connected. Tenant: {0}  Account: {1}" -f $ctx.TenantId, $ctx.Account)

# 6. Resolve the EXCHANGESTANDARD SKU dynamically
try {
    $sku = Get-MgSubscribedSku -All -ErrorAction Stop |
           Where-Object { $_.SkuPartNumber -eq $TargetSkuPart } |
           Select-Object -First 1
} catch {
    Write-Log "Failed to enumerate SKUs: $($_.Exception.Message)" 'ERROR'
    Disconnect-MgGraph | Out-Null
    return
}
if (-not $sku) {
    Write-Log "SKU '$TargetSkuPart' is not present in this tenant. Wrong tenant?" 'ERROR'
    Disconnect-MgGraph | Out-Null
    return
}

$enabled   = [int]$sku.PrepaidUnits.Enabled
$consumed  = [int]$sku.ConsumedUnits
$available = $enabled - $consumed
Write-Log ("SKU {0}  SkuId={1}  Enabled={2}  Consumed={3}  Available={4}" -f `
            $sku.SkuPartNumber, $sku.SkuId, $enabled, $consumed, $available)

if ($available -lt $upns.Count) {
    Write-Log ("Not enough licenses available ({0} available, {1} requested). Continuing - users beyond the limit will fail with a clear error." -f $available, $upns.Count) 'WARN'
} else {
    Write-Log ("License capacity OK: {0} of {1} available." -f $available, $enabled) 'SUCCESS'
}

# 7. Process users
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($upn in $upns) {
    $i++
    $status = [ordered]@{
        Index        = $i
        UPN          = $upn
        ObjectId     = $null
        Action       = $null
        Result       = $null
        Detail       = $null
    }

    Write-Log ("[{0}/{1}] {2}" -f $i, $upns.Count, $upn)

    try {
        $user = Get-MgUser -UserId $upn -Property 'Id,UserPrincipalName,DisplayName,UsageLocation,AssignedLicenses,AccountEnabled' -ErrorAction Stop
    } catch {
        $status.Action = 'Lookup'
        $status.Result = 'Failed'
        $status.Detail = "User not found or lookup error: $($_.Exception.Message)"
        Write-Log $status.Detail 'ERROR'
        $results.Add([pscustomobject]$status); continue
    }

    $status.ObjectId = $user.Id

    # Already licensed (directly)?
    $hasSku = @($user.AssignedLicenses | Where-Object { $_.SkuId -eq $sku.SkuId }).Count -gt 0
    if ($hasSku) {
        $status.Action = 'Assign'
        $status.Result = 'Skipped'
        $status.Detail = "Already has $TargetSkuPart assigned directly."
        Write-Log $status.Detail 'SKIP'
        $results.Add([pscustomobject]$status); continue
    }

    # UsageLocation must be set before licensing
    if ([string]::IsNullOrWhiteSpace($user.UsageLocation)) {
        if ($DryRun) {
            Write-Log "Would set UsageLocation='$DefaultUsageLocation' on $upn" 'DRYRUN'
        } else {
            try {
                Update-MgUser -UserId $user.Id -UsageLocation $DefaultUsageLocation -ErrorAction Stop
                Write-Log "Set UsageLocation='$DefaultUsageLocation' on $upn" 'INFO'
            } catch {
                $status.Action = 'SetUsageLocation'
                $status.Result = 'Failed'
                $status.Detail = "UsageLocation update failed: $($_.Exception.Message)"
                Write-Log $status.Detail 'ERROR'
                $results.Add([pscustomobject]$status); continue
            }
        }
    }

    # Assign the license
    $status.Action = 'Assign'
    if ($DryRun) {
        $status.Result = 'DryRun'
        $status.Detail = "Would assign $TargetSkuPart ($($sku.SkuId))."
        Write-Log $status.Detail 'DRYRUN'
    } else {
        try {
            $addLic = @( @{ SkuId = $sku.SkuId } )
            Set-MgUserLicense -UserId $user.Id -AddLicenses $addLic -RemoveLicenses @() -ErrorAction Stop | Out-Null
            $status.Result = 'Success'
            $status.Detail = "Assigned $TargetSkuPart."
            Write-Log $status.Detail 'SUCCESS'
        } catch {
            $status.Result = 'Failed'
            $status.Detail = "Set-MgUserLicense failed: $($_.Exception.Message)"
            Write-Log $status.Detail 'ERROR'
        }
    }
    $results.Add([pscustomobject]$status)
}

# 8. Summary + CSV export
$summary = $results | Group-Object Result | Select-Object Name, Count | Sort-Object Name
Write-Log "==== Summary ===="
foreach ($s in $summary) { Write-Log ("  {0,-8} : {1}" -f $s.Name, $s.Count) }

$csvOut = [System.IO.Path]::ChangeExtension($LogFile, '.csv')
try {
    $results | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
    Write-Log "Results CSV: $csvOut" 'SUCCESS'
} catch {
    Write-Log "Failed to export CSV: $($_.Exception.Message)" 'WARN'
}

try { Disconnect-MgGraph | Out-Null } catch { }
Write-Log "==== Done ===="
