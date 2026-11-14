#Requires -Version 5.1
<#
.SYNOPSIS
    Ranks how soon a device will hit FortiEDR bug 1326457 (USB storage BSOD,
    collector 6.2.0.1437, fixed in 6.2.0.1462).

.DESCRIPTION
    Every device on collector 6.2.0.1437 is exposed. This does NOT tell you which
    devices are safe. It tells you which ones will crash SOONEST, so waves can be
    ordered and the highest risk machines pulled forward.

    The bug lives in partmgr, the partition manager, so only devices that create a
    disk object count. Thumb drives, external disks, SD cards and dictation cradles
    qualify. Phones on MTP generally do not.

    Signals, in order of weight:
      1. USB disk attached right now          -> already at risk this session
      2. Card reader present                   -> enumerates at boot, no user action
      3. Days since last USB storage attach    -> recency predicts recurrence
      4. Distinct USB storage devices ever     -> habit indicator

    Read only. Safe to run fleet wide as SYSTEM via ConnectWise RMM.

.NOTES
    Requires admin/SYSTEM to read the USBSTOR device properties.
#>

[CmdletBinding()]
param(
    [switch]$AsObject
)

$ErrorActionPreference = 'SilentlyContinue'

# DEVPKEY_Device_LastArrivalDate lives under this property GUID as value 0066.
$PropGuid   = '{83da6326-97a6-4088-9453-a1923f573b29}'
$LastArrival = '0066'
$FirstInstall = '0065'

function Get-RegDefaultValue {
    param([string]$SubKey)
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey)
        if ($k) { $v = $k.GetValue(''); $k.Close(); return $v }
    } catch { }
    return $null
}

function ConvertFrom-FileTimeBytes {
    param($Bytes)
    if ($Bytes -isnot [byte[]] -or $Bytes.Length -lt 8) { return $null }
    try {
        $ft = [BitConverter]::ToInt64($Bytes, 0)
        if ($ft -le 0) { return $null }
        return [DateTime]::FromFileTime($ft)
    } catch { return $null }
}

try {
    $collectorDrv = Get-ChildItem "$env:SystemRoot\System32\drivers\FortiEDRWinDriver*.sys" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $collectorVer = if ($collectorDrv) { $collectorDrv.VersionInfo.FileVersion } else { 'None' }
    $affected     = $collectorVer -match '6\.2\.0\.1437'

    # --- 1. USB storage history with timestamps ---------------------------------
    $root = 'SYSTEM\CurrentControlSet\Enum\USBSTOR'
    $devices = @()

    $rootKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($root)
    if ($rootKey) {
        foreach ($devClass in $rootKey.GetSubKeyNames()) {
            $classKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$root\$devClass")
            if (-not $classKey) { continue }
            foreach ($inst in $classKey.GetSubKeyNames()) {
                $base = "$root\$devClass\$inst\Properties\$PropGuid"
                $last  = ConvertFrom-FileTimeBytes (Get-RegDefaultValue "$base\$LastArrival")
                $first = ConvertFrom-FileTimeBytes (Get-RegDefaultValue "$base\$FirstInstall")

                # Friendly name lives on the instance key itself.
                $ik = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$root\$devClass\$inst")
                $friendly = if ($ik) { $ik.GetValue('FriendlyName') } else { $null }
                if ($ik) { $ik.Close() }

                $devices += [pscustomobject]@{
                    Name        = if ($friendly) { $friendly } else { $devClass }
                    LastArrival = $last
                    FirstSeen   = $first
                }
            }
            $classKey.Close()
        }
        $rootKey.Close()
    }

    $lastAttach = ($devices | Where-Object LastArrival | Sort-Object LastArrival -Descending |
        Select-Object -First 1).LastArrival
    $daysSince  = if ($lastAttach) { [int]((Get-Date) - $lastAttach).TotalDays } else { $null }

    # Devices seen in the last 90 days indicate an active habit, not one-off history.
    $recentCount = @($devices | Where-Object { $_.LastArrival -and $_.LastArrival -gt (Get-Date).AddDays(-90) }).Count

    # --- 2. Card readers: enumerate at boot with no user action -----------------
    $cardReaders = @(Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.Name -match 'Card Reader|SD Host Adapter|RTS5\d{3}|Realtek USB.*Card|USB.*SD.*Reader' } |
        Select-Object -ExpandProperty Name -Unique)

    # --- 3. USB disks attached right now ----------------------------------------
    $liveUsbDisks = @(Get-CimInstance Win32_DiskDrive |
        Where-Object { $_.InterfaceType -eq 'USB' } |
        Select-Object -ExpandProperty Model -Unique)

    # --- 4. Docking stations ------------------------------------------------------
    $dock = @(Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.Name -match 'Dock|Anker|Thunderbolt.*Dock|USB.*Hub.*Dock' } |
        Select-Object -ExpandProperty Name -Unique)

    # --- Risk tier ----------------------------------------------------------------
    # LOW does NOT mean safe. It means no recent history. The bug still fires the
    # moment anyone plugs in a drive.
    $tier, $why = switch ($true) {
        { $liveUsbDisks.Count -gt 0 } { 'IMMINENT', "USB disk attached now: $($liveUsbDisks -join ',')"; break }
        { $cardReaders.Count  -gt 0 } { 'IMMINENT', "Card reader enumerates at boot: $($cardReaders -join ',')"; break }
        { $daysSince -ne $null -and $daysSince -le 7 }   { 'HIGH',   "USB storage $daysSince days ago"; break }
        { $daysSince -ne $null -and $daysSince -le 30 }  { 'HIGH',   "USB storage $daysSince days ago"; break }
        { $daysSince -ne $null -and $daysSince -le 180 } { 'MEDIUM', "USB storage $daysSince days ago"; break }
        # A dock may simply be detached at scan time, and is where readers and
        # drives get plugged in. Never rank a docked machine below MEDIUM.
        { $dock.Count -gt 0 }         { 'MEDIUM', "Dock present, may carry a reader: $($dock -join ',')"; break }
        { $devices.Count -gt 0 -and $daysSince -eq $null } { 'UNKNOWN', "$($devices.Count) USB device(s) but timestamps unreadable, re-run elevated"; break }
        { $devices.Count -gt 0 }      { 'LOW', 'USB storage history but none recent'; break }
        default                       { 'LOW', 'No USB storage history recorded' }
    }

    $result = [pscustomobject]@{
        Computer        = $env:COMPUTERNAME
        CollectorVer    = $collectorVer
        Affected        = $affected
        RiskTier        = if ($affected) { $tier } else { "n/a-$tier" }
        Why             = $why
        DaysSinceUSB    = if ($daysSince -ne $null) { $daysSince } else { 'never' }
        LastUSBDevice   = ($devices | Where-Object LastArrival | Sort-Object LastArrival -Descending |
                            Select-Object -First 1).Name
        UsbDevicesEver  = $devices.Count
        UsbDevices90d   = $recentCount
        CardReader      = ($cardReaders -join ',')
        AttachedNow     = ($liveUsbDisks -join ',')
        Dock            = ($dock -join ',')
    }

    if ($AsObject) { $result }
    else { ($result.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|' }
}
catch {
    "Computer=$env:COMPUTERNAME|RiskTier=ERROR|Why=$($_.Exception.Message)"
}
finally {
    $global:LASTEXITCODE = 0
}
exit 0
