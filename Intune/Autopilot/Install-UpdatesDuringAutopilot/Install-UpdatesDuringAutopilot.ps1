#Requires -Version 5.1
<#
.SYNOPSIS
    v2. Installs Windows quality updates during the Autopilot pre-provisioning
    (technician) phase, before the device is resealed and shipped.

.DESCRIPTION
    Microsoft does not install monthly security updates during the technician flow of a
    pre-provisioned deployment. The ESP "Install Windows quality updates" setting is
    ignored at the bench and only honored during the user flow, which SkipUserStatusPage
    suppresses. Net result without this app: no OOBE patching on either flow.

    This drives the Windows Update Agent COM API directly as a Win32 app so the patching
    happens at the bench instead.

    Scope is deliberately narrow. Quality/security updates only. Feature updates are
    excluded by category GUID and again by title, so an enablement package can never flip
    the feature version. Drivers are excluded because firmware updates raise the UEFI
    Physical Presence Interface prompt, which parks the ESP on a black BIOS screen waiting
    for a human at the keyboard.

    The device advances to the newest BUILD of whatever feature version it is already on.
    24H2 stays 24H2, 25H2 stays 25H2.

.PARAMETER Reboot
    Soft = return 3010 when an update needs a restart, letting the ESP perform the reboot
           and resume the technician phase. The cumulative update is then COMMITTED before
           Reseal. This is what the established implementations do.
    None = never request a reboot. The update stays staged and finalizes on the device's
           next power on, which for a resealed device is in front of the new hire.

    IMPORTANT: Soft depends on defaultuser0 autologon working. Per the Microsoft Autopilot
    policy-conflict table, AutoAdminLogon = 0 breaks Autopilot, and DeviceLock password
    policies "or any similar group policy settings (including any that disable autologon)"
    can make the OOBE autologon fail when a device reboots during the device ESP. Run the
    pre-flight check before switching this to Soft.

.PARAMETER LiftQualityDeferral
    Temporarily sets DeferQualityUpdatesPeriodInDays to 0 so the newest cumulative is
    offered, then restores the original value in a finally block. The Update Ring itself
    is never modified and Intune reasserts it on the next MDM sync. Only needed if an
    update ring with a nonzero quality deferral reaches the device during provisioning.

.PARAMETER IncludeMicrosoftUpdate
    Opts into Microsoft Update (service ID 7971f918...) to pick up Defender platform and
    other non-Windows patches. Off by default to keep the bench run tight.

.PARAMETER MaxRuntimeMinutes
    Soft budget. Once exceeded the script stops starting new work and exits rather than
    being killed at MaxRunTime with no exit code captured. That is the exact failure shape
    that made Sentinel One look like a hang on a pilot device.

.NOTES
    Exit codes:  0 = success (or nothing to do)   3010 = success, reboot needed
                 1 = FAILED, detection tag deliberately NOT written

    A blocking app that exits 1 fails the ESP. That is intentional. A device that reports
    "patched" while sitting on the old build is worse than a failed bench run, and it
    matches the allowDeviceUseOnInstallFailure = FALSE choice already made on
    ESP-Preprovision.

    Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\ESP-QualityUpdates.log
         (in the IME folder so Intune "Collect diagnostics" picks it up automatically)
    Tag: C:\ProgramData\AutopilotUpdates\ESP-QualityUpdates.tag
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Soft', 'None')]
    [string]$Reboot = 'None',

    [switch]$LiftQualityDeferral,

    [switch]$IncludeMicrosoftUpdate,

    [ValidateRange(1, 20)]
    [int]$SearchRetryCount = 5,

    [ValidateRange(10, 600)]
    [int]$SearchRetryDelaySeconds = 60,

    [ValidateRange(5, 180)]
    [int]$MaxRuntimeMinutes = 60
)

