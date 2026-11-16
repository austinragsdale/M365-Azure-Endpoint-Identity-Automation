# Conditional Access

A backup and restore pair for Conditional Access. Export a tenant's policies to JSON, keep them somewhere safe, and import them back when someone deletes a policy. You can also use them to stand up a new tenant from a set of policies you already trust.

## Export-ConditionalAccessPolicies

[Export-ConditionalAccessPolicies.ps1](Export-ConditionalAccessPolicies.ps1)

```powershell
Connect-MgGraph -Scopes "Policy.Read.All","Group.Read.All","User.Read.All","Application.Read.All"
.\Export-ConditionalAccessPolicies.ps1 -OutputPath C:\Backups\CA
```

You get a folder with:

- `Policies\`: one JSON file per policy
- `NamedLocations\`: one JSON file per named location
- `object-map.csv`: the name behind every group, user, location and app ID the policies reference

The JSON files are cleaned up so they can go straight back into Graph. Read-only fields are gone, and authentication strength is trimmed down to just its ID.

The object map matters if you're importing somewhere else. Group and user IDs are different in every tenant, so a raw policy export is full of IDs that mean nothing in the new tenant. The map lets the importer find the same objects by name.

Read-only.

## Import-ConditionalAccessPolicies

[Import-ConditionalAccessPolicies.ps1](Import-ConditionalAccessPolicies.ps1)

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Policy.Read.All","Group.Read.All","User.Read.All","Application.ReadWrite.All"

.\Import-ConditionalAccessPolicies.ps1 -Path C:\Backups\CA                                       # dry run
.\Import-ConditionalAccessPolicies.ps1 -Path C:\Backups\CA -Apply -CreateMissingServicePrincipals
```

Without `-Apply` it's a dry run. It reads the tenant and tells you what it would create, what already exists and what it can't resolve. With `-Apply` you have to type IMPORT to confirm (`-Force` skips that, for automation).

The rules it follows:

- **Everything is created report-only**, whatever state the file says. Check the sign-in logs, then turn policies on yourself. `-KeepExportedState` keeps the saved state if you really want that.
- **Nothing gets overwritten.** If a policy or named location with the same name exists, it's skipped. Safe to run again.
- **Group, user and location IDs get checked against the target tenant.** Any that don't exist get matched by name from `object-map.csv` (groups by display name, users by UPN). If something still can't be found, the whole policy is skipped and the missing objects are listed. I'd rather skip a policy than create one with a hole in its exclusions.

`-CreateMissingServicePrincipals` is there because of something I hit importing into a new tenant. Policies that target certain Microsoft apps (Azure DevOps and Microsoft Intune Enrollment, for example) fail with `ServicePrincipalNotFound`, because a fresh tenant doesn't have service principals for those apps yet. This switch creates them first.

Results also go to a CSV in the import folder.

It doesn't create custom authentication strengths, terms of use or authentication contexts. A policy that depends on one of those fails, and the Graph error ends up in the results CSV.

---

[Back to the toolkit](../README.md)
