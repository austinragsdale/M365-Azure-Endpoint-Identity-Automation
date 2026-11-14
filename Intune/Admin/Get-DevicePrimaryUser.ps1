<#
.SYNOPSIS
    For each specified device, dump the fields that drive the "Enrolled user
    exists" compliance check so we can see what is actually broken.

.PARAMETER DeviceNames
    One or more device names to check. Required.

.PARAMETER OutputFolder
    Folder for the CSV. Defaults to your Downloads folder.

.EXAMPLE
    .\Get-DevicePrimaryUser.ps1 -DeviceNames "LAPTOP-001","DESKTOP-002"

.NOTES
    Author: Austin Ragsdale
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$DeviceNames,
    [string]$OutputFolder = "$env:USERPROFILE\Downloads"
)

$ErrorActionPreference = 'Stop'

$mods = 'Microsoft.Graph.Authentication'
foreach ($m in $mods) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue

Connect-MgGraph -Scopes @(
    'DeviceManagementManagedDevices.Read.All',
    'Device.Read.All',
    'Directory.Read.All',
    'User.Read.All'
) -NoWelcome | Out-Null

$ctx = Get-MgContext
Write-Host "Connected. Tenant: $($ctx.TenantId)  Account: $($ctx.Account)`n" -ForegroundColor Green

$results = New-Object System.Collections.Generic.List[object]

foreach ($name in $DeviceNames) {
    Write-Host "== $name ==" -ForegroundColor Cyan

    # 1. Intune managed device record
    $mdUri  = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=deviceName eq '$name'"
    $mdResp = Invoke-MgGraphRequest -Method GET -Uri $mdUri
    $md     = $mdResp.value | Select-Object -First 1

    if (-not $md) {
        Write-Warning "  Not found in managedDevices."
        continue
    }

    # 2. Intune primary user
    $puUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($md.id)/users"
    $pu    = (Invoke-MgGraphRequest -Method GET -Uri $puUri).value

    # 3. AAD device object (matched by azureADDeviceId)
    $aad = $null
    if ($md.azureADDeviceId) {
        $aadUri  = "https://graph.microsoft.com/beta/devices?`$filter=deviceId eq '$($md.azureADDeviceId)'"
        $aad     = (Invoke-MgGraphRequest -Method GET -Uri $aadUri).value | Select-Object -First 1
    }

    # 4. AAD registered owner and users
    $owner = $null
    $users = @()
    if ($aad) {
        try {
            $owner = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/devices/$($aad.id)/registeredOwners").value | Select-Object -First 1
        } catch {}
        try {
            $users = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/devices/$($aad.id)/registeredUsers").value
        } catch {}
    }

    $row = [pscustomobject]@{
        DeviceName                = $name
        IntuneUPN                 = $md.userPrincipalName
        IntuneUserId              = $md.userId
        IntunePrimaryUserUPN      = ($pu | Select-Object -First 1 -ExpandProperty userPrincipalName -ErrorAction SilentlyContinue)
        IntunePrimaryUserId       = ($pu | Select-Object -First 1 -ExpandProperty id -ErrorAction SilentlyContinue)
        AADDeviceObjectFound      = [bool]$aad
        AADDisplayName            = $aad.displayName
        AADRegisteredOwnerUPN     = $owner.userPrincipalName
        AADRegisteredOwnerId      = $owner.id
        AADRegisteredUsersUPNs    = ($users | ForEach-Object { $_.userPrincipalName }) -join ';'
        LastSync                  = $md.lastSyncDateTime
        ComplianceState           = $md.complianceState
        EnrolledDateTime          = $md.enrolledDateTime
        ManagementAgent           = $md.managementAgent
        JoinType                  = $md.joinType
        EnrollmentType            = $md.deviceEnrollmentType
    }

    Write-Host ("  Intune Primary UPN     : {0}" -f $row.IntunePrimaryUserUPN)
    Write-Host ("  Intune userPrincipal   : {0}" -f $row.IntuneUPN)
    Write-Host ("  AAD Registered Owner   : {0}" -f $row.AADRegisteredOwnerUPN)
    Write-Host ("  AAD Registered Users   : {0}" -f $row.AADRegisteredUsersUPNs)
    Write-Host ("  Last Sync              : {0}" -f $row.LastSync)
    Write-Host ""

    $results.Add($row)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$out   = Join-Path $OutputFolder "UserAffinity-$stamp.csv"
$results | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8

Write-Host "CSV saved: $out" -ForegroundColor Green
Disconnect-MgGraph | Out-Null
