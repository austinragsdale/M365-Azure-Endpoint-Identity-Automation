#Requires -Version 7.2
<#
.SYNOPSIS
    Syncs Entra ID staff into a "Company Directory" contact folder in each staff mailbox.

.DESCRIPTION
    Azure Automation runbook (PowerShell 7.2 runtime, no extra modules).

    Auth: system-assigned managed identity, token from the Automation identity endpoint.
    Graph permissions on the MI:
      - User.Read.All (Entra app role, tenant-wide read)
      - Contacts.ReadWrite via Exchange RBAC for Applications ONLY
        (role "Application Contacts.ReadWrite", scope "CompanyDirectory-Mailboxes").
        Do NOT grant Contacts.ReadWrite in Entra, it would remove the mailbox scoping.

    Who is in the directory and whose mailbox gets the folder:
      Exactly the mailboxes the Exchange scope allows (UserMailbox, CustomAttribute15
      not 'ExcludeDirectory'). The runbook probes each enabled member account:
      200 = in scope, 403 = out of scope, 404 = no mailbox. Any other error aborts.

    What it touches:
      Only the "Company Directory" folder, and only contacts it created (marked with a
      hidden extended property holding the Entra object ID). Contacts a user adds to the
      folder by hand are left alone.

    Safety:
      - DryRun defaults to $true (logs planned changes, writes nothing).
      - Aborts if fewer than MinDirectorySize staff are in scope (protects against
        permission or propagation problems wiping the directory).
      - Skips removals in a mailbox if more than MaxRemovalsPerMailbox would be removed.
      - Stops itself after MaxRuntimeMinutes.

.PARAMETER DryRun
    $true (default) = report only. $false = make changes.

.PARAMETER PilotMailboxes
    Optional comma-separated UPNs. When set, only these mailboxes are written to.
    The directory content is still the full in-scope staff list.

.PARAMETER MinDirectorySize
    Abort if fewer in-scope staff than this are found. Default 15.

.PARAMETER MaxRemovalsPerMailbox
    Skip removals in a mailbox when more than this many would be removed. Default 5.

.PARAMETER MaxRuntimeMinutes
    Stop cleanly after this many minutes. Default 14.

.NOTES
    Author: Austin Ragsdale. Suggested schedule: weekly.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [bool]$DryRun = $true,
    [string]$PilotMailboxes = '',
    [int]$MinDirectorySize = 15,
    [int]$MaxRemovalsPerMailbox = 5,
    [int]$MaxRuntimeMinutes = 14
)

$ErrorActionPreference = 'Stop'

$FolderName  = 'Company Directory'
$GraphRoot   = 'https://graph.microsoft.com/v1.0'
# Hidden named property that marks contacts this runbook owns. Do not change after go-live.
$MarkerPropId = 'String {6f3c2a51-8d4e-4b7a-9c15-2e7d0b9a4f68} Name EntraObjectId'

$Clock = [System.Diagnostics.Stopwatch]::StartNew()
$Stats = [ordered]@{ Created = 0; Updated = 0; Removed = 0; Unchanged = 0; Skipped = 0; Errors = 0 }
$Mode  = if ($DryRun -or $WhatIfPreference) { 'DRY RUN' } else { 'LIVE' }

function Write-Log { param([string]$Message) Write-Output ("{0:HH:mm:ss} {1}" -f (Get-Date), $Message) }

function Test-TimeLeft {
    if ($Clock.Elapsed.TotalMinutes -ge $MaxRuntimeMinutes) {
        Write-Log "Runtime limit of $MaxRuntimeMinutes min reached, stopping. Next run continues."
        return $false
    }
    return $true
}

#region Auth
function Get-GraphToken {
    if (-not $env:IDENTITY_ENDPOINT -or -not $env:IDENTITY_HEADER) {
        throw 'Managed identity endpoint not found. This runbook must run in Azure Automation with the system-assigned identity enabled.'
    }
    $uri = "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com/&api-version=2019-08-01"
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }
    }
    catch {
        throw "Could not get a Graph token from the managed identity: $($_.Exception.Message)"
    }
    # Identity endpoint returns expires_on (Unix seconds). Fall back to 1 hour if absent.
    $script:TokenExpires = if ($resp.expires_on) {
        [DateTimeOffset]::FromUnixTimeSeconds([long]$resp.expires_on).LocalDateTime.AddMinutes(-5)
    } else { (Get-Date).AddMinutes(55) }
    return $resp.access_token
}

