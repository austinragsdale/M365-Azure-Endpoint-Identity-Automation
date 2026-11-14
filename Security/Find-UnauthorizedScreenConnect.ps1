#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Read-only hunt for rogue ScreenConnect / SCKit indicators (November 2026 MSP campaign).

.DESCRIPTION
    Built for ConnectWise RMM deployment (runs as SYSTEM, Windows PowerShell 5.1).
    Makes NO changes to the device. Nothing is removed, stopped, or quarantined.

    Indicator sources (verify against the latest published lists before each run):
      - Huntress: "SCKit Worm Installs Rogue ScreenConnect Clients and Session Cookie Relays"
      - ConnectWise Trust Center ScreenConnect advisory (updated 2026-11-13)
      - Sophos origin instance IDs as republished by Inception Security

    The strongest generic check is "any ScreenConnect-style client that is NOT ours".
    Hash and filename checks are weak on their own: the attacker rebuilds scripts per
    victim and compiles RelayTrap.exe per host.

    Output: first line is "RESULT: CLEAN | REVIEW | SUSPICIOUS | COMPROMISED", then findings.
    Exit codes: 0 = clean or info only, 1 = medium/high findings, 2 = critical findings,
    3 = script error.

.PARAMETER AllowedThumbprints
    ScreenConnect client thumbprints (the 16 hex in the service name) that belong to you.
    Required: pass it, or set the default in the param block for a pasted RMM copy.

.PARAMETER AllowedRelayHosts
    Relay hosts (h= value in the client service command line) that belong to you.
    Required: pass it, or set the default in the param block for a pasted RMM copy.

.PARAMETER SkipUserTempScan
    Skip scanning C:\Users\*\AppData\Local\Temp (fastest run).

.PARAMETER AlwaysExitZero
    Always exit 0 so the RMM task row reports success and later rows (Set Custom Field) still run.
    Status is then read from the RESULT line. For a pasted RMM copy, set the default:
    [switch]$AlwaysExitZero = $true

.EXAMPLE
    .\Find-UnauthorizedScreenConnect.ps1 -AllowedThumbprints '0123456789abcdef' -AllowedRelayHosts 'instance-xxxxxx-relay.screenconnect.com'

.EXAMPLE
    .\Find-UnauthorizedScreenConnect.ps1 -AllowedThumbprints '0123456789abcdef','fedcba9876543210' -AllowedRelayHosts 'instance-xxxxxx-relay.screenconnect.com' -AlwaysExitZero

.NOTES
    Author: Austin Ragsdale
#>
[CmdletBinding()]
param(
    [string[]]$AllowedThumbprints = @(),
    [string[]]$AllowedRelayHosts  = @(),
    [switch]$SkipUserTempScan,
    [switch]$AlwaysExitZero
)

# --- Relaunch in 64-bit PowerShell if the RMM agent started a 32-bit host (registry and System32 redirection) ---
# Only possible when running from a .ps1 file; pasted/inline execution has no $PSCommandPath and continues in place
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $PSCommandPath) {
    $ps64 = Join-Path $env:windir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $ps64) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        if ($AllowedThumbprints) { $argList += '-AllowedThumbprints'; $argList += ($AllowedThumbprints -join ',') }
        if ($AllowedRelayHosts)  { $argList += '-AllowedRelayHosts';  $argList += ($AllowedRelayHosts -join ',') }
        if ($SkipUserTempScan)   { $argList += '-SkipUserTempScan' }
        if ($AlwaysExitZero)     { $argList += '-AlwaysExitZero' }
        & $ps64 @argList
        exit $LASTEXITCODE
    }
}

