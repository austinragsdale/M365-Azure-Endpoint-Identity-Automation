# FortiEDR Readiness

Checks I ran on every machine before moving it from SentinelOne to FortiEDR. A few known problems make the FortiEDR agent crash or blue screen, and it's much better to find them before the rollout than after.

All three are read-only and run through an RMM tool as SYSTEM. Each one prints a single pipe-delimited line per device so you can paste a few hundred results into Excel and sort them. Add `-AsObject` if you're running one by hand and want readable output.

None of them ever return a non-zero exit code, because most RMM tools treat that as the script failing.

## Test-FortiEDRReadiness

[Test-FortiEDRReadiness.ps1](Test-FortiEDRReadiness.ps1)

The main check. Gives each device a **BLOCK**, **WARN** or **OK**.

- **Collector version.** 6.2.0.1437 blue screens when USB storage is plugged in. Fixed in 6.2.0.1462. It reads the version from the driver because the uninstall entry can be wrong.
- **SentinelOne leftovers.** Checks the installed product, the service and the loaded driver separately. A "clean" uninstall can still leave the driver running.
- **Other security products** with kernel filter drivers, read from `fltmc` so they show up even if their uninstall entry is gone. Two filter stacks on one machine is asking for trouble.
- **Backup agents.** FortiEDR bug 1315829 crashes during server backups.
- **USB storage history**, pending reboot, OS build and chassis type.

BLOCK means something on that machine has caused a crash before. Fix it first.

## Get-FortiEDRUsbCrashRisk

[Get-FortiEDRUsbCrashRisk.ps1](Get-FortiEDRUsbCrashRisk.ps1)

Every machine on collector 1437 is exposed to the USB blue screen bug (1326457). This ranks them by how soon they're likely to hit it, so you know which ones to fix first.

It scores, strongest signal first: a USB disk attached right now, a card reader (it loads at boot, no user action needed), how recently USB storage was last used, and how many different USB drives have ever been plugged in.

Docked laptops are never ranked below MEDIUM. The dock might be unplugged when the scan runs, but that's where people plug in drives and card readers. Only things that show up as a disk count (thumb drives, external disks, SD cards, dictation cradles). Phones don't.

LOW doesn't mean safe. It means there's no recent history.

## Get-UsbDeviceInventory

[Get-UsbDeviceInventory.ps1](Get-UsbDeviceInventory.ps1)

A snapshot of the USB hardware physically plugged in right now: docks, card readers, dictation hardware and storage. It goes with the crash risk script above. I used it to confirm what was really out there.

It only reports what's connected at that moment, so run it a few times during the workday. Dictation recorders sitting in a cradle show up as USB storage. Foot pedals and mics don't.

`-Csv` gives CSV output instead of a single line. `-WriteLocalCopy` also saves a CSV on the device.

---

[Back to Security](../README.md)