$script:Token = Get-GraphToken
#endregion

#region Graph helper
# Returns @{ Status = <int>; Body = <object> }. Retries 429/502/503/504. Throws on other non-2xx
# unless the status is listed in -AllowStatus.
function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body,
        [int[]]$AllowStatus = @()
    )
    if ((Get-Date) -ge $script:TokenExpires) { $script:Token = Get-GraphToken }
    if ($Uri -notmatch '^https://') { $Uri = "$GraphRoot$Uri" }

    $params = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = @{ Authorization = "Bearer $script:Token" }
        SkipHttpErrorCheck = $true
        StatusCodeVariable = 'code'
    }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 6 -Compress)
        $params.ContentType = 'application/json; charset=utf-8'
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $resp = Invoke-RestMethod @params -ResponseHeadersVariable 'hdrs'
        if ($code -in 429, 502, 503, 504) {
            $wait = 10
            if ($hdrs -and $hdrs['Retry-After']) { $wait = [int]($hdrs['Retry-After'] | Select-Object -First 1) }
            Write-Log "Graph throttled ($code), waiting $wait s (attempt $attempt)."
            Start-Sleep -Seconds $wait
            continue
        }
        if (($code -ge 200 -and $code -lt 300) -or $code -in $AllowStatus) {
            return @{ Status = $code; Body = $resp }
        }
        $msg = if ($resp.error) { "$($resp.error.code): $($resp.error.message)" } else { "$resp" }
        throw "Graph $Method $Uri failed ($code). $msg"
    }
    throw "Graph $Method $Uri still throttled after 5 attempts."
}

function Get-GraphAll {
    param([Parameter(Mandatory)][string]$Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $r = Invoke-Graph -Method GET -Uri $next
        if ($r.Body.value) { $items.AddRange([object[]]$r.Body.value) }
        $next = $r.Body.'@odata.nextLink'
    }
    return $items
}
#endregion

#region Contact shaping
function Get-Clean { param($Value) if ($null -eq $Value) { return '' } return ([string]$Value).Trim() }

# Desired contact body built from an Entra user.
function New-ContactBody {
    param([Parameter(Mandatory)]$User)
    $email = Get-Clean $User.mail
    $body = [ordered]@{
        displayName    = Get-Clean $User.displayName
        givenName      = Get-Clean $User.givenName
        surname        = Get-Clean $User.surname
        jobTitle       = Get-Clean $User.jobTitle
        department     = Get-Clean $User.department
        companyName    = Get-Clean $User.companyName
        officeLocation = Get-Clean $User.officeLocation
        mobilePhone    = Get-Clean $User.mobilePhone
        businessPhones = @($User.businessPhones | ForEach-Object { Get-Clean $_ } | Where-Object { $_ })
        emailAddresses = @()
    }
    if ($email) { $body.emailAddresses = @(@{ address = $email; name = $body.displayName }) }
    return $body
}

# Fields that differ between the desired body and an existing contact. Empty = no change.
function Get-ContactDiff {
    param([Parameter(Mandatory)]$Desired, [Parameter(Mandatory)]$Existing)
    $patch = [ordered]@{}
    foreach ($f in 'displayName', 'givenName', 'surname', 'jobTitle', 'department', 'companyName', 'officeLocation', 'mobilePhone') {
        if ((Get-Clean $Desired[$f]) -cne (Get-Clean $Existing.$f)) { $patch[$f] = $Desired[$f] }
    }
    $wantPhones = ($Desired.businessPhones -join '|')
    $havePhones = (@($Existing.businessPhones) | ForEach-Object { Get-Clean $_ } | Where-Object { $_ }) -join '|'
    if ($wantPhones -cne $havePhones) { $patch.businessPhones = $Desired.businessPhones }

    # Exchange can store an internal address as an X500/EX address instead of SMTP. Only
    # compare when the stored value is SMTP, otherwise every run would rewrite the email.
    $wantMail = ($Desired.emailAddresses | ForEach-Object { $_.address }) -join '|'
    $haveList = @($Existing.emailAddresses | ForEach-Object { Get-Clean $_.address })
    $haveMail = $haveList -join '|'
    $haveIsSmtp = ($haveList.Count -eq 0) -or (@($haveList | Where-Object { $_ -notmatch '@' }).Count -eq 0)
    if ($haveIsSmtp -and $wantMail -ne $haveMail) { $patch.emailAddresses = $Desired.emailAddresses }
    return $patch
}
#endregion

