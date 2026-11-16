# Automation Runbooks

Scheduled jobs for Azure Automation. They sign in with the Automation account's managed identity, so there's no password or client secret sitting anywhere.

## Sync-CompanyDirectoryContacts

[Sync-CompanyDirectoryContacts.ps1](Sync-CompanyDirectoryContacts.ps1)

Keeps a "Company Directory" contacts folder in everyone's mailbox in sync with the staff list in Entra ID. People get current coworker contacts on their phone and in Outlook without anyone maintaining a list by hand.

On each run it adds new staff, updates anyone whose details changed, and removes people who left. It only touches contacts it created itself. Each one is tagged with a hidden property holding the person's Entra object ID, so contacts a user added on their own never get changed or deleted.

**The permissions are the important part.** Don't grant Contacts.ReadWrite to the managed identity in Entra. That gives it every mailbox in the tenant. Grant it through **Exchange RBAC for Applications** with a management scope instead, so it can only reach the mailboxes you pick. The runbook doesn't decide who's in scope. It tests each mailbox and Exchange answers (200 = in scope, 403 = out of scope, 404 = no mailbox).

It's built so a mistake can't wipe out everyone's contacts:

- `-DryRun` is on by default. It logs what it would do and writes nothing. Set it to `$false` once you've read the output.
- It stops if it finds fewer than 15 staff (`-MinDirectorySize`), which usually means a permissions problem rather than a mass layoff.
- It won't remove more than 5 contacts from any one mailbox in a single run (`-MaxRemovalsPerMailbox`).
- Use `-PilotMailboxes` to try it on a few mailboxes first.
- It stops cleanly after 14 minutes (`-MaxRuntimeMinutes`) and the next run carries on.

It compares fields before updating, so contacts aren't rewritten on every run, and it retries throttling and temporary Graph errors (429, 502, 503, 504).

**Needs:** Azure Automation with the PowerShell 7.2 runtime (no extra modules). The managed identity needs User.Read.All as an Entra app role, plus Contacts.ReadWrite through Exchange RBAC for Applications as described above.

---

[Back to the toolkit](../README.md)
