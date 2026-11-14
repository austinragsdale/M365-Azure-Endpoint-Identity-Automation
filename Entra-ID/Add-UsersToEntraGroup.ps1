<#
.SYNOPSIS
    Bulk add users to any Entra ID group by UPN.

.DESCRIPTION
    Reusable version. Accepts a group (by displayName or ObjectId) and a list
    of UPNs (inline array, .txt file, or .csv file with a UPN or
    UserPrincipalName column). Skips existing members. Emits color coded
    console output and a CSV log to the specified output folder.

    Required scopes: Group.ReadWrite.All, GroupMember.ReadWrite.All, User.Read.All

.PARAMETER GroupName
    Group displayName. One of GroupName or GroupId is required.

.PARAMETER GroupId
    Group ObjectId (guid). Preferred if the name is ambiguous.

.PARAMETER UpnFile
    Path to a .txt (one UPN per line) or .csv (with a UPN or UserPrincipalName
    column). Blank lines and lines starting with # are ignored.

.PARAMETER Upn
    Inline array of UPNs. Alternative to UpnFile.

.PARAMETER OutputFolder
    Folder for the run log CSV. Defaults to your Downloads folder.

.EXAMPLE
    Connect-MgGraph -Scopes "Group.ReadWrite.All","GroupMember.ReadWrite.All","User.Read.All"
    .\Add-UsersToEntraGroup.ps1 -GroupName "App-Users" -UpnFile "C:\lists\app-users.txt"

.EXAMPLE
    .\Add-UsersToEntraGroup.ps1 -GroupId "00000000-0000-0000-0000-000000000000" -Upn "adele@contoso.com","alex@contoso.com" -WhatIf

.EXAMPLE
    .\Add-UsersToEntraGroup.ps1 -GroupName "Sales-Global" -UpnFile "C:\hr\newhires.csv"

.NOTES
    Author: Austin Ragsdale
    PowerShell 5.1 compatible, tuned for 7.
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Users

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "NameFile")]
param(
    [Parameter(Mandatory, ParameterSetName = "NameFile")]
    [Parameter(Mandatory, ParameterSetName = "NameInline")]
    [string]$GroupName,

    [Parameter(Mandatory, ParameterSetName = "IdFile")]
    [Parameter(Mandatory, ParameterSetName = "IdInline")]
    [string]$GroupId,

    [Parameter(Mandatory, ParameterSetName = "NameFile")]
    [Parameter(Mandatory, ParameterSetName = "IdFile")]
    [ValidateScript({ Test-Path $_ })]
    [string]$UpnFile,

    [Parameter(Mandatory, ParameterSetName = "NameInline")]
    [Parameter(Mandatory, ParameterSetName = "IdInline")]
    [string[]]$Upn,

    [string]$OutputFolder = (Join-Path $env:USERPROFILE "Downloads"),

    [switch]$SkipConfirm
)

