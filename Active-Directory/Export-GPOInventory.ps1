#Requires -Version 5.1
#Requires -Modules GroupPolicy, ActiveDirectory
<#
.SYNOPSIS
    Read-only Group Policy inventory for one AD domain, built for cloud migration discovery.

.DESCRIPTION
    For every GPO in the domain, reports status, links (domain, OU, site), enforcement, security
    filtering, WMI filter, AD/SYSVOL version match, and which setting areas each side actually
    configures (Registry, Security, Drive Maps, Folder Redirection, Scripts, and so on).

    Each GPO is classified as Active or Inactive, with the reason (unlinked, links disabled,
    all settings disabled, empty, no Apply permission).

    Also lists the GPOs in effect on the Domain Controllers OU, and with -IncludeDCRsop pulls the
    resultant computer policy from every DC using gpresult.

    Makes NO changes to Active Directory or Group Policy. It only writes report files to OutputPath.

.PARAMETER Domain
    DNS name of the domain to inventory. Defaults to the domain of the current machine.

.PARAMETER Server
    Domain controller to query. Defaults to the PDC emulator of the domain.

.PARAMETER OutputPath
    Parent folder for the report. A timestamped subfolder is created per run.

.PARAMETER IncludeDCRsop
    Runs gpresult against every DC in the domain to capture what policy actually applied.
    Requires local admin on each DC and remote RPC access.

.PARAMETER SkipHtmlReports
    Skips the per-GPO HTML settings reports (faster on large domains).

.EXAMPLE
    .\Export-GPOInventory.ps1

.EXAMPLE
    .\Export-GPOInventory.ps1 -IncludeDCRsop -OutputPath C:\Temp\Discovery
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$Server,
    [string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'GPO-Inventory'),
    [switch]$IncludeDCRsop,
    [switch]$SkipHtmlReports
)

$ErrorActionPreference = 'Stop'

# GPO and RSoP report XML elements named "Name" collide with the XmlElement .Name property,
# so child values are always read by LocalName.
function Get-NodeText {
    param($Node, [string]$LocalName)
    if (-not $Node) { return $null }
    $child = $Node.ChildNodes | Where-Object { $_.LocalName -eq $LocalName } | Select-Object -First 1
    if ($child) { $child.InnerText }
}

function Get-ChildNodes {
    param($Node, [string]$LocalName)
    if (-not $Node) { return @() }
    @($Node.ChildNodes | Where-Object { $_.LocalName -eq $LocalName })
}

function Get-SafeFileName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
    ($Name -replace "[$([regex]::Escape($invalid))]", '_').Trim()
}

# --- Domain and output folder ------------------------------------------------
try {
    $adParams = @{}
    if ($Server) { $adParams.Server = $Server }
    $adDomain = if ($Domain) { Get-ADDomain -Identity $Domain @adParams } else { Get-ADDomain @adParams }
}
catch {
    throw "Could not read domain '$Domain'. Run this from a DC or a domain-joined machine with RSAT in that domain. $($_.Exception.Message)"
}

$dns = $adDomain.DNSRoot
if (-not $Server) { $Server = $adDomain.PDCEmulator }
$gpParams = @{ Domain = $dns; Server = $Server }

$runFolder = Join-Path $OutputPath ('{0}_{1:yyyyMMdd-HHmm}' -f $dns, (Get-Date))
$htmlFolder = Join-Path $runFolder 'GPO-Reports'
try {
    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    if (-not $SkipHtmlReports) { New-Item -ItemType Directory -Path $htmlFolder -Force | Out-Null }
}
catch {
    throw "Could not create output folder '$runFolder'. $($_.Exception.Message)"
}

Write-Host "Domain: $dns   DC queried: $Server" -ForegroundColor Cyan
Write-Host "Output: $runFolder`n" -ForegroundColor Cyan

# --- GPO inventory -----------------------------------------------------------
try {
    $gpos = @(Get-GPO -All @gpParams | Sort-Object DisplayName)
}
catch {
    throw "Get-GPO failed against $Server. $($_.Exception.Message)"
}

