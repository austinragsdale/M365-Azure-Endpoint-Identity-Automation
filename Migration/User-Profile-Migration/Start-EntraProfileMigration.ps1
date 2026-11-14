<#
.SYNOPSIS
    Downloads a ForensiT User Profile Wizard migration package and runs it on the device.
    Deployed through an RMM tool, runs as SYSTEM.
.DESCRIPTION
    Cleans up state left by failed earlier attempts (the ForensiT "already migrated" flag,
    a stale extraction folder, and a previously applied migration provisioning package),
    downloads the package, checks its size, runs it, and logs every step.
    If your RMM tool cannot pass parameters, set the defaults in the param block.
.PARAMETER DownloadUrl
    Direct download URL for the migration package (.exe). Required.
.PARAMETER PackageName
    File name to save the package as.
.PARAMETER ProvisioningPackageName
    Wildcard matching a previously applied migration provisioning package to remove before
    re-running (for example '*Entra Migration*'). Leave empty to skip this step.
.PARAMETER MinimumSizeBytes
    Downloads smaller than this are treated as failed (for example an HTML error page).
.PARAMETER LogPath
    Log file path.
.EXAMPLE
    .\Start-EntraProfileMigration.ps1 -DownloadUrl 'https://example.com/Migrate-Entra.exe' -ProvisioningPackageName '*Entra Migration*'
.NOTES
    Author: Austin Ragsdale
    Windows PowerShell 5.1, SYSTEM context. Requires a ForensiT User Profile Wizard Corporate license
    and a configured migration package.
#>
param(
    [string]$DownloadUrl = '',
    [string]$PackageName = 'Migrate-Entra.exe',
    [string]$ProvisioningPackageName = '',
    [long]$MinimumSizeBytes = 1000000,
    [string]$LogPath = 'C:\ProgramData\ProfileMigration.log'
)

$ErrorActionPreference = 'Stop'

# ===============================
# TLS 1.2 Enforcement
# ===============================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===============================
# Logging Configuration
# ===============================

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"

    try {
        Add-Content -Path $LogPath -Value $LogEntry -Force -ErrorAction Stop
    }
    catch {
        Write-Output $LogEntry
    }

    Write-Output $LogEntry
}

# ===============================
# Installer details
# ===============================
$Location = $DownloadUrl
if (-not $Location) {
    Write-Log "No download URL. Pass -DownloadUrl or set its default at the top of the script." -Level ERROR
    exit 1
}

# Use ProgramData for SYSTEM context (persistent, not temp)
$PackageDir = "C:\ProgramData\ForensiT"
$PackageLocalPath = Join-Path $PackageDir $PackageName

# ===============================
# Pre-flight cleanup
# Clears the ForensiTMigrated flag + stale extraction folder + stale ppkg so
# the ForensiT script inside the package doesn't hit Read-Host on re-runs.
# ===============================
function Clear-MigrationState {
    Write-Log "Pre-flight cleanup: checking for stale migration state" -Level INFO

    # 1. ForensiT flag file (the Read-Host culprit)
    $flagPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'ForensiTMigrated'
    if (Test-Path $flagPath) {
        Write-Log "Stale flag found at $flagPath - removing" -Level INFO
        try {
            Remove-Item $flagPath -Force -ErrorAction Stop
            Write-Log "Flag removed" -Level SUCCESS
        }
        catch {
            Write-Log "Could not remove flag: $($_.Exception.Message)" -Level WARNING
        }
    } else {
        Write-Log "No stale flag file present" -Level INFO
    }

    # 2. Stale Migrate extraction folder from prior failed run
    if (Test-Path 'C:\ProgramData\ForensiT\Migrate') {
        Write-Log "Stale Migrate folder found - removing" -Level INFO
        try {
            Remove-Item 'C:\ProgramData\ForensiT\Migrate' -Recurse -Force -ErrorAction Stop
            Write-Log "Migrate folder removed" -Level SUCCESS
        }
        catch {
            Write-Log "Could not remove Migrate folder: $($_.Exception.Message)" -Level WARNING
        }
    }

    # 3. Previously-applied migration ppkg (if any)
    try {
        $stalePpkgs = Get-ProvisioningPackage -ErrorAction SilentlyContinue |
            Where-Object { $ProvisioningPackageName -and $_.PackageName -like $ProvisioningPackageName }
        foreach ($ppkg in $stalePpkgs) {
            Write-Log "Removing previously-applied ppkg: $($ppkg.PackageName) [$($ppkg.PackageID)]" -Level INFO
            try {
                Remove-ProvisioningPackage -PackageId $ppkg.PackageID -ErrorAction Stop | Out-Null
                Write-Log "Ppkg removed" -Level SUCCESS
            }
            catch {
                Write-Log "Could not remove ppkg: $($_.Exception.Message)" -Level WARNING
            }
        }
    }
    catch {
        Write-Log "Get-ProvisioningPackage not available on this system - skipping ppkg cleanup" -Level WARNING
    }
}

