#Requires -Version 5.1
<#
.SYNOPSIS
    Enables the Windows master Location Services setting at the device level.

.DESCRIPTION
    Intune Platform Script. Must run in SYSTEM context, 64-bit PowerShell.

    Devices built by Autopilot with the OOBE privacy page hidden are born with
    Location Services off. Standard users then see "Location has been turned off
    by an admin on this device" and cannot enable it.

    The master location state lives inside camsvc and is only reachable through
    the CapabilityConsentManager API. Registry writes to ConsentStore or to
    SensorPermissionState do NOT work: they are mirrors that lfsvc re-stamps from
    the real state within seconds of service start. Proven by Procmon 2026-08-09.

    SystemSettingsAdminFlows.exe is the binary the Settings app itself calls when
    an admin flips the master toggle. It drives the real API, so the change sticks
    through service restarts and reboots.

    This does NOT force location on for applications. The per-app layer is left
    entirely under user control.

.NOTES
    Version : 2.0
    Date    : 2026-08-09
    Log     : C:\ProgramData\EndpointScripts\Logs\Enable-LocationServices.log
    Exit 0  : location enabled (or already enabled)
    Exit 1  : failed
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$MirrorPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
$LogDir     = 'C:\ProgramData\EndpointScripts\Logs'
$LogFile    = Join-Path $LogDir 'Enable-LocationServices.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -ErrorAction Stop
    } catch {
        Write-Output "Could not write to log file: $($_.Exception.Message)"
    }
}

function Get-LocationState {
    try {
        return (Get-ItemProperty -Path $MirrorPath -Name SensorPermissionState -ErrorAction Stop).SensorPermissionState
    } catch {
        return $null
    }
}

Write-Log "Starting. Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

try {
    $before = Get-LocationState
    Write-Log "SensorPermissionState before: $before"

    if ($before -eq 1) {
        Write-Log "Location Services already enabled. Nothing to do."
        exit 0
    }

    $exe = Join-Path $env:SystemRoot 'System32\SystemSettingsAdminFlows.exe'
    if (-not (Test-Path $exe)) {
        Write-Log "SystemSettingsAdminFlows.exe not found at $exe" 'ERROR'
        exit 1
    }

    if ($PSCmdlet.ShouldProcess('Windows Location Services', 'Enable at device level')) {

        Write-Log "Running: $exe SetCamSystemGlobal location 1"
        $p = Start-Process -FilePath $exe -ArgumentList 'SetCamSystemGlobal', 'location', '1' `
                           -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Write-Log "Process exit code: $($p.ExitCode)"

        Start-Sleep -Seconds 5

        $after = Get-LocationState
        Write-Log "SensorPermissionState after: $after"

        if ($after -eq 1) {
            Write-Log "SUCCESS. Location Services enabled. Per-app control left to the user."
            exit 0
        } else {
            Write-Log "FAILED. State is '$after', expected 1." 'ERROR'
            exit 1
        }
    }
} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR'
    exit 1
}
