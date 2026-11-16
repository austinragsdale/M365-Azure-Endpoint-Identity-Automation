#Requires -Version 5.1
<#
.SYNOPSIS
    Bulk-imports Intune device compliance policies from JSON into a tenant, optionally rebuilding assignments.

.DESCRIPTION
    Restores a backup made by Export-CompliancePolicies.ps1, or imports any folder of compliance policy JSON
    files (Windows, macOS, iOS/iPadOS, Android, Linux), into the tenant you are connected to.

    WITHOUT -Apply (default): dry run. Reads the tenant only and shows what would happen to every file.
    WITH -Apply: creates the policies. You are asked to type IMPORT first (skip with -Force).

    Safety rules:
      - A policy whose display name already exists is SKIPPED, never overwritten. Safe to re-run.
      - Policies are created UNASSIGNED unless you add -Assign. With -Assign, assignments.csv is read and
        each group is found by NAME in this tenant. A group that does not exist is reported, not created.
      - Graph will not create a compliance policy without an action for noncompliance. A file with none gets
        the Intune default: mark the device noncompliant immediately.
      - A notification message template that does not exist in this tenant is removed from the action (the
        action itself is kept) and noted in the results.
      - A results CSV is written to the import folder.

    Folder layout read (the export layout). A flat folder of policy JSON files also works.
      <Path>\Policies\*.json
      <Path>\assignments.csv   (optional, used with -Assign)

    Module needed : Microsoft.Graph.Authentication
    Role needed   : Intune Administrator
    Connect line  : Connect-MgGraph -Scopes DeviceManagementConfiguration.ReadWrite.All,Group.Read.All

.PARAMETER Path
    Backup folder made by Export-CompliancePolicies.ps1, or a folder of compliance policy JSON files.

.PARAMETER Apply
    Create policies. Without it the script is a read-only dry run.

.PARAMETER Assign
    Rebuild assignments from assignments.csv, matching groups by display name.

.PARAMETER Force
    Skip the typed IMPORT confirmation (for automation).

.EXAMPLE
    .\Import-CompliancePolicies.ps1 -Path .\Compliance-Backup-20261115-1600
    Dry run.

.EXAMPLE
    .\Import-CompliancePolicies.ps1 -Path .\Compliance-Backup-20261115-1600 -Apply -Assign
    Creates every policy and assigns each one to the same groups (by name) it had in the source tenant.

.NOTES
    Author: Austin Ragsdale
    Uses the Graph beta endpoint, which is the only one that accepts every compliance setting.
    Not handled: custom compliance scripts (Windows) are tenant-specific; a policy that points to one fails
    with the Graph error written to the results CSV.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Apply,
    [switch]$Assign,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) {
    throw 'Not connected. Run: Connect-MgGraph -Scopes DeviceManagementConfiguration.ReadWrite.All,Group.Read.All'
}
if (-not (Test-Path $Path -PathType Container)) { throw "Folder not found: $Path" }

