# Conditional Access

Back up, restore and copy Conditional Access policies between tenants through Microsoft Graph.

| Script | What it does | Changes anything? |
|---|---|---|
| [Export-ConditionalAccessPolicies](#export-conditionalaccesspolicies) | Backs up every Conditional Access policy and named location to clean, import-ready JSON, with a map of every group, user and app the policies reference. | READ-ONLY |
| [Import-ConditionalAccessPolicies](#import-conditionalaccesspolicies) | Bulk-imports policies from JSON into the same or a different tenant, report-only, matching groups and users by name and never overwriting. | WRITES (dry run unless `-Apply`) |

Typical use: export from a tenant, keep the backup in source control, and import it to restore a deleted policy or to build a new tenant from a known-good policy set.

---

## Export-ConditionalAccessPolicies

**READ-ONLY** · [View script](Export-ConditionalAccessPolicies.ps1)

Backs up every Conditional Access policy and named location to clean, import-ready JSON, with a map of every group, user and app the policies reference.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** A complete, restorable backup of a tenant's Conditional Access configuration. The output is the input for Import-ConditionalAccessPolicies.

**How it works:**
1. Checks for a Graph connection.
2. Exports every named location to `NamedLocations\<name>.json`.
3. Exports every policy to `Policies\<name>.json`. Read-only fields (id, created and modified dates, templateId, `@odata.context`) and null values are removed, and authentication strength is reduced to its ID, so each file can be posted straight back to Graph.
4. Collects every group, user, named location and application ID the policies point to and looks up its name (group display name, user UPN, app display name).
5. Writes `object-map.csv` so the importer can match those objects by name in a tenant where the IDs are different.

**Inputs:** `-OutputPath` (default: `CA-Backup-<date-time>` in the current folder).

**Outputs:** A backup folder with `Policies\`, `NamedLocations\` and `object-map.csv`.

**Requirements:** Module: Microsoft.Graph.Authentication. Graph permissions: Policy.Read.All, Group.Read.All, User.Read.All, Application.Read.All.

**Changes anything?** READ-ONLY.

</details>

---

## Import-ConditionalAccessPolicies

**WRITES (dry run unless `-Apply`)** · [View script](Import-ConditionalAccessPolicies.ps1)

Bulk-imports policies from JSON into the same or a different tenant, report-only, matching groups and users by name and never overwriting.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Restore deleted or broken policies from a backup, or stand up a new tenant's Conditional Access from a tested policy set, without clicking through the portal one policy at a time.

**How it works:**
1. Without `-Apply` it is a dry run: it reads the tenant and reports what would be created, what already exists and what cannot be resolved. With `-Apply` you type IMPORT to confirm (or pass `-Force`).
2. Creates any named location that does not exist yet and maps the old location IDs to the new ones.
3. For each policy, checks every group, user, named location and application ID against the target tenant. An ID that is not found is matched by name using `object-map.csv` (groups by display name, users by UPN).
4. Skips a policy if any reference still cannot be resolved and lists what is missing, so a policy is never created with a hole in its include or exclude lists.
5. With `-CreateMissingServicePrincipals`, creates service principals for first-party Microsoft apps (such as Azure DevOps or Microsoft Intune Enrollment) that a new tenant does not have yet. Without them Graph rejects the policy with `ServicePrincipalNotFound`.
6. Creates each policy in report-only mode (unless `-KeepExportedState`), skips any name that already exists, and writes a results CSV.

**Inputs:** `-Path` (backup folder or a folder of policy JSON files), `-Apply`, `-Force`, `-KeepExportedState`, `-CreateMissingServicePrincipals`, `-SkipNamedLocations`.

**Outputs:** Console results by policy and `import-results-<date-time>.csv` in the import folder.

**Requirements:** Module: Microsoft.Graph.Authentication. Graph permissions: Policy.ReadWrite.ConditionalAccess, Policy.Read.All, Group.Read.All, User.Read.All, and Application.ReadWrite.All for `-CreateMissingServicePrincipals`. Role: Conditional Access Administrator.

**Changes anything?** WRITES: creates named locations, policies (report-only) and optionally service principals. Never modifies or deletes existing objects.

</details>

---

Coming next: drift detection against a saved baseline, an HTML policy report, and a break-glass exclusion check.

[Back to the toolkit](../README.md)
