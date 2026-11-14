<#
.SYNOPSIS
    Audits all Entra ID users to identify who will be affected when the tenant
    password expiration policy is changed from "never expire" to 90 days.

.DESCRIPTION
    Connects to Microsoft Graph (delegated / interactive auth as a Global Admin),
    pulls every user, reads lastPasswordChangeDateTime and passwordPolicies, and
    classifies each account by how long ago the password was last changed:

        EXPIRED  - last change 90+ days ago      (expires the instant the policy flips)
        AT-RISK  - last change 76-89 days ago     (expires within 14 days of the flip)
        OK       - everyone else

    It also flags whether each account is cloud-only or synced from on-prem AD
    (onPremisesSyncEnabled). This matters: while Entra Connect / password hash sync
    is still running, the Entra-side passwordValidityPeriodInDays only governs
    CLOUD-ONLY accounts. Synced users are governed by the on-prem AD password policy
    reflected in their passwordPolicies attribute. Review the SyncType and
    PasswordPolicies columns before flipping anything.

    Results are written to a timestamped CSV and a summary is printed to console.

.PARAMETER OutputPath
    Folder for the CSV export. Defaults to the current user's Downloads folder.

.PARAMETER ExpireDays
    Number of days that defines an expired password. Defaults to 90 (the target policy).

.PARAMETER AtRiskWindow
    Number of days before expiry to flag AT-RISK. Defaults to 14, so AT-RISK is
    the 76-89 day band (ExpireDays - AtRiskWindow .. ExpireDays - 1).

.EXAMPLE
    .\Get-PasswordExpiryReport.ps1

    Runs with defaults (90-day expiry, 14-day at-risk window), exports to Downloads.

.EXAMPLE
    .\Get-PasswordExpiryReport.ps1 -OutputPath "C:\Temp" -ExpireDays 90 -AtRiskWindow 14

.NOTES
    Required role:    Global Administrator (or a role with User.Read.All)
    Required module:  Microsoft.Graph (Authentication + Users sub-modules)
    Graph scope:      User.Read.All  (read-only; this script makes NO changes)
    Author:          Austin Ragsdale
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = (Join-Path $env:USERPROFILE 'Downloads'),

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$ExpireDays = 90,

    [Parameter()]
    [ValidateRange(1, 89)]
    [int]$AtRiskWindow = 14
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# AT-RISK lower bound: ExpireDays - AtRiskWindow. With defaults => 76.
$AtRiskFloor = $ExpireDays - $AtRiskWindow

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath   = Join-Path $OutputPath "PasswordExpiry-Audit_$timestamp.csv"

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host ''
Write-Host '=== Entra ID Password Expiry Audit ===' -ForegroundColor Cyan
Write-Host ("Target expiry  : {0} days" -f $ExpireDays)
Write-Host ("At-risk band   : {0}-{1} days" -f $AtRiskFloor, ($ExpireDays - 1))
Write-Host ("Export to      : {0}" -f $csvPath)
Write-Host ''

