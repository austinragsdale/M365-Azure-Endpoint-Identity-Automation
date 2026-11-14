# Intune Win32 app REQUIREMENT script. Do NOT put this inside the .intunewin package.
# Upload it on the app's Requirements tab as a script requirement:
#   Script name              : Test-DeviceInSetup.ps1
#   Run script as 32-bit      : No
#   Run this script using the logged on credentials : No  (System)
#   Enforce script signature check : No
#   Select output data type   : String
#   Operator                  : Equals
#   Value                     : InOOBE
#
# Purpose: make the app applicable ONLY while the device is still in OOBE / ESP. Without
# this, a broad assignment would run Windows Update on already-provisioned production
# machines. Belt and braces alongside assigning only to Intune-Autopilot-PreProvision,
# which matters here because that group is static and a wipe can land the device on a new
# Entra object and silently lose membership.

$signature = @"
using System;
using System.Runtime.InteropServices;
public static class OobeState {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int OOBEComplete(ref int isComplete);
}
"@

Add-Type -TypeDefinition $signature -Language CSharp

$isComplete = 0
[OobeState]::OOBEComplete([ref]$isComplete) | Out-Null

if ($isComplete -eq 0) { Write-Output 'InOOBE' } else { Write-Output 'Provisioned' }
exit 0
