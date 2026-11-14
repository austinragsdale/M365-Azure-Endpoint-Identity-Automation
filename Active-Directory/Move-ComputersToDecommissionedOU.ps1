<#
.SYNOPSIS
    Move computer objects into a decommissioned OU in Active Directory.

.DESCRIPTION
    This script moves computer objects to the OU given in -TargetOU (for example an OU outside
    Entra Connect sync scope) for hybrid to cloud-only migration.
    Run this script on a Domain Controller or a machine with RSAT AD tools installed.

    You can input devices by:
    - Passing device names as a parameter: -DeviceNames "PC1","PC2","PC3"
    - Entering them interactively when prompted

    Features:
    - Dry-run mode (-WhatIf) to preview actions without making changes
    - Confirmation prompts before each move
    - Detailed logging to file
    - Searches entire domain for computer objects (not just Computers OU)

.PARAMETER TargetOU
    Distinguished name of the OU to move computers into. Required.
    Example: "OU=Decommissioned Computers,DC=contoso,DC=com"

.PARAMETER DeviceNames
    Array of device names to move. If not provided, you'll be prompted to enter them.

.PARAMETER WhatIf
    Run in dry-run mode. Shows what would be moved without actually moving.

.PARAMETER LogPath
    Path for the log file. Defaults to script directory with timestamp.

.EXAMPLE
    .\Move-ComputersToDecommissionedOU.ps1 -TargetOU "OU=Decommissioned Computers,DC=contoso,DC=com" -WhatIf
    Enter devices interactively and preview what would be moved (dry-run mode)

.EXAMPLE
    .\Move-ComputersToDecommissionedOU.ps1 -TargetOU "OU=Decommissioned Computers,DC=contoso,DC=com" -DeviceNames "DESKTOP-ABC123","LAPTOP-XYZ789"
    Move specific devices with confirmation prompts

.EXAMPLE
    .\Move-ComputersToDecommissionedOU.ps1 -TargetOU "OU=Decommissioned Computers,DC=contoso,DC=com"
    Enter devices interactively and move with confirmation prompts

.NOTES
    Author: Austin Ragsdale
    Requires: ActiveDirectory PowerShell module (RSAT)
    Run on: Domain Controller or machine with RSAT AD tools
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetOU,

    [Parameter(Mandatory = $false)]
    [string[]]$DeviceNames,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $env:USERPROFILE "Downloads\ADDeviceMove_$(Get-Date -Format 'yyyyMMdd_HHmmss').log")
)

# Configuration
$DecommissionedOU = $TargetOU

#region Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'Info'    { Write-Host $logEntry -ForegroundColor Cyan }
        'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
        'Error'   { Write-Host $logEntry -ForegroundColor Red }
        'Success' { Write-Host $logEntry -ForegroundColor Green }
    }

    Add-Content -Path $LogPath -Value $logEntry
}

function Get-DeviceNamesFromUser {
    Write-Host ""
    Write-Host "Enter device names one per line." -ForegroundColor White
    Write-Host "When finished, type 'DONE' and press Enter." -ForegroundColor White
    Write-Host ""

    $devices = @()
    while ($true) {
        $userInput = Read-Host "Device name (or DONE to finish)"
        if ($userInput.ToUpper() -eq 'DONE') {
            break
        }
        if (-not [string]::IsNullOrWhiteSpace($userInput)) {
            $devices += $userInput.Trim()
            Write-Host "  Added: $($userInput.Trim())" -ForegroundColor Green
        }
    }
    return $devices
}

function Test-ADModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log "ActiveDirectory module not found. Please install RSAT or run on a Domain Controller." -Level Error
        return $false
    }
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    return $true
}