# Allow comma-joined values from RMM parameter fields
$AllowedThumbprints = @($AllowedThumbprints | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$AllowedRelayHosts  = @($AllowedRelayHosts  | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
if ($AllowedThumbprints.Count -eq 0 -or $AllowedRelayHosts.Count -eq 0) {
    Write-Output 'RESULT: ERROR - set -AllowedThumbprints and -AllowedRelayHosts to your own ScreenConnect instance.'
    exit $(if ($AlwaysExitZero) { 0 } else { 3 })
}

#region Indicators
$RogueIds = @(
    '2588ef5c15954b10'  # attacker client ID (Huntress, high confidence)
    'ed630cc2c873b091'  # attacker client ID (Huntress, high confidence)
    'de362a425905bcc4'  # "Windows Update Agent (de362a425905bcc4)" rogue client folder
    'd905b2b1b165d0a9'  # Sophos origin instance ID (incomplete list)
    '4b8f4089ddaac6a9'  # Sophos origin instance ID (incomplete list)
    'df1f7ef0cfacd0d8'  # Sophos origin instance ID (incomplete list)
)
$IocIps = @('185.99.255.28', '155.94.150.39', '185.241.211.197')
$IocDomains = @(
    'newnewnew.gotdns.org', 'soxnewwork.homedns.org', 'sc.payproofkit.com', 'payproofkit.com',
    'cdn007-digitaldownloads.com', 'ns.mo7sen.dev', 'mo7sen.dev', '007.from-ak.com', 'from-ak.com'
)
$ToolkitNames = @(
    'Panel-Lateral-free.ps1', 'Panel-Lateral.ps1', 'LabConfig.ps1', 'lab-context.json', 'RelayTrap.cs',
    'RelayTrap.exe', 'TrapWatch.ps1', 'Lite-Alert.ps1', 'Stage0Loader.ps1', 'Release-Machine.cmd',
    'Recover-ExecutionPolicy.cmd', 'TRAP-PROOF.bat', 'Stop-LabTrap.bat', 'Stop-LabTrap.ps1',
    'Run-Lateral-Full.bat', 'runnew.cmd', 'sckit-loader.ps1', 'ToolboxRelayUploader.exe',
    'WithUninstall.ps1', 'SilentForceInstall-WithUninstall.ps1', 'lab-trap-cleanup-embedded.ps1', 'RELAY-TRAP-PROOF.txt',
    'UpdateConnect.ClientService.exe', 'UpdateConnect.ClientSetup.msi'
)
# install.ps1 and sqlite3.exe are generic names; they are hash-checked or reported as INFO only
$KnownHashes = @{
    '94b93c649b0ae0281352da9d01761fa9195ab1e6ac7010af3b9ba1646355eb11' = 'Panel-Lateral-free.ps1'
    '7a9aca9fdd4dcc13fe497cabdb13ca1e5d6a529271c8aa495e5ca1c1c80271ec' = 'Panel-Lateral.ps1'
    'b93f10f30ee453d1e1c046fec9d141c41d7680be5cd46c3aeb3febe0f4953b4d' = 'LabConfig.ps1'
    '3c7a98f0fdb6235b8076319c74dc1085f7b349b6d750416dd0cadb07d7972ec4' = 'RelayTrap.cs'
    'd2ed7a7bf4f8ac9c7969e9b3a07ebd4dda0d858f372c876ac0a041611698de9a' = 'TrapWatch.ps1'
    '4a1dd3cd2ea14368afadf7e9dfdd63b104e3981ef8c85bbb6510919b810af04b' = 'install.ps1'
    '8cb5f48bbe70b5248db7f327f3d1ad6649df5c767d2a7e0711ee147fd92e06af' = 'ToolboxRelayUploader.exe'
    'cf50d73fa8117a758093b1344de41cd6a6ccddc645cdda1fa91a9264efe93956' = 'Lite-Alert.ps1'
    '81cc2baa35b798d6084bd078662fa29ff28df02c46c6ccdb2b43bde97d19f781' = 'Stage0Loader.ps1'
    'c31e6f075cd77e01839aebce32ed35659a9ee962d102aca53040bb5e297410a9' = 'Release-Machine.cmd'
    'deda7c30d798a19b6699a45fbcba503cf778594df9163c61c2f96bb2d2b9fb45' = 'Recover-ExecutionPolicy.cmd'
    '0bd84c776dc01f784a617e73fc77b269f847fc4a062ffd489e4692869724bf08' = 'lab-context.json'
    '454c43d296b1276bde9a4f6ff1da2221cb35ccdb2fc7991bdd572e45bce12a8a' = 'TRAP-PROOF.bat'
    '5dd3a6ba806ac472663e243cfc1c034c534d5d9a42ec362c3dbf0f8d950148d0' = 'Stop-LabTrap.bat'
    '43b7a5e56f9e6c7b74e1ce2b7b5af63f383084625fcc2d3a5985fa1059e2db95' = 'Run-Lateral-Full.bat'
    '50659748723e906c8b3d3c0386bd4cf692f693a3e23639398c1a14d0c31fed61' = 'runnew.cmd'
    # Blackpoint additions
    'a1937467fd862916f89342cdd61f55c4bc405fb35b6e1379e27cfbfdba77dcdc' = 'SilentForceInstall-WithUninstall.ps1'
    '338e37f58043635ebab64ee5fdc919935e55cb146ca97834b358f934e55e88ec' = 'p=4 decoder'
    '8e6912deed82e80bb6bd66f73509d024b1f78b993515366d8317e69a97cff4f4' = 'p=3 decoded bundle'
    'd85315bd7602b6f5c13dc0eada2c9cba0892c7cd3b1eb7dacb1bffdd536ceb21' = 'attacker ScreenConnect.ClientSetup.msi'
}
$StringIocPattern = 'RelayTrap|TrapWatch|sckit|UpdateConnect|Lite-Alert|Stage0Loader|mo7sen|payproofkit|gotdns|homedns|from-ak\.com|cdn007-digitaldownloads'
#endregion

#region Helpers
$script:Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param(
        [ValidateSet('CRITICAL', 'HIGH', 'MEDIUM', 'INFO')][string]$Severity,
        [string]$Check,
        [string]$Detail
    )
    $script:Findings.Add([pscustomobject]@{ Severity = $Severity; Check = $Check; Detail = $Detail })
}
function Invoke-Check {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body }
    catch { Add-Finding -Severity 'INFO' -Check $Name -Detail "Check failed: $($_.Exception.Message)" }
}
function Get-ScIdFromText {
    param([string]$Text)
    $m = [regex]::Matches($Text, '\(([0-9a-fA-F]{16})\)')
    foreach ($x in $m) { $x.Groups[1].Value.ToLower() }
}
function Get-Sha256 {
    # .NET instead of Get-FileHash so it works regardless of the host's module path
    param([string]$Path)
    $stream = $null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLower()
    }
    catch { return $null }
    finally { if ($stream) { $stream.Dispose() }; $sha.Dispose() }
}
function Test-RogueIdInText {
    param([string]$Text)
    foreach ($id in $RogueIds) { if ($Text -match $id) { return $id } }
    return $null
}
#endregion

