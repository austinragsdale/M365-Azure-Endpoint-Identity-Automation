# Intune

Split into three folders depending on where the script runs:

- [Admin](Admin/): run from your own machine against Graph. Reports, bulk changes, policy backups.
- [On-Device](On-Device/): pushed to devices through Intune or an RMM tool, runs as SYSTEM.
- [Autopilot](Autopilot/): grabbing hardware hashes, and a package that patches devices during pre-provisioning.

---

[Back to the toolkit](../README.md)
