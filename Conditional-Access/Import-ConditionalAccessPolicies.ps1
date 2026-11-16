#Requires -Version 5.1
<#
.SYNOPSIS
    Bulk-imports Conditional Access policies (and their named locations) from JSON into a tenant, report-only.

.DESCRIPTION
    Restores a backup made by Export-ConditionalAccessPolicies.ps1, or imports any folder of Conditional Access
    policy JSON files, into the tenant you are connected to. Works for a restore into the same tenant or for
    copying a policy set into a new tenant.

    WITHOUT -Apply (default): dry run. Reads the tenant only and shows what would happen to every file.
    WITH -Apply: creates the named locations and policies. You are asked to type IMPORT first (skip with -Force).

    Safety rules:
      - A policy or named location whose display name already exists is SKIPPED, never overwritten. Safe to re-run.
      - Every policy is created REPORT-ONLY (enabledForReportingButNotEnforced), whatever state the file has.
        Review the sign-in logs, then turn policies on in the portal. Use -KeepExportedState to keep the
        state saved in each file.
      - Group, user and named location IDs are checked against the target tenant. An ID that does not exist
        there is matched by name using object-map.csv (groups by display name, users by UPN, named locations
        by display name). If any reference still cannot be resolved, that policy is SKIPPED and the missing
        objects are listed, so a policy is never created with a hole in its include or exclude lists.
      - Applications are checked too. Some first-party Microsoft apps (Azure DevOps, Microsoft Intune
        Enrollment, and others) have no service principal in a new tenant, and Graph then rejects the policy
        with "ServicePrincipalNotFound". Add -CreateMissingServicePrincipals to create them first.
      - A results CSV is written to the import folder.

    Folder layout read (the export layout). A flat folder of policy JSON files also works.
      <Path>\Policies\*.json
      <Path>\NamedLocations\*.json   (optional)
      <Path>\object-map.csv          (optional, used for name matching)

    Module needed : Microsoft.Graph.Authentication
    Role needed   : Conditional Access Administrator (plus Application Administrator for -CreateMissingServicePrincipals)
    Connect line  :
      Connect-MgGraph -Scopes Policy.ReadWrite.ConditionalAccess,Policy.Read.All,Group.Read.All,User.Read.All,Application.ReadWrite.All

.PARAMETER Path
    Backup folder made by Export-ConditionalAccessPolicies.ps1, or a folder of policy JSON files.

.PARAMETER Apply
    Create objects. Without it the script is a read-only dry run.

.PARAMETER Force
    Skip the typed IMPORT confirmation (for automation).

.PARAMETER KeepExportedState
    Create each policy with the state saved in its file instead of report-only.

.PARAMETER CreateMissingServicePrincipals
    Create a service principal for any application ID a policy targets that has none in this tenant.

.PARAMETER SkipNamedLocations
    Do not create named locations. Policies that need a missing location are skipped.

.EXAMPLE
    .\Import-ConditionalAccessPolicies.ps1 -Path .\CA-Backup-20261115-1600
    Dry run: shows what would be created, what already exists, and what cannot be resolved.

.EXAMPLE
    .\Import-ConditionalAccessPolicies.ps1 -Path .\CA-Backup-20261115-1600 -Apply -CreateMissingServicePrincipals
    Creates the named locations and every policy, report-only.

.NOTES
    Author: Austin Ragsdale
    Not handled: custom authentication strengths, terms of use and authentication contexts are not created.
    A policy that points to one of these is skipped by Graph with an error that is written to the results CSV.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Apply,
    [switch]$Force,
    [switch]$KeepExportedState,
    [switch]$CreateMissingServicePrincipals,
    [switch]$SkipNamedLocations
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) {
    throw 'Not connected. Run the Connect-MgGraph line from this script''s help (Get-Help .\Import-ConditionalAccessPolicies.ps1 -Full).'
}
if (-not (Test-Path $Path -PathType Container)) { throw "Folder not found: $Path" }

