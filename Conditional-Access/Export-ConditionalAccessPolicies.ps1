#Requires -Version 5.1
<#
.SYNOPSIS
    Backs up every Conditional Access policy and named location in a tenant to clean, import-ready JSON.

.DESCRIPTION
    Read-only. Nothing in the tenant is changed.

    Creates a backup folder with:
      Policies\<policy name>.json        one file per Conditional Access policy
      NamedLocations\<location name>.json one file per named location
      object-map.csv                     the ID, type and display name of every group, user, named location
                                         and application the policies point to

    Each JSON file is cleaned so it can be posted straight back to Graph: read-only fields (id, created and
    modified dates, templateId, @odata.context) and null values are removed, and authentication strength is
    reduced to its ID.

    Groups, users and named locations have different IDs in every tenant. object-map.csv records their names
    so Import-ConditionalAccessPolicies.ps1 can find the matching objects by name when you restore into a
    different tenant.

    Module needed : Microsoft.Graph.Authentication
    Connect line  : Connect-MgGraph -Scopes Policy.Read.All,Group.Read.All,User.Read.All,Application.Read.All

.PARAMETER OutputPath
    Folder to create. Default: CA-Backup-<date-time> in the current folder.

.EXAMPLE
    Connect-MgGraph -Scopes Policy.Read.All,Group.Read.All,User.Read.All,Application.Read.All
    .\Export-ConditionalAccessPolicies.ps1

.EXAMPLE
    .\Export-ConditionalAccessPolicies.ps1 -OutputPath D:\Backups\CA\2026-11-15

.NOTES
    Author: Austin Ragsdale
    Pair with Import-ConditionalAccessPolicies.ps1 to restore or copy policies to another tenant.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Get-Location) ("CA-Backup-{0:yyyyMMdd-HHmm}" -f (Get-Date)))
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) {
    throw 'Not connected. Run: Connect-MgGraph -Scopes Policy.Read.All,Group.Read.All,User.Read.All,Application.Read.All'
}

$guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$readOnly = 'id', 'createdDateTime', 'modifiedDateTime', 'templateId', 'deletedDateTime'

function Get-GraphAll([string]$Uri) {
    $out = @(); $next = "https://graph.microsoft.com/$Uri"
    while ($next) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        $out += @($r.value); $next = $r.'@odata.nextLink'
    }
    $out
}

# Drops null values and "@odata.context" keys at every level. Returns a cleaned copy.
function ConvertTo-CleanObject($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $n = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) {
            if ($null -eq $p.Value -or $p.Name -like '*@odata.context') { continue }
            $n[$p.Name] = ConvertTo-CleanObject $p.Value
        }
        return [pscustomobject]$n
    }
    if ($o -is [array]) { return , @($o | ForEach-Object { ConvertTo-CleanObject $_ }) }
    $o
}

function Get-SafeFileName([string]$Name) {
    $safe = ($Name -replace '[\\/:*?"<>|]', '_').Trim()
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120).Trim() }
    $safe
}

function Save-Json($Object, [string]$Folder, [string]$Name) {
    $file = Join-Path $Folder ((Get-SafeFileName $Name) + '.json')
    $i = 2
    while (Test-Path $file) { $file = Join-Path $Folder ("{0} ({1}).json" -f (Get-SafeFileName $Name), $i); $i++ }
    $json = $Object | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding $false))
}

$policyFolder   = Join-Path $OutputPath 'Policies'
$locationFolder = Join-Path $OutputPath 'NamedLocations'
New-Item -ItemType Directory -Path $policyFolder, $locationFolder -Force | Out-Null

$ctx = Get-MgContext
Write-Host "Exporting from tenant $($ctx.TenantId) as $($ctx.Account)" -ForegroundColor Cyan

# ------------------------------------------------------------------ named locations
$map = @{}
$locations = @(Get-GraphAll 'v1.0/identity/conditionalAccess/namedLocations')
foreach ($l in $locations) {
    $map[$l.id] = [pscustomobject]@{ Id = $l.id; Type = 'NamedLocation'; DisplayName = $l.displayName }
    $clean = ConvertTo-CleanObject $l
    foreach ($p in $readOnly) { $clean.PSObject.Properties.Remove($p) }
    Save-Json $clean $locationFolder $l.displayName
}
Write-Host "Named locations : $($locations.Count)"

# ------------------------------------------------------------------ policies
$policies = @(Get-GraphAll 'v1.0/identity/conditionalAccess/policies')
$refs = @{ Group = @{}; User = @{}; Application = @{} }
foreach ($pol in $policies) {
    $u = $pol.conditions.users
    foreach ($id in @($u.includeGroups) + @($u.excludeGroups)) { if ($id -match $guid) { $refs.Group[$id] = $true } }
    foreach ($id in @($u.includeUsers) + @($u.excludeUsers)) { if ($id -match $guid) { $refs.User[$id] = $true } }
    $a = $pol.conditions.applications
    foreach ($id in @($a.includeApplications) + @($a.excludeApplications)) { if ($id -match $guid) { $refs.Application[$id] = $true } }

    $clean = ConvertTo-CleanObject $pol
    foreach ($p in $readOnly) { $clean.PSObject.Properties.Remove($p) }
    if ($clean.grantControls -and $clean.grantControls.authenticationStrength) {
        $clean.grantControls.authenticationStrength = [pscustomobject]@{ id = $pol.grantControls.authenticationStrength.id }
    }
    Save-Json $clean $policyFolder $pol.displayName
}
Write-Host "Policies        : $($policies.Count)"

# ------------------------------------------------------------------ object map (names for every referenced ID)
foreach ($id in $refs.Group.Keys) {
    try {
        $g = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$id`?`$select=id,displayName" -OutputType PSObject
        $map[$id] = [pscustomobject]@{ Id = $id; Type = 'Group'; DisplayName = $g.displayName }
    } catch { Write-Warning "Group $id is referenced by a policy but no longer exists." }
}
foreach ($id in $refs.User.Keys) {
    try {
        $usr = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$id`?`$select=id,userPrincipalName" -OutputType PSObject
        $map[$id] = [pscustomobject]@{ Id = $id; Type = 'User'; DisplayName = $usr.userPrincipalName }
    } catch { Write-Warning "User $id is referenced by a policy but no longer exists." }
}
foreach ($id in $refs.Application.Keys) {
    $f = [uri]::EscapeDataString("appId eq '$id'")
    $sp = @(Get-GraphAll "v1.0/servicePrincipals?`$filter=$f&`$select=appId,displayName")
    $name = if ($sp.Count) { $sp[0].displayName } else { '' }
    $map[$id] = [pscustomobject]@{ Id = $id; Type = 'Application'; DisplayName = $name }
}

$map.Values | Sort-Object Type, DisplayName |
    Export-Csv (Join-Path $OutputPath 'object-map.csv') -NoTypeInformation -Encoding UTF8

Write-Host "Referenced objects: $($map.Count) (object-map.csv)"
Write-Host "Backup saved to: $OutputPath" -ForegroundColor Green
