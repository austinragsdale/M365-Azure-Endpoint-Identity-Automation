#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only pre-flight assessment for the SentinelOne to FortiEndpoint migration.

.DESCRIPTION
    Emits a single pipe-delimited line per device describing every factor that is
    known to cause FortiEndpoint / FortiEDR collector instability:

      - Existing FortiEDR collector version (gates on the 6.2.0.1437 USB storage bug)
      - SentinelOne remnants (product, service, and resident driver checked separately)
      - Other endpoint security products carrying kernel minifilters
      - Backup agents (FortiEDR bug 1315829, crash during server backup)
      - Whether USB mass storage has ever been attached (exposure to bug 1326457)
      - Pending reboot, OS build, chassis type

    Makes no changes. Safe to run fleet wide via ConnectWise RMM automation.
    Designed for a single line of output so results aggregate cleanly.

.NOTES
    Run as SYSTEM or elevated. Registry and minifilter queries need admin.
#>

[CmdletBinding()]
param(
    # Emit a readable object instead of the one line RMM string.
    [switch]$AsObject
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName }
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return [bool]$pfro.PendingFileRenameOperations
}

try {
    $os      = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cs      = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $apps    = Get-UninstallEntries

    # --- Fortinet current state -------------------------------------------------
    $fortiEdrApp = $apps | Where-Object { $_.DisplayName -match 'FortiEDR|Endpoint Detection and Response' } | Select-Object -First 1
    $fortiCliApp = $apps | Where-Object { $_.DisplayName -match '^FortiClient' } | Select-Object -First 1

    # Driver version is authoritative. The uninstall entry can lag after an upgrade.
    $edrDriver = Get-ChildItem "$env:SystemRoot\System32\drivers\FortiEDRWinDriver*.sys" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $edrDriverVer = if ($edrDriver) { $edrDriver.VersionInfo.FileVersion } else { '' }

    # Known bad: 6.2.0.1437 bugchecks on USB storage insert. Fixed in 6.2.0.1462.
    $collectorVer = if ($edrDriverVer) { $edrDriverVer } elseif ($fortiEdrApp) { $fortiEdrApp.DisplayVersion } else { 'None' }
    $collectorBad = $collectorVer -match '6\.2\.0\.1437'

    # --- SentinelOne: three independent checks ----------------------------------
    # A clean console uninstall can still leave the driver resident. Check all three.
    $s1App    = [bool]($apps | Where-Object { $_.DisplayName -match 'Sentinel' })
    $s1Svc    = [bool](Get-Service | Where-Object { $_.Name -match 'Sentinel' })
    $s1Driver = [bool](Get-ChildItem "$env:SystemRoot\System32\drivers\*.sys" |
                    Where-Object { $_.Name -match 'Sentinel' })
    $s1Dir    = [bool](Test-Path "$env:ProgramFiles\SentinelOne")

    $s1State = if ($s1App -and $s1Svc)        { 'INSTALLED' }
               elseif ($s1Driver -or $s1Svc)  { 'REMNANT-DRIVER' }   # the dangerous one
               elseif ($s1App -or $s1Dir)     { 'REMNANT-FILES' }
               else                           { 'Clean' }

    # --- Other endpoint security with kernel filters ----------------------------
    # ThreatLocker is named in FortiEDR bug 1315981. Elastic was found undeclared
    # on a pilot device. Anything here means two filter stacks on one box.
    $edrPattern = 'ThreatLocker|Elastic|CrowdStrike|Carbon Black|Cylance|Webroot|Huntress|Sophos|Bitdefender|Cortex|Trend Micro|ESET|Malwarebytes|Symantec|McAfee|Trellix'
    $otherEdr = @($apps | Where-Object { $_.DisplayName -match $edrPattern } |
        Select-Object -ExpandProperty DisplayName -Unique)

    # Minifilters tell the truth even when the uninstall entry is gone.
    # fltmc needs admin. Under RMM this runs as SYSTEM, so it will populate.
    $filters = @()
    $global:LASTEXITCODE = 0
    $fltOut = & fltmc.exe filters 2>$null
    if ($LASTEXITCODE -eq 0 -and $fltOut) {
        $filters = $fltOut | Select-Object -Skip 3 | ForEach-Object {
            ($_ -split '\s+') | Select-Object -First 1
        } | Where-Object { $_ -and $_ -notmatch '^-+$' }
    }
    $suspectFilters = @($filters | Where-Object {
        $_ -match 'Sentinel|Elastic|ThreatLocker|CSAgent|cbk7|CyOptics|WRkrn|HuntressBlock|SophosED|trufos|bdvedisk|eamonm|mbamwatch|SymEFA|mfe|Trellix'
    })

    # --- Backup agents (FortiEDR bug 1315829) -----------------------------------
    $backup = @($apps | Where-Object { $_.DisplayName -match 'Veeam|Acronis|Datto|Backup Exec|ShadowProtect|Carbonite|Cove|N-able Backup' } |
        Select-Object -ExpandProperty DisplayName -Unique)

    # --- Exposure to the USB storage bug ----------------------------------------
    # USBSTOR enum keys persist for every mass storage device ever attached.
    # A non-zero count means this machine WILL hit bug 1326457 on collector 1437.
    $usbHistory = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR' -ErrorAction SilentlyContinue).Count

    # Card readers in docks enumerate as USB storage and fire the bug at boot.
    $cardReader = [bool](Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.Name -match 'Card Reader|SD Host|RTS5|Realtek USB.*Card' })

    # --- Chassis ------------------------------------------------------------------
    $isServer  = $os.ProductType -ne 1
    $chassis   = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes | Select-Object -First 1
    $isLaptop  = $chassis -in 8,9,10,11,12,14,18,21,30,31,32

    # --- Verdict ------------------------------------------------------------------
    # Anything that has historically caused a bugcheck is BLOCK, not WARN.
    $reasons = @()
    if ($collectorBad)                  { $reasons += 'Collector-6.2.0.1437-USB-BSOD' }
    if ($s1State -eq 'REMNANT-DRIVER')  { $reasons += 'S1-driver-resident' }
    if ($suspectFilters.Count -gt 0)    { $reasons += "Foreign-minifilter:$($suspectFilters -join ',')" }
    if ($otherEdr -match 'ThreatLocker'){ $reasons += 'ThreatLocker-bug-1315981' }

    $warnings = @()
    if ($s1State -eq 'REMNANT-FILES')   { $warnings += 'S1-files-left' }
    if ($otherEdr.Count -gt 0)          { $warnings += "OtherEDR:$($otherEdr -join ',')" }
    if ($isServer -and $backup.Count)   { $warnings += "Server-backup-bug-1315829:$($backup -join ',')" }
    if ($usbHistory -gt 0)              { $warnings += "USB-storage-history:$usbHistory" }
    if ($cardReader)                    { $warnings += 'Card-reader-present' }
    if (Test-PendingReboot)             { $warnings += 'Pending-reboot' }

    $verdict = if ($reasons.Count) { 'BLOCK' } elseif ($warnings.Count) { 'REVIEW' } else { 'READY' }

    $result = [pscustomobject]@{
        Computer      = $env:COMPUTERNAME
        Verdict       = $verdict
        Blockers      = ($reasons  -join '; ')
        Warnings      = ($warnings -join '; ')
        OSBuild       = "$($os.Caption) $($os.Version)"
        Type          = if ($isServer) { 'Server' } elseif ($isLaptop) { 'Laptop' } else { 'Desktop' }
        Model         = "$($cs.Manufacturer) $($cs.Model)".Trim()
        CollectorVer  = $collectorVer
        FortiClient   = if ($fortiCliApp) { $fortiCliApp.DisplayVersion } else { 'None' }
        SentinelOne   = $s1State
        OtherSecurity = ($otherEdr -join ',')
        FilterCount   = $filters.Count
        USBStorHist   = $usbHistory
    }

    if ($AsObject) { $result }
    else {
        # One line, pipe delimited, for RMM output aggregation.
        ($result.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|'
    }
}
catch {
    "Computer=$env:COMPUTERNAME|Verdict=ERROR|Blockers=Preflight failed: $($_.Exception.Message)"
}
finally {
    # Never leak a native exit code. RMM treats nonzero as a failed script.
    $global:LASTEXITCODE = 0
}
exit 0
