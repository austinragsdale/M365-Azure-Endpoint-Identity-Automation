# Exchange Online

Mailbox administration through Microsoft Graph.

| Script | What it does | Changes anything? |
|---|---|---|
| [Remove-OldMailboxMessages](#remove-oldmailboxmessages) | Bulk deletes Inbox messages older than a cutoff date from an oversized mailbox. | WRITES, deletes (`-DryRun`) |

---

## Remove-OldMailboxMessages

**WRITES, deletes (`-DryRun`)** · [View script](Remove-OldMailboxMessages.ps1)

Bulk deletes Inbox messages older than a cutoff date from an oversized mailbox. Handles throttling, can be stopped and resumed, and never logs message content. Deleted items stay recoverable.

<details>
<summary><b>Full details: how it works, inputs, requirements</b></summary>

**Purpose:** Bulk deletes old messages from one mailbox's Inbox (everything received before a cutoff date) when the mailbox has grown too large to clean up normally.

**How it works:**
1. Connects to Graph with delegated access to the mailbox.
2. Counts every Inbox message received before the cutoff and shows the oldest and newest dates in scope. In `-DryRun` mode it stops here.
3. In delete mode, asks for confirmation, then fetches a page of messages and deletes them in Graph batch requests of 20, waiting and retrying when Microsoft throttles the requests.
4. Shows live progress and an estimated time remaining.
5. Never writes message subjects or bodies to the screen or the log, only counts, dates, and the IDs of failures. This keeps sensitive mailbox content out of logs.
6. Can be stopped with Ctrl+C and run again. It picks up where it left off, because each pass asks the server what is left.

Deleted messages go to Recoverable Items and can be restored during the mailbox's retention period.

**Inputs:** `-Mailbox` and `-CutoffUtc` (required), `-DryRun`, `-PageSize` (default 500).

**Outputs:** Log file and console progress.

**Requirements:** PowerShell 7. Module: Microsoft.Graph.Authentication. Delegated permission: Mail.ReadWrite.Shared. The signed-in admin needs Full Access to the mailbox (allow 30 to 60 minutes after granting it).

**Changes anything?** WRITES. Deletes messages (soft delete). Run with `-DryRun` first.

</details>

---

[Back to the toolkit](../README.md)
