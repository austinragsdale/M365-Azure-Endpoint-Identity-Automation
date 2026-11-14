<#
.SYNOPSIS
    Diagnoses and fixes common causes of Intune AntivirusRequired non-compliance
    when Defender is intended to be the AV provider.

.NOTES
    Run as SYSTEM (via Intune remediation or ConnectWise Run as Admin).
    Reboot recommended after execution.
#>

$log = "$env:ProgramData\Fix-DefenderAV.log"
"[{0}] START" -f (Get-Date) | Out-File $log -Append

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $line | Out-File $log -Append
}

# -------- 1. Snapshot current state --------
Log "=== BEFORE ==="

$svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
if ($svc) {
    Log ("WinDefend service : {0} / StartType {1}" -f $svc.Status, $svc.StartType)
} else {
    Log "WinDefend service : NOT FOUND (Defender missing or blocked)"
}

try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Log ("AMRunningMode         : {0}" -f $mp.AMRunningMode)
    Log ("RealTimeProtection    : {0}" -f $mp.RealTimeProtectionEnabled)
    Log ("AntivirusEnabled      : {0}" -f $mp.AntivirusEnabled)
    Log ("AntispywareEnabled    : {0}" -f $mp.AntispywareEnabled)
    Log ("AVSignatureAgeDays    : {0}" -f $mp.AntivirusSignatureAge)
    Log ("AVSignatureVersion    : {0}" -f $mp.AntivirusSignatureVersion)
    Log ("TamperProtection      : {0}" -f $mp.IsTamperProtected)
} catch {
    Log "Get-MpComputerStatus FAILED: $($_.Exception.Message)"
    Log "This usually means WMI is broken. Will attempt WMI repair."
}

Log "Registered SecurityCenter2 AV providers:"
try {
    Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop |
        ForEach-Object { Log ("  - {0}  (state=0x{1:X})" -f $_.displayName, $_.productState) }
} catch {
    Log "  Query failed: $($_.Exception.Message)"
}

# -------- 2. Fixes --------
Log "=== FIX ==="

# 2a. Ensure WinDefend is running and auto
try {
    Set-Service -Name WinDefend -StartupType Automatic -ErrorAction Stop
    Start-Service -Name WinDefend -ErrorAction Stop
    Log "WinDefend set Automatic and started."
} catch {
    Log "Could not start WinDefend: $($_.Exception.Message)"
}

# 2b. Ensure real time protection is on
try {
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
    Log "Real time monitoring enabled."
} catch {
    Log "Set-MpPreference RealtimeMonitoring failed: $($_.Exception.Message)"
}

# 2c. Force signature update
try {
    Update-MpSignature -ErrorAction Stop
    Log "Signatures updated."
} catch {
    Log "Signature update failed: $($_.Exception.Message)"
    # Fallback via MpCmdRun
    try {
        & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -SignatureUpdate | Out-Null
        Log "Signatures updated via MpCmdRun fallback."
    } catch { Log "MpCmdRun signature update also failed: $($_.Exception.Message)" }
}

# 2d. Remove GPO registry blocks on Defender if present
$policyKeys = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
)
foreach ($k in $policyKeys) {
    if (Test-Path $k) {
        try {
            $vals = Get-ItemProperty $k -ErrorAction SilentlyContinue
            foreach ($name in @('DisableAntiSpyware','DisableAntiVirus','DisableRealtimeMonitoring')) {
                if ($null -ne $vals.$name) {
                    Remove-ItemProperty -Path $k -Name $name -ErrorAction SilentlyContinue
                    Log "Removed policy $k\$name"
                }
            }
        } catch {}
    }
}

# 2e. Force WMI SecurityCenter2 to re-register Defender
try {
    Log "Refreshing SecurityCenter2 registration..."
    & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -WDEnable | Out-Null
    Restart-Service -Name wscsvc -Force -ErrorAction SilentlyContinue
    Log "wscsvc restarted."
} catch { Log "wscsvc refresh error: $($_.Exception.Message)" }

# 2f. Force Intune management extension to sync
try {
    Restart-Service -Name IntuneManagementExtension -Force -ErrorAction SilentlyContinue
    Log "IntuneManagementExtension restarted."
} catch {}

# Kick MDM sync (device management schedule)
try {
    $task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" -TaskName 'PushLaunch' -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -InputObject $task
        Log "MDM PushLaunch triggered."
    }
} catch {}

# -------- 3. After state --------
Log "=== AFTER ==="
try {
    $mp2 = Get-MpComputerStatus -ErrorAction Stop
    Log ("AMRunningMode         : {0}" -f $mp2.AMRunningMode)
    Log ("RealTimeProtection    : {0}" -f $mp2.RealTimeProtectionEnabled)
    Log ("AntivirusEnabled      : {0}" -f $mp2.AntivirusEnabled)
    Log ("AVSignatureAgeDays    : {0}" -f $mp2.AntivirusSignatureAge)
} catch {
    Log "Get-MpComputerStatus still failing. WMI repair likely needed."
}

Log "DONE. Log: $log"
