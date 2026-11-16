# Security

Scripts meant to run across a whole fleet through an RMM tool, as SYSTEM.

The [FortiEDR-Readiness](FortiEDR-Readiness/) folder has the checks I ran before moving machines to FortiEDR.

## Find-UnauthorizedScreenConnect

[Find-UnauthorizedScreenConnect.ps1](Find-UnauthorizedScreenConnect.ps1)

In 2026 there was a campaign where attackers installed their own ScreenConnect clients on MSP-managed machines, right next to the MSP's legitimate one. This is the hunt I wrote for it. It doesn't remove or stop anything. It just looks and reports.

You tell it which ScreenConnect instances are yours, and anything else gets flagged:

```powershell
.\Find-UnauthorizedScreenConnect.ps1 -AllowedThumbprints '0123456789abcdef' -AllowedRelayHosts 'instance-xxxxxx-relay.screenconnect.com'
```

Both parameters are required. If either is missing it stops with `RESULT: ERROR` instead of reporting every client as rogue.

The first line of output is the verdict, `RESULT: CLEAN`, `REVIEW`, `SUSPICIOUS` or `COMPROMISED`, followed by one line per finding. That makes it easy to sort a few hundred results in the RMM.

What it checks:

- ScreenConnect services, identified by the program file and not the display name (the rogue ones use convincing names). Also flags your own client being stopped or set to manual, which this campaign did.
- Installed programs, install folders, scheduled tasks (including event 4698 for tasks that were deleted afterwards), running processes and Run keys
- Temp folders, netsh portproxy rules, the hosts file, DNS cache and live connections to known bad infrastructure
- Defender exclusions for msiexec.exe and powershell.exe, which the attackers added
- AppLocker and software restriction rules aimed at ScreenConnect's temp folders, and MSI install history since the campaign started

Hash and filename matches only count as weak signals, because the attackers rebuilt their files for each victim. The check that really matters is "is there a ScreenConnect client here that isn't ours?"

Exit codes are 0 (clean), 1 (medium/high findings), 2 (critical) and 3 (script error). Add `-AlwaysExitZero` if a non-zero exit would stop the rest of your RMM workflow. `-SkipUserTempScan` speeds it up on machines with a lot of profiles.

**Don't run it through ScreenConnect's own Run Command.** Use your RMM. It needs Windows PowerShell 5.1 as SYSTEM, and relaunches itself as 64-bit if needed.

Indicators came from public write-ups by Huntress, ConnectWise, Sophos and Blackpoint.

---

[Back to the toolkit](../README.md)