$scanStart = Get-Date

# 1. Services: every ScreenConnect-style client service, matched by binary not by display name
Invoke-Check 'Services' {
    $svcs = Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
        $_.Name -match 'ScreenConnect|UpdateConnect|Windows Update Agent' -or
        $_.PathName -match '\.ClientService\.exe|ScreenConnect|UpdateConnect|RelayTrap|[?&]y=Guest&h='
    }
    foreach ($s in $svcs) {
        $text  = "$($s.Name) $($s.DisplayName) $($s.PathName)"
        $rogue = Test-RogueIdInText $text
        $relay = ([regex]::Match([string]$s.PathName, '[?&]h=([^&"]+)')).Groups[1].Value.ToLower()
        $ids   = @(Get-ScIdFromText $text)
        $desc  = "Service '$($s.Name)' State=$($s.State) Start=$($s.StartMode) Relay='$relay' Path=$($s.PathName)"

        if ($rogue) { Add-Finding 'CRITICAL' 'Services' "Known rogue ID $rogue. $desc"; continue }
        if ($text -match 'UpdateConnect|RelayTrap') { Add-Finding 'CRITICAL' 'Services' "SCKit persistence service. $desc"; continue }
        if ($s.Name -match '^Windows Update Agent' -and $s.PathName -match '\.ClientService\.exe') {
            Add-Finding 'CRITICAL' 'Services' "ScreenConnect client disguised as 'Windows Update Agent'. $desc"; continue
        }

        $isOurs = $false
        foreach ($id in $ids) { if ($AllowedThumbprints -contains $id) { $isOurs = $true } }
        if ($relay -and ($AllowedRelayHosts -notcontains $relay)) { $isOurs = $false }

        if (-not $isOurs) {
            Add-Finding 'HIGH' 'Services' "ScreenConnect client NOT on the allow list (may be a customer or vendor instance, verify). $desc"
        }
        elseif ($s.State -ne 'Running' -or $s.StartMode -ne 'Auto') {
            # SCKit stops our client and sets it to manual, then runs its own copy
            Add-Finding 'MEDIUM' 'Services' "Our ScreenConnect client is not Running/Auto (SCKit sets it to manual). $desc"
        }
    }
}

