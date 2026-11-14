# Export-AutopilotHardwareHash.ps1
# Run this at OOBE (Shift+F10) or on a configured device
# Captures Autopilot hardware hash and saves to USB drive
Write-Host "=== Autopilot Hardware ID Capture ===" -ForegroundColor Cyan
Write-Host ""
# Find the USB drive
$USBDrive = (Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.FileSystemLabel -ne 'SYSTEM' } | Select-Object -First 1).DriveLetter + ":"
if (-not $USBDrive -or $USBDrive -eq ":") {
    Write-Host "ERROR: No USB drive detected. Please insert USB and try again." -ForegroundColor Red
    pause
    exit 1
}
Write-Host "USB Drive detected: $USBDrive" -ForegroundColor Green
Write-Host ""
# Install NuGet provider if needed
Write-Host "Installing NuGet provider..." -ForegroundColor Yellow
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
# Set PSGallery as trusted
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
# Install the Get-WindowsAutopilotInfo script
Write-Host "Installing Get-WindowsAutopilotInfo script..." -ForegroundColor Yellow
Install-Script -Name Get-WindowsAutopilotInfo -Force -ErrorAction Stop
# Get device serial number for filename
$Serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
$Serial = $Serial -replace '[\/:*?"<>|]', '_'
# Export hardware hash to USB
$OutputFile = "$USBDrive\AutopilotHWID_$Serial.csv"
Write-Host ""
Write-Host "Capturing hardware hash for device: $Serial" -ForegroundColor Yellow
Write-Host "This may take a moment..." -ForegroundColor Yellow
Write-Host ""
Get-WindowsAutopilotInfo -OutputFile $OutputFile
if (Test-Path $OutputFile) {
    Write-Host ""
    Write-Host "SUCCESS! Hardware ID saved to:" -ForegroundColor Green
    Write-Host $OutputFile -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "1. Remove USB drive" -ForegroundColor White
    Write-Host "2. Go to Intune > Devices > Enrollment > Windows Autopilot devices" -ForegroundColor White
    Write-Host "3. Click Import and upload the CSV file" -ForegroundColor White
} else {
    Write-Host "ERROR: Failed to create output file." -ForegroundColor Red
}
Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