$summary = New-Object System.Collections.Generic.List[object]
$linkRows = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($gpo in $gpos) {
    $i++
    Write-Progress -Activity 'Reading GPOs' -Status $gpo.DisplayName -PercentComplete (($i / $gpos.Count) * 100)

    try {
        [xml]$report = Get-GPOReport -Guid $gpo.Id -ReportType Xml @gpParams
    }
    catch {
        Write-Warning "Skipping '$($gpo.DisplayName)': report failed. $($_.Exception.Message)"
        continue
    }

    $root = $report.DocumentElement
    $compNode = Get-ChildNodes $root 'Computer' | Select-Object -First 1
    $userNode = Get-ChildNodes $root 'User' | Select-Object -First 1
    $compExt = @(Get-ChildNodes $compNode 'ExtensionData' | ForEach-Object { Get-NodeText $_ 'Name' })
    $userExt = @(Get-ChildNodes $userNode 'ExtensionData' | ForEach-Object { Get-NodeText $_ 'Name' })

    # Links (domain root, OUs, and sites)
    # @() matters: a single link comes back as a bare XmlElement whose .Count is empty in PS 5.1
    $links = @(Get-ChildNodes $root 'LinksTo')
    foreach ($link in $links) {
        $linkRows.Add([pscustomobject]@{
            GPO         = $gpo.DisplayName
            LinkedTo    = Get-NodeText $link 'SOMPath'
            LinkEnabled = (Get-NodeText $link 'Enabled') -eq 'true'
            Enforced    = (Get-NodeText $link 'NoOverride') -eq 'true'
            GpoStatus   = $gpo.GpoStatus
        })
    }
    $enabledLinks = @($links | Where-Object { (Get-NodeText $_ 'Enabled') -eq 'true' })

    # Security filtering: who actually has Apply Group Policy
    try {
        $applyTo = @(Get-GPPermission -Guid $gpo.Id -All @gpParams |
            Where-Object { $_.Permission -eq 'GpoApply' } |
            ForEach-Object { $_.Trustee.Name })
    }
    catch {
        Write-Warning "Could not read permissions on '$($gpo.DisplayName)'. $($_.Exception.Message)"
        $applyTo = @('<unreadable>')
    }

    $compSideOn = $gpo.GpoStatus -notin 'AllSettingsDisabled', 'ComputerSettingsDisabled'
    $userSideOn = $gpo.GpoStatus -notin 'AllSettingsDisabled', 'UserSettingsDisabled'
    $hasEffectiveSettings = ($compSideOn -and $compExt.Count) -or ($userSideOn -and $userExt.Count)

    $issues = @()
    if (-not $links.Count) { $issues += 'Unlinked' }
    elseif (-not $enabledLinks.Count) { $issues += 'AllLinksDisabled' }
    if ($gpo.GpoStatus -eq 'AllSettingsDisabled') { $issues += 'AllSettingsDisabled' }
    if (-not ($compExt.Count -or $userExt.Count)) { $issues += 'Empty' }
    elseif (-not $hasEffectiveSettings) { $issues += 'SettingsOnlyOnDisabledSide' }
    if (-not $applyTo.Count) { $issues += 'NoApplyPermission' }

    $versionMismatch = ($gpo.Computer.DSVersion -ne $gpo.Computer.SysvolVersion) -or
                       ($gpo.User.DSVersion -ne $gpo.User.SysvolVersion)

    $summary.Add([pscustomobject]@{
        GPO                = $gpo.DisplayName
        Active             = -not $issues.Count
        Issues             = $issues -join '; '
        GpoStatus          = $gpo.GpoStatus
        EnabledLinks       = $enabledLinks.Count
        LinkedTo           = ($enabledLinks | ForEach-Object { Get-NodeText $_ 'SOMPath' }) -join '; '
        Enforced           = [bool]($enabledLinks | Where-Object { (Get-NodeText $_ 'NoOverride') -eq 'true' })
        ComputerSettings   = $compExt -join '; '
        UserSettings       = $userExt -join '; '
        SecurityFiltering  = $applyTo -join '; '
        WmiFilter          = $gpo.WmiFilter.Name
        ADSysvolMismatch   = $versionMismatch
        Created            = $gpo.CreationTime
        Modified           = $gpo.ModificationTime
        Owner              = $gpo.Owner
        Id                 = $gpo.Id
    })

    if (-not $SkipHtmlReports) {
        try {
            $htmlPath = Join-Path $htmlFolder ((Get-SafeFileName $gpo.DisplayName) + '.html')
            Get-GPOReport -Guid $gpo.Id -ReportType Html -Path $htmlPath @gpParams
        }
        catch {
            Write-Warning "HTML report failed for '$($gpo.DisplayName)'. $($_.Exception.Message)"
        }
    }
}
Write-Progress -Activity 'Reading GPOs' -Completed

$summary | Export-Csv (Join-Path $runFolder 'GPO-Summary.csv') -NoTypeInformation -Encoding UTF8
$linkRows | Export-Csv (Join-Path $runFolder 'GPO-Links.csv') -NoTypeInformation -Encoding UTF8