# 2. Installed programs (both registry views)
Invoke-Check 'InstalledPrograms' {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'ScreenConnect|UpdateConnect|Windows Update Agent \(' }
    foreach ($a in $apps) {
        $rogue = Test-RogueIdInText $a.DisplayName
        $ids   = @(Get-ScIdFromText $a.DisplayName)
        $desc  = "'$($a.DisplayName)' Version=$($a.DisplayVersion) InstallDate=$($a.InstallDate)"
        if ($rogue) { Add-Finding 'CRITICAL' 'InstalledPrograms' "Known rogue ID $rogue. $desc" }
        elseif ($a.DisplayName -match 'UpdateConnect|Windows Update Agent \(') { Add-Finding 'CRITICAL' 'InstalledPrograms' "SCKit client package. $desc" }
        elseif ($ids.Count -gt 0 -and -not ($ids | Where-Object { $AllowedThumbprints -contains $_ })) {
            Add-Finding 'HIGH' 'InstalledPrograms' "ScreenConnect client NOT on the allow list. $desc"
        }
    }
}

# 3. Folders: RelayTrap, disguised client folder, foreign client install folders
Invoke-Check 'Folders' {
    if (Test-Path 'C:\ProgramData\RelayTrap') {
        $items = Get-ChildItem 'C:\ProgramData\RelayTrap' -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 15 -ExpandProperty FullName
        Add-Finding 'CRITICAL' 'Folders' "C:\ProgramData\RelayTrap exists. Contents: $($items -join '; ')"
    }
    $roots = @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $roots) {
        Get-ChildItem $r -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'ScreenConnect|UpdateConnect|^Windows Update Agent \(' } |
            ForEach-Object {
                $rogue = Test-RogueIdInText $_.Name
                $ids   = @(Get-ScIdFromText $_.Name)
                $desc  = "$($_.FullName) Created=$($_.CreationTime)"
                if ($rogue) { Add-Finding 'CRITICAL' 'Folders' "Known rogue ID $rogue. $desc" }
                elseif ($_.Name -match 'UpdateConnect|^Windows Update Agent \(') { Add-Finding 'CRITICAL' 'Folders' "SCKit client folder. $desc" }
                elseif ($ids.Count -gt 0 -and -not ($ids | Where-Object { $AllowedThumbprints -contains $_ })) {
                    Add-Finding 'HIGH' 'Folders' "ScreenConnect client folder NOT on the allow list. $desc"
                }
            }
    }
}

# 4. Scheduled tasks
Invoke-Check 'ScheduledTasks' {
    $tasks = Get-ScheduledTask -ErrorAction Stop
    foreach ($t in $tasks) {
        $actions = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | '
        if ($t.TaskName -match 'TrapWatch|RelayTrap' -or $actions -match $StringIocPattern) {
            Add-Finding 'CRITICAL' 'ScheduledTasks' "Task '$($t.TaskPath)$($t.TaskName)' State=$($t.State) Actions=$actions"
        }
    }
    # Event 4698 (task created) catches a TrapWatch task that was later deleted. Needs task-creation auditing enabled.
    Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4698; StartTime = [datetime]'2026-11-01' } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'TrapWatch|RelayTrap' } |
        ForEach-Object { Add-Finding 'CRITICAL' 'ScheduledTasks' "Event 4698 at $($_.TimeCreated): TrapWatch/RelayTrap task was created" }
}