$guid       = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$reportOnly = 'enabledForReportingButNotEnforced'
$readOnly   = 'id', 'createdDateTime', 'modifiedDateTime', 'templateId', 'deletedDateTime'
$results    = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Area, [string]$Name, [string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Area = $Area; Name = $Name; Status = $Status; Detail = $Detail })
    $color = switch -Wildcard ($Status) { 'Created*' { 'Green' } 'WouldCreate*' { 'Cyan' } 'Exists' { 'DarkGray' } default { 'Yellow' } }
    Write-Host ('{0,-14} {1,-12} {2} {3}' -f $Area, $Status, $Name, $Detail) -ForegroundColor $color
}

function Invoke-Graph([string]$Method, [string]$Uri, $Body) {
    $p = @{ Method = $Method; Uri = "https://graph.microsoft.com/$Uri"; OutputType = 'PSObject' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 100); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}

function Get-GraphAll([string]$Uri) {
    $out = @(); $next = "https://graph.microsoft.com/$Uri"
    while ($next) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        $out += @($r.value); $next = $r.'@odata.nextLink'
    }
    $out
}

# Returns only the Graph error message, not the full HTTP dump.
function Get-ErrorText($Err) {
    $text = if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) { $Err.ErrorDetails.Message } else { $Err.Exception.Message }
    if ($text -match '"message"\s*:\s*"((?:[^"\\]|\\.)*)"') { return ($Matches[1] -replace '\\"', '"') }
    $text -replace '\s+', ' '
}

function Test-GraphObject([string]$Uri) {
    try { Invoke-Graph GET $Uri $null | Out-Null; $true } catch { $false }
}

