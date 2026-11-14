#Requires -Version 5.1
<#
.SYNOPSIS
    Live snapshot of USB hardware currently attached to a device: docks, card
    readers, dictation hardware, and USB mass storage.

.DESCRIPTION
    Uses -PresentOnly so this reports what is physically connected AT RUN TIME,
    not historical registry leftovers.

    This is a snapshot, not a guarantee. A dock unplugged before the scan will be
    missed. Run during business hours, and run it more than once.

    Read only. Safe fleet wide as SYSTEM via ConnectWise RMM.
#>

[CmdletBinding()]
param(
    # Readable object instead of the one line RMM string.
    [switch]$AsObject,

    # Emit CSV (header + row) instead of pipe delimited. Some RMM result exports
    # handle this better. Values are quoted, so commas inside are safe.
    [switch]$Csv,

    # Opt in ONLY. Also drop the result to a local file as a fallback if the RMM
    # result export is awkward. This is the script's only write, and it writes
    # nothing outside its own folder.
    [switch]$WriteLocalCopy,

    [string]$LocalPath = "$env:ProgramData\FortiPreflight\usb-inventory.csv"
)

$ErrorActionPreference = 'SilentlyContinue'

try {
    $present = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.Status -eq 'OK' }

    # --- Docks ------------------------------------------------------------------
    $dock = @($present | Where-Object {
        $_.FriendlyName -match 'Dock|Anker|Kensington|Targus|Plugable|StarTech|WavLink|ThinkPad.*USB-C|Thunderbolt.*Dock|HP.*Dock|Dell.*Dock'
    } | Select-Object -ExpandProperty FriendlyName -Unique)

    # --- Card readers (enumerate as USB storage with no user action) ------------
    $reader = @($present | Where-Object {
        $_.FriendlyName -match 'Card Reader|SD Host Adapter|RTS5\d{3}|SDXC|MMC.*Reader|USB.*SD'
    } | Select-Object -ExpandProperty FriendlyName -Unique)

    # --- Dictation hardware -----------------------------------------------------
    # Olympus/OM recorders in a cradle mount as USB mass storage, which is exactly
    # the trigger for FortiEDR bug 1326457. Foot pedals and mics do not.
    $dictation = @($present | Where-Object {
        $_.FriendlyName -match 'Olympus|OM SYSTEM|DS-?\d{4}|AS-?\d{4}|DirectRec|SpeechMike|Philips.*Speech|PowerMic|Nuance|Foot.*(Control|Switch|Pedal)|RS-?2[678]|Dictaphone|Winscribe'
    } | Select-Object -ExpandProperty FriendlyName -Unique)

    # --- USB mass storage attached right now ------------------------------------
    # This is the list that actually matters for the bug: devices creating a disk object.
    $usbDisks = @(Get-CimInstance Win32_DiskDrive |
        Where-Object { $_.InterfaceType -eq 'USB' } |
        ForEach-Object { "$($_.Model) [$([math]::Round($_.Size/1GB,0))GB]" })

    # Generic catch-all: anything currently enumerated under USBSTOR.
    $usbStorPresent = @($present | Where-Object { $_.InstanceId -like 'USBSTOR\*' } |
        Select-Object -ExpandProperty FriendlyName -Unique)

    # --- Every USB device, for the "what did I miss" column ---------------------
    $allUsb = @($present | Where-Object { $_.InstanceId -like 'USB\*' } |
        Select-Object -ExpandProperty FriendlyName -Unique)

    # --- Collector version, so the sheet is self contained ----------------------
    $drv = Get-ChildItem "$env:SystemRoot\System32\drivers\FortiEDRWinDriver*.sys" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $collectorVer = if ($drv) { $drv.VersionInfo.FileVersion } else { 'None' }

    # Anything creating a disk object, or able to, while on 1437.
    $triggers = @($usbDisks + $usbStorPresent + $reader | Where-Object { $_ } | Select-Object -Unique)

    $result = [pscustomobject]@{
        Computer       = $env:COMPUTERNAME
        ScanTime       = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        CollectorVer   = $collectorVer
        OnBadCollector = ($collectorVer -match '6\.2\.0\.1437')
        TriggerCount   = $triggers.Count
        Triggers       = ($triggers  -join ' / ')
        Docks          = ($dock      -join ' / ')
        CardReaders    = ($reader    -join ' / ')
        Dictation      = ($dictation -join ' / ')
        UsbDisks       = ($usbDisks  -join ' / ')
        AllUsbDevices  = ($allUsb    -join ' / ')
    }

    if ($WriteLocalCopy) {
        try {
            $dir = Split-Path $LocalPath -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $result | Export-Csv -Path $LocalPath -NoTypeInformation -Encoding UTF8 -Force
        } catch { }   # a failed fallback must never fail the scan
    }

    if     ($AsObject) { $result }
    elseif ($Csv)      { $result | ConvertTo-Csv -NoTypeInformation }
    else   { ($result.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|' }
}
catch {
    "Computer=$env:COMPUTERNAME|ScanTime=ERROR|Triggers=$($_.Exception.Message)"
}
finally { $global:LASTEXITCODE = 0 }
exit 0
