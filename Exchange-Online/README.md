# Exchange Online

## Remove-OldMailboxMessages

[Remove-OldMailboxMessages.ps1](Remove-OldMailboxMessages.ps1)

For a mailbox that's gotten too big to clean up in Outlook. It deletes everything in the Inbox older than a date you pick, in batches of 20, and backs off when Microsoft throttles it.

```powershell
# count what would go, delete nothing
.\Remove-OldMailboxMessages.ps1 -Mailbox shared@contoso.com -CutoffUtc '2026-06-22T05:00:00Z' -DryRun

# do it (asks first)
.\Remove-OldMailboxMessages.ps1 -Mailbox shared@contoso.com -CutoffUtc '2026-06-22T05:00:00Z'
```

The dry run shows how many messages are in scope and the oldest and newest dates, so you can sanity check the cutoff before anything gets deleted. For around 70,000 messages, plan on one to three hours depending on throttling.

If you stop it partway (Ctrl+C is fine), just run it again. It asks the server what's left each time, so it picks up where it stopped.

It never writes subjects or message bodies to the screen or the log, only counts, dates and the IDs of anything that failed. That matters if the mailbox has anything sensitive in it.

Deleted mail goes to Recoverable Items, so you can still get it back during the retention period.

**Needs:** PowerShell 7, the Microsoft.Graph.Authentication module, and the delegated Mail.ReadWrite.Shared permission. Your admin account also needs Full Access to the mailbox. Give that 30 to 60 minutes to kick in after you grant it, or you'll get access denied errors.

---

[Back to the toolkit](../README.md)
