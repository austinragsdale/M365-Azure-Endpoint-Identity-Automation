# Security: FortiEDR Readiness

Read-only checks run on every device before moving to FortiEDR, to find what is known to make the agent unstable or cause blue screens. Each script prints one line per device so results are easy to combine across the fleet.

| Script | What it does | Changes anything? |
|---|---|---|
| [Test-FortiEDRReadiness](#test-fortiedrreadiness) | Checks a device for everything known to make the FortiEDR agent crash before a rollout (bad collector version, leftover SentinelOne drivers, conflicting security products, backup agents) and gives a BLOCK, WARN, or OK verdict. | READ-ONLY |
| [Get-FortiEDRUsbCrashRisk](#get-fortiedrusbcrashrisk) | Ranks devices by how likely they are to hit the FortiEDR USB blue-screen bug, based on USB history, card readers, and docks, so the riskiest machines get fixed first. | READ-ONLY |
| [Get-UsbDeviceInventory](#get-usbdeviceinventory) | A snapshot of the USB hardware plugged into a device right now: docks, card readers, dictation hardware, and storage. | READ-ONLY |

---

## Test-FortiEDRReadiness

**READ-ONLY** · [View script](Test-FortiEDRReadiness.ps1)

Checks a device for everything known to make the FortiEDR agent crash before a rollout (bad collector version, leftover SentinelOne drivers, conflicting security products, backup agents) and gives a BLOCK, WARN, or OK verdict.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** A read-only readiness check run on every device before moving from another EDR product (such as SentinelOne) to FortiEDR. Flags everything known to make the FortiEDR agent unstable or cause blue screens.

**How it works:** Checks each risk and outputs one line per device:
1. **Existing FortiEDR collector version**, read from the driver rather than the uninstall entry. Version 6.2.0.1437 crashes when USB storage is inserted; fixed in 6.2.0.1462.
2. **SentinelOne leftovers**, using three separate checks (installed product, service, loaded driver), because a clean uninstall can still leave the driver running.
3. **Other security products** with kernel filter drivers, read from fltmc so they show up even if the uninstall entry is gone. Two filter stacks on one machine cause conflicts.
4. **Backup agents** (FortiEDR bug 1315829, crashes during server backup).
5. **USB storage history**, since any device that has ever attached USB storage will hit the USB bug on collector 1437.
6. **Pending reboot**, OS build, and chassis type.
7. **Verdict:** BLOCK for anything that has caused a crash before, WARN for lesser risks, otherwise OK.

It never returns a non-zero exit code, because RMM tools treat that as a script failure.

**Inputs:** `-AsObject` for readable output instead of the one-line RMM format.

**Outputs:** One pipe-delimited line per device, easy to combine across the fleet.

**Requirements:** SYSTEM or administrator. Runs through an RMM tool.

**Changes anything?** READ-ONLY.

</details>

---

## Get-FortiEDRUsbCrashRisk

**READ-ONLY** · [View script](Get-FortiEDRUsbCrashRisk.ps1)

Ranks devices by how likely they are to hit the FortiEDR USB blue-screen bug, based on USB history, card readers, and docks, so the riskiest machines get fixed first.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Ranks devices by how soon they are likely to hit the FortiEDR USB blue-screen bug (1326457), so the riskiest machines are fixed first. Every device on collector 1437 is exposed; this sets the order of the fix waves.

**How it works:** Scores four signals, strongest first:
1. A USB disk attached right now (already at risk this session)
2. A card reader present (it loads at boot with no user action)
3. Days since USB storage was last attached (recent use predicts repeat use)
4. Number of different USB storage devices ever attached (a habit indicator)

It also detects docking stations. A docked machine is never ranked below MEDIUM, because a dock may be unplugged when the scan runs and is where drives and readers get plugged in. Only devices that create a disk (thumb drives, external disks, SD cards, dictation cradles) count, not phones.

**Inputs:** `-AsObject`.

**Outputs:** One line per device with the risk tier and supporting details. LOW does not mean safe; it means no recent history.

**Requirements:** Administrator or SYSTEM. Runs through an RMM tool.

**Changes anything?** READ-ONLY.

</details>

---

## Get-UsbDeviceInventory

**READ-ONLY** · [View script](Get-UsbDeviceInventory.ps1)

A snapshot of the USB hardware plugged into a device right now: docks, card readers, dictation hardware, and storage.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** A live snapshot of the USB hardware physically connected to a device at the moment it runs: docks, card readers, dictation hardware, and USB storage. A companion to Get-FortiEDRUsbCrashRisk.

**How it works:**
1. Reports only what is connected right now, not leftover registry entries.
2. Lists docks, card readers, and dictation devices. Dictation recorders in a cradle show up as USB storage; foot pedals and microphones do not.
3. Lists all USB storage currently attached.
4. Lists every USB device as a catch-all.
5. Adds the FortiEDR collector version so each result stands on its own.

It is a snapshot, so run it more than once during business hours.

**Inputs:** `-AsObject`, `-Csv`, `-WriteLocalCopy`, `-LocalPath`.

**Outputs:** One pipe-delimited line (or CSV) per device. Writes a local CSV only with `-WriteLocalCopy`.

**Requirements:** SYSTEM, through an RMM tool.

**Changes anything?** READ-ONLY, except the optional local CSV.

</details>

---

[Back to the toolkit](../../README.md)
