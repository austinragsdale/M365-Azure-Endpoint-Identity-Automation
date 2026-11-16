# Entra ID

User, group and license scripts I use for Entra ID. All of them go through Microsoft Graph, so connect with `Connect-MgGraph` first and give it only the scopes the script asks for.

| Script | What it's for |
|---|---|
| [Add-UsersToEntraGroup](Add-UsersToEntraGroup.ps1) | Bulk add users to a group from a list |
| [Resolve-UserUPNsFromNames](Resolve-UserUPNsFromNames.ps1) | Turn a list of names into UPNs |
| [Add-LicenseToUsers](Add-LicenseToUsers.ps1) | Assign a license to everyone in a spreadsheet |
| [Get-PasswordExpiryReport](Get-PasswordExpiryReport.ps1) | See who gets locked out before you turn on password expiration |

## Add-UsersToEntraGroup

The portal is fine for adding three people to a group. It's painful for 200. This takes a list of UPNs (typed in, a .txt file, or a .csv) and adds them, skipping anyone who's already a member.

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All","GroupMember.ReadWrite.All","User.Read.All"
.\Add-UsersToEntraGroup.ps1 -GroupName "App-Users" -UpnFile "C:\lists\app-users.txt" -WhatIf
```

Run it with `-WhatIf` first. It also prints the tenant and account you're connected to and asks before doing anything. If you work in more than one tenant, read that line.

A few things it handles so you don't have to:
- CSV files can use a column named UPN, UserPrincipalName, Email or EmailAddress
- If two groups have the same name it stops and lists them instead of guessing (use `-GroupId` then)
- It won't touch groups synced from on-prem AD, since those have to be changed in AD anyway

Writes a CSV log of every result to your Downloads folder.

## Resolve-UserUPNsFromNames

For when someone sends you a list of names instead of email addresses. HR and line-of-business app exports are the usual culprits, with names like "SMITH MR, JOHN A".

```powershell
Connect-MgGraph -Scopes "User.Read.All"
.\Resolve-UserUPNsFromNames.ps1 -NameFile "C:\lists\names.txt"
```

It handles "Last, First" and "First Last", strips titles like MR, and tries a few different Graph lookups until one works. Every name comes back as Resolved, Ambiguous or NotFound. At the end it prints the resolved UPNs as a block you can paste straight into Add-UsersToEntraGroup.

Check the Ambiguous ones by hand. Two John Smiths is a people problem, not a script problem.

Read-only.

## Add-LicenseToUsers

Assigns one license to every user in an Excel sheet. I built it for a batch of Exchange Online Plan 1 assignments, so that's the default. Pass a different SKU with `-SkuPartNumber` to use it for anything else.

```powershell
.\Add-LicenseToUsers.ps1 -Path "C:\Temp\users.xlsx" -UpnColumnNumber 3 -DryRun
```

You give it the column *number* instead of a header name. The sheet I was working from had two columns with the same header, and reading by position was the simplest way around it.

Before assigning anything it checks that you actually have enough licenses free. It sets usage location to US if it's blank (licensing fails without it; change it with `-UsageLocation`) and skips anyone who already has the license, so it's safe to re-run if it stops halfway.

Needs the ImportExcel module. It installs it if it's missing.

## Get-PasswordExpiryReport

Run this **before** you switch a tenant from "passwords never expire" to an expiration policy. The moment you flip that setting, anyone whose password is older than the new limit has to change it at their next sign-in. This tells you who that is ahead of time.

```powershell
.\Get-PasswordExpiryReport.ps1                     # 90 day policy, 14 day warning window
.\Get-PasswordExpiryReport.ps1 -ExpireDays 180
```

Each user lands in one of four buckets: **EXPIRED** (affected immediately), **AT-RISK** (affected in the next 14 days), **OK**, or **UNKNOWN** (no password date, check manually). Guests, disabled accounts and unlicensed accounts like shared mailboxes are left out.

The report also marks each account as cloud-only or synced, and that's the part people miss. If Entra Connect is doing password hash sync, the Entra expiration setting only applies to cloud-only accounts. Synced users still follow your on-prem AD password policy.

Read-only. Exports a CSV sorted worst-first.

---

[Back to the toolkit](../README.md)