$policyUri = 'beta/deviceManagement/deviceCompliancePolicies'
$readOnly  = 'id', 'createdDateTime', 'lastModifiedDateTime', 'version', 'roleScopeTagIds', 'assignments'
$emptyGuid = '00000000-0000-0000-0000-000000000000'
$results   = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $color = switch -Wildcard ($Status) { 'Created*' { 'Green' } 'WouldCreate*' { 'Cyan' } 'Exists' { 'DarkGray' } default { 'Yellow' } }
    Write-Host ('{0,-17} {1} {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
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

# ------------------------------------------------------------------ inputs
$policyFolder = if (Test-Path (Join-Path $Path 'Policies')) { Join-Path $Path 'Policies' } else { $Path }
$policyFiles  = @(Get-ChildItem $policyFolder -Filter *.json -File | Sort-Object Name)
if (-not $policyFiles) { throw "No policy JSON files found in $policyFolder" }

$assignments = @{}
if ($Assign) {
    $assignFile = Join-Path $Path 'assignments.csv'
    if (-not (Test-Path $assignFile)) { throw "-Assign needs $assignFile (made by Export-CompliancePolicies.ps1)." }
    foreach ($row in (Import-Csv $assignFile)) {
        if (-not $assignments.ContainsKey($row.Policy)) { $assignments[$row.Policy] = @() }
        $assignments[$row.Policy] += $row
    }
}

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

# ------------------------------------------------------------------ lookups (cached)
$existing = @{}
foreach ($p in (Get-GraphAll "$policyUri`?`$select=id,displayName")) { $existing[$p.displayName] = $p.id }

$templates = @{}
foreach ($t in (Get-GraphAll 'beta/deviceManagement/notificationMessageTemplates?$select=id')) { $templates[$t.id] = $true }

$groupIds = @{}
function Get-GroupId([string]$Name) {
    if (-not $groupIds.ContainsKey($Name)) {
        $f = [uri]::EscapeDataString("displayName eq '$($Name -replace "'", "''")'")
        $hit = @(Get-GraphAll "v1.0/groups?`$filter=$f&`$select=id")
        $groupIds[$Name] = if ($hit.Count -eq 1) { $hit[0].id } else { $null }
    }
    $groupIds[$Name]
}

# Builds the Graph assignment targets for one policy. Returns targets plus a list of problems.
function Get-AssignmentTarget([string]$PolicyName) {
    $targets = @(); $problems = @()
    foreach ($row in @($assignments[$PolicyName])) {
        if (-not $row) { continue }
        switch ($row.TargetType) {
            'allLicensedUsersAssignmentTarget' { $targets += @{ target = @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } } }
            'allDevicesAssignmentTarget'       { $targets += @{ target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } } }
            default {
                $id = Get-GroupId $row.GroupName
                if ($id) { $targets += @{ target = @{ '@odata.type' = "#microsoft.graph.$($row.TargetType)"; groupId = $id } } }
                else { $problems += "group '$($row.GroupName)' not found" }
            }
        }
    }
    [pscustomobject]@{ Targets = $targets; Problems = $problems }
}

# ------------------------------------------------------------------ policies
foreach ($file in $policyFiles) {
    try { $pol = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { Add-Result $file.Name 'FAILED' 'not valid JSON'; continue }

    $name = [string]$pol.displayName
    if (-not $name -or ([string]$pol.'@odata.type') -notlike '*CompliancePolicy') {
        Add-Result $file.Name 'SKIPPED' 'not a device compliance policy file'; continue
    }
    if ($existing.ContainsKey($name)) { Add-Result $name 'Exists'; continue }

    foreach ($p in $readOnly) { $pol.PSObject.Properties.Remove($p) }
    $notes = @()

    if (-not $pol.scheduledActionsForRule) {
        $pol | Add-Member -NotePropertyName scheduledActionsForRule -Force -NotePropertyValue @(
            [pscustomobject]@{ ruleName = 'PasswordRequired'; scheduledActionConfigurations = @(
                [pscustomobject]@{ actionType = 'block'; gracePeriodHours = 0; notificationTemplateId = ''; notificationMessageCCList = @() }) })
        $notes += 'added default action (noncompliant immediately)'
    }
    foreach ($rule in @($pol.scheduledActionsForRule)) {
        foreach ($cfg in @($rule.scheduledActionConfigurations)) {
            $tid = [string]$cfg.notificationTemplateId
            if ($tid -and $tid -ne $emptyGuid -and -not $templates.ContainsKey($tid)) {
                $cfg.notificationTemplateId = ''
                $notes += 'notification template not in this tenant, removed'
            }
        }
    }

    $plan = $null
    if ($Assign) {
        $plan = Get-AssignmentTarget $name
        if ($plan.Targets.Count) { $notes += "assign to $($plan.Targets.Count) target(s)" }
        $notes += $plan.Problems
    }
    $detail = ($notes | Select-Object -Unique) -join '; '

    if (-not $Apply) { Add-Result $name 'WouldCreate' $detail; continue }
    try {
        $new = Invoke-Graph POST $policyUri $pol
        $existing[$name] = $new.id
        $status = 'Created'
        if ($plan -and $plan.Targets.Count) {
            try {
                Invoke-Graph POST "$policyUri/$($new.id)/assign" @{ assignments = @($plan.Targets) } | Out-Null
                $status = 'Created+Assigned'
            } catch { $detail = "created, assignment FAILED: $(Get-ErrorText $_)" }
        }
        Add-Result $name $status $detail
    } catch { Add-Result $name 'FAILED' (Get-ErrorText $_) }
}

# ------------------------------------------------------------------ summary
Write-Host ''
$results | Group-Object Status | ForEach-Object { Write-Host ('{0,-17} {1}' -f $_.Name, $_.Count) }
if ($Apply) {
    $log = Join-Path $Path ("import-results-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
    $results | Export-Csv $log -NoTypeInformation -Encoding UTF8
    Write-Host "Results: $log"
}
