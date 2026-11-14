<#
.SYNOPSIS
    Batch-deletes Inbox messages received before a cutoff date from one
    mailbox via Microsoft Graph, with a dry-run mode.

.DESCRIPTION
    Lists messages in the Inbox folder ONLY (no other folders) whose
    receivedDateTime is earlier than the cutoff, then deletes them in Graph
    $batch requests of 20 with throttle-aware retries and a live progress
    readout.

    Graph DELETE on a message is a soft delete: items land in Recoverable
    Items\Deletions. They remain
    recoverable for the mailbox's RetainDeletedItemsFor window (consider
    extending it to 30 days before running) via Outlook "Recover Deleted Items From Server"
    or Restore-RecoverableItems.

    ALWAYS run with -DryRun first. Dry run authenticates, counts every
    matching message, shows the oldest/newest received dates in scope, and
    deletes nothing. No subjects or bodies are ever written to console or
    log (keeps sensitive mailbox content out of logs); only counts, dates, and message IDs on errors.

.PARAMETER Mailbox
    Target mailbox (UPN or SMTP address). Required.

.PARAMETER CutoffUtc
    Deletes messages received STRICTLY BEFORE this UTC instant. Required.
    A value without a time zone is treated as local time.
    Example: 2026-06-22T05:00:00Z = midnight 06/22 Central (CDT = UTC-5),
    i.e. "everything received on or before 06/21/2026 local time".

.PARAMETER DryRun
    Count and report only. Nothing is deleted.

.PARAMETER PageSize
    Messages fetched per page (max 1000). Default 500.

.EXAMPLE
    .\Remove-OldMailboxMessages.ps1 -Mailbox shared@contoso.com -CutoffUtc '2026-06-22T05:00:00Z' -DryRun
    Counts matching Inbox messages, deletes nothing.

.EXAMPLE
    .\Remove-OldMailboxMessages.ps1 -Mailbox shared@contoso.com -CutoffUtc '2026-06-22T05:00:00Z'
    Deletes after an explicit confirmation prompt. Expect roughly 1-3 hours
    for ~70k messages depending on Graph throttling.

.NOTES
    Author: Austin Ragsdale

    Prerequisites:
      - Microsoft.Graph.Authentication module (Install-Module Microsoft.Graph.Authentication)
      - Signed-in account must hold Full Access on the shared mailbox:
        Add-MailboxPermission -Identity shared@contoso.com -User <you> -AccessRights FullAccess -AutoMapping $false
        (allow ~30-60 min to take effect if newly granted)
      - Delegated Graph scope Mail.ReadWrite.Shared (consent at sign-in)
    Safe to stop (Ctrl+C) and re-run at any time: it re-queries the server
    each pass, so it simply resumes where it left off.
#>
#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Mailbox,

    [Parameter(Mandatory)]
    [datetime]$CutoffUtc,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$PageSize = 500
)

