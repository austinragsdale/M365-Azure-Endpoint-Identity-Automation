<#
.SYNOPSIS
    v2: Pulls EVERY Windows managed device with no server side filter,
    then evaluates compliance state and per setting failures client side.
    Catches anything v1 missed.
#>

[CmdletBinding()]
param(
    [string]$OutputFolder = "$env:USERPROFILE\Downloads"
)

$ErrorActionPreference = 'Stop'

# Modules
$mods = 'Microsoft.Graph.Authentication','Microsoft.Graph.DeviceManagement'
foreach ($m in $mods) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue

# Connect
$scopes = @(
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementConfiguration.Read.All',
    'Device.Read.All'
)
Write-Host "`nConnecting to Microsoft Graph ..." -ForegroundColor Cyan
Connect-MgGraph -Scopes $scopes -NoWelcome | Out-Null
$ctx = Get-MgContext
Write-Host ("Connected. Tenant: {0}  Account: {1}" -f $ctx.TenantId, $ctx.Account) -ForegroundColor Green

# Pull EVERY Windows device (no compliance filter)
$select = 'id,deviceName,userPrincipalName,osVersion,lastSyncDateTime,complianceState,enrolledDateTime,managedDeviceOwnerType,model,manufacturer,serialNumber,joinType'
$uri    = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=$select"

$all = New-Object System.Collections.Generic.List[object]
do {
    $r = Invoke-MgGraphRequest -Method GET -Uri $uri
    foreach ($v in $r.value) { $all.Add($v) }
    $uri = $r.'@odata.nextLink'
} while ($uri)

Write-Host ("`nTotal Windows devices in tenant: {0}" -f $all.Count) -ForegroundColor Yellow

Write-Host "`n=== COMPLIANCE STATE DISTRIBUTION ===" -ForegroundColor Cyan
$all | Group-Object complianceState | Sort-Object Count -Descending |
    Format-Table Count, Name -AutoSize

# Anything that is NOT 'compliant' is in scope (compliant is the only true pass state)
$target = $all | Where-Object { $_.complianceState -ne 'compliant' }
Write-Host ("Devices needing investigation: {0}" -f $target.Count) -ForegroundColor Yellow
Write-Host ""
$target | Format-Table deviceName, complianceState, userPrincipalName, model, osVersion, lastSyncDateTime -AutoSize

# For each, get all policy states (even compliant ones) so we see the full picture
$report = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($d in $target) {
    $i++
    Write-Progress -Activity 'Policy states' -Status "$($d.deviceName) ($i of $($target.Count))" -PercentComplete (($i / [Math]::Max($target.Count,1)) * 100)

    $polUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($d.id)/deviceCompliancePolicyStates"
    try {
        $policies = (Invoke-MgGraphRequest -Method GET -Uri $polUri).value
    } catch {
        Write-Warning "Policy state read failed for $($d.deviceName): $($_.Exception.Message)"
        continue
    }

    foreach ($p in $policies) {
        $setUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($d.id)/deviceCompliancePolicyStates/$($p.id)/settingStates"
        try {
            $settings = (Invoke-MgGraphRequest -Method GET -Uri $setUri).value
        } catch {
            $settings = @()
        }

        # Capture EVERY setting state so nothing is hidden
        foreach ($s in $settings) {
            $report.Add([pscustomobject]@{
                DeviceName       = $d.deviceName
                User             = $d.userPrincipalName
                Model            = $d.model
                Manufacturer     = $d.manufacturer
                Serial           = $d.serialNumber
                OSVersion        = $d.osVersion
                JoinType         = $d.joinType
                LastSync         = $d.lastSyncDateTime
                DeviceComplState = $d.complianceState
                PolicyName       = $p.displayName
                PolicyState      = $p.state
                SettingName      = $s.setting
                SettingState     = $s.state
                CurrentValue     = $s.currentValue
                ErrorDescription = $s.errorDescription
                DeviceId         = $d.id
            })
        }

        # If a policy reports a state but no settings come back, log the policy row itself
        if (-not $settings) {
            $report.Add([pscustomobject]@{
                DeviceName       = $d.deviceName
                User             = $d.userPrincipalName
                Model            = $d.model
                Manufacturer     = $d.manufacturer
                Serial           = $d.serialNumber
                OSVersion        = $d.osVersion
                JoinType         = $d.joinType
                LastSync         = $d.lastSyncDateTime
                DeviceComplState = $d.complianceState
                PolicyName       = $p.displayName
                PolicyState      = $p.state
                SettingName      = '(no settings returned)'
                SettingState     = $p.state
                CurrentValue     = ''
                ErrorDescription = ''
                DeviceId         = $d.id
            })
        }
    }
}
Write-Progress -Activity 'Policy states' -Completed

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$out   = Join-Path $OutputFolder "NonCompliant-Windows-FULL-$stamp.csv"
$report | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8

Write-Host "`nCSV saved: $out" -ForegroundColor Green
Write-Host "Total rows captured: $($report.Count)" -ForegroundColor Green

Write-Host "`n=== NON COMPLIANT / ERROR / GRACE SETTING ROWS BY SETTING ===" -ForegroundColor Cyan
$report | Where-Object { $_.SettingState -in @('nonCompliant','error','conflict','inGracePeriod','notApplicable') } |
    Group-Object SettingName | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize

Write-Host "`n=== SECURE BOOT ROWS (every device, every state) ===" -ForegroundColor Cyan
$report | Where-Object { $_.SettingName -like '*SecureBoot*' } |
    Sort-Object DeviceName |
    Format-Table DeviceName, User, Model, OSVersion, SettingState, CurrentValue, ErrorDescription -AutoSize -Wrap

Disconnect-MgGraph | Out-Null
Write-Host "`nDone." -ForegroundColor Green