function Test-OUExists {
    param([string]$OUPath)

    try {
        $ou = Get-ADOrganizationalUnit -Identity $OUPath -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-ADComputerObject {
    param([string]$ComputerName)

    try {
        # Search entire domain for the computer using script block filter (safer than string interpolation)
        $computer = Get-ADComputer -Filter {Name -eq $ComputerName} -Properties DistinguishedName -ErrorAction Stop
        return $computer
    }
    catch {
        Write-Log "Error searching for computer '$ComputerName': $_" -Level Error
        return $null
    }
}

function Move-ComputerToDecommissioned {
    param(
        [Parameter(Mandatory)]
        $Computer,
        [string]$TargetOU,
        [switch]$WhatIf
    )

    $computerName = $Computer.Name
    $currentLocation = $Computer.DistinguishedName

    if ($WhatIf) {
        Write-Log "[WHATIF] Would move '$computerName' from:" -Level Warning
        Write-Log "[WHATIF]   $currentLocation" -Level Warning
        Write-Log "[WHATIF] To: $TargetOU" -Level Warning
        return $true
    }

    try {
        Move-ADObject -Identity $Computer.DistinguishedName -TargetPath $TargetOU -ErrorAction Stop
        Write-Log "Successfully moved '$computerName' to the target OU" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to move '$computerName': $_" -Level Error
        return $false
    }
}
#endregion

#region Main Script
Clear-Host
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  AD Device Move Script" -ForegroundColor Magenta
Write-Host "  Move to the target OU" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""

# Check if running in WhatIf mode
if ($WhatIfPreference) {
    Write-Host ">>> RUNNING IN DRY-RUN MODE (WhatIf) <<<" -ForegroundColor Yellow
    Write-Host ">>> No changes will be made <<<" -ForegroundColor Yellow
    Write-Host ""
}

# Initialize log file
Write-Log "Script started" -Level Info
Write-Log "Target OU: $DecommissionedOU" -Level Info
if ($WhatIfPreference) {
    Write-Log "Running in DRY-RUN mode (WhatIf)" -Level Warning
}

# Check for AD module
if (-not (Test-ADModule)) {
    exit 1
}

# Verify target OU exists
Write-Log "Verifying target OU exists..." -Level Info
if (-not (Test-OUExists -OUPath $DecommissionedOU)) {
    Write-Log "Target OU not found: $DecommissionedOU" -Level Error
    Write-Log "Please verify the OU path is correct." -Level Error
    exit 1
}
Write-Log "Target OU verified" -Level Success

# Get device names - either from parameter or interactive input
if (-not $DeviceNames -or $DeviceNames.Count -eq 0) {
    $DeviceNames = Get-DeviceNamesFromUser
}

if ($DeviceNames.Count -eq 0) {
    Write-Log "No devices specified. Exiting." -Level Warning
    exit 0
}

Write-Log "Loaded $($DeviceNames.Count) devices to process" -Level Info

# Display summary
Write-Host ""
Write-Host "Devices to process:" -ForegroundColor White
$DeviceNames | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host ""
Write-Host "Target OU: $DecommissionedOU" -ForegroundColor White
Write-Host ""

# Confirm before proceeding
if (-not $WhatIfPreference) {
    $confirm = Read-Host "Do you want to proceed with moving $($DeviceNames.Count) device(s)? (Y/N)"
    if ($confirm -ne 'Y') {
        Write-Log "Operation cancelled by user" -Level Warning
        exit 0
    }
}

# Process each device
$results = @{
    Moved = 0
    NotFound = 0
    AlreadyInOU = 0
    Failed = 0
}

foreach ($deviceName in $DeviceNames) {
    $deviceName = $deviceName.Trim()
    # Remove any trailing $ if user included it
    $deviceName = $deviceName.TrimEnd('$')

    Write-Host ""
    Write-Log "Processing device: $deviceName" -Level Info
    Write-Host ("-" * 50) -ForegroundColor DarkGray

    # Find the computer in AD
    Write-Log "Searching for computer in Active Directory..." -Level Info
    $computer = Get-ADComputerObject -ComputerName $deviceName

    if (-not $computer) {
        Write-Log "Computer '$deviceName' not found in Active Directory" -Level Warning
        $results.NotFound++
        continue
    }

    # Handle multiple matches - don't guess, require user to be specific
    if (@($computer).Count -gt 1) {
        Write-Log "ERROR: Found $(@($computer).Count) computers matching '$deviceName'" -Level Error
        foreach ($match in $computer) {
            Write-Log "  - $($match.DistinguishedName)" -Level Error
        }
        Write-Log "Cannot proceed - computer name is ambiguous. Please verify in AD." -Level Error
        $results.Failed++
        continue
    }

    Write-Log "Found computer: $($computer.Name)" -Level Info
    Write-Log "Current location: $($computer.DistinguishedName)" -Level Info

    # Check if already in decommissioned OU
    if ($computer.DistinguishedName -like "*$DecommissionedOU*") {
        Write-Log "Computer '$deviceName' is already in the target OU" -Level Warning
        $results.AlreadyInOU++
        continue
    }

    # Confirm move
    if (-not $WhatIfPreference) {
        Write-Host ""
        Write-Host "  Current: $($computer.DistinguishedName)" -ForegroundColor Gray
        Write-Host "  Target:  $DecommissionedOU" -ForegroundColor Gray
        $confirmMove = Read-Host "Move this computer to the target OU? (Y/N)"
        if ($confirmMove -ne 'Y') {
            Write-Log "Skipped move for $deviceName" -Level Warning
            continue
        }
    }

    # Move the computer
    if (Move-ComputerToDecommissioned -Computer $computer -TargetOU $DecommissionedOU -WhatIf:$WhatIfPreference) {
        $results.Moved++
    } else {
        $results.Failed++
    }
}

# Summary
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SUMMARY" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta

if ($WhatIfPreference) {
    Write-Host "  [DRY-RUN MODE - No changes were made]" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  AD COMPUTER MOVES:" -ForegroundColor White
Write-Host "    Moved:         $($results.Moved)" -ForegroundColor Green
Write-Host "    Not Found:     $($results.NotFound)" -ForegroundColor Yellow
Write-Host "    Already in OU: $($results.AlreadyInOU)" -ForegroundColor Cyan
Write-Host "    Failed:        $($results.Failed)" -ForegroundColor Red

Write-Host ""
Write-Log "Script completed. Log saved to: $LogPath" -Level Info
Write-Host ""
#endregion