# --- Re-launch 64-bit if we landed in the 32-bit host -------------------------------
# The Intune Management Extension runs Win32 install commands from a 32-bit process, so
# %windir%\System32 redirects to SysWOW64. The Windows Update COM API needs the real
# 64-bit host. Guard on PROCESSOR_ARCHITEW6432 so ARM64 devices are handled correctly.
if ("$env:PROCESSOR_ARCHITEW6432" -ne 'ARM64') {
    if (Test-Path "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe") {
        $relaunch = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                      '-File', "`"$PSCommandPath`"", '-Reboot', $Reboot,
                      '-SearchRetryCount', $SearchRetryCount,
                      '-SearchRetryDelaySeconds', $SearchRetryDelaySeconds,
                      '-MaxRuntimeMinutes', $MaxRuntimeMinutes)
        if ($LiftQualityDeferral)    { $relaunch += '-LiftQualityDeferral' }
        if ($IncludeMicrosoftUpdate) { $relaunch += '-IncludeMicrosoftUpdate' }

        & "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" @relaunch
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Stop'
$started = Get-Date

$LogDir  = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogDir 'ESP-QualityUpdates.log'
$TagDir  = "$env:ProgramData\AutopilotUpdates"
$TagFile = Join-Path $TagDir 'ESP-QualityUpdates.tag'

# Feature update category. Matching the GUID rather than the English category name
# "Upgrades" keeps this working regardless of OS display language.
$FeatureUpdateCategoryId = '3689BDC8-B205-4AF4-8D4A-A63924C5E9D5'

# An LCU always needs a restart to commit. Used to gate success and force the reboot flag.
$LcuPattern = 'Cumulative Update for Windows|Security Update \(KB'

foreach ($d in @($LogDir, $TagDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Test-Budget {
    $elapsed = (New-TimeSpan -Start $started -End (Get-Date)).TotalMinutes
    if ($elapsed -ge $MaxRuntimeMinutes) {
        Write-Log ("Runtime budget of {0} min reached ({1:N1} elapsed)." -f $MaxRuntimeMinutes, $elapsed) 'WARN'
        return $false
    }
    return $true
}

function Write-Tag {
    param([string]$Summary)
    Set-Content -LiteralPath $TagFile -Value ('{0}  {1}' -f (Get-Date -Format 'o'), $Summary) -Encoding UTF8
    Write-Log ("Detection tag written: {0}" -f $Summary)
}

function Exit-Run {
    param([int]$Code, [string]$Summary)
    $elapsed = (New-TimeSpan -Start $started -End (Get-Date)).TotalMinutes
    Write-Log ("RESULT: {0}. Exit {1}. Elapsed {2:N1} min." -f $Summary, $Code, $elapsed)
    Write-Log '================================================================'
    exit $Code
}

Write-Log '================================================================'
Write-Log ("ESP quality update run starting. Reboot mode = {0}." -f $Reboot)
Write-Log ("Host: {0}  PS: {1}  64-bit process: {2}  Identity: {3}" -f `
    $env:COMPUTERNAME, $PSVersionTable.PSVersion, [Environment]::Is64BitProcess,
    [Security.Principal.WindowsIdentity]::GetCurrent().Name)

$rebootNeeded = $false

try {
    # --- Step 0: skip Insider / flighting devices gracefully -------------------------
    # These get builds through their own channel. The blocking-app contract means a plain
    # failure here would fail provisioning, so on skip we write the tag and exit 0.
    # The flighting registry is the authoritative signal. Build numbers are NOT, because
    # Release Preview Insiders share the retail build family (26100.x / 26200.x).
    $selfHost = 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability'
    if (Test-Path $selfHost) {
        $sh = Get-ItemProperty -Path $selfHost -ErrorAction SilentlyContinue
        if ($sh.BranchName -or $sh.Ring -or $sh.ContentType -or ($sh.EnablePreviewBuilds -eq 1)) {
            Write-Log ("Insider/flighting device (BranchName='{0}', Ring='{1}'). Skipping." -f $sh.BranchName, $sh.Ring) 'WARN'
            Write-Tag 'Skipped, Insider device'
            Exit-Run 0 'Skipped on Insider build, ESP not failed'
        }
    }

    # --- Step 1: Windows Update service ----------------------------------------------
    $wu = Get-Service -Name wuauserv
    if ($wu.StartType -eq 'Disabled') {
        Write-Log 'wuauserv is Disabled. Setting to Manual.' 'WARN'
        if ($PSCmdlet.ShouldProcess('wuauserv', 'Set start type to Manual')) {
            Set-Service -Name wuauserv -StartupType Manual
        }
    }
    if ($wu.Status -ne 'Running') {
        Write-Log ("wuauserv is {0}. Starting." -f $wu.Status)
        if ($PSCmdlet.ShouldProcess('wuauserv', 'Start service')) {
            Start-Service -Name wuauserv
            $wu.WaitForStatus('Running', '00:02:00')
        }
    }

    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-Log ("Feature version {0}, build {1}.{2}. This run advances the BUILD only, never the version." -f `
        $cv.DisplayVersion, $cv.CurrentBuildNumber, $cv.UBR)

    if ($IncludeMicrosoftUpdate) {
        # 7971f918-a847-4430-9279-4a52d1efe18d = Microsoft Update
        try {
            $svcMgr = New-Object -ComObject Microsoft.Update.ServiceManager
            $svcMgr.AddService2('7971f918-a847-4430-9279-4a52d1efe18d', 7, '') | Out-Null
            Write-Log 'Opted into Microsoft Update.'
        }
        catch { Write-Log ("Could not opt into Microsoft Update: {0}" -f $_.Exception.Message) 'WARN' }
    }

    # --- Step 2: optionally lift the WUfB quality deferral ---------------------------
    # If an update ring assigns DeferQualityUpdatesPeriodInDays, WUfB withholds any
    # quality update released inside that window, so the scan would return everything
    # EXCEPT the newest LCU. Transient override only. The ring is never touched and
    # Intune reasserts the value on next sync, so this is belt and braces.
    $policyPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $origDefer  = $null

    try {
        if ($LiftQualityDeferral -and (Test-Path $policyPath)) {
            $origDefer = (Get-ItemProperty $policyPath -Name DeferQualityUpdatesPeriodInDays -ErrorAction SilentlyContinue).DeferQualityUpdatesPeriodInDays
            if ($null -ne $origDefer -and $origDefer -gt 0) {
                Set-ItemProperty $policyPath -Name DeferQualityUpdatesPeriodInDays -Value 0 -Type DWord -ErrorAction SilentlyContinue
                Write-Log ("Quality deferral temporarily set to 0 (was {0})." -f $origDefer)
                Start-Sleep -Seconds 5
            }
            else {
                Write-Log 'No nonzero quality deferral in effect, nothing to lift.'
                $origDefer = $null
            }
        }

        # --- Step 3: scan --------------------------------------------------------------
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'Autopilot-QualityUpdates'
        $searcher = $session.CreateUpdateSearcher()

        # Type='Software' already excludes drivers at the query level.
        $criteria = "IsInstalled=0 and Type='Software' and IsHidden=0"
        $searchResult = $null

        for ($attempt = 1; $attempt -le $SearchRetryCount; $attempt++) {
            if (-not (Test-Budget)) { Exit-Run 1 'Budget reached during scan, no tag written' }
            try {
                Write-Log ("Scan attempt {0} of {1}: {2}" -f $attempt, $SearchRetryCount, $criteria)
                $searchResult = $searcher.Search($criteria)
                Write-Log ("Scan succeeded. {0} update(s) returned." -f $searchResult.Updates.Count)
                break
            }
            catch {
                $msg = $_.Exception.Message
                # 8024004A = "Windows Update agent operations are not available while OS
                # setup is running." Worth naming, it means we ran too early rather than
                # that anything is broken.
                if ($msg -match '8024004A') {
                    Write-Log ("Attempt {0}: WU agent unavailable, OS setup still running (8024004A)." -f $attempt) 'WARN'
                }
                else {
                    Write-Log ("Attempt {0} failed: {1}" -f $attempt, $msg) 'WARN'
                }
                $searchResult = $null
                if ($attempt -lt $SearchRetryCount) { Start-Sleep -Seconds $SearchRetryDelaySeconds }
            }
        }

        if ($null -eq $searchResult) {
            Exit-Run 1 'All scan attempts failed, no tag written'
        }

        # --- Step 4: filter ------------------------------------------------------------
        $wanted = @()
        foreach ($u in $searchResult.Updates) {
            $cats = @($u.Categories | ForEach-Object { $_.CategoryID })

            if ($cats -contains $FeatureUpdateCategoryId) {
                Write-Log ("SKIP feature update: {0}" -f $u.Title); continue
            }
            # Title guard, in case an enablement package is ever mis-categorised.
            if ($u.Title -match 'Feature update|Enablement Package') {
                Write-Log ("SKIP by title (feature/eKB): {0}" -f $u.Title); continue
            }
            if ($u.Title -match 'Preview') {
                Write-Log ("SKIP preview update: {0}" -f $u.Title); continue
            }
            if ($u.BrowseOnly) {
                Write-Log ("SKIP browse-only/optional: {0}" -f $u.Title); continue
            }
            if ($u.InstallationBehavior.CanRequestUserInput) {
                # Nobody is at the keyboard. An update that can prompt would sit in
                # session 0 until the IME kills it.
                Write-Log ("SKIP can prompt for input: {0}" -f $u.Title) 'WARN'; continue
            }

            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            Write-Log ("QUEUED: {0}" -f $u.Title)
            $wanted += $u
        }

        if ($wanted.Count -eq 0) {
            Write-Log 'No applicable quality updates.'
            Write-Tag 'No applicable updates'
            Exit-Run 0 'Nothing to install'
        }

        # Record which cumulative updates were pending, for the success gate below.
        $lcuPending = @($wanted | Where-Object { $_.Title -match $LcuPattern })
        Write-Log ("{0} update(s) queued, {1} of them cumulative/security." -f $wanted.Count, $lcuPending.Count)

        # --- Step 5: download and install, one update at a time -------------------------
        # Per-update rather than batched, so one failure is isolated and attributable.
        $installedOk = @()
        $failed      = @()

        foreach ($u in $wanted) {
            if (-not (Test-Budget)) {
                Write-Log ("Budget reached, not starting: {0}" -f $u.Title) 'WARN'
                break
            }

            $single = New-Object -ComObject Microsoft.Update.UpdateColl
            $single.Add($u) | Out-Null

            if (-not $PSCmdlet.ShouldProcess($u.Title, 'Download and install')) { continue }

            try {
                $dl = $session.CreateUpdateDownloader()
                $dl.Updates = $single
                Write-Log ("Downloading: {0}" -f $u.Title)
                $dlResult = $dl.Download()
                Write-Log ("  download result {0} (2 = Succeeded), HResult 0x{1:X8}" -f $dlResult.ResultCode, $dlResult.HResult)

                if (-not $u.IsDownloaded) {
                    Write-Log ("  NOT downloaded, skipping install: {0}" -f $u.Title) 'WARN'
                    $failed += $u
                    continue
                }

                $inst = $session.CreateUpdateInstaller()
                $inst.Updates = $single
                $inst.ForceQuiet = $true
                $inst.AllowSourcePrompts = $false

                Write-Log ("Installing: {0}" -f $u.Title)
                $instResult = $inst.Install()
                Write-Log ("  install result {0} (2 = Succeeded), HResult 0x{1:X8}" -f $instResult.ResultCode, $instResult.HResult)

                if ($instResult.ResultCode -eq 2) {
                    $installedOk += $u
                    if ($instResult.RebootRequired) { $rebootNeeded = $true }
                }
                else {
                    $failed += $u
                }
            }
            catch {
                Write-Log ("  EXCEPTION on {0}: {1}" -f $u.Title, $_.Exception.Message) 'ERROR'
                $failed += $u
            }
        }

        Write-Log ("Result check: {0} installed, {1} failed, of {2} queued." -f $installedOk.Count, $failed.Count, $wanted.Count)
        foreach ($f in $failed) { Write-Log ("  FAILED: {0}" -f $f.Title) 'WARN' }

        # --- Step 6: success gates ------------------------------------------------------
        # Gate 1: nothing installed at all is a failure, not a quiet success.
        if ($installedOk.Count -eq 0) {
            Exit-Run 1 'Every queued update failed, no tag written'
        }

        # Gate 2: if a cumulative was pending it MUST be in the installed set. Without
        # this, a run that installs Defender platform updates but fails the LCU would
        # write the tag and report "installed" while the device sits on the old build.
        if ($lcuPending.Count -gt 0) {
            $lcuInstalled = @($installedOk | Where-Object { $_.Title -match $LcuPattern })
            if ($lcuInstalled.Count -eq 0) {
                Exit-Run 1 ("Cumulative update failed to install ({0}), no tag written" -f $lcuPending[0].Title)
            }
            Write-Log ("LCU check passed: {0}" -f $lcuInstalled[0].Title)
            # Do not trust the WU reboot flag here. A cumulative always needs a restart
            # to commit, and the flag has been observed reporting otherwise.
            $rebootNeeded = $true
        }

        # Secondary reboot signals.
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $rebootNeeded = $true }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $rebootNeeded = $true }
    }
    finally {
        if ($null -ne $origDefer) {
            Set-ItemProperty $policyPath -Name DeferQualityUpdatesPeriodInDays -Value $origDefer -Type DWord -ErrorAction SilentlyContinue
            Write-Log ("Quality deferral restored to {0}." -f $origDefer)
        }
    }

    # --- Step 7: tag and exit ----------------------------------------------------------
    Write-Tag ("Installed {0} update(s)" -f $installedOk.Count)

    if ($rebootNeeded -and $Reboot -eq 'Soft') {
        Exit-Run 3010 'Updates installed, requesting ESP soft reboot to commit'
    }
    elseif ($rebootNeeded) {
        Write-Log 'Reboot IS required to commit. Reboot mode is None, so NOT requesting one.' 'WARN'
        Write-Log 'The update stays staged and finalizes on the next power on, which for a resealed device is in front of the end user.' 'WARN'
        Exit-Run 0 'Updates installed, staged but not committed'
    }
    else {
        Exit-Run 0 ("Installed {0} update(s), no reboot required" -f $installedOk.Count)
    }
}
catch {
    Write-Log ("UNHANDLED: {0}" -f $_.Exception.Message) 'ERROR'
    Write-Log ("At: {0}" -f $_.InvocationInfo.PositionMessage) 'ERROR'
    Exit-Run 1 'Unhandled error, no tag written'
}