function Find-ByFilter([string]$Collection, [string]$Property, [string]$Value) {
    $f = [uri]::EscapeDataString("$Property eq '$($Value -replace "'", "''")'")
    @(Get-GraphAll "v1.0/$Collection`?`$filter=$f&`$select=id")
}

function Read-JsonFile([string]$File) {
    [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

# ------------------------------------------------------------------ inputs
$policyFolder   = if (Test-Path (Join-Path $Path 'Policies')) { Join-Path $Path 'Policies' } else { $Path }
$locationFolder = Join-Path $Path 'NamedLocations'
$mapFile        = Join-Path $Path 'object-map.csv'

$nameMap = @{}
if (Test-Path $mapFile) { foreach ($row in (Import-Csv $mapFile)) { $nameMap[$row.Id] = $row } }

$policyFiles = @(Get-ChildItem $policyFolder -Filter *.json -File | Sort-Object Name)
if (-not $policyFiles) { throw "No policy JSON files found in $policyFolder" }

$ctx = Get-MgContext
if ($Apply) {
    Write-Host "APPLY MODE. Tenant: $($ctx.TenantId)  Account: $($ctx.Account)" -ForegroundColor Magenta
    if (-not $Force) {
        $answer = Read-Host 'Type the word IMPORT to continue'
        if ($answer -ne 'IMPORT') { Write-Host 'Cancelled.'; return }
    }
} else {
    Write-Host "DRY RUN. Tenant: $($ctx.TenantId). Nothing will be created. Add -Apply to import." -ForegroundColor Cyan
}

# ------------------------------------------------------------------ named locations
# idMap: source ID -> target ID (or a placeholder in a dry run)
$idMap = @{}
$existingNL = @{}
foreach ($l in (Get-GraphAll 'v1.0/identity/conditionalAccess/namedLocations')) { $existingNL[$l.displayName] = $l.id }

# A source location ID that already exists in this tenant (same-tenant restore) maps to itself.
foreach ($id in $existingNL.Values) { $idMap[$id] = $id }

# Named locations referenced in object-map.csv but not exported as files can still be matched by name.
foreach ($row in $nameMap.Values) {
    if ($row.Type -eq 'NamedLocation' -and -not $idMap.ContainsKey($row.Id) -and $existingNL.ContainsKey($row.DisplayName)) {
        $idMap[$row.Id] = $existingNL[$row.DisplayName]
    }
}

if (Test-Path $locationFolder) {
    $sourceIdByName = @{}
    foreach ($row in $nameMap.Values) { if ($row.Type -eq 'NamedLocation') { $sourceIdByName[$row.DisplayName] = $row.Id } }

    foreach ($file in (Get-ChildItem $locationFolder -Filter *.json -File | Sort-Object Name)) {
        $loc  = Read-JsonFile $file.FullName
        $name = [string]$loc.displayName
        $srcId = $sourceIdByName[$name]
        if ($existingNL.ContainsKey($name)) {
            if ($srcId) { $idMap[$srcId] = $existingNL[$name] }
            Add-Result 'NamedLocation' $name 'Exists'; continue
        }
        if ($SkipNamedLocations) { Add-Result 'NamedLocation' $name 'SKIPPED' '-SkipNamedLocations'; continue }
        foreach ($p in $readOnly) { $loc.PSObject.Properties.Remove($p) }
        if (-not $Apply) {
            if ($srcId) { $idMap[$srcId] = "<new:$name>" }
            Add-Result 'NamedLocation' $name 'WouldCreate'; continue
        }
        try {
            $new = Invoke-Graph POST 'v1.0/identity/conditionalAccess/namedLocations' $loc
            if ($srcId) { $idMap[$srcId] = $new.id }
            $existingNL[$name] = $new.id
            Add-Result 'NamedLocation' $name 'Created'
        } catch { Add-Result 'NamedLocation' $name 'FAILED' (Get-ErrorText $_) }
    }
}

# ------------------------------------------------------------------ reference resolvers (cached)
$cache = @{}
function Resolve-Reference([string]$Type, [string]$Id) {
    $key = "$Type|$Id"
    if ($cache.ContainsKey($key)) { return $cache[$key] }
    $target = $null
    switch ($Type) {
        'Group' {
            if (Test-GraphObject "v1.0/groups/$Id`?`$select=id") { $target = $Id }
            elseif ($nameMap[$Id].DisplayName) {
                $hit = @(Find-ByFilter 'groups' 'displayName' $nameMap[$Id].DisplayName)
                if ($hit.Count -eq 1) { $target = $hit[0].id }
            }
        }
        'User' {
            if (Test-GraphObject "v1.0/users/$Id`?`$select=id") { $target = $Id }
            elseif ($nameMap[$Id].DisplayName) {
                $hit = @(Find-ByFilter 'users' 'userPrincipalName' $nameMap[$Id].DisplayName)
                if ($hit.Count -eq 1) { $target = $hit[0].id }
            }
        }
        'Location' { if ($idMap.ContainsKey($Id)) { $target = $idMap[$Id] } }
        'Application' {
            $hit = @(Find-ByFilter 'servicePrincipals' 'appId' $Id)
            if ($hit.Count) { $target = $Id }
            elseif ($CreateMissingServicePrincipals -and -not $Apply) { $target = $Id; $script:spToCreate[$Id] = $true }
            elseif ($CreateMissingServicePrincipals -and $Apply) {
                try {
                    Invoke-Graph POST 'v1.0/servicePrincipals' @{ appId = $Id } | Out-Null
                    $target = $Id
                    Add-Result 'ServicePrincipal' $Id 'Created' $nameMap[$Id].DisplayName
                } catch { Add-Result 'ServicePrincipal' $Id 'FAILED' (Get-ErrorText $_) }
            }
        }
    }
    $cache[$key] = $target
    $target
}
$spToCreate = @{}

# Replaces each GUID in a list with its target-tenant ID. Non-GUID values (All, None, GuestsOrExternalUsers,
# AllTrusted, Office365, ...) and directory role template IDs are passed through unchanged.
function Convert-IdList($List, [string]$Type, [System.Collections.Generic.List[string]]$Missing) {
    if ($null -eq $List) { return $null }
    $out = @()
    foreach ($id in @($List)) {
        if ($id -notmatch $guid) { $out += $id; continue }
        $t = Resolve-Reference $Type $id
        if ($t) { $out += $t } else {
            $label = if ($nameMap[$id].DisplayName) { "$Type '$($nameMap[$id].DisplayName)'" } else { "$Type $id" }
            $Missing.Add($label)
        }
    }
    , $out
}

# ------------------------------------------------------------------ policies
$existingCA = @{}
foreach ($pol in (Get-GraphAll 'v1.0/identity/conditionalAccess/policies')) { $existingCA[$pol.displayName] = $pol.id }

foreach ($file in $policyFiles) {
    try { $pol = Read-JsonFile $file.FullName } catch { Add-Result 'Policy' $file.Name 'FAILED' 'not valid JSON'; continue }
    $name = [string]$pol.displayName
    if (-not $name -or -not $pol.conditions) { Add-Result 'Policy' $file.Name 'SKIPPED' 'not a Conditional Access policy file'; continue }
    if ($existingCA.ContainsKey($name)) { Add-Result 'Policy' $name 'Exists'; continue }

    foreach ($p in $readOnly) { $pol.PSObject.Properties.Remove($p) }
    if ($pol.grantControls -and $pol.grantControls.authenticationStrength) {
        $pol.grantControls.authenticationStrength = [pscustomobject]@{ id = $pol.grantControls.authenticationStrength.id }
    }

    $missing = New-Object System.Collections.Generic.List[string]
    $u = $pol.conditions.users
    if ($u) {
        foreach ($prop in 'includeGroups', 'excludeGroups') { if ($u.$prop) { $u.$prop = Convert-IdList $u.$prop 'Group' $missing } }
        foreach ($prop in 'includeUsers', 'excludeUsers')   { if ($u.$prop) { $u.$prop = Convert-IdList $u.$prop 'User' $missing } }
    }
    $a = $pol.conditions.applications
    if ($a) {
        foreach ($prop in 'includeApplications', 'excludeApplications') { if ($a.$prop) { $a.$prop = Convert-IdList $a.$prop 'Application' $missing } }
    }
    $l = $pol.conditions.locations
    if ($l) {
        foreach ($prop in 'includeLocations', 'excludeLocations') { if ($l.$prop) { $l.$prop = Convert-IdList $l.$prop 'Location' $missing } }
    }

    if ($missing.Count) { Add-Result 'Policy' $name 'SKIPPED' ("not found in this tenant: " + (($missing | Sort-Object -Unique) -join '; ')); continue }

    $stateNote = ''
    if (-not $KeepExportedState -and $pol.state -ne $reportOnly) {
        $stateNote = "state '$($pol.state)' -> report-only"
        $pol.state = $reportOnly
    }

    if (-not $Apply) { Add-Result 'Policy' $name 'WouldCreate' $stateNote; continue }
    try {
        Invoke-Graph POST 'v1.0/identity/conditionalAccess/policies' $pol | Out-Null
        $existingCA[$name] = $true
        Add-Result 'Policy' $name 'Created' $stateNote
    } catch { Add-Result 'Policy' $name 'FAILED' (Get-ErrorText $_) }
}

foreach ($id in $spToCreate.Keys) { Add-Result 'ServicePrincipal' $id 'WouldCreate' $nameMap[$id].DisplayName }

# ------------------------------------------------------------------ summary
Write-Host ''
$results | Group-Object Area, Status | Sort-Object Name | ForEach-Object { Write-Host ('{0,-30} {1}' -f $_.Name, $_.Count) }
if ($Apply) {
    $log = Join-Path $Path ("import-results-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
    $results | Export-Csv $log -NoTypeInformation -Encoding UTF8
    Write-Host "Results: $log"
}