# 4b. Running processes whose command line contains campaign strings (only sees what is running now)
Invoke-Check 'Processes' {
    # Skip this script, its parent (RMM launcher), and any copy of it passed inline, which contain the IOC strings themselves
    $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
    Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
            $_.CommandLine -match "$StringIocPattern|Exploited\d+|185\.99\.255\.28|155\.94\.150\.39|185\.241\.211\.197" -and
            $_.ProcessId -ne $PID -and $_.ProcessId -ne $parentPid -and
            $_.CommandLine -notmatch 'Find-UnauthorizedScreenConnect|Add-Finding'
        } |
        ForEach-Object { Add-Finding 'CRITICAL' 'Processes' "PID $($_.ProcessId) $($_.Name): $($_.CommandLine)" }
}

# 5. Run keys (machine and every loaded user hive)
Invoke-Check 'RunKeys' {
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    if (-not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null }
    Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
        ForEach-Object { $runKeys += "HKU:\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run" }
    foreach ($k in $runKeys) {
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            if ($p.Name -match 'RelayTrap' -or [string]$p.Value -match $StringIocPattern) {
                Add-Finding 'CRITICAL' 'RunKeys' "$k : $($p.Name) = $($p.Value)"
            }
        }
    }
}

# 6. Files: Windows\Temp, Public, ScreenConnect temp, and every user's Temp
Invoke-Check 'Files' {
    $scanDirs = @("$env:windir\Temp", $env:PUBLIC, 'C:\ProgramData\RelayTrap')
    if (-not $SkipUserTempScan) {
        $scanDirs += Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue }
    }
    foreach ($d in ($scanDirs | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue })) {
        $files = Get-ChildItem $d -Recurse -Depth 3 -Force -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $hit = $null
            if ($ToolkitNames -contains $f.Name)          { $hit = 'toolkit filename' }
            elseif ($f.Name -like 'sckit-*')              { $hit = 'sckit-* filename' }
            elseif ($f.FullName -match '\\sckit-[^\\]*\\') { $hit = 'inside sckit-* folder' }
            elseif ($f.FullName -match '^C:\\Windows\\Temp\\sc\.msi$') { $hit = 'sc.msi installer drop' }
            elseif ($f.Name -match '^CWInstall_[0-9a-fA-F]{8}-c1$|^Installer\.ps1$' -and $f.DirectoryName -match 'CWInstall_[0-9a-fA-F]{8}-c1') { $hit = 'CWInstall_*-c1 installer' }
            elseif ($f.Name -match '^k[0-9a-fA-F]{32}\.ps1$') { $hit = 'k<32 hex>.ps1 loader' }

            $hash = $null
            if ($hit -or ($f.Extension -match '^\.(ps1|bat|cmd|exe|cs|json)$' -and $f.Length -lt 20MB -and $f.Name -match 'install|lateral|trap|relay|loader|lab|stage0|runnew|withuninstall')) {
                $hash = Get-Sha256 $f.FullName
                if ($hash -and $KnownHashes.ContainsKey($hash.ToLower())) {
                    Add-Finding 'CRITICAL' 'Files' "Known SCKit hash ($($KnownHashes[$hash.ToLower()])): $($f.FullName) Modified=$($f.LastWriteTime)"
                    continue
                }
            }
            if ($hit) { Add-Finding 'CRITICAL' 'Files' "$hit : $($f.FullName) Modified=$($f.LastWriteTime) SHA256=$hash" }
            elseif ($f.Name -eq 'sqlite3.exe') { Add-Finding 'INFO' 'Files' "sqlite3.exe in temp (legit tool, abused for cookie theft; correlate): $($f.FullName) Modified=$($f.LastWriteTime)" }
        }
    }
}

# 7. netsh portproxy (127.0.0.1:88 to 185.241.211.197:80 seen in the 11-13 wave)
Invoke-Check 'PortProxy' {
    foreach ($kind in 'v4tov4', 'v4tov6', 'v6tov4', 'v6tov6') {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\$kind\tcp"
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            $entry = "$kind listen=$($p.Name) connect=$($p.Value)"
            $sev = 'MEDIUM'
            foreach ($ip in $IocIps) { if ([string]$p.Value -match [regex]::Escape($ip)) { $sev = 'CRITICAL' } }
            if ($p.Name -match '(^|\/)88$') { $sev = 'CRITICAL' }
            Add-Finding $sev 'PortProxy' "Port proxy rule present: $entry"
        }
    }
}

