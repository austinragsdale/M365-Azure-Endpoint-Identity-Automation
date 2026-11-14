# Automation Runbooks

Scheduled Azure Automation jobs that sign in with a managed identity, so no passwords or secrets are stored.

| Script | What it does | Changes anything? |
|---|---|---|
| [Sync-CompanyDirectoryContacts](#sync-companydirectorycontacts) | Scheduled Azure Automation job that keeps a "Company Directory" contacts folder in every mailbox matched to the current staff list. | WRITES, contacts only (dry run by default) |

---

## Sync-CompanyDirectoryContacts

**WRITES, contacts only (dry run by default)** · [View script](Sync-CompanyDirectoryContacts.ps1)

Scheduled Azure Automation job that keeps a "Company Directory" contacts folder in every mailbox matched to the current staff list. Uses a managed identity, only touches contacts it created, and has safety limits so a mistake cannot wipe anyone's contacts.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Keeps a "Company Directory" contacts folder in every staff mailbox matched to the current staff list in Entra ID, so everyone has up-to-date coworker contacts on their phone and in Outlook. Runs on a schedule in Azure Automation.

**How it works:**
1. Signs in with the Automation account's managed identity, so no passwords or secrets are stored.
2. Pulls enabled member accounts from Entra ID.
3. Tests each account's mailbox to see whether the runbook is allowed to write to it. Access is controlled by Exchange RBAC for Applications, not by the script: 200 means in scope, 403 means out of scope, 404 means no mailbox. Any other error stops the run.
4. Picks the target mailboxes: every in-scope mailbox, or only the mailboxes in `-PilotMailboxes` if set.
5. For each mailbox: finds or creates the "Company Directory" folder, then adds, updates, or removes contacts so the folder matches the staff list.
6. Only touches contacts it created. Each one is marked with a hidden property holding the person's Entra object ID, so contacts a user added by hand are never changed.
7. Compares fields before updating, and ignores internal X500 address formats, so contacts are not rewritten on every run.
8. Retries throttling and temporary Graph errors (429, 502, 503, 504).

**Safety features:**
- `-DryRun` is on by default: it logs planned changes and writes nothing
- Stops if fewer than `-MinDirectorySize` staff are found, so a permissions problem cannot wipe everyone's directory
- Skips removals in a mailbox if more than `-MaxRemovalsPerMailbox` contacts would be removed
- Stops cleanly after `-MaxRuntimeMinutes`, and the next run continues

**Inputs:** `-DryRun`, `-PilotMailboxes`, `-MinDirectorySize` (default 15), `-MaxRemovalsPerMailbox` (default 5), `-MaxRuntimeMinutes` (default 14).

**Outputs:** Runbook job output and logs.

**Requirements:** Azure Automation, PowerShell 7.2 runtime, no extra modules. Managed identity with User.Read.All (Entra app role) and Contacts.ReadWrite granted **only** through Exchange RBAC for Applications with a management scope. Granting Contacts.ReadWrite in Entra instead would give the runbook access to every mailbox in the tenant.

**Changes anything?** WRITES to mailboxes (contacts only). Dry run by default.

</details>

---

[Back to the toolkit](../README.md)