# ===============================
# Download function
# ===============================
function Download-FromURL ($URL, $LocalFilePath) {
    try {
        Write-Log "Starting download from: $URL" -Level INFO
        Write-Log "Target location: $LocalFilePath" -Level INFO

        # Ensure directory exists
        $dir = Split-Path $LocalFilePath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Write-Log "Created directory: $dir" -Level INFO
        }

        if (Test-Path $LocalFilePath) {
            Write-Log "Removing existing file at target location" -Level INFO
            Remove-Item -Path $LocalFilePath -Force
        }

        $WebClient = New-Object System.Net.WebClient
        $WebClient.Headers.Add("User-Agent", "PowerShell-Migration-Script")
        $WebClient.DownloadFile($URL, $LocalFilePath)

        if (-not (Test-Path $LocalFilePath)) {
            throw "Download failed: file not found"
        }

        $size = (Get-Item $LocalFilePath).Length
        Write-Log "Download completed. File size: $size bytes" -Level INFO

        # Reject downloads below the expected size (for example an HTML error page)
        if ($size -lt $MinimumSizeBytes) {
            throw "Downloaded file too small ($size bytes) - expected at least $MinimumSizeBytes bytes"
        }

        Write-Log "File size validation passed" -Level SUCCESS
    }
    catch {
        Write-Log "Download error: $($_.Exception.Message)" -Level ERROR
        throw "Download error: $($_.Exception.Message)"
    }
    finally {
        if ($WebClient) {
            $WebClient.Dispose()
        }
    }
}

# ===============================
# Execute EXE (WITH WAIT for proper tracking)
# ===============================
function Run-EXE ($Path) {
    try {
        Write-Log "Unblocking file: $Path" -Level INFO
        Unblock-File -Path $Path -ErrorAction SilentlyContinue
        Write-Log "File unblocked successfully" -Level SUCCESS

        Write-Log "Starting execution: $Path" -Level INFO
        Write-Log "Running as user: $env:USERNAME" -Level INFO
        Write-Log "NOTE: Migration will run and reboot the machine when complete" -Level INFO

        # Start the process and WAIT for it to complete
        # The ForensIT EXE will handle the migration and trigger a reboot
        $process = Start-Process -FilePath $Path -PassThru -Wait

        Write-Log "Process completed with exit code: $($process.ExitCode)" -Level INFO

        return $process.ExitCode
    }
    catch {
        Write-Log "Execution error: $($_.Exception.Message)" -Level ERROR
        throw "Execution error: $($_.Exception.Message)"
    }
}

# ===============================
# Main execution
# ===============================
Write-Log "========================================" -Level INFO
Write-Log "Script execution started" -Level INFO
Write-Log "Script version: 2.3 (V7 Package - flag cleanup + idempotent re-runs)" -Level INFO
Write-Log "PowerShell version: $($PSVersionTable.PSVersion)" -Level INFO
Write-Log "Operating System: $([System.Environment]::OSVersion.VersionString)" -Level INFO
Write-Log "Current user: $env:USERNAME" -Level INFO
Write-Log "Computer name: $env:COMPUTERNAME" -Level INFO
Write-Log "TLS protocol: $([Net.ServicePointManager]::SecurityProtocol)" -Level INFO
Write-Log "========================================" -Level INFO

try {
    Clear-MigrationState
    Download-FromURL $Location $PackageLocalPath
    $exitCode = Run-EXE $PackageLocalPath

    Write-Log "========================================" -Level INFO

    if ($exitCode -eq 0) {
        Write-Log "Migration package completed successfully (Exit Code: 0)" -Level SUCCESS
        Write-Log "Machine should reboot shortly to complete migration" -Level INFO
    }
    elseif ($exitCode -eq 3010) {
        Write-Log "Migration completed - Reboot required (Exit Code: 3010)" -Level SUCCESS
    }
    else {
        Write-Log "Migration package returned exit code: $exitCode" -Level WARNING
    }

    Write-Log "========================================" -Level INFO

    exit $exitCode
}
catch {
    Write-Log "========================================" -Level ERROR
    Write-Log "SCRIPT FAILED: $($_.Exception.Message)" -Level ERROR
    Write-Log "Error details: $($_.Exception)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    Write-Log "========================================" -Level ERROR

    Write-Error $_
    exit 1
}
