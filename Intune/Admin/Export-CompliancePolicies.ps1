#Requires -Version 5.1
<#
.SYNOPSIS
    Backs up every Intune device compliance policy, with its actions for noncompliance and assignments, to JSON.

.DESCRIPTION
    Read-only. Nothing in the tenant is changed.

    Creates a backup folder with:
      Policies\<policy name>.json   one import-ready file per compliance policy (all platforms)
      assignments.csv               who each policy is assigned to, by group NAME, so the assignments can be
                                    rebuilt in another tenant where the group IDs are different

    Each policy is exported with its scheduled actions (the "actions for noncompliance" Graph requires when a
    policy is created). Read-only fields (id, dates, version, scope tags, @odata.context) and null values are
    removed so the file can be posted straight back to Graph.

    Module needed : Microsoft.Graph.Authentication
    Connect line  : Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,Group.Read.All

.PARAMETER OutputPath
    Folder to create. Default: Compliance-Backup-<date-time> in the current folder.

.EXAMPLE
    Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,Group.Read.All
    .\Export-CompliancePolicies.ps1

.NOTES
    Author: Austin Ragsdale
    Pair with Import-CompliancePolicies.ps1 to restore or copy policies to another tenant.
    Uses the Graph beta endpoint, which is the only one that returns every compliance setting.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Get-Location) ("Compliance-Backup-{0:yyyyMMdd-HHmm}" -f (Get-Date)))
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) {
    throw 'Not connected. Run: Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,Group.Read.All'
}

$readOnly = 'id', 'createdDateTime', 'lastModifiedDateTime', 'version', 'roleScopeTagIds', 'assignments',
            'scheduledActionsForRule@odata.context', 'assignments@odata.context'

function Get-GraphAll([string]$Uri) {
    $out = @(); $next = "https://graph.microsoft.com/$Uri"
    while ($next) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        $out += @($r.value); $next = $r.'@odata.nextLink'
    }
    $out
}

# Drops null values, "@odata.context" keys and nested "id" values at every level. Returns a cleaned copy.
function ConvertTo-CleanObject($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $n = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) {
            if ($null -eq $p.Value -or $p.Name -like '*@odata.context' -or $p.Name -eq 'id') { continue }
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

$policyFolder = Join-Path $OutputPath 'Policies'
New-Item -ItemType Directory -Path $policyFolder -Force | Out-Null

$ctx = Get-MgContext
Write-Host "Exporting from tenant $($ctx.TenantId) as $($ctx.Account)" -ForegroundColor Cyan

$expand = '$expand=scheduledActionsForRule($expand=scheduledActionConfigurations),assignments'
$policies = @(Get-GraphAll "beta/deviceManagement/deviceCompliancePolicies?$expand")

$groupNames = @{}
function Get-GroupName([string]$Id) {
    if (-not $groupNames.ContainsKey($Id)) {
        try {
            $g = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$Id`?`$select=displayName" -OutputType PSObject
            $groupNames[$Id] = $g.displayName
        } catch { $groupNames[$Id] = $null; Write-Warning "Group $Id is assigned to a policy but no longer exists." }
    }
    $groupNames[$Id]
}

$assignRows = New-Object System.Collections.Generic.List[object]
foreach ($pol in $policies) {
    foreach ($as in @($pol.assignments)) {
        if (-not $as) { continue }
        $type = ([string]$as.target.'@odata.type').Replace('#microsoft.graph.', '')
        $group = ''
        if ($as.target.groupId) { $group = Get-GroupName $as.target.groupId; if (-not $group) { continue } }
        $assignRows.Add([pscustomobject]@{ Policy = $pol.displayName; TargetType = $type; GroupName = $group })
    }

    $clean = ConvertTo-CleanObject $pol
    foreach ($p in $readOnly) { $clean.PSObject.Properties.Remove($p) }

    $file = Join-Path $policyFolder ((Get-SafeFileName $pol.displayName) + '.json')
    $i = 2
    while (Test-Path $file) { $file = Join-Path $policyFolder ("{0} ({1}).json" -f (Get-SafeFileName $pol.displayName), $i); $i++ }
    [IO.File]::WriteAllText($file, ($clean | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding $false))

    $platform = ([string]$pol.'@odata.type').Replace('#microsoft.graph.', '').Replace('CompliancePolicy', '')
    Write-Host ('  {0,-22} {1}' -f $platform, $pol.displayName)
}

$assignRows | Export-Csv (Join-Path $OutputPath 'assignments.csv') -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "Policies   : $($policies.Count)"
Write-Host "Assignments: $($assignRows.Count) (assignments.csv)"
Write-Host "Backup saved to: $OutputPath" -ForegroundColor Green
