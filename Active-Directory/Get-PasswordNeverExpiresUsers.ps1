<#
.SYNOPSIS
    Generates a report of all Active Directory users with "Password Never Expires" enabled.

.DESCRIPTION
    Queries Active Directory for all enabled/disabled user accounts where the
    PasswordNeverExpires flag is set. Exports results to a timestamped CSV file
    and prints a summary to the console.

.PARAMETER SearchBase
    The OU Distinguished Name to scope the search. Defaults to the entire domain.
    Example: "OU=Users,DC=contoso,DC=com"

.PARAMETER OutputPath
    Directory where the CSV report will be saved. Defaults to the script's directory.

.PARAMETER IncludeDisabledAccounts
    Switch to include disabled user accounts in the report. Excluded by default.

.PARAMETER Server
    Target a specific Domain Controller. Defaults to the PDC Emulator.

.EXAMPLE
    .\Get-PasswordNeverExpiresUsers.ps1

.EXAMPLE
    .\Get-PasswordNeverExpiresUsers.ps1 -SearchBase "OU=Corp Users,DC=contoso,DC=com" -IncludeDisabledAccounts

.EXAMPLE
    .\Get-PasswordNeverExpiresUsers.ps1 -OutputPath "C:\Reports" -Server "DC01.contoso.com"

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT or installed on a DC)
    Required Role: Domain Users (read), or Domain Admins for full attribute access
#>

#Requires -Modules ActiveDirectory
#Requires -Version 5.1

[CmdletBinding()]
param (
    [Parameter()]
    [string]$SearchBase,

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$OutputPath = $PSScriptRoot,

    [Parameter()]
    [switch]$IncludeDisabledAccounts,

    [Parameter()]
    [string]$Server
)

# ─── Configuration ────────────────────────────────────────────────────────────
$Timestamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
$ReportFileName = "PasswordNeverExpires_$Timestamp.csv"
$ReportPath     = Join-Path -Path $OutputPath -ChildPath $ReportFileName
$TranscriptPath = Join-Path -Path $OutputPath -ChildPath "PasswordNeverExpires_$Timestamp.log"

# ─── Start Transcript ─────────────────────────────────────────────────────────
Start-Transcript -Path $TranscriptPath -Append | Out-Null
Write-Host "`n=== Password Never Expires Report ===" -ForegroundColor Cyan
Write-Host "Started : $(Get-Date)" -ForegroundColor Gray

try {

    # ── Build Get-ADUser Splat ─────────────────────────────────────────────────
    $ADParams = @{
        Filter     = { PasswordNeverExpires -eq $true }
        Properties = @(
            'DisplayName',
            'SamAccountName',
            'UserPrincipalName',
            'EmailAddress',
            'Enabled',
            'PasswordNeverExpires',
            'PasswordLastSet',
            'LastLogonDate',
            'DistinguishedName',
            'Department',
            'Title',
            'Manager',
            'WhenCreated',
            'LockedOut'
        )
    }

    if ($SearchBase)         { $ADParams['SearchBase'] = $SearchBase }
    if ($Server)             { $ADParams['Server']     = $Server }

    # ── Retrieve Users ─────────────────────────────────────────────────────────
    Write-Host "`n[*] Querying Active Directory..." -ForegroundColor Yellow
    $AllUsers = Get-ADUser @ADParams -ErrorAction Stop

    # ── Filter disabled accounts unless requested ──────────────────────────────
    if (-not $IncludeDisabledAccounts) {
        $Users = $AllUsers | Where-Object { $_.Enabled -eq $true }
        Write-Host "[*] Excluded $($AllUsers.Count - $Users.Count) disabled account(s). Use -IncludeDisabledAccounts to include them." -ForegroundColor Gray
    } else {
        $Users = $AllUsers
    }

    if (-not $Users) {
        Write-Host "`n[!] No users found matching the criteria." -ForegroundColor Green
        return
    }

    Write-Host "[*] Found $($Users.Count) user(s) with Password Never Expires set." -ForegroundColor Yellow

    # ── Build Report Objects ───────────────────────────────────────────────────
    Write-Host "[*] Building report..." -ForegroundColor Yellow
    $Report = foreach ($User in $Users) {

        # Resolve Manager display name (best-effort)
        $ManagerName = if ($User.Manager) {
            try { (Get-ADUser -Identity $User.Manager -ErrorAction Stop).Name } catch { $User.Manager }
        } else { 'N/A' }

        # Days since last password set
        $DaysSincePwdSet = if ($User.PasswordLastSet) {
            [math]::Round(((Get-Date) - $User.PasswordLastSet).TotalDays)
        } else { 'Never Set' }

        # Days since last logon
        $DaysSinceLogon = if ($User.LastLogonDate) {
            [math]::Round(((Get-Date) - $User.LastLogonDate).TotalDays)
        } else { 'Never Logged In' }

        [PSCustomObject]@{
            DisplayName         = $User.DisplayName
            SamAccountName      = $User.SamAccountName
            UserPrincipalName   = $User.UserPrincipalName
            EmailAddress        = $User.EmailAddress
            AccountEnabled      = $User.Enabled
            LockedOut           = $User.LockedOut
            Department          = $User.Department
            Title               = $User.Title
            Manager             = $ManagerName
            PasswordLastSet     = $User.PasswordLastSet
            DaysSincePasswordSet = $DaysSincePwdSet
            LastLogonDate       = $User.LastLogonDate
            DaysSinceLastLogon  = $DaysSinceLogon
            AccountCreated      = $User.WhenCreated
            DistinguishedName   = $User.DistinguishedName
        }
    }

    # ── Export to CSV ──────────────────────────────────────────────────────────
    $Report | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Write-Host "`n[+] Report exported to: $ReportPath" -ForegroundColor Green

    # ── Console Summary ────────────────────────────────────────────────────────
    Write-Host "`n--- Summary ---" -ForegroundColor Cyan
    Write-Host "Total accounts found : $($Report.Count)"
    Write-Host "Enabled accounts     : $(($Report | Where-Object { $_.AccountEnabled }).Count)"
    Write-Host "Disabled accounts    : $(($Report | Where-Object { -not $_.AccountEnabled }).Count)"
    Write-Host "Locked out           : $(($Report | Where-Object { $_.LockedOut }).Count)"
    Write-Host "Password never set   : $(($Report | Where-Object { $_.PasswordLastSet -eq $null }).Count)"

    # Top 5 oldest password ages
    $OldPasswords = $Report |
        Where-Object { $_.DaysSincePasswordSet -is [int] } |
        Sort-Object DaysSincePasswordSet -Descending |
        Select-Object -First 5

    if ($OldPasswords) {
        Write-Host "`n--- Top 5 Oldest Passwords ---" -ForegroundColor Cyan
        $OldPasswords | Format-Table DisplayName, SamAccountName, DaysSincePasswordSet, LastLogonDate -AutoSize
    }

    Write-Host "Report complete. Log saved to: $TranscriptPath`n" -ForegroundColor Gray

} catch [Microsoft.ActiveDirectory.Management.ADException] {
    Write-Error "AD query failed: $($_.Exception.Message). Verify the SearchBase DN and your permissions."
} catch {
    Write-Error "Unexpected error: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