# 8. Hosts file
Invoke-Check 'HostsFile' {
    $hostsPath = "$env:windir\System32\drivers\etc\hosts"
    $lines = Get-Content $hostsPath -ErrorAction Stop | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() }
    foreach ($l in $lines) {
        $hit = $false
        foreach ($i in ($IocDomains + $IocIps)) { if ($l -match [regex]::Escape($i)) { $hit = $true } }
        if ($hit) { Add-Finding 'CRITICAL' 'HostsFile' "IOC in hosts file: $l" }
        elseif ($l -match 'screenconnect|connectwise') { Add-Finding 'HIGH' 'HostsFile' "ScreenConnect-related hosts entry: $l" }
    }
    $hf = Get-Item $hostsPath
    if ($hf.LastWriteTime -gt [datetime]'2026-11-01') { Add-Finding 'INFO' 'HostsFile' "hosts file modified $($hf.LastWriteTime) (SCKit modifies hosts; correlate)" }
}

# 9. Live network: DNS cache and TCP connections
Invoke-Check 'Network' {
    $dns = Get-DnsClientCache -ErrorAction SilentlyContinue
    foreach ($e in $dns) {
        foreach ($d in $IocDomains) {
            if ($e.Entry -like "*$d") { Add-Finding 'HIGH' 'Network' "DNS cache has IOC domain: $($e.Entry) -> $($e.Data)" }
        }
        if ($IocIps -contains [string]$e.Data) { Add-Finding 'HIGH' 'Network' "DNS cache resolves to IOC IP: $($e.Entry) -> $($e.Data)" }
    }
    $conns = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $IocIps -contains $_.RemoteAddress }
    foreach ($c in $conns) {
        $proc = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).Path
        Add-Finding 'CRITICAL' 'Network' "TCP $($c.State) to $($c.RemoteAddress):$($c.RemotePort) by PID $($c.OwningProcess) $proc"
    }
}

# 10. Defender exclusions (Installer.ps1 adds them)
Invoke-Check 'DefenderExclusions' {
    $all = @()
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $all = @($mp.ExclusionPath) + @($mp.ExclusionProcess) + @($mp.ExclusionExtension)
    }
    catch {
        $mpError = $_.Exception.Message
        # 0x800106ba = Defender service not running (third-party AV is primary). Read the stored exclusions from the registry instead.
        $exKeys = foreach ($base in 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions') {
            foreach ($sub in 'Paths', 'Processes', 'Extensions') { Join-Path $base $sub }
        }
        $readable = $false
        foreach ($k in $exKeys) {
            try {
                $props = Get-ItemProperty $k -ErrorAction Stop
                $readable = $true
                $all += $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name }
            }
            catch [System.Management.Automation.ItemNotFoundException] { $readable = $true }
            catch { }
        }
        if (-not $readable) { Add-Finding 'INFO' 'DefenderExclusions' "Defender not running and exclusion keys not readable (run as SYSTEM): $mpError" }
    }
    $all = $all | Where-Object { $_ }
    foreach ($x in $all) {
        if ($x -match $StringIocPattern -or $x -match 'Windows Update Agent') {
            Add-Finding 'CRITICAL' 'DefenderExclusions' "Exclusion matches SCKit artifact: $x"
        }
        elseif ($x -match '(^|\\)(msiexec|powershell)\.exe$') {
            # Blackpoint: the campaign adds process exclusions for msiexec.exe / powershell.exe
            Add-Finding 'HIGH' 'DefenderExclusions' "Process exclusion for $x (SCKit adds these; rarely legitimate)"
        }
        elseif ($x -match 'ScreenConnect|\\Temp\\?$|\\ProgramData\\?$|^C:\\?$|\.ps1$|\.bat$|\.cmd$') {
            Add-Finding 'MEDIUM' 'DefenderExclusions' "Broad or remote-access exclusion (verify it is ours): $x"
        }
    }
}