# ============================================================
# Load UPN list
# ============================================================
function Read-UpnList {
    param([string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    $upns = @()

    if ($ext -eq ".csv") {
        $rows = Import-Csv -Path $Path
        if (-not $rows) { return @() }
        $col = $null
        foreach ($candidate in @("UPN", "UserPrincipalName", "Email", "EmailAddress")) {
            if ($rows[0].PSObject.Properties.Name -contains $candidate) {
                $col = $candidate
                break
            }
        }
        if (-not $col) {
            throw "CSV must contain a column named UPN, UserPrincipalName, Email, or EmailAddress. Found: $(($rows[0].PSObject.Properties.Name) -join ', ')"
        }
        $upns = $rows | ForEach-Object { $_.$col }
    }
    else {
        # Treat everything else as line delimited text
        $upns = Get-Content -Path $Path
    }

    # Clean: trim, drop blanks, drop comment lines
    $upns = $upns |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") }

    return $upns
}

if ($UpnFile) {
    try {
        $upns = Read-UpnList -Path $UpnFile
    } catch {
        Write-Error $_.Exception.Message
        return
    }
}
else {
    $upns = $Upn | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

if (-not $upns -or $upns.Count -eq 0) {
    Write-Error "No UPNs to process."
    return
}

# Deduplicate (case insensitive), preserve first occurrence
$seen = @{}
$upns = $upns | Where-Object {
    $k = $_.ToLower()
    if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = $true; $true }
}

Write-Host ("Loaded {0} UPNs from {1}." -f $upns.Count, ($(if ($UpnFile) { $UpnFile } else { "inline" })))

# ============================================================
# Verify Graph connection
# ============================================================
try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    Write-Host ""
    Write-Host "Account : $($ctx.Account)"
    Write-Host "Tenant  : $($ctx.TenantId)"
    Write-Host "Scopes  : $($ctx.Scopes -join ', ')"
    Write-Host ""
}
catch {
    Write-Error "Not connected. Run: Connect-MgGraph -Scopes 'Group.ReadWrite.All','GroupMember.ReadWrite.All','User.Read.All'"
    return
}

if (-not $SkipConfirm -and -not $WhatIfPreference) {
    $confirm = Read-Host "Proceed against this tenant? (Y/N)"
    if ($confirm -notmatch '^(Y|y)') {
        Write-Warning "Aborted."
        return
    }
}

# ============================================================
# Resolve target group
# ============================================================
if ($GroupId) {
    try {
        $group = Get-MgGroup -GroupId $GroupId -ErrorAction Stop
    } catch {
        Write-Error "Group Id '$GroupId' not found: $($_.Exception.Message)"
        return
    }
}
else {
    $escGroup = $GroupName.Replace("'", "''")
    $found = Get-MgGroup -Filter "displayName eq '$escGroup'" -All
    $foundArr = @($found)
    if ($foundArr.Count -eq 0) {
        Write-Error "Group '$GroupName' not found."
        return
    }
    if ($foundArr.Count -gt 1) {
        Write-Error "Multiple groups named '$GroupName' found. Rerun with -GroupId to disambiguate. Candidates:"
        $foundArr | ForEach-Object { Write-Host ("  {0}  Id: {1}" -f $_.DisplayName, $_.Id) }
        return
    }
    $group = $foundArr[0]
}

# Guard: on premises synced groups cannot be written via Graph
if ($group.OnPremisesSyncEnabled) {
    Write-Error "Group '$($group.DisplayName)' is synced from on premises AD. Membership must be managed in AD, not Graph."
    return
}

Write-Host ("Group   : {0}  (Id: {1})" -f $group.DisplayName, $group.Id) -ForegroundColor Cyan

# ============================================================
# Preload existing members
# ============================================================
$existingMemberIds = @{}
Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object {
    $existingMemberIds[$_.Id] = $true
}
Write-Host ("Existing members: {0}" -f $existingMemberIds.Count) -ForegroundColor Cyan
Write-Host ""

# ============================================================
# Process each UPN
# ============================================================
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($u in $upns) {
    $i++
    Write-Progress -Activity "Adding to $($group.DisplayName)" -Status "$i of $($upns.Count): $u" -PercentComplete (($i / $upns.Count) * 100)

    $entry = [PSCustomObject]@{
        UPN         = $u
        Status      = ""
        DisplayName = ""
        UserId      = ""
        Detail      = ""
    }

    try {
        $user = Get-MgUser -UserId $u -Property "id,displayName,userPrincipalName" -ErrorAction Stop
        $entry.DisplayName = $user.DisplayName
        $entry.UserId      = $user.Id
    }
    catch {
        $entry.Status = "NotFound"
        $entry.Detail = $_.Exception.Message
        Write-Host ("[NOT FOUND ] {0}" -f $u) -ForegroundColor Yellow
        $results.Add($entry) | Out-Null
        continue
    }

    if ($existingMemberIds.ContainsKey($user.Id)) {
        $entry.Status = "AlreadyMember"
        Write-Host ("[ALREADY   ] {0}  ({1})" -f $u, $user.DisplayName) -ForegroundColor DarkGray
        $results.Add($entry) | Out-Null
        continue
    }

    if ($PSCmdlet.ShouldProcess($u, "Add to $($group.DisplayName)")) {
        try {
            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
            $entry.Status = "Added"
            $existingMemberIds[$user.Id] = $true
            Write-Host ("[ADDED     ] {0}  ({1})" -f $u, $user.DisplayName) -ForegroundColor Green
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match 'already exist|One or more added object references already exist') {
                $entry.Status = "AlreadyMember"
                $entry.Detail = "Caught on add"
                Write-Host ("[ALREADY   ] {0}  ({1})" -f $u, $user.DisplayName) -ForegroundColor DarkGray
            }
            else {
                $entry.Status = "Error"
                $entry.Detail = $msg
                Write-Host ("[ERROR     ] {0}  {1}" -f $u, $msg) -ForegroundColor Red
            }
        }
    }
    else {
        $entry.Status = "WhatIf"
    }
    $results.Add($entry) | Out-Null
}
Write-Progress -Activity "Adding to $($group.DisplayName)" -Completed

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "===== SUMMARY =====" -ForegroundColor Cyan
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ("{0,-14} : {1}" -f $_.Name, $_.Count)
}

# ============================================================
# CSV log
# ============================================================
if (-not $WhatIfPreference) {
    if (-not (Test-Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
    $safeName = ($group.DisplayName -replace '[^a-zA-Z0-9_-]', '_')
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath = Join-Path $OutputFolder "GroupAddLog_${safeName}_$timestamp.csv"
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Log CSV: $csvPath" -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "(WhatIf mode: no changes made, no CSV written)" -ForegroundColor Yellow
}