try {
    Write-Log "Company Directory sync starting. Mode: $Mode."

    #region 1. Candidate accounts from Entra
    $select = 'id,userPrincipalName,displayName,givenName,surname,mail,jobTitle,department,companyName,officeLocation,mobilePhone,businessPhones,accountEnabled,userType'
    $allUsers = Get-GraphAll -Uri "/users?`$select=$select&`$top=999"
    $candidates = @($allUsers | Where-Object { $_.accountEnabled -eq $true -and $_.userType -eq 'Member' })
    Write-Log "Entra: $($allUsers.Count) users, $($candidates.Count) enabled members to check."
    #endregion

    #region 2. Probe mailbox scope (the Exchange RBAC scope decides who is in the directory)
    $staff = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $candidates) {
        $r = Invoke-Graph -Method GET -Uri "/users/$($u.id)/contactFolders?`$top=1&`$select=id" -AllowStatus 403, 404
        switch ($r.Status) {
            200     { $staff.Add($u) }
            403     { Write-Verbose "Out of scope: $($u.userPrincipalName)" }
            404     { Write-Verbose "No mailbox: $($u.userPrincipalName)" }
        }
    }
    $staff = @($staff | Sort-Object displayName)
    Write-Log "In scope (directory members): $($staff.Count)."
    $staff | ForEach-Object { Write-Log "  + $($_.displayName) <$($_.userPrincipalName)>" }

    if ($staff.Count -lt $MinDirectorySize) {
        throw "Only $($staff.Count) in-scope mailboxes found, minimum is $MinDirectorySize. Aborting with no changes. Check the RBAC assignment (Test-ServicePrincipalAuthorization) or permission propagation."
    }
    #endregion

    #region 3. Choose target mailboxes
    $targets = $staff
    if ($PilotMailboxes.Trim()) {
        $pilot = $PilotMailboxes.Split(',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
        $targets = @($staff | Where-Object { $_.userPrincipalName.ToLower() -in $pilot -or (Get-Clean $_.mail).ToLower() -in $pilot })
        $missing = $pilot | Where-Object { $_ -notin ($targets | ForEach-Object { $_.userPrincipalName.ToLower(); (Get-Clean $_.mail).ToLower() }) }
        if ($missing) { Write-Log "WARNING: pilot mailbox not in scope or not found: $($missing -join ', ')" }
        Write-Log "Pilot mode: writing to $($targets.Count) mailbox(es)."
    }
    $desiredById = @{}
    foreach ($s in $staff) { $desiredById[$s.id] = New-ContactBody -User $s }
    #endregion

    #region 4. Sync each mailbox
    foreach ($t in $targets) {
        if (-not (Test-TimeLeft)) { break }
        $who = $t.userPrincipalName
        try {
            # Folder: find or create
            $folderFilter = [uri]::EscapeDataString("displayName eq '$FolderName'")
            $folderUri = "/users/$($t.id)/contactFolders?`$filter=$folderFilter&`$select=id,displayName"
            $folder = (Invoke-Graph -Method GET -Uri $folderUri).Body.value | Select-Object -First 1
            $existing = @()
            if (-not $folder) {
                Write-Log "[$who] Folder missing, creating."
                if (-not $DryRun -and $PSCmdlet.ShouldProcess($who, "Create folder '$FolderName'")) {
                    $folder = (Invoke-Graph -Method POST -Uri "/users/$($t.id)/contactFolders" -Body @{ displayName = $FolderName }).Body
                }
            }
            if ($folder) {
                $expand = [uri]::EscapeDataString("singleValueExtendedProperties(`$filter=id eq '$MarkerPropId')")
                $existing = Get-GraphAll -Uri "/users/$($t.id)/contactFolders/$($folder.id)/contacts?`$top=500&`$expand=$expand"
            }

            # Index contacts we own by Entra object ID; ignore hand-added ones
            $ownedById = @{}
            $duplicates = [System.Collections.Generic.List[object]]::new()
            foreach ($c in $existing) {
                $marker = $c.singleValueExtendedProperties | Where-Object { $_.id -eq $MarkerPropId } | Select-Object -First 1
                if (-not $marker) { continue }
                if ($ownedById.ContainsKey($marker.value)) { $duplicates.Add($c) } else { $ownedById[$marker.value] = $c }
            }

            $plan = [ordered]@{ Create = @(); Update = @(); Remove = @() }
            foreach ($id in $desiredById.Keys) {
                if (-not $ownedById.ContainsKey($id)) { $plan.Create += $id; continue }
                $diff = Get-ContactDiff -Desired $desiredById[$id] -Existing $ownedById[$id]
                if ($diff.Count -gt 0) { $plan.Update += [pscustomobject]@{ Id = $id; Patch = $diff } } else { $Stats.Unchanged++ }
            }
            foreach ($id in $ownedById.Keys) { if (-not $desiredById.ContainsKey($id)) { $plan.Remove += $ownedById[$id] } }
            $plan.Remove += $duplicates

            if ($plan.Remove.Count -gt $MaxRemovalsPerMailbox) {
                Write-Log "[$who] WARNING: $($plan.Remove.Count) removals planned, over the limit of $MaxRemovalsPerMailbox. Skipping removals for this mailbox, review manually."
                $Stats.Skipped += $plan.Remove.Count
                $plan.Remove = @()
            }

            Write-Log "[$who] Create $($plan.Create.Count), update $($plan.Update.Count), remove $($plan.Remove.Count)."

            foreach ($id in $plan.Create) {
                $body = [ordered]@{}
                foreach ($k in $desiredById[$id].Keys) { $body[$k] = $desiredById[$id][$k] }
                $body.singleValueExtendedProperties = @(@{ id = $MarkerPropId; value = $id })
                Write-Verbose "[$who] create $($body.displayName)"
                if (-not $DryRun -and $PSCmdlet.ShouldProcess($who, "Create contact $($body.displayName)")) {
                    $null = Invoke-Graph -Method POST -Uri "/users/$($t.id)/contactFolders/$($folder.id)/contacts" -Body $body
                }
                $Stats.Created++
            }
            foreach ($u in $plan.Update) {
                $c = $ownedById[$u.Id]
                Write-Log "[$who] update $($c.displayName): $($u.Patch.Keys -join ', ')"
                if (-not $DryRun -and $PSCmdlet.ShouldProcess($who, "Update contact $($c.displayName)")) {
                    $null = Invoke-Graph -Method PATCH -Uri "/users/$($t.id)/contacts/$($c.id)" -Body $u.Patch
                }
                $Stats.Updated++
            }
            foreach ($c in $plan.Remove) {
                Write-Log "[$who] remove $($c.displayName)"
                if (-not $DryRun -and $PSCmdlet.ShouldProcess($who, "Remove contact $($c.displayName)")) {
                    $null = Invoke-Graph -Method DELETE -Uri "/users/$($t.id)/contacts/$($c.id)" -AllowStatus 404
                }
                $Stats.Removed++
            }
        }
        catch {
            $Stats.Errors++
            Write-Log "[$who] ERROR: $($_.Exception.Message)"
        }
    }
    #endregion

    $summary = ($Stats.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '
    Write-Log "Done in $([math]::Round($Clock.Elapsed.TotalMinutes, 1)) min. Mode: $Mode. $summary."
    if ($Stats.Errors -gt 0) { throw "$($Stats.Errors) mailbox(es) had errors, see log above." }
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    throw "Company Directory sync failed: $($_.Exception.Message)"
}