# --- GPOs in effect on the Domain Controllers OU -----------------------------
# Get-GPInheritance covers domain and OU links only. Site-linked GPOs appear in GPO-Links.csv.
try {
    $dcInherited = (Get-GPInheritance -Target $adDomain.DomainControllersContainer @gpParams).InheritedGpoLinks |
        Select-Object Order, DisplayName, Enabled, Enforced, Target
    $dcInherited | Export-Csv (Join-Path $runFolder 'DomainControllersOU-Inheritance.csv') -NoTypeInformation -Encoding UTF8
}
catch {
    Write-Warning "Could not read inheritance on the Domain Controllers OU. $($_.Exception.Message)"
    $dcInherited = @()
}

# --- Optional: resultant computer policy from each DC ------------------------
$rsopRows = New-Object System.Collections.Generic.List[object]
if ($IncludeDCRsop) {
    $dcs = @(Get-ADDomainController -Filter * -Server $Server | Sort-Object HostName)
    foreach ($dc in $dcs) {
        $xmlPath = Join-Path $runFolder ("RSoP-{0}.xml" -f $dc.Name)
        Write-Host "gpresult against $($dc.HostName)..." -ForegroundColor Gray
        $null = & gpresult.exe /s $dc.HostName /scope computer /x $xmlPath /f 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $xmlPath)) {
            Write-Warning "gpresult failed on $($dc.HostName) (exit $LASTEXITCODE). Needs local admin on the DC and RPC access."
            continue
        }
        try {
            [xml]$rsop = Get-Content $xmlPath -Raw
            $compResults = Get-ChildNodes $rsop.DocumentElement 'ComputerResults' | Select-Object -First 1
            foreach ($g in (Get-ChildNodes $compResults 'GPO')) {
                $applied = (Get-NodeText $g 'Enabled') -eq 'true' -and
                           (Get-NodeText $g 'IsValid') -eq 'true' -and
                           (Get-NodeText $g 'FilterAllowed') -eq 'true' -and
                           (Get-NodeText $g 'AccessDenied') -ne 'true'
                $rsopRows.Add([pscustomobject]@{
                    DC            = $dc.Name
                    GPO           = Get-NodeText $g 'Name'
                    Applied       = $applied
                    Enabled       = Get-NodeText $g 'Enabled'
                    FilterAllowed = Get-NodeText $g 'FilterAllowed'
                    AccessDenied  = Get-NodeText $g 'AccessDenied'
                    LinkedAt      = (Get-ChildNodes $g 'Link' | ForEach-Object { Get-NodeText $_ 'SOMPath' }) -join '; '
                })
            }
        }
        catch {
            Write-Warning "Could not parse RSoP from $($dc.HostName). Raw XML kept at $xmlPath. $($_.Exception.Message)"
        }
    }
    $rsopRows | Export-Csv (Join-Path $runFolder 'DC-AppliedPolicy.csv') -NoTypeInformation -Encoding UTF8
}

# --- Console summary ---------------------------------------------------------
$active = @($summary | Where-Object Active)
$inactive = @($summary | Where-Object { -not $_.Active })

Write-Host "`n=== $dns : $($summary.Count) GPOs, $($active.Count) active, $($inactive.Count) inactive ===" -ForegroundColor Green

Write-Host "`nACTIVE GPOs" -ForegroundColor Yellow
$active | Format-Table GPO, EnabledLinks, Enforced, ComputerSettings, UserSettings -AutoSize -Wrap

if ($inactive.Count) {
    Write-Host "INACTIVE GPOs (cleanup candidates, do not migrate)" -ForegroundColor Yellow
    $inactive | Format-Table GPO, Issues -AutoSize -Wrap
}

Write-Host "GPOs in effect on the Domain Controllers OU (precedence order)" -ForegroundColor Yellow
$dcInherited | Format-Table Order, DisplayName, Enforced, Target -AutoSize

if ($IncludeDCRsop -and $rsopRows.Count) {
    Write-Host "Applied on each DC (gpresult)" -ForegroundColor Yellow
    $rsopRows | Where-Object Applied | Format-Table DC, GPO, LinkedAt -AutoSize
}

$mismatch = @($summary | Where-Object ADSysvolMismatch)
if ($mismatch.Count) {
    Write-Warning "$($mismatch.Count) GPO(s) have AD and SYSVOL versions out of sync (possible replication problem): $(($mismatch.GPO) -join ', ')"
}

Write-Host "`nReports saved to $runFolder" -ForegroundColor Cyan