$ErrorActionPreference = 'Stop'
$CutoffUtc = $CutoffUtc.ToUniversalTime()
$cutoffString = $CutoffUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$logPath = Join-Path $env:USERPROFILE ("Downloads\MailboxCleanup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$connectedHere = $false

# First page URL. $count=true asks Graph to include the total match count.
$baseUrl = "https://graph.microsoft.com/v1.0/users/$Mailbox/mailFolders/inbox/messages" +
           "?`$filter=receivedDateTime lt $cutoffString" +
           "&`$select=id,receivedDateTime&`$orderby=receivedDateTime&`$top=$PageSize&`$count=true"
$baseUrl = $baseUrl -replace ' ', '%20'

try {
    Start-Transcript -Path $logPath | Out-Null
    Write-Host "Cutoff (UTC): $cutoffString  |  Mailbox: $Mailbox  |  Mode: $(if ($DryRun) {'DRY RUN'} else {'DELETE'})"

    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes 'Mail.ReadWrite.Shared' -NoWelcome
        $connectedHere = $true
    }

    # --- Initial count (this IS the dry run; delete mode uses it for progress/ETA) ---
    $firstPage = Invoke-MgGraphRequest -Method GET -Uri $baseUrl
    $total = $firstPage.'@odata.count'
    if ($null -eq $total) {
        # Fallback: page through and count IDs if @odata.count is unsupported
        Write-Host 'Server did not return @odata.count; counting by paging (may take a minute)...'
        $total = 0
        $page = $firstPage
        while ($true) {
            $total += $page.value.Count
            if (-not $page.'@odata.nextLink') { break }
            $page = Invoke-MgGraphRequest -Method GET -Uri $page.'@odata.nextLink'
        }
    }

    $oldest = if ($firstPage.value.Count -gt 0) { $firstPage.value[0].receivedDateTime } else { 'n/a' }
    Write-Host ("Matching Inbox messages: {0:N0}   Oldest in scope: {1}" -f $total, $oldest)

    if ($DryRun) {
        Write-Host 'DRY RUN complete. Nothing was deleted.' -ForegroundColor Green
        return [pscustomobject]@{ Mailbox = $Mailbox; CutoffUtc = $cutoffString; Matching = $total; Deleted = 0; Mode = 'DryRun' }
    }
    if ($total -eq 0) {
        Write-Host 'Nothing matches the cutoff. Done.' -ForegroundColor Green
        return [pscustomobject]@{ Mailbox = $Mailbox; CutoffUtc = $cutoffString; Matching = 0; Deleted = 0; Mode = 'Delete' }
    }
    if (-not $PSCmdlet.ShouldProcess("$Mailbox : $($total.ToString('N0')) Inbox messages received before $cutoffString", 'Soft-delete to Recoverable Items')) {
        return
    }

    # --- Delete loop: fetch first page, delete it in batches of 20, re-fetch ---
    $deleted = 0
    $failed  = @{}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $baseUrl
        $ids = @($page.value.id | Where-Object { -not $failed.ContainsKey($_) })
        if ($ids.Count -eq 0) { break }

        for ($i = 0; $i -lt $ids.Count; $i += 20) {
            $slice = $ids[$i..([Math]::Min($i + 19, $ids.Count - 1))]
            $requests = @(); $n = 0
            foreach ($id in $slice) {
                $n++
                $requests += @{ id = "$n"; method = 'DELETE'; url = "/users/$Mailbox/messages/$id" }
            }
            $resp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' `
                        -Body (@{ requests = $requests } | ConvertTo-Json -Depth 4) -ContentType 'application/json'

            $retryAfter = 0
            foreach ($r in $resp.responses) {
                switch ($r.status) {
                    204     { $deleted++ }                                   # deleted
                    404     { $deleted++ }                                   # already gone
                    429     { $retryAfter = [Math]::Max($retryAfter, [int]($r.headers.'Retry-After' ?? 10)) }
                    default {
                        $badId = $slice[[int]$r.id - 1]
                        $failed[$badId] = $r.status
                        Write-Warning "Message $badId failed with status $($r.status); skipping."
                    }
                }
            }
            if ($retryAfter -gt 0) {
                Write-Host "Throttled. Sleeping $retryAfter s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $retryAfter   # throttled items are NOT marked failed; next re-fetch picks them up
            }

            $rate = if ($sw.Elapsed.TotalSeconds -gt 0) { $deleted / $sw.Elapsed.TotalSeconds } else { 0 }
            $eta  = if ($rate -gt 0) { [TimeSpan]::FromSeconds(($total - $deleted) / $rate).ToString('hh\:mm\:ss') } else { '...' }
            Write-Progress -Activity "Deleting pre-$cutoffString Inbox mail from $Mailbox" `
                -Status ("{0:N0} of {1:N0} deleted  |  {2:N1}/sec  |  ETA {3}" -f $deleted, $total, $rate, $eta) `
                -PercentComplete ([Math]::Min(100, 100 * $deleted / $total))
        }
    }
    $sw.Stop()
    Write-Progress -Activity 'done' -Completed
    Write-Host ("Finished. Deleted {0:N0} messages in {1}. Permanently failed: {2}" -f $deleted, $sw.Elapsed.ToString('hh\:mm\:ss'), $failed.Count) -ForegroundColor Green
    if ($failed.Count -gt 0) { $failed.GetEnumerator() | ForEach-Object { Write-Warning "Failed ID $($_.Key) (status $($_.Value))" } }

    [pscustomobject]@{ Mailbox = $Mailbox; CutoffUtc = $cutoffString; Matching = $total; Deleted = $deleted; Failed = $failed.Count; Duration = $sw.Elapsed; Mode = 'Delete' }
}
catch {
    Write-Error "Cleanup stopped: $($_.Exception.Message)"
    throw
}
finally {
    if ($connectedHere) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