try {
    # -----------------------------------------------------------------------
    # Connect (delegated / interactive). Read-only scope.
    # -----------------------------------------------------------------------
    Write-Host 'Connecting to Microsoft Graph (sign in as Global Admin)...' -ForegroundColor Yellow
    Connect-MgGraph -Scopes 'User.Read.All' -NoWelcome

    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Failed to establish a Microsoft Graph context.' }
    Write-Host ("Connected as : {0}" -f $ctx.Account) -ForegroundColor Green
    Write-Host ("Tenant       : {0}" -f $ctx.TenantId) -ForegroundColor Green
    Write-Host ''

    # -----------------------------------------------------------------------
    # Pull all users. -All handles pagination automatically (nextLink loop),
    # so even if the directory grows past one page this stays correct.
    # We select only the properties we need to keep the payload small and fast.
    # lastPasswordChangeDateTime requires being named explicitly in -Property.
    # -----------------------------------------------------------------------
    Write-Host 'Retrieving users from Entra ID...' -ForegroundColor Yellow

    $selectProps = @(
        'id'
        'displayName'
        'userPrincipalName'
        'accountEnabled'
        'lastPasswordChangeDateTime'
        'passwordPolicies'
        'onPremisesSyncEnabled'
        'userType'
        'assignedLicenses'
    )

    # Server-side: enabled accounts and Members only (excludes guests and disabled accounts)
    $graphFilter = "accountEnabled eq true and userType eq 'Member'"

    $users = Get-MgUser -All -Property $selectProps -PageSize 999 -ConsistencyLevel eventual -Filter $graphFilter

    Write-Host ("Retrieved {0} enabled Member account(s)." -f $users.Count) -ForegroundColor Green

    # Client-side: exclude unlicensed accounts (shared mailboxes are typically unlicensed)
    $users = $users | Where-Object { $_.AssignedLicenses.Count -gt 0 }

    Write-Host ("After removing unlicensed accounts (shared mailboxes): {0} user(s) in scope." -f $users.Count) -ForegroundColor Green
    Write-Host ''

    # -----------------------------------------------------------------------
    # Classify each user
    # -----------------------------------------------------------------------
    $now     = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($u in $users) {

        $lastChange = $u.LastPasswordChangeDateTime
        $syncType   = if ($u.OnPremisesSyncEnabled -eq $true) { 'Synced (on-prem AD)' } else { 'Cloud-only' }

        # passwordPolicies is a space/comma-delimited string e.g. "DisablePasswordExpiration"
        $pwPolicies = if ([string]::IsNullOrWhiteSpace($u.PasswordPolicies)) { '(none)' } else { $u.PasswordPolicies }

        if ($null -eq $lastChange) {
            # No timestamp: typically guests, never-signed-in, or accounts created
            # before the attribute was populated. Flag for manual review.
            $daysSince = $null
            $status    = 'UNKNOWN'
            $lastStr   = '(no data)'
        }
        else {
            $daysSince = [math]::Floor( ($now - $lastChange).TotalDays )
            $lastStr   = $lastChange.ToString('yyyy-MM-dd')

            if ($daysSince -ge $ExpireDays) {
                $status = 'EXPIRED'
            }
            elseif ($daysSince -ge $AtRiskFloor) {
                $status = 'AT-RISK'
            }
            else {
                $status = 'OK'
            }
        }

        $results.Add([PSCustomObject]@{
            DisplayName        = $u.DisplayName
            UPN                = $u.UserPrincipalName
            LastPasswordChange = $lastStr
            DaysSinceChange    = $daysSince
            Status             = $status
            SyncType           = $syncType
            PasswordPolicies   = $pwPolicies
            AccountEnabled     = $u.AccountEnabled
            UserType           = $u.UserType
        })
    }

    # -----------------------------------------------------------------------
    # Export. Sort worst-first so the CSV opens on the urgent accounts.
    # -----------------------------------------------------------------------
    $statusRank = @{ 'EXPIRED' = 0; 'AT-RISK' = 1; 'OK' = 2; 'UNKNOWN' = 3 }

    $sorted = $results | Sort-Object `
        @{ Expression = { $statusRank[$_.Status] } }, `
        @{ Expression = { $_.DaysSinceChange }; Descending = $true }

    $sorted | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    # -----------------------------------------------------------------------
    # Console summary
    # -----------------------------------------------------------------------
    $total       = $results.Count
    $expired     = ($results | Where-Object Status -eq 'EXPIRED').Count
    $atRisk      = ($results | Where-Object Status -eq 'AT-RISK').Count
    $ok          = ($results | Where-Object Status -eq 'OK').Count
    $unknown     = ($results | Where-Object Status -eq 'UNKNOWN').Count

    $syncedTotal = ($results | Where-Object SyncType -eq 'Synced (on-prem AD)').Count
    $cloudTotal  = ($results | Where-Object SyncType -eq 'Cloud-only').Count

    # Cross-tab: how many of the EXPIRED / AT-RISK are synced vs cloud-only,
    # because the flip behaves differently for each.
    $expiredSynced = ($results | Where-Object { $_.Status -eq 'EXPIRED' -and $_.SyncType -like 'Synced*' }).Count
    $atRiskSynced  = ($results | Where-Object { $_.Status -eq 'AT-RISK' -and $_.SyncType -like 'Synced*' }).Count

    Write-Host ''
    Write-Host '================ SUMMARY ================' -ForegroundColor Cyan
    Write-Host ("Total users          : {0}" -f $total)
    Write-Host ("  EXPIRED (>= {0}d)   : {1}" -f $ExpireDays, $expired)  -ForegroundColor Red
    Write-Host ("  AT-RISK ({0}-{1}d)  : {2}" -f $AtRiskFloor, ($ExpireDays - 1), $atRisk) -ForegroundColor Yellow
    Write-Host ("  OK                  : {0}" -f $ok)      -ForegroundColor Green
    if ($unknown -gt 0) {
        Write-Host ("  UNKNOWN (no data)   : {0}  <- review manually" -f $unknown) -ForegroundColor DarkGray
    }
    Write-Host '-----------------------------------------'
    Write-Host ("Cloud-only           : {0}" -f $cloudTotal)
    Write-Host ("Synced from on-prem  : {0}" -f $syncedTotal)
    Write-Host '-----------------------------------------'
    Write-Host 'Of the affected accounts that are SYNCED (governed by on-prem AD policy,'
    Write-Host 'NOT the Entra passwordValidityPeriodInDays setting):'
    Write-Host ("  EXPIRED & synced   : {0}" -f $expiredSynced) -ForegroundColor Magenta
    Write-Host ("  AT-RISK & synced   : {0}" -f $atRiskSynced)  -ForegroundColor Magenta
    Write-Host '========================================='
    Write-Host ''
    Write-Host ("CSV written to: {0}" -f $csvPath) -ForegroundColor Green
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    throw
}
finally {
    # Always disconnect to leave no lingering session.
    if (Get-MgContext -ErrorAction SilentlyContinue) {
        Disconnect-MgGraph | Out-Null
        Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor DarkGray
    }
}