# 11. SRP / AppLocker path rules aimed at ScreenConnect temp folders
Invoke-Check 'SoftwareRestriction' {
    $srp = Get-ChildItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.ItemData -match 'ScreenConnect|\\Temp' }
    foreach ($r in $srp) { Add-Finding 'MEDIUM' 'SoftwareRestriction' "SRP rule: $($r.ItemData) ($($r.PSPath -replace '^.*::',''))" }
    $al = Get-ChildItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.Value -match 'ScreenConnect' }
    foreach ($r in $al) { Add-Finding 'MEDIUM' 'SoftwareRestriction' "AppLocker rule references ScreenConnect: $($r.PSPath -replace '^.*::','')" }
}

# 12. MSI install history since the campaign window
Invoke-Check 'MsiInstallHistory' {
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033, 11707; StartTime = [datetime]'2026-11-01' } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'ScreenConnect|UpdateConnect|Windows Update Agent' }
    foreach ($e in $events) {
        $rogue = Test-RogueIdInText $e.Message
        $ids   = @(Get-ScIdFromText $e.Message)
        $msg   = ($e.Message -replace '\s+', ' ')
        if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) }
        if ($rogue -or $e.Message -match 'UpdateConnect|Windows Update Agent') { Add-Finding 'CRITICAL' 'MsiInstallHistory' "$($e.TimeCreated): $msg" }
        elseif ($ids.Count -gt 0 -and -not ($ids | Where-Object { $AllowedThumbprints -contains $_ })) { Add-Finding 'HIGH' 'MsiInstallHistory' "$($e.TimeCreated): $msg" }
    }
}

# 13. Technician client version (technician workstations only; 26.6.5+ blocks the reverse pivot)
Invoke-Check 'TechnicianClient' {
    # ClickOnce keeps old copies in the cache, so judge only the newest version per user profile
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $profileName = $_.Name
        $apps = Join-Path $_.FullName 'AppData\Local\Apps\2.0'
        if (-not (Test-Path $apps)) { return }
        $newest = Get-ChildItem $apps -Recurse -Depth 4 -Filter 'ScreenConnect.WindowsClient.exe' -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $ver = $null
                try { $ver = [version]($_.VersionInfo.FileVersion -replace '[^\d\.]', '') } catch { }
                [pscustomobject]@{ Version = $ver; Path = $_.FullName }
            } | Where-Object { $_.Version } | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $newest) { return }
        if ($newest.Version -lt [version]'26.6.5') {
            Add-Finding 'MEDIUM' 'TechnicianClient' "Profile '$profileName' newest technician client is v$($newest.Version), older than 26.6.5 (reverse-pivot exposure). Relaunch from the instance to update."
        }
        else { Add-Finding 'INFO' 'TechnicianClient' "Profile '$profileName' technician client v$($newest.Version)" }
    }
}

# --- Report ---
try {
    $order = @{ CRITICAL = 0; HIGH = 1; MEDIUM = 2; INFO = 3 }
    $sorted = $script:Findings | Sort-Object { $order[$_.Severity] }, Check
    $crit = @($script:Findings | Where-Object Severity -eq 'CRITICAL').Count
    $high = @($script:Findings | Where-Object Severity -eq 'HIGH').Count
    $med  = @($script:Findings | Where-Object Severity -eq 'MEDIUM').Count

    $status = 'CLEAN'; $exit = 0
    if ($med)  { $status = 'REVIEW';      $exit = 1 }
    if ($high) { $status = 'SUSPICIOUS';  $exit = 1 }
    if ($crit) { $status = 'COMPROMISED'; $exit = 2 }

    $secs = [int]((Get-Date) - $scanStart).TotalSeconds
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    Write-Output "RESULT: $status | Host=$env:COMPUTERNAME | Critical=$crit High=$high Medium=$med | ${secs}s | $arch | $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    if ($crit) { Write-Output 'ACTION: Do NOT connect to this device with ScreenConnect. Isolate with EDR and escalate.' }
    foreach ($f in $sorted) { Write-Output "[$($f.Severity)] $($f.Check): $($f.Detail)" }
    if ($AlwaysExitZero) { exit 0 }
    exit $exit
}
catch {
    Write-Output "RESULT: ERROR | Host=$env:COMPUTERNAME | $($_.Exception.Message)"
    if ($AlwaysExitZero) { exit 0 }
    exit 3
}
